/**
 * server.mjs — 教学评估 Web 服务
 *
 * 安全特性：
 *   - Helmet 安全头（CSP, XSS, 点击劫持保护等）
 *   - 请求速率限制（每 IP 每分钟 10 次评估请求）
 *   - 输入校验（学号格式、密码非空、URL 格式）
 *   - 评估作业在独立子进程中运行（进程隔离）
 *   - 临时工作目录，完成后自动清理
 *   - 密码不写入日志、不持久化存储
 *   - 任务超时自动终止（10 分钟）
 *   - CORS 限制为同源
 *
 * 启动：
 *   node server.mjs
 *   # 生产环境建议：
 *   NODE_ENV=production node server.mjs
 */

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

// ──────────── 配置 ────────────

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '0.0.0.0';
const NODE_ENV = process.env.NODE_ENV || 'development';
const JOB_TIMEOUT_MS = parseInt(process.env.JOB_TIMEOUT || '600000', 10); // 10 min
const MAX_LOG_LENGTH = parseInt(process.env.MAX_LOG_LENGTH || '20000', 10);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, 'public');
const SCRIPTS_DIR = path.join(__dirname, 'scripts');
const WORKER_SCRIPT = path.join(SCRIPTS_DIR, 'evaluate-worker.mjs');

// ──────────── 内存作业存储 ────────────

const jobs = new Map(); // jobId -> { status, progress, result, createdAt, timeout }

function createJob() {
  const id = randomUUID();
  const job = {
    id,
    status: 'pending',     // pending | running | completed | failed | timeout
    progress: [],           // [{step, message, timestamp}]
    result: null,
    error: null,
    createdAt: Date.now(),
    child: null,
    timeout: null,
    tempDir: null
  };
  jobs.set(id, job);
  return job;
}

function addProgress(job, step, message) {
  job.progress.push({ step, message, timestamp: new Date().toISOString() });
}

// ──────────── Express 应用 ────────────

const app = express();

// ── 安全头 ──

app.use(helmet({
  contentSecurityPolicy: NODE_ENV === 'production' ? undefined : false,
  crossOriginEmbedderPolicy: false
}));

// ── 速率限制 ──

const evalLimiter = rateLimit({
  windowMs: 60 * 1000,        // 1 分钟窗口
  max: 10,                     // 每 IP 每分钟最多 10 次
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: '请求过于频繁，请稍后再试。' }
});

// ── 请求体解析 ──

app.use(express.json({ limit: '10kb' }));

// ── 静态文件 ──

app.use(express.static(PUBLIC_DIR, {
  maxAge: NODE_ENV === 'production' ? '1h' : 0
}));

// ──────────── API 路由 ────────────

/**
 * POST /api/evaluate
 * 启动一个新的评估作业
 *
 * 请求体：
 *   username: string  学号
 *   password: string  密码
 *   loginUrl: string  教务系统登录地址（可选，有默认值）
 *   comment:  string  评价内容（可选）
 *
 * 安全说明：
 *   - 密码仅用于本次登录，不持久化存储
 *   - 密码不写入日志
 *   - 作业完成后自动清理所有临时文件
 */
