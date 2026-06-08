#!/bin/bash
set -e

# ═══════════════════════════════════════════
# 教学评估 Web 服务 — 自解压安装脚本
# 在服务器上以 root 运行:
#   wget -qO- https://raw.githubusercontent.com/xxx/xxx/main/deploy/install.sh | bash
#   或直接 bash install.sh
# ═══════════════════════════════════════════

APP_DIR="/opt/auto-eval-web"

echo "========================================"
echo "  教学评估 Web 服务 — 安装"
echo "  域名: rimurutempest.me"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请以 root 运行"
  exit 1
fi

# ── 创建目录 ──
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# ── 安装系统依赖 ──
echo "[1/6] 📦 安装系统依赖..."
apt update -qq && apt install -y -qq tesseract-ocr tesseract-ocr-eng nginx certbot python3-certbot-nginx nodejs npm 2>/dev/null || true

# ── 创建项目文件 ──
echo "[2/6] 📝 创建项目文件..."

# 如果当前目录是空的才创建（避免覆盖已有代码）
if [ ! -f "$APP_DIR/package.json" ]; then
  mkdir -p scripts public deploy

  # package.json
  cat > package.json << 'PKGJSON'
{
  "name": "auto-eval-server",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "教学评估自动提交 Web 服务",
  "scripts": {
    "start": "node server.mjs",
    "prod": "NODE_ENV=production node server.mjs"
  },
  "dependencies": {
    "cheerio": "^1.0.0",
    "express": "^4.21.0",
    "express-rate-limit": "^7.4.0",
    "helmet": "^7.1.0",
    "iconv-lite": "^0.6.3",
    "playwright": "^1.52.0",
    "sharp": "^0.34.5",
    "tesseract.js": "^7.0.0"
  }
}
PKGJSON

  # .gitignore
  cat > .gitignore << 'GITIGNORE'
node_modules/
tmp/
.session.json
artifacts/
.env
*.log
GITIGNORE

  # deploy/auto-eval-web.service
  cat > deploy/auto-eval-web.service << 'SERVICE'
[Unit]
Description=教学评估自动提交 Web 服务
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/auto-eval-web
ExecStart=/usr/bin/node /opt/auto-eval-web/server.mjs
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOST=0.0.0.0
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/auto-eval-web/tmp

[Install]
WantedBy=multi-user.target
SERVICE

  echo "  ✅ 配置文件已创建"
else
  echo "  ⏭️  package.json 已存在，跳过文件创建"
fi

# ── 安装 Node 依赖 ──
echo "[3/6] 📥 安装 Node 依赖..."
cd "$APP_DIR"
npm install --omit=dev --quiet 2>/dev/null || npm install --omit=dev
npx playwright install chromium 2>&1 | tail -3
mkdir -p tmp

# ── 下载 server.mjs ──
echo "[4/6] 📥 下载后端服务..."

# server.mjs
cat > server.mjs << 'SERVERJS'
import express from 'express';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '0.0.0.0';
const NODE_ENV = process.env.NODE_ENV || 'development';
const JOB_TIMEOUT_MS = parseInt(process.env.JOB_TIMEOUT || '600000', 10);
const MAX_LOG_LENGTH = parseInt(process.env.MAX_LOG_LENGTH || '20000', 10);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, 'public');
const SCRIPTS_DIR = path.join(__dirname, 'scripts');
const WORKER_SCRIPT = path.join(SCRIPTS_DIR, 'evaluate-worker.mjs');

const jobs = new Map();

function createJob() {
  const id = randomUUID();
  const job = { id, status: 'pending', progress: [], result: null, error: null, createdAt: Date.now(), child: null, timeout: null, tempDir: null };
  jobs.set(id, job);
  return job;
}

function addProgress(job, step, message) {
  job.progress.push({ step, message, timestamp: new Date().toISOString() });
}

const app = express();
app.use(helmet({ contentSecurityPolicy: NODE_ENV === 'production' ? undefined : false, crossOriginEmbedderPolicy: false }));

const evalLimiter = rateLimit({ windowMs: 60 * 1000, max: 10, standardHeaders: true, legacyHeaders: false, message: { error: '请求过于频繁，请稍后再试。' } });

app.use(express.json({ limit: '10kb' }));
app.use(express.static(PUBLIC_DIR, { maxAge: NODE_ENV === 'production' ? '1h' : 0 }));

