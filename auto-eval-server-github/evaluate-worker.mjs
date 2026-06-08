#!/usr/bin/env node
/**
 * evaluate-worker.mjs — 评估作业工作器（子进程运行）
 *
 * 通过环境变量接收配置（绝不通过命令行参数传密码）：
 *   EVAL_USERNAME    学号
 *   EVAL_PASSWORD    密码
 *   EVAL_LOGIN_URL   教务系统地址（可选）
 *   EVAL_COMMENT     评价内容（可选）
 *   EVAL_JOB_ID      作业 ID（日志追踪用）
 *
 * 通过 stdout 输出 JSON Lines 格式的进度事件：
 *   {"type":"progress","step":"login","message":"登录中..."}
 *   {"type":"progress","step":"login_ok","message":"登录成功"}
 *
 * 最终结果：
 *   ---JOB_RESULT_START---
 *   {"success": 3, "failed": 0, ...}
 *   ---JOB_RESULT_END---
 */

import { request } from 'playwright';
import * as cheerio from 'cheerio';
import iconv from 'iconv-lite';
import sharp from 'sharp';
import Tesseract from 'tesseract.js';
import fs from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';

// ──────────── 安全：禁止密码出现在日志中 ────────────

const CONFIG = {
  username: process.env.EVAL_USERNAME || '',
  password: process.env.EVAL_PASSWORD || '',
  loginUrl: process.env.EVAL_LOGIN_URL || 'http://192.168.16.207/loginAction.do',
  captchaUrl: process.env.EVAL_CAPTCHA_URL || '',
  comment: process.env.EVAL_COMMENT || '老师授课认真负责，内容清晰，课堂组织良好。',
  answerStrategy: process.env.EVAL_STRATEGY || 'mostly_best',
  maxRetries: parseInt(process.env.EVAL_MAX_RETRIES || '5', 10)
};

// 如果没有传 loginUrl 里带 captcha 路径，自动拼接
if (!CONFIG.captchaUrl) {
  const base = CONFIG.loginUrl.substring(0, CONFIG.loginUrl.lastIndexOf('/') + 1);
  CONFIG.captchaUrl = `${base}validateCodeAction.do`;
}

const JOB_ID = process.env.EVAL_JOB_ID || 'unknown';

// ──────────── 日志工具 ────────────

function emit(type, step, message) {
  const event = JSON.stringify({ type, step, message, jobId: JOB_ID, timestamp: new Date().toISOString() });
  console.log(event);
}

function emitResult(result) {
  console.log('---JOB_RESULT_START---');
  console.log(JSON.stringify(result));
  console.log('---JOB_RESULT_END---');
}

function warn(...args) {
  console.error(`[${JOB_ID}]`, ...args);
}

// ──────────── 字符集工具 ────────────

function normalizeCharset(charset) {
  const v = String(charset || '').trim().toLowerCase();
  if (['gb2312', 'gb18030', 'gbk'].includes(v)) return 'gbk';
  return v || 'utf-8';
}