app.post('/api/evaluate', evalLimiter, async (req, res) => {
  // ── 输入校验 ──
  const { username, password, loginUrl, comment } = req.body;

  const errors = [];
  if (!username || typeof username !== 'string' || !username.trim()) {
    errors.push('请输入学号');
  }
  if (!password || typeof password !== 'string' || !password) {
    errors.push('请输入密码');
  }
  if (password && password.length > 128) {
    errors.push('密码过长');
  }
  if (username && !/^[\w@.\-]+$/.test(username.trim())) {
    errors.push('学号格式不正确');
  }
  if (loginUrl && typeof loginUrl === 'string' && loginUrl.length > 0) {
    try {
      new URL(loginUrl);
    } catch {
      errors.push('教务系统地址格式不正确');
    }
  }
  if (comment && (typeof comment !== 'string' || comment.length > 200)) {
    errors.push('评价内容过长（最多200字）');
  }

  if (errors.length > 0) {
    return res.status(400).json({ error: errors.join('；') });
  }

  // ── 创建作业 ──
  const job = createJob();
  const tempDir = path.join(__dirname, 'tmp', job.id);
  await fs.mkdir(tempDir, { recursive: true });
  job.tempDir = tempDir;

  // 启动子进程
  const child = spawn(process.execPath, [WORKER_SCRIPT], {
    cwd: tempDir,
    stdio: ['pipe', 'pipe', 'pipe'],
    env: {
      ...process.env,
      EVAL_USERNAME: username.trim(),
      EVAL_PASSWORD: password,
      EVAL_LOGIN_URL: (loginUrl || '').trim() || undefined,
      EVAL_COMMENT: (comment || '').trim() || undefined,
      EVAL_JOB_ID: job.id,
      NODE_ENV: 'production'
    },
    timeout: JOB_TIMEOUT_MS
  });

  job.child = child;
  job.status = 'running';
  addProgress(job, 'started', '评估作业已启动...');

  // ── 收集子进程输出 ──
  let stdoutBuffer = '';
  let stderrBuffer = '';

  child.stdout.on('data', (chunk) => {
    const text = chunk.toString('utf8');
    stdoutBuffer += text;
    if (stdoutBuffer.length > MAX_LOG_LENGTH) {
      stdoutBuffer = stdoutBuffer.slice(-MAX_LOG_LENGTH);
    }
    // 解析进度事件（JSON Lines 格式）
    for (const line of text.split('\n').filter(Boolean)) {
      try {
        const event = JSON.parse(line);
        if (event.type === 'progress') {
          addProgress(job, event.step, event.message);
        }
      } catch {
        // 不是 JSON 格式，忽略（普通日志）
      }
    }
  });

  child.stderr.on('data', (chunk) => {
    stderrBuffer += chunk.toString('utf8');
    if (stderrBuffer.length > MAX_LOG_LENGTH) {
      stderrBuffer = stderrBuffer.slice(-MAX_LOG_LENGTH);
    }
  });

  child.on('error', (err) => {
    job.status = 'failed';
    job.error = `进程启动失败: ${err.message}`;
    addProgress(job, 'error', job.error);
    cleanupJob(job);
  });

  child.on('exit', async (code, signal) => {
    clearTimeout(job.timeout);

    if (signal === 'SIGTERM') {
      job.status = 'timeout';
      job.error = '评估作业超时已被终止（10分钟限制）';
      addProgress(job, 'timeout', job.error);
    } else if (code === 0) {
      job.status = 'completed';
      addProgress(job, 'completed', '评估作业已完成');

      // 尝试从 stdout 提取结果 JSON
      const resultMatch = stdoutBuffer.match(/---JOB_RESULT_START---\n([\s\S]*?)\n---JOB_RESULT_END---/);
      if (resultMatch) {
        try {
          job.result = JSON.parse(resultMatch[1]);
        } catch {
          job.result = { raw: resultMatch[1] };
        }
      }
    } else {
      job.status = 'failed';
      const lastStderr = stderrBuffer.slice(-500);
      job.error = `进程异常退出 (code: ${code})`;
      if (lastStderr) job.error += `\n${lastStderr}`;
      addProgress(job, 'error', job.error);
    }

    // 清理临时目录
    await cleanupJob(job);
  });

  // 作业超时
  job.timeout = setTimeout(() => {
    if (job.child && !job.child.killed) {
      job.child.kill('SIGTERM');
      // 2 秒后强制杀
      setTimeout(() => {
        if (job.child && !job.child.killed) {
          job.child.kill('SIGKILL');
        }
      }, 2000);
    }
  }, JOB_TIMEOUT_MS);

  // 返回作业 ID
  res.json({
    jobId: job.id,
    status: 'running',
    message: '评估作业已启动'
  });

  // 日志记录（不包含密码）
  console.log(`[eval] job=${job.id} username=${username} status=running`);
});