app.post('/api/evaluate', evalLimiter, async (req, res) => {
  const { username, password, loginUrl, comment } = req.body;
  const errors = [];
  if (!username || typeof username !== 'string' || !username.trim()) errors.push('请输入学号');
  if (!password || typeof password !== 'string' || !password) errors.push('请输入密码');
  if (password && password.length > 128) errors.push('密码过长');
  if (username && !/^[\w@.\-]+$/.test(username.trim())) errors.push('学号格式不正确');
  if (loginUrl && typeof loginUrl === 'string' && loginUrl.length > 0) { try { new URL(loginUrl); } catch { errors.push('教务系统地址格式不正确'); } }
  if (comment && (typeof comment !== 'string' || comment.length > 200)) errors.push('评价内容过长');
  if (errors.length > 0) return res.status(400).json({ error: errors.join('；') });

  const job = createJob();
  const tempDir = path.join(__dirname, 'tmp', job.id);
  await fs.mkdir(tempDir, { recursive: true });
  job.tempDir = tempDir;

  const child = spawn(process.execPath, [WORKER_SCRIPT], {
    cwd: tempDir, stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, EVAL_USERNAME: username.trim(), EVAL_PASSWORD: password, EVAL_LOGIN_URL: (loginUrl || '').trim() || undefined, EVAL_COMMENT: (comment || '').trim() || undefined, EVAL_JOB_ID: job.id, NODE_ENV: 'production' },
    timeout: JOB_TIMEOUT_MS
  });

  job.child = child;
  job.status = 'running';
  addProgress(job, 'started', '评估作业已启动...');

  let stdoutBuffer = '', stderrBuffer = '';
  child.stdout.on('data', (chunk) => {
    const text = chunk.toString('utf8');
    stdoutBuffer += text;
    if (stdoutBuffer.length > MAX_LOG_LENGTH) stdoutBuffer = stdoutBuffer.slice(-MAX_LOG_LENGTH);
    for (const line of text.split('\n').filter(Boolean)) {
      try { const event = JSON.parse(line); if (event.type === 'progress') addProgress(job, event.step, event.message); } catch {}
    }
  });

  child.stderr.on('data', (chunk) => {
    stderrBuffer += chunk.toString('utf8');
    if (stderrBuffer.length > MAX_LOG_LENGTH) stderrBuffer = stderrBuffer.slice(-MAX_LOG_LENGTH);
  });

  child.on('error', (err) => { job.status = 'failed'; job.error = `进程启动失败: ${err.message}`; addProgress(job, 'error', job.error); cleanupJob(job); });
  child.on('exit', async (code, signal) => {
    clearTimeout(job.timeout);
    if (signal === 'SIGTERM') { job.status = 'timeout'; job.error = '评估作业超时已被终止'; addProgress(job, 'timeout', job.error); }
    else if (code === 0) {
      job.status = 'completed'; addProgress(job, 'completed', '评估作业已完成');
      const resultMatch = stdoutBuffer.match(/---JOB_RESULT_START---\n([\s\S]*?)\n---JOB_RESULT_END---/);
      if (resultMatch) { try { job.result = JSON.parse(resultMatch[1]); } catch { job.result = { raw: resultMatch[1] }; } }
    } else { job.status = 'failed'; const lastStderr = stderrBuffer.slice(-500); job.error = lastStderr ? `进程异常退出 (code: ${code})\n${lastStderr}` : `进程异常退出 (code: ${code})`; addProgress(job, 'error', job.error); }
    await cleanupJob(job);
  });

  job.timeout = setTimeout(() => { if (job.child && !job.child.killed) { job.child.kill('SIGTERM'); setTimeout(() => { if (job.child && !job.child.killed) job.child.kill('SIGKILL'); }, 2000); } }, JOB_TIMEOUT_MS);

  res.json({ jobId: job.id, status: 'running', message: '评估作业已启动' });
  console.log(`[eval] job=${job.id} username=${username} status=running`);
});

app.get('/api/evaluate/:jobId', (req, res) => {
  const job = jobs.get(req.params.jobId);
  if (!job) return res.status(404).json({ error: '作业不存在' });
  res.json({ id: job.id, status: job.status, progress: job.progress, result: job.result, error: job.error, createdAt: job.createdAt });
});

app.get('/api/evaluate/:jobId/stream', (req, res) => {
  const job = jobs.get(req.params.jobId);
  if (!job) return res.status(404).json({ error: '作业不存在' });
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no' });
  for (const p of job.progress) res.write(`data: ${JSON.stringify({ type: 'progress', ...p })}\n\n`);
  if (job.status !== 'pending' && job.status !== 'running') { res.write(`data: ${JSON.stringify({ type: 'status', status: job.status, result: job.result, error: job.error })}\n\n`); res.end(); return; }
  const interval = setInterval(() => {
    res.write(`data: ${JSON.stringify({ type: 'progress', progress: job.progress.slice(-1)[0] })}\n\n`);
    if (job.status !== 'pending' && job.status !== 'running') { clearInterval(interval); res.write(`data: ${JSON.stringify({ type: 'status', status: job.status, result: job.result, error: job.error })}\n\n`); res.end(); }
  }, 1000);
  req.on('close', () => clearInterval(interval));
});

app.get('/api/health', (req, res) => { res.json({ status: 'ok', uptime: process.uptime(), activeJobs: Array.from(jobs.values()).filter(j => j.status === 'running').length, totalJobs: jobs.size }); });
app.use((req, res) => { res.status(404).json({ error: 'Not found' }); });
app.use((err, req, res, _next) => { console.error('[error]', err.message); res.status(500).json({ error: NODE_ENV === 'production' ? '服务器内部错误' : err.message }); });

async function cleanupJob(job) {
  if (job.tempDir) { try { await fs.rm(job.tempDir, { recursive: true, force: true }); } catch {} job.tempDir = null; }
}

setInterval(() => {
  const now = Date.now();
  for (const [id, job] of jobs) {
    if (now - job.createdAt > 2 * 60 * 60 * 1000) { if (job.child && !job.child.killed) job.child.kill('SIGKILL'); cleanupJob(job); jobs.delete(id); }
  }
}, 60 * 60 * 1000);

createServer(app).listen(PORT, HOST, () => {
  console.log(`\n  ╔═════════════════════════════════════╗`);
  console.log(`  ║   教学评估 Web 服务                    ║`);
  console.log(`  ║   地址: http://${HOST}:${PORT}            ║`);
  console.log(`  ║   模式: ${NODE_ENV}                         ║`);
  console.log(`  ╚═════════════════════════════════════╝\n`);
});
SERVERJS
echo "  ✅ server.mjs"

# ── 下载 evaluate-worker.mjs ──
cat > scripts/evaluate-worker.mjs << 'WORKERJS'
#!/usr/bin/env node
import { request } from 'playwright';
import * as cheerio from 'cheerio';
import iconv from 'iconv-lite';
import sharp from 'sharp';
import Tesseract from 'tesseract.js';
import fs from 'node:fs/promises';
import path from 'node:path';

const CONFIG = {
  username: process.env.EVAL_USERNAME || '',
  password: process.env.EVAL_PASSWORD || '',
  loginUrl: process.env.EVAL_LOGIN_URL || 'http://192.168.16.207/loginAction.do',
  comment: process.env.EVAL_COMMENT || '老师授课认真负责，内容清晰，课堂组织良好。',
  answerStrategy: process.env.EVAL_STRATEGY || 'mostly_best',
  maxRetries: parseInt(process.env.EVAL_MAX_RETRIES || '5', 10)
};

if (!CONFIG.loginUrl.includes('validateCodeAction')) {
  const base = CONFIG.loginUrl.substring(0, CONFIG.loginUrl.lastIndexOf('/') + 1);
  CONFIG.captchaUrl = `${base}validateCodeAction.do`;
}