function detectCharset(buffer, headers) {
  const ct = headers['content-type'] || headers['Content-Type'] || '';
  const m = ct.match(/charset=([^;\s]+)/i);
  if (m) return normalizeCharset(m[1]);
  const preview = buffer.toString('ascii', 0, Math.min(buffer.length, 4096));
  const m2 = preview.match(/charset\s*=\s*["']?([^"'\s/>]+)/i);
  if (m2) return normalizeCharset(m2[1]);
  return 'utf-8';
}

async function readBody(response) {
  const body = await response.body();
  return iconv.decode(body, detectCharset(body, response.headers()));
}

function cleanText(v) {
  return String(v || '').replace(/\s+/g, ' ').trim();
}

function absUrl(raw, base) {
  return raw ? new URL(raw, base).toString() : '';
}

// ──────────── GBK 表单编码 ────────────

function gbkEncode(v) {
  const buf = iconv.encode(String(v ?? ''), 'gbk');
  let out = '';
  for (const b of buf) {
    if ((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) ||
        b === 0x2a || b === 0x2d || b === 0x2e || b === 0x5f) {
      out += String.fromCharCode(b);
    } else if (b === 0x20) {
      out += '+';
    } else {
      out += `%${b.toString(16).toUpperCase().padStart(2, '0')}`;
    }
  }
  return out;
}

function encodeForm(fields) {
  return Object.entries(fields).map(([k, v]) => `${gbkEncode(k)}=${gbkEncode(v)}`).join('&');
}

async function postGbk(api, url, fields, referer) {
  return api.post(url, {
    data: Buffer.from(encodeForm(fields), 'ascii'),
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Referer: referer }
  });
}

// ──────────── HTML 解析 ────────────

function parseHiddenFields(html) {
  const $ = cheerio.load(html);
  const fields = {};
  $('form[name="loginForm"] input').each((_, el) => {
    const name = $(el).attr('name');
    if (name) fields[name] = $(el).attr('value') || '';
  });
  return fields;
}

function parseEvalList(html, pageUrl, formName) {
  const $ = cheerio.load(html);
  const form = $(`form[name="${formName}"]`).first();
  const formInfo = form.length
    ? { action: absUrl(form.attr('action'), pageUrl), method: form.attr('method') || 'post' }
    : null;

  const items = $('img').toArray()
    .filter(el => {
      const img = $(el);
      return (img.attr('name') || '').includes('#@') || (img.attr('onclick') || '').includes('evaluation');
    })
    .map((el, idx) => {
      const img = $(el);
      const row = img.closest('tr');
      const cells = row.find('td,th').toArray().map(c => cleanText($(c).text()));
      const rawName = img.attr('name') || '';
      const parts = rawName.split('#@');
      const status = cells.find(c => c === '是' || c === '否') || '';
      return {
        index: idx, cells, status,
        pending: status === '否',
        done: status === '是',
        wjbm: parts[0] || '', bpr: parts[1] || '',
        bprm: parts[2] || cells[1] || '',
        wjmc: parts[3] || cells[0] || '',
        pgnrm: parts[4] || '', pgnr: parts[5] || '',
        courseName: cells[2] || parts[5] || ''
      };
    });

  return { formInfo, items, pendingCount: items.filter(i => i.pending).length, doneCount: items.filter(i => i.done).length };
}

// ──────────── OCR ────────────

async function ocrCaptcha(buf) {
  const { width, height } = await sharp(buf).metadata();
  const pp = await sharp(buf)
    .grayscale().normalize().threshold(128)
    .resize({ width: width * 3, height: height * 3, kernel: 'nearest' })
    .png().toBuffer();
  const { data } = await Tesseract.recognize(pp, 'eng', {
    tessedit_char_whitelist: '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
  });
  return data.text.replace(/\s/g, '');
}

// ──────────── 登录（含 OCR 重试） ────────────

async function login(api) {
  emit('progress', 'login', '正在获取登录页面...');

  for (let attempt = 1; attempt <= CONFIG.maxRetries; attempt++) {
    if (attempt > 1) {
      emit('progress', 'login_retry', `验证码识别失败，第 ${attempt} 次重试...`);
    }

    // 1. 获取登录页 hidden fields
    const loginRes = await api.get(CONFIG.loginUrl);
    const loginHtml = await readBody(loginRes);
    const fields = parseHiddenFields(loginHtml);

    // 2. 获取验证码
    const captchaUrl = `${absUrl(CONFIG.captchaUrl, CONFIG.loginUrl)}?random=${Math.random()}`;
    const captchaRes = await api.get(captchaUrl, { headers: { Referer: CONFIG.loginUrl } });
    const captchaBody = await captchaRes.body();

    // 3. OCR
    const captchaText = await ocrCaptcha(captchaBody);
    emit('progress', 'ocr', `验证码识别结果: ${captchaText}`);

    // 4. 提交登录
    const form = { ...fields, zjh: CONFIG.username, mm: CONFIG.password, v_yzm: captchaText.trim() };
    const loginResp = await api.post(CONFIG.loginUrl, { form, headers: { Referer: CONFIG.loginUrl } });
    const resultHtml = await readBody(loginResp);
    const resultText = cleanText(cheerio.load(resultHtml)('body').text());

    // 5. 检查结果
    const failed =
      /验证码错误|验证码不正确|请输入验证码/.test(resultText) &&
      !/当前用户|注销|安全退出|首页/.test(resultText);
    const authFailed = /密码错误|帐号不存在|账号不存在|用户名或密码错误/.test(resultText);

    if (authFailed) {
      emit('progress', 'login_failed', '❌ 账号或密码错误');
      return { ok: false, error: '账号或密码错误' };
    }

    if (!failed) {
      emit('progress', 'login_ok', '✅ 登录成功');
      return { ok: true };
    }
  }

  emit('progress', 'login_failed', `❌ 验证码识别失败 ${CONFIG.maxRetries} 次`);
  return { ok: false, error: `验证码识别失败 ${CONFIG.maxRetries} 次` };
}

// ──────────── 评估表单操作 ────────────

function parseEvalForm(html, pageUrl) {
  const $ = cheerio.load(html);
  const form = $('form[name="StDaForm"]').first();
  const info = { action: absUrl(form.attr('action') || pageUrl, pageUrl), method: form.attr('method') || 'post' };

  const hidden = {};
  form.find('input[type="hidden"]').each((_, el) => {
    const name = $(el).attr('name');
    if (name) hidden[name] = $(el).attr('value') || '';
  });

  const radioGroups = {};
  form.find('input[type="radio"]').each((_, el) => {
    const r = $(el);
    const name = r.attr('name') || '';
    if (!name) return;
    (radioGroups[name] ||= []).push({ id: r.attr('id') || '', value: r.attr('value') || '' });
  });

  const textareas = form.find('textarea').toArray().map(el => $(el).attr('name') || '').filter(Boolean);
  return { info, hidden, radioGroups, textareas };
}

function pickAnswers(groups, strategy) {
  const entries = Object.entries(groups);
  const answers = {};
  entries.forEach(([name, options], idx) => {
    const best = options.find(o => o.id === '1') || options[0];
    const second = options.find(o => o.id === '2') || options[1] || best;
    answers[name] = strategy === 'all_best' ? best.value : (idx === entries.length - 1 ? second.value : best.value);
  });
  return answers;
}

function buildPayload(form, comment) {
  return {
    ...form.hidden,
    ...pickAnswers(form.radioGroups, CONFIG.answerStrategy),
    xumanyzg: 'zg',
    ...Object.fromEntries(form.textareas.map(n => [n, (comment || CONFIG.comment || '').slice(0, 100)]))
  };
}

function itemKey(item) {
  return `${item.wjbm}::${item.bpr}::${item.pgnr}`;
}

// ──────────── 获取评估列表 ────────────

async function fetchList(api) {
  const listUrls = [
    CONFIG.loginUrl.replace(/loginAction\.do.*$/, '') + 'jxpgXsAction.do?oper=listWj',
    CONFIG.loginUrl.replace(/loginAction\.do.*$/, '') + 'ggglAction.do?actionType=5',
    ...(process.env.EVAL_LIST_URLS ? process.env.EVAL_LIST_URLS.split(',') : [])
  ];

  for (const rawUrl of listUrls) {
    const url = absUrl(rawUrl, CONFIG.loginUrl);
    try {
      const res = await api.get(url, { headers: { Referer: CONFIG.loginUrl } });
      const html = await readBody(res);
      const result = parseEvalList(html, url, 'WjList');
      if (result.formInfo || result.items.length) return result;
    } catch (e) {
      warn(`获取列表失败: ${url}`, e.message);
    }
  }
  return null;
}

// ──────────── 提交单个评估 ────────────

async function submitOne(api, list, item, seq) {
  const formUrl = absUrl(list.formInfo.action, list.pageUrl);
  const showData = {
    wjbm: item.wjbm, bpr: item.bpr, bprm: item.bprm, wjmc: item.wjmc,
    pgnrm: item.pgnrm, pgnr: item.pgnr, wjbz: 'null', oper: 'wjShow'
  };
  const showRes = await postGbk(api, formUrl, showData, list.pageUrl);
  const showHtml = await readBody(showRes);
  const form = parseEvalForm(showHtml, formUrl);
  const payload = buildPayload(form, CONFIG.comment);

  const submitRes = await postGbk(api, form.info.action, payload, formUrl);
  const submitHtml = await readBody(submitRes);

  // 提交后校验
  const afterList = await fetchList(api);
  const afterItem = afterList?.items.find(i => itemKey(i) === itemKey(item));
  const ok = afterItem && afterItem.status === '是';

  return { ok, courseName: item.courseName, teacher: item.bprm };
}

// ──────────── 主流程 ────────────

async function main() {
  emit('progress', 'init', '评估工作器启动...');

  if (!CONFIG.username || !CONFIG.password) {
    emit('progress', 'error', '❌ 未提供账号密码');
    emitResult({ success: 0, failed: 1, error: '未提供账号密码' });
    process.exit(1);
  }

  // 创建临时目录
  const artifactsDir = path.join(process.cwd(), 'artifacts');
  await fs.mkdir(artifactsDir, { recursive: true });

  // 初始化 Playwright API
  const api = await request.newContext();

  // ── 阶段 1: 登录 ──
  emit('progress', 'login', '🔐 正在登录教务系统...');
  const loginResult = await login(api);

  if (!loginResult.ok) {
    emit('progress', 'error', `❌ ${loginResult.error}`);
    emitResult({ success: 0, failed: 0, error: loginResult.error });
    await api.dispose();
    process.exit(0);
  }

  // ── 阶段 2: 获取列表 ──
  emit('progress', 'fetching', '📋 正在获取评估列表...');
  const list = await fetchList(api);
  if (!list || !list.formInfo) {
    emit('progress', 'error', '❌ 无法获取评估列表，可能是 session 过期或地址不对');
    emitResult({ success: 0, failed: 0, error: '无法获取评估列表' });
    await api.dispose();
    process.exit(0);
  }

  emit('progress', 'list', `📋 待评估: ${list.pendingCount}  已完成: ${list.doneCount}`);

  if (list.pendingCount === 0) {
    emit('progress', 'done', '✅ 没有待评估项');
    emitResult({ success: 0, failed: 0, pendingCount: 0 });
    await api.dispose();
    process.exit(0);
  }

  // ── 阶段 3: 批量提交 ──
  const pendingItems = list.items.filter(i => i.pending);
  let success = 0;
  let failed = 0;
  const details = [];

  emit('progress', 'submitting', `🚀 开始提交 ${pendingItems.length} 项评估...`);

  for (let i = 0; i < pendingItems.length; i++) {
    const item = pendingItems[i];
    const seq = `${i + 1}/${pendingItems.length}`;

    // 重新获取最新列表
    const freshList = await fetchList(api);
    const freshItem = freshList?.items.find(it => it.pending && itemKey(it) === itemKey(item));

    if (!freshItem) {
      emit('progress', 'skip', `⏭️  [${seq}] ${item.courseName} — 已不在待评估列表`);
      details.push({ course: item.courseName, teacher: item.bprm, status: 'skipped' });
      continue;
    }

    emit('progress', 'submitting', `📝 [${seq}] 正在提交: ${item.courseName}`);
    const result = await submitOne(api, freshList, freshItem, seq);

    if (result.ok) {
      emit('progress', 'submit_ok', `✅ [${seq}] ${result.courseName} — 提交成功`);
      success++;
      details.push({ course: result.courseName, teacher: result.teacher, status: 'success' });
    } else {
      emit('progress', 'submit_fail', `❌ [${seq}] ${result.courseName} — 提交失败`);
      failed++;
      details.push({ course: result.courseName, teacher: result.teacher, status: 'failed' });
    }
  }

  // ── 最终结果 ──
  const finalList = await fetchList(api);
  emit('progress', 'done', `✅ 全部完成！成功: ${success}, 失败: ${failed}`);

  emitResult({
    success,
    failed,
    total: pendingItems.length,
    pendingAfter: finalList?.pendingCount ?? 'unknown',
    doneAfter: finalList?.doneCount ?? 'unknown',
    details
  });

  await api.dispose();
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => {
  emit('progress', 'error', `❌ 脚本异常: ${err.message}`);
  emitResult({ success: 0, failed: 0, error: err.message });
  process.exit(1);
});