/**
 * GET /api/evaluate/:jobId
 * 获取作业状态
 */
app.get('/api/evaluate/:jobId', (req, res) => {
  const job = jobs.get(req.params.jobId);
  if (!job) {
    return res.status(404).json({ error: '作业不存在' });
  }

  res.json({
    id: job.id,
    status: job.status,
    progress: job.progress,
    result: job.result,
    error: job.error,
    createdAt: job.createdAt
  });
});

/**
 * GET /api/evaluate/:jobId/stream
 * SSE (Server-Sent Events) 实时进度推送
 */
app.get('/api/evaluate/:jobId/stream', (req, res) => {
  const job = jobs.get(req.params.jobId);
  if (!job) {
    return res.status(404).json({ error: '作业不存在' });
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no'  // 禁用 nginx 缓冲
  });

  // 发送已有进度
  for (const p of job.progress) {
    res.write(`data: ${JSON.stringify({ type: 'progress', ...p })}\n\n`);
  }

  // 如果作业已完成/失败，立即发送结果
  if (job.status !== 'pending' && job.status !== 'running') {
    res.write(`data: ${JSON.stringify({ type: 'status', status: job.status, result: job.result, error: job.error })}\n\n`);
    res.end();
    return;
  }

  // 轮询更新
  const interval = setInterval(() => {
    // 发送最新进度
    res.write(`data: ${JSON.stringify({ type: 'progress', progress: job.progress.slice(-1)[0] })}\n\n`);

    if (job.status !== 'pending' && job.status !== 'running') {
      clearInterval(interval);
      res.write(`data: ${JSON.stringify({ type: 'status', status: job.status, result: job.result, error: job.error })}\n\n`);
      res.end();
    }
  }, 1000);

  req.on('close', () => {
    clearInterval(interval);
  });
});

/**
 * GET /api/health
 * 健康检查
 */
app.get('/api/health', (req, res) => {
  res.json({
    status: 'ok',
    uptime: process.uptime(),
    activeJobs: Array.from(jobs.values()).filter(j => j.status === 'running').length,
    totalJobs: jobs.size
  });
});

// ──────────── 404 处理 ────────────

app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// ──────────── 错误处理 ────────────

app.use((err, req, res, _next) => {
  console.error('[error]', err.message);
  res.status(500).json({ error: NODE_ENV === 'production' ? '服务器内部错误' : err.message });
});

// ──────────── 清理函数 ────────────

async function cleanupJob(job) {
  if (job.tempDir) {
    try {
      await fs.rm(job.tempDir, { recursive: true, force: true });
    } catch { /* ignore */ }
    job.tempDir = null;
  }
}

// 定期清理过期作业（每小时）
setInterval(() => {
  const now = Date.now();
  const maxAge = 2 * 60 * 60 * 1000; // 2 小时
  for (const [id, job] of jobs) {
    if (now - job.createdAt > maxAge) {
      if (job.child && !job.child.killed) {
        job.child.kill('SIGKILL');
      }
      cleanupJob(job);
      jobs.delete(id);
    }
  }
}, 60 * 60 * 1000);

// ──────────── 启动 ────────────

createServer(app).listen(PORT, HOST, () => {
  console.log(`\n  ╔═════════════════════════════════════╗`);
  console.log(`  ║   教学评估 Web 服务                    ║`);
  console.log(`  ╠═════════════════════════════════════╣`);
  console.log(`  ║  地址: http://${HOST}:${PORT}            ║`);
  console.log(`  ║  模式: ${NODE_ENV}                         ║`);
  console.log(`  ║  作业超时: ${JOB_TIMEOUT_MS / 1000}s               ║`);
  console.log(`  ╚═════════════════════════════════════╝\n`);
});