const JOB_ID = process.env.EVAL_JOB_ID || 'unknown';

function emit(type, step, message) {
  console.log(JSON.stringify({ type, step, message, jobId: JOB_ID, timestamp: new Date().toISOString() }));
}
function emitResult(r) { console.log('---JOB_RESULT_START---\n' + JSON.stringify(r) + '\n---JOB_RESULT_END---'); }

function normalizeCharset(v) { const c = String(v || '').trim().toLowerCase(); if (['gb2312','gb18030','gbk'].includes(c)) return 'gbk'; return c || 'utf-8'; }
function detectCharset(buf, hdrs) {
  const ct = hdrs['content-type'] || hdrs['Content-Type'] || '';
  const m = ct.match(/charset=([^;\s]+)/i); if (m) return normalizeCharset(m[1]);
  const pv = buf.toString('ascii', 0, Math.min(buf.length, 4096));
  const m2 = pv.match(/charset\s*=\s*["']?([^"'\s/>]+)/i); if (m2) return normalizeCharset(m2[1]);
  return 'utf-8';
}
async function readBody(r) { const b = await r.body(); return iconv.decode(b, detectCharset(b, r.headers())); }
function cleanText(v) { return String(v || '').replace(/\s+/g, ' ').trim(); }
function absUrl(r, b) { return r ? new URL(r, b).toString() : ''; }
function gbkEncode(v) {
  const buf = iconv.encode(String(v ?? ''), 'gbk'); let out = '';
  for (const b of buf) {
    if ((b>=0x30&&b<=0x39)||(b>=0x41&&b<=0x5a)||(b>=0x61&&b<=0x7a)||b===0x2a||b===0x2d||b===0x2e||b===0x5f) out += String.fromCharCode(b);
    else if (b === 0x20) out += '+';
    else out += `%${b.toString(16).toUpperCase().padStart(2,'0')}`;
  }
  return out;
}
function encodeForm(f) { return Object.entries(f).map(([k,v])=>`${gbkEncode(k)}=${gbkEncode(v)}`).join('&'); }
async function postGbk(api, url, fields, referer) { return api.post(url, { data: Buffer.from(encodeForm(fields),'ascii'), headers: { 'Content-Type': 'application/x-www-form-urlencoded', Referer: referer } }); }

function parseHiddenFields(html) {
  const $ = cheerio.load(html); const f = {};
  $('form[name="loginForm"] input').each((_,e)=>{const n=$(e).attr('name');if(n) f[n]=$(e).attr('value')||''});
  return f;
}

function parseEvalList(html, pageUrl, formName) {
  const $ = cheerio.load(html);
  const form = $(`form[name="${formName}"]`).first();
  const formInfo = form.length ? { action: absUrl(form.attr('action'), pageUrl), method: form.attr('method')||'post' } : null;
  const items = $('img').toArray().filter(el => { const img = $(el); return (img.attr('name')||'').includes('#@') || (img.attr('onclick')||'').includes('evaluation'); }).map((el,idx) => {
    const img = $(el); const row = img.closest('tr');
    const cells = row.find('td,th').toArray().map(c=>cleanText($(c).text()));
    const rawName = img.attr('name')||''; const parts = rawName.split('#@');
    const status = cells.find(c=>c==='是'||c==='否')||'';
    return { index: idx, cells, status, pending: status==='否', done: status==='是', wjbm: parts[0]||'', bpr: parts[1]||'', bprm: parts[2]||cells[1]||'', wjmc: parts[3]||cells[0]||'', pgnrm: parts[4]||'', pgnr: parts[5]||'', courseName: cells[2]||parts[5]||'' };
  });
  return { formInfo, items, pendingCount: items.filter(i=>i.pending).length, doneCount: items.filter(i=>i.done).length };
}

async function ocrCaptcha(buf) {
  const {width,height} = await sharp(buf).metadata();
  const pp = await sharp(buf).grayscale().normalize().threshold(128).resize({width:width*3,height:height*3,kernel:'nearest'}).png().toBuffer();
  const {data} = await Tesseract.recognize(pp, 'eng', {tessedit_char_whitelist:'0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'});
  return data.text.replace(/\s/g,'');
}

async function login(api) {
  emit('progress','login','正在获取登录页面...');
  for (let a=1; a<=CONFIG.maxRetries; a++) {
    if (a>1) emit('progress','login_retry',`验证码识别失败，第 ${a} 次重试...`);
    const loginRes = await api.get(CONFIG.loginUrl);
    const loginHtml = await readBody(loginRes); const fields = parseHiddenFields(loginHtml);
    const captchaUrl = `${absUrl(CONFIG.captchaUrl, CONFIG.loginUrl)}?random=${Math.random()}`;
    const captchaRes = await api.get(captchaUrl, {headers:{Referer:CONFIG.loginUrl}});
    const captchaBody = await captchaRes.body();
    const captchaText = await ocrCaptcha(captchaBody);
    emit('progress','ocr',`验证码识别结果: ${captchaText}`);
    const form = {...fields, zjh: CONFIG.username, mm: CONFIG.password, v_yzm: captchaText.trim()};
    const loginResp = await api.post(CONFIG.loginUrl, {form, headers:{Referer:CONFIG.loginUrl}});
    const resultHtml = await readBody(loginResp);
    const resultText = cleanText(cheerio.load(resultHtml)('body').text());
    const failed = /验证码错误|验证码不正确|请输入验证码/.test(resultText) && !/当前用户|注销|安全退出|首页/.test(resultText);
    const authFailed = /密码错误|帐号不存在|账号不存在|用户名或密码错误/.test(resultText);
    if (authFailed) { emit('progress','login_failed','❌ 账号或密码错误'); return {ok:false,error:'账号或密码错误'}; }
    if (!failed) { emit('progress','login_ok','✅ 登录成功'); return {ok:true}; }
  }
  emit('progress','login_failed',`❌ 验证码识别失败 ${CONFIG.maxRetries} 次`);
  return {ok:false,error:`验证码识别失败 ${CONFIG.maxRetries} 次`};
}

function parseEvalForm(html, pageUrl) {
  const $ = cheerio.load(html);
  const form = $('form[name="StDaForm"]').first();
  const info = {action: absUrl(form.attr('action')||pageUrl, pageUrl), method: form.attr('method')||'post'};
  const hidden = {};
  form.find('input[type="hidden"]').each((_,e)=>{const n=$(e).attr('name');if(n) hidden[n]=$(e).attr('value')||''});
  const radioGroups = {};
  form.find('input[type="radio"]').each((_,e)=>{const r=$(e);const n=r.attr('name')||'';if(!n)return;(radioGroups[n]||=[]).push({id:r.attr('id')||'',value:r.attr('value')||''})});
  const textareas = form.find('textarea').toArray().map(e=>$(e).attr('name')||'').filter(Boolean);
  return {info,hidden,radioGroups,textareas};
}

function pickAnswers(groups, strategy) {
  const entries = Object.entries(groups); const answers = {};
  entries.forEach(([name,options],idx)=>{const best=options.find(o=>o.id==='1')||options[0];const second=options.find(o=>o.id==='2')||options[1]||best;answers[name]=strategy==='all_best'?best.value:(idx===entries.length-1?second.value:best.value)});
  return answers;
}

function buildPayload(form, comment) {
  return {...form.hidden, ...pickAnswers(form.radioGroups, CONFIG.answerStrategy), xumanyzg: 'zg', ...Object.fromEntries(form.textareas.map(n=>[n,(comment||CONFIG.comment||'').slice(0,100)]))};
}

function itemKey(item) { return `${item.wjbm}::${item.bpr}::${item.pgnr}`; }

async function fetchList(api) {
  const base = CONFIG.loginUrl.replace(/loginAction\.do.*$/,'');
  const urls = [`${base}jxpgXsAction.do?oper=listWj`,`${base}ggglAction.do?actionType=5`];
  for (const rawUrl of urls) {
    const url = absUrl(rawUrl, CONFIG.loginUrl);
    try { const res = await api.get(url, {headers:{Referer:CONFIG.loginUrl}}); const html = await readBody(res); const result = parseEvalList(html, url, 'WjList'); if (result.formInfo||result.items.length) return result; } catch(e){}
  }
  return null;
}

async function main() {
  emit('progress','init','评估工作器启动...');
  if (!CONFIG.username||!CONFIG.password) { emit('progress','error','❌ 未提供账号密码'); emitResult({success:0,failed:1,error:'未提供账号密码'}); process.exit(1); }
  await fs.mkdir(path.join(process.cwd(),'artifacts'),{recursive:true});
  const api = await request.newContext();
  emit('progress','login','🔐 正在登录教务系统...');
  const loginResult = await login(api);
  if (!loginResult.ok) { emit('progress','error',`❌ ${loginResult.error}`); emitResult({success:0,failed:0,error:loginResult.error}); await api.dispose(); process.exit(0); }
  emit('progress','fetching','📋 正在获取评估列表...');
  const list = await fetchList(api);
  if (!list||!list.formInfo) { emit('progress','error','❌ 无法获取评估列表'); emitResult({success:0,failed:0,error:'无法获取评估列表'}); await api.dispose(); process.exit(0); }
  emit('progress','list',`📋 待评估: ${list.pendingCount}  已完成: ${list.doneCount}`);
  if (list.pendingCount===0) { emit('progress','done','✅ 没有待评估项'); emitResult({success:0,failed:0,pendingCount:0}); await api.dispose(); process.exit(0); }
  const pendingItems = list.items.filter(i=>i.pending);
  let success=0,failed=0; const details=[];
  emit('progress','submitting',`🚀 开始提交 ${pendingItems.length} 项评估...`);
  for (let i=0;i<pendingItems.length;i++) {
    const item = pendingItems[i]; const seq = `${i+1}/${pendingItems.length}`;
    const freshList = await fetchList(api);
    const freshItem = freshList?.items.find(it=>it.pending&&itemKey(it)===itemKey(item));
    if (!freshItem) { emit('progress','skip',`⏭️ [${seq}] ${item.courseName} — 已不在待评估列表`); details.push({course:item.courseName,teacher:item.bprm,status:'skipped'}); continue; }
    emit('progress','submitting',`📝 [${seq}] 正在提交: ${item.courseName}`);
    const formUrl = absUrl(freshList.formInfo.action, freshList.pageUrl);
    const showData = {wjbm:item.wjbm,bpr:item.bpr,bprm:item.bprm,wjmc:item.wjmc,pgnrm:item.pgnrm,pgnr:item.pgnr,wjbz:'null',oper:'wjShow'};
    const showRes = await postGbk(api, formUrl, showData, freshList.pageUrl);
    const showHtml = await readBody(showRes); const form = parseEvalForm(showHtml, formUrl);
    const payload = buildPayload(form, CONFIG.comment);
    const submitRes = await postGbk(api, form.info.action, payload, formUrl);
    const submitHtml = await readBody(submitRes);
    const afterList = await fetchList(api);
    const afterItem = afterList?.items.find(i=>itemKey(i)===itemKey(item));
    const ok = afterItem && afterItem.status === '是';
    if (ok) { emit('progress','submit_ok',`✅ [${seq}] ${item.courseName} — 提交成功`); success++; details.push({course:item.courseName,teacher:item.bprm,status:'success'}); }
    else { emit('progress','submit_fail',`❌ [${seq}] ${item.courseName} — 提交失败`); failed++; details.push({course:item.courseName,teacher:item.bprm,status:'failed'}); }
  }
  const finalList = await fetchList(api);
  emit('progress','done',`✅ 全部完成！成功: ${success}, 失败: ${failed}`);
  emitResult({success,failed,total:pendingItems.length,pendingAfter:finalList?.pendingCount??'unknown',doneAfter:finalList?.doneCount??'unknown',details});
  await api.dispose(); process.exit(failed>0?1:0);
}
main().catch(err=>{emit('progress','error',`❌ 脚本异常: ${err.message}`);emitResult({success:0,failed:0,error:err.message});process.exit(1);});
WORKERJS
echo "  ✅ scripts/evaluate-worker.mjs"

# ── 前端 HTML ──
cat > public/index.html << 'HTMLEND'
<!DOCTYPE html>
<html lang="zh-CN" class="scroll-smooth">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="description" content="教学评估自动提交工具">
  <meta name="theme-color" content="#6366F1" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#0F172A" media="(prefers-color-scheme: dark)">
  <title>教学评估助手</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:opsz,wght@14..32,300..700&display=swap" rel="stylesheet">
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    :root{--primary:#6366F1;--primary-light:#818CF8;--primary-dark:#4F46E5;--bg:#F8FAFC;--bg-card:#FFFFFF;--text:#0F172A;--text-muted:#475569;--border:#E2E8F0;--success:#10B981;--error:#EF4444;--shadow:0 1px 3px rgba(0,0,0,0.06);--shadow-lg:0 10px 40px rgba(0,0,0,0.08);--radius:16px}
    .dark{--bg:#0F172A;--bg-card:#1E293B;--text:#F1F5F9;--text-muted:#94A3B8;--border:#334155;--shadow:0 1px 3px rgba(0,0,0,0.3);--shadow-lg:0 10px 40px rgba(0,0,0,0.4)}
    html{font-family:'Inter',system-ui,sans-serif}
    body{background:var(--bg);color:var(--text);transition:background 0.3s,color 0.3s;min-height:100vh}
    .glass{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow);transition:all 0.25s}
    .gradient-text{background:linear-gradient(135deg,#6366F1,#8B5CF6,#A78BFA);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
    .input-field{width:100%;padding:0.75rem 1rem;background:var(--bg);border:1.5px solid var(--border);border-radius:10px;color:var(--text);font-size:0.95rem;transition:all 0.2s;outline:none}
    .input-field:focus{border-color:var(--primary);box-shadow:0 0 0 3px rgba(99,102,241,0.15)}
    .dark .input-field{background:#0F172A}
    .btn-primary{display:inline-flex;align-items:center;justify-content:center;gap:0.5rem;padding:0.75rem 1.75rem;background:linear-gradient(135deg,#6366F1,#4F46E5);color:#fff;font-weight:600;font-size:1rem;border:none;border-radius:10px;cursor:pointer;transition:all 0.25s}
    .btn-primary:hover:not(:disabled){transform:translateY(-1px);box-shadow:0 8px 25px rgba(99,102,241,0.35)}
    .btn-primary:disabled{opacity:0.6;cursor:not-allowed}
    .step-item{display:flex;align-items:center;gap:0.75rem;padding:0.5rem 0;opacity:0.5;transition:all 0.3s}
    .step-item.active{opacity:1}.step-item.done{opacity:0.8}
    .step-dot{width:28px;height:28px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:0.75rem;font-weight:600;flex-shrink:0;transition:all 0.3s;border:2px solid var(--border);color:var(--text-muted)}
    .step-item.active .step-dot{background:var(--primary);border-color:var(--primary);color:#fff}
    .step-item.done .step-dot{background:var(--success);border-color:var(--success);color:#fff}
    .progress-track{width:100%;height:6px;background:var(--border);border-radius:3px;overflow:hidden}
    .progress-fill{height:100%;background:linear-gradient(90deg,var(--primary),#8B5CF6);border-radius:3px;transition:width 0.5s}
    .security-badge{display:inline-flex;align-items:center;gap:0.4rem;padding:0.35rem 0.75rem;background:rgba(16,185,129,0.1);border:1px solid rgba(16,185,129,0.2);border-radius:20px;font-size:0.8rem;color:var(--success);font-weight:500}
    @keyframes fadeInUp{from{opacity:0;transform:translateY(20px)}to{opacity:1;transform:translateY(0)}}
    .fade-in-up{animation:fadeInUp 0.5s forwards}
    @media(max-width:640px){.glass{padding:1.25rem!important}}
    @media(prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:0.01ms!important;transition-duration:0.01ms!important}}
  </style>
</head>
<body>
  <nav class="sticky top-0 z-50 backdrop-blur-xl" style="background:rgba(255,255,255,0.7);border-bottom:1px solid var(--border)">
    <div class="max-w-4xl mx-auto px-4 sm:px-6 h-16 flex items-center justify-between">
      <div class="flex items-center gap-3">
        <div class="w-9 h-9 rounded-xl flex items-center justify-center" style="background:linear-gradient(135deg,#6366F1,#4F46E5)">
          <svg class="w-5 h-5 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z"/></svg>
        </div>
        <span class="font-semibold text-base" style="color:var(--text)">教学评估助手</span>
      </div>
      <button id="themeToggle" class="w-9 h-9 rounded-lg flex items-center justify-center cursor-pointer" style="background:var(--bg-card);color:var(--text-muted);border:1px solid var(--border)" aria-label="切换主题">
        <svg id="sunIcon" class="w-5 h-5 hidden" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M12 3v2.25m6.364.386l-1.591 1.591M21 12h-2.25m-.386 6.364l-1.591-1.591M12 18.75V21m-4.773-4.227l-1.591 1.591M5.25 12H3m4.227-4.773L5.636 5.636M15.75 12a3.75 3.75 0 11-7.5 0 3.75 3.75 0 017.5 0z"/></svg>
        <svg id="moonIcon" class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M21.752 15.002A9.718 9.718 0 0118 15.75c-5.385 0-9.75-4.365-9.75-9.75 0-1.33.266-2.597.748-3.752A9.753 9.753 0 003 11.25C3 16.635 7.365 21 12.75 21a9.753 9.753 0 009.002-5.998z"/></svg>
      </button>
    </div>
  </nav>

  <main class="max-w-4xl mx-auto px-4 sm:px-6 py-8 space-y-6">
    <div class="text-center mb-2 fade-in-up">
      <h1 class="text-3xl sm:text-4xl font-bold gradient-text mb-3">教学评估自动提交</h1>
      <p class="text-base" style="color:var(--text-muted)">安全、快速、自动化提交教务系统教学评估</p>
      <div class="flex items-center justify-center gap-3 mt-4 flex-wrap">
        <span class="security-badge"><svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z"/></svg> 内存加密处理</span>
        <span class="security-badge"><svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/></svg> 用完即焚不留存</span>
        <span class="security-badge"><svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"/></svg> 进程隔离运行</span>
      </div>
    </div>

    <div id="formSection" class="glass p-6 sm:p-8 fade-in-up">
      <div class="flex items-center gap-3 mb-6">
        <div class="w-10 h-10 rounded-xl flex items-center justify-center" style="background:rgba(99,102,241,0.1)"><svg class="w-5 h-5" style="color:var(--primary)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 6a3.75 3.75 0 11-7.5 0 3.75 3.75 0 017.5 0zM4.501 20.118a7.5 7.5 0 0114.998 0A17.933 17.933 0 0112 21.75c-2.676 0-5.216-.584-7.499-1.632z"/></svg></div>
        <div><h2 class="font-semibold text-lg">安全登录</h2><p class="text-sm" style="color:var(--text-muted)">输入教务系统账号信息，凭证仅在本次评估中使用</p></div>
      </div>
      <button id="toggleConfig" class="flex items-center gap-2 text-sm font-medium cursor-pointer mb-4" style="color:var(--text-muted)" onclick="document.getElementById('configPanel').style.maxHeight=document.getElementById('configPanel').style.maxHeight==='200px'?'0':'200px';document.getElementById('configPanel').style.opacity=document.getElementById('configPanel').style.opacity==='1'?'0':'1'">
        <svg class="w-4 h-4 transition-transform" id="configChevron" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5"/></svg> 高级设置 — 教务系统地址
      </button>
      <div id="configPanel" class="mb-4 overflow-hidden transition-all duration-300" style="max-height:0;opacity:0">
        <div class="p-4 rounded-xl" style="background:var(--bg);border:1px solid var(--border)">
          <label class="block text-sm font-medium mb-1.5" for="loginUrl">教务系统登录地址</label>
          <input id="loginUrl" class="input-field" type="url" placeholder="http://192.168.16.207/loginAction.do" autocomplete="off">
        </div>
      </div>
      <form id="evalForm" onsubmit="return startEvaluation(event)" class="space-y-4">
        <div><label class="block text-sm font-medium mb-1.5" for="username">学号</label><input id="username" class="input-field" type="text" placeholder="请输入学号" required autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></div>
        <div><label class="block text-sm font-medium mb-1.5" for="password">密码</label>
          <div class="relative"><input id="password" class="input-field pr-12" type="password" placeholder="请输入密码" required autocomplete="off">
            <button type="button" class="absolute right-3 top-1/2 -translate-y-1/2 cursor-pointer" style="color:var(--text-muted)" onclick="togglePassword()" tabindex="-1">
              <svg id="eyeIcon" class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
            </button>
          </div>
        </div>
        <div><label class="block text-sm font-medium mb-1.5" for="comment">评价语（可选）</label><input id="comment" class="input-field" type="text" placeholder="老师授课认真负责，内容清晰，课堂组织良好。" maxlength="100" autocomplete="off"></div>
        <div class="pt-2"><button id="submitBtn" type="submit" class="btn-primary w-full text-base py-3"><svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M19.5 13.5L12 21m0 0l-7.5-7.5M12 21V3"/></svg> 开始评估</button></div>
      </form>
      <div class="mt-5 pt-4 flex items-center gap-2 text-xs" style="border-top:1px solid var(--border);color:var(--text-muted)"><svg class="w-4 h-4 flex-shrink-0" style="color:var(--success)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z"/></svg><span>安全说明：<strong>密码不存储不记录</strong>，仅在本次评估的内存中使用，完成后自动销毁。</span></div>
    </div>

    <div id="progressSection" class="glass p-6 sm:p-8 fade-in-up hidden">
      <div class="flex items-center gap-3 mb-6"><div class="w-10 h-10 rounded-xl flex items-center justify-center" style="background:rgba(99,102,241,0.1)"><svg class="w-5 h-5" style="color:var(--primary)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5"><path stroke-linecap="round" stroke-linejoin="round" d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z"/></svg></div>
        <div><h2 class="font-semibold text-lg">评估进度</h2><p id="progressSubtitle" class="text-sm" style="color:var(--text-muted)">正在运行...</p></div>
      </div>
      <div class="space-y-1 mb-5">
        <div id="step-login" class="step-item"><div class="step-dot">1</div><span class="text-sm font-medium">登录教务系统</span><span id="step-login-status" class="ml-auto text-xs" style="color:var(--text-muted)">等待中</span></div>
        <div id="step-fetch" class="step-item"><div class="step-dot">2</div><span class="text-sm font-medium">获取评估列表</span><span id="step-fetch-status" class="ml-auto text-xs" style="color:var(--text-muted)">等待中</span></div>
        <div id="step-submit" class="step-item"><div class="step-dot">3</div><span class="text-sm font-medium">批量提交评估</span><span id="step-submit-status" class="ml-auto text-xs" style="color:var(--text-muted)">等待中</span></div>
      </div>
      <div class="mb-4"><div class="flex items-center justify-between text-xs mb-1.5" style="color:var(--text-muted)"><span id="progressLabel">初始化...</span><span id="progressPercent">0%</span></div><div class="progress-track"><div id="progressFill" class="progress-fill" style="width:0%"></div></div></div>
      <div class="rounded-xl p-4" style="background:var(--bg);border:1px solid var(--border);max-height:200px;overflow-y:auto"><div id="logContainer"></div></div>
    </div>

    <div id="resultsSection" class="glass p-6 sm:p-8 fade-in-up hidden">
      <div class="flex items-center gap-3 mb-6"><div id="resultsIcon" class="w-10 h-10 rounded-xl flex items-center justify-center" style="background:rgba(16,185,129,0.1)"><svg class="w-5 h-5" style="color:var(--success)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg></div>
        <div><h2 class="font-semibold text-lg" id="resultsTitle">评估完成</h2><p class="text-sm" style="color:var(--text-muted)" id="resultsSubtitle">以下为本次评估的详细结果</p></div>
      </div>
      <div class="grid grid-cols-3 gap-3 sm:gap-4 mb-6">
        <div class="rounded-xl p-4 text-center" style="background:rgba(16,185,129,0.08);border:1px solid rgba(16,185,129,0.2)"><div class="text-2xl font-bold" style="color:var(--success)" id="resultSuccess">0</div><div class="text-xs mt-1" style="color:var(--text-muted)">提交成功</div></div>
        <div class="rounded-xl p-4 text-center" style="background:rgba(239,68,68,0.08);border:1px solid rgba(239,68,68,0.2)"><div class="text-2xl font-bold" style="color:var(--error)" id="resultFailed">0</div><div class="text-xs mt-1" style="color:var(--text-muted)">提交失败</div></div>
        <div class="rounded-xl p-4 text-center" style="background:rgba(99,102,241,0.08);border:1px solid rgba(99,102,241,0.2)"><div class="text-2xl font-bold" style="color:var(--primary)" id="resultTotal">0</div><div class="text-xs mt-1" style="color:var(--text-muted)">总评项数</div></div>
      </div>
      <div id="resultDetails" class="space-y-2"></div>
      <div class="flex flex-col sm:flex-row gap-3 mt-6 pt-4" style="border-top:1px solid var(--border)">
        <button onclick="resetForm()" class="flex-1 btn-primary" style="background:var(--bg-card);color:var(--text);border:1px solid var(--border);box-shadow:none"><svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 15L3 9m0 0l6-6M3 9h12a6 6 0 010 12h-3"/></svg> 重新评估</button>
        <button onclick="resetForm()" class="flex-1 btn-primary"><svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M4.5 12a7.5 7.5 0 1115 0 7.5 7.5 0 01-15 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M12 9v3.75m0 0a.75.75 0 000 1.5.75.75 0 000-1.5z"/></svg> 评估其他账号</button>
      </div>
    </div>

    <div id="errorSection" class="glass p-6 sm:p-8 fade-in-up hidden" style="border-left:4px solid var(--error)">
      <div class="flex items-start gap-4"><div class="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0" style="background:rgba(239,68,68,0.1)"><svg class="w-5 h-5" style="color:var(--error)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5"><path stroke-linecap="round" stroke-linejoin="round" d="M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z"/></svg></div>
        <div class="flex-1"><h2 class="font-semibold text-lg" style="color:var(--error)">评估过程中出现错误</h2><p class="text-sm mt-1" style="color:var(--text-muted)" id="errorMessage">未知错误</p>
          <button onclick="resetForm()" class="mt-4 btn-primary" style="background:var(--bg-card);color:var(--text);border:1px solid var(--border);box-shadow:none"><svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 15L3 9m0 0l6-6M3 9h12a6 6 0 010 12h-3"/></svg> 返回重试</button></div></div>
    </div>
  </main>

  <footer class="max-w-4xl mx-auto px-4 sm:px-6 py-8 text-center">
    <div class="flex flex-col items-center gap-3">
      <div class="flex items-center gap-2 text-xs" style="color:var(--text-muted)"><svg class="w-4 h-4" style="color:var(--success)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z"/></svg><span>所有数据仅在内存中处理，提交完成后自动清除。</span></div>
      <div class="text-xs" style="color:var(--text-muted);opacity:0.6">教学评估助手 · 仅供自动化提交教学评估使用</div>
    </div>
  </footer>

  <script>
    function getTheme(){const s=localStorage.getItem('theme');if(s)return s;return window.matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light'}
    function setTheme(t){document.documentElement.classList.toggle('dark',t==='dark');localStorage.setItem('theme',t);document.getElementById('sunIcon').classList.toggle('hidden',t!=='light');document.getElementById('moonIcon').classList.toggle('hidden',t!=='dark')}
    document.getElementById('themeToggle').addEventListener('click',()=>setTheme(document.documentElement.classList.contains('dark')?'light':'dark'));setTheme(getTheme());
    window.togglePassword=function(){const i=document.getElementById('password');i.type=i.type==='password'?'text':'password'};
    window.startEvaluation=async function(e){e.preventDefault();const u=document.getElementById('username').value.trim(),p=document.getElementById('password').value;if(!u||!p){alert('请输入学号和密码');return false}
    document.getElementById('formSection').classList.add('hidden');document.getElementById('progressSection').classList.remove('hidden');document.getElementById('resultsSection').classList.add('hidden');document.getElementById('errorSection').classList.add('hidden');
    document.getElementById('logContainer').innerHTML='';setLoading(true);addLog('正在连接到服务器...');
    try{const r=await fetch('/api/evaluate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p,loginUrl:document.getElementById('loginUrl').value.trim()||undefined,comment:document.getElementById('comment').value.trim()||undefined})});
    if(!r.ok){const e=await r.json();throw new Error(e.error||'请求失败')}const{jobId}=await r.json();currentJobId=jobId;addLog('评估作业已创建');connectSSE(jobId)}catch(e){setLoading(false);showError(e.message)}return false}
    function connectSSE(jobId){if(eventSource)eventSource.close();eventSource=new EventSource(`/api/evaluate/${jobId}/stream`);eventSource.onmessage=function(e){try{const d=JSON.parse(e.data);if(d.type==='progress')handleProgress(d);else if(d.type==='status')handleComplete(d)}catch{}};eventSource.onerror=function(){eventSource.close();eventSource=null;pollJob(jobId)}}
    function handleProgress(d){const s=d.step||'',m=d.message||'';if(s.includes('login')&&!s.includes('fail')&&!s.includes('ok')){setStepActive('login')}if(s==='login_ok'){setStepDone('login');setStepActive('fetch')}if(s==='fetching'||s==='list'){setStepDone('fetch');setStepActive('submit')}if(s==='submitting'){addLog(m)}if(s==='submit_ok'){addLog(m,'success')}if(s==='submit_fail'){addLog(m,'error')}if(s==='done'){addLog(m,'success')}}
    function handleComplete(d){setLoading(false);if(eventSource){eventSource.close();eventSource=null}if(d.status==='completed'&&d.result){setStepDone('submit');showResults(d.result)}else{showError(d.error||'评估失败')}}
    async function pollJob(id){try{const r=await fetch(`/api/evaluate/${id}`);const d=await r.json();if(d.progress)d.progress.forEach(p=>handleProgress({step:p.step,message:p.message}));if(d.status==='completed'||d.status==='failed'||d.status==='timeout')handleComplete(d);else setTimeout(()=>pollJob(id),2000)}catch{setTimeout(()=>pollJob(id),3000)}}
    function showResults(r){document.getElementById('progressSection').classList.add('hidden');document.getElementById('resultsSection').classList.remove('hidden');document.getElementById('errorSection').classList.add('hidden');
    document.getElementById('resultSuccess').textContent=r.success||0;document.getElementById('resultFailed').textContent=r.failed||0;document.getElementById('resultTotal').textContent=r.total||(r.success+r.failed);
    const c=document.getElementById('resultDetails');c.innerHTML='';
    (r.details||[]).forEach(d=>{const card=document.createElement('div');card.className=d.status==='success'?'result-success rounded-xl p-3 flex items-center gap-3':'result-error rounded-xl p-3 flex items-center gap-3';card.innerHTML='<span class="w-5 h-5 flex-shrink-0">'+(d.status==='success'?'✅':'❌')+'</span><div class="flex-1 min-w-0"><div class="text-sm font-medium truncate">'+(d.course||'')+'</div><div class="text-xs" style="color:var(--text-muted)">'+(d.teacher||'')+'</div></div><span class="text-xs font-medium" style="color:'+(d.status==='success'?'var(--success)':'var(--error)')+'">'+(d.status==='success'?'成功':'失败')+'</span>';c.appendChild(card)})}
    function showError(m){setLoading(false);document.getElementById('progressSection').classList.add('hidden');document.getElementById('resultsSection').classList.add('hidden');document.getElementById('errorSection').classList.remove('hidden');document.getElementById('errorMessage').textContent=m}
    window.resetForm=function(){document.getElementById('formSection').classList.remove('hidden');document.getElementById('progressSection').classList.add('hidden');document.getElementById('resultsSection').classList.add('hidden');document.getElementById('errorSection').classList.add('hidden');setLoading(false);currentJobId=null;if(eventSource){eventSource.close();eventSource=null}document.getElementById('password').value=''}
    function setLoading(l){const b=document.getElementById('submitBtn');if(l){b.disabled=true;b.innerHTML='<svg class="w-5 h-5 animate-spin" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/></svg> 评估运行中...'}else{b.disabled=false;b.innerHTML='<svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M19.5 13.5L12 21m0 0l-7.5-7.5M12 21V3"/></svg> 开始评估'}}
    function addLog(msg,type){const c=document.getElementById('logContainer');const e=document.createElement('div');e.className='log-entry fade-in-up';e.innerHTML='<span class="opacity-60 mr-1">'+new Date().toLocaleTimeString()+'</span> '+(type==='error'?'❌':type==='success'?'✅':'•')+' '+msg;c.appendChild(e)}
    function resetSteps(){['login','fetch','submit'].forEach(id=>{const e=document.getElementById('step-'+id);e.classList.remove('active','done');document.getElementById('step-'+id+'-status').textContent='等待中'})}
    function setStepActive(id){const e=document.getElementById('step-'+id);e.classList.remove('done');e.classList.add('active');document.getElementById('step-'+id+'-status').textContent='进行中...'}
    function setStepDone(id){const e=document.getElementById('step-'+id);e.classList.remove('active');e.classList.add('done');document.getElementById('step-'+id+'-status').innerHTML='<svg class="w-4 h-4" style="color:var(--success)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"><path stroke-linecap="round" stroke-linejoin="round" d="M4.5 12.75l6 6 9-13.5"/></svg>'}
    console.log('%c🔒 教学评估助手 - 安全提示','font-size:16px;font-weight:bold;');console.log('%c本工具不会记录或上传你的密码。所有认证信息仅在浏览器内存中处理。','font-size:12px;');
  </script>
</body>
</html>
HTMLEND
echo "  ✅ public/index.html"

else
  echo "  ⏭️  项目文件已存在，跳过"
fi

# ── 配置 systemd 服务 ──
echo "[5/6] ⚙️  配置 systemd 服务..."
cp deploy/auto-eval-web.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now auto-eval-web
sleep 2

# ── 配置 Nginx + SSL ──
echo "[6/6] 🌐 配置 Nginx + SSL..."
cat > /etc/nginx/sites-available/auto-eval << 'NGINXCONF'
server {
    listen 80;
    server_name rimurutempest.me;
    return 301 https://$server_name$request_uri;
}
server {
    listen 443 ssl http2;
    server_name rimurutempest.me;
    ssl_certificate /etc/letsencrypt/live/rimurutempest.me/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/rimurutempest.me/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    ssl_buffer_size 4k;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    client_max_body_size 10k;
}
NGINXCONF

ln -sf /etc/nginx/sites-available/auto-eval /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

if [ ! -d "/etc/letsencrypt/live/rimurutempest.me" ]; then
  echo "🔐 申请 SSL 证书..."
  certbot --nginx -d rimurutempest.me --non-interactive --agree-tos -m admin@rimurutempest.me 2>/dev/null || echo "⚠️  证书申请失败，DNS 可能未指向本机"
fi

nginx -t && systemctl reload nginx 2>/dev/null || echo "⚠️  Nginx 配置需检查"

# ── 验证 ──
echo ""
echo "═══════════════════════════════════════"
if systemctl is-active --quiet auto-eval-web; then echo "  ✅ Node.js: 运行中"; else echo "  ❌ Node.js: 未运行"; fi
if systemctl is-active --quiet nginx; then echo "  ✅ Nginx: 运行中"; fi
if [ -d "/etc/letsencrypt/live/rimurutempest.me" ]; then echo "  ✅ SSL: 已安装"; fi
echo ""
echo "  访问: https://rimurutempest.me"
echo "═══════════════════════════════════════"
