/**
 * 一键本地测试：起一台**隔离的**服务器（独立端口 + 独立数据目录）→ 跑全部场景 → 关掉。
 *
 *   node devtest/run.js
 *
 * 数据写在 devtest/.data/，跟线上 /opt/voice-room/data 完全隔离，
 * 可以随便建房、传背景、刷数据，不影响真实用户。
 *
 * 想对着线上跑（只读性质的自检）：
 *   VR_HOST=43.142.76.172:8125 node devtest/scenarios.js
 */
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.DEV_PORT || 8126);
const DATA_DIR = path.join(__dirname, '.data');

function waitHealth(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      http.get({ host: '127.0.0.1', port, path: '/healthz' }, (r) => {
        let d = ''; r.on('data', (c) => { d += c; });
        r.on('end', () => resolve(d));
      }).on('error', () => {
        if (Date.now() > deadline) reject(new Error('本地服务器启动超时'));
        else setTimeout(tick, 250);
      });
    };
    tick();
  });
}

(async () => {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const port = PORT;
  console.log(`启动本地隔离服务器  端口=${port}  数据目录=${path.relative(ROOT, DATA_DIR)}`);

  const child = spawn(process.execPath, [path.join(ROOT, 'server.js')], {
    cwd: ROOT,
    env: { ...process.env, PORT: String(port), DATA_DIR },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let serverLog = '';
  child.stdout.on('data', (d) => { serverLog += d.toString(); });
  child.stderr.on('data', (d) => { serverLog += d.toString(); });
  child.on('exit', (code) => {
    if (code !== 0 && code !== null) {
      console.log('⚠️ 服务器进程退出，code=' + code);
      console.log(serverLog.slice(-1500));
    }
  });

  const cleanup = () => { try { child.kill(); } catch (_) {} };
  process.on('exit', cleanup);
  process.on('SIGINT', () => { cleanup(); process.exit(130); });

  try {
    const health = await waitHealth(port, 15000);
    console.log('本地服务器就绪  ' + health.trim() + '\n');

    process.env.VR_HOST = '127.0.0.1:' + port;
    const { main } = require('./scenarios');
    // scenarios.js 在 require 时读取 VR_HOST，必须在 require 之前设好 —— 见上
    await main();
  } catch (e) {
    console.log('❌ ' + e.message);
    console.log(serverLog.slice(-1500));
    cleanup();
    process.exit(1);
  } finally {
    cleanup();
  }
})();
