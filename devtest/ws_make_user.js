/**
 * 辅助脚本：用 WebSocket 在线上服务端登录/注册一个账号，打印结果后退出。
 *
 * 为什么单独拆出来：这个环境里 node 无法 spawn 子进程（execFileSync 直接 EBUSY），
 * 所以不会由 node 去调度别的语言 —— 而是反过来，由 devtest/verify_clear_user.py
 * 用 subprocess 调用本脚本，需要的信息从 stdout 读。
 *
 * 用法：
 *   node ws_make_user.js <username> <password> [deviceId]
 * 输出（stdout，单行 JSON）：
 *   {"ok":true,"userId":"u_xxx","name":"xxx"}
 *   {"ok":false,"error":"密码错误"}
 */
const WebSocket = require('ws');

const WS = process.env.VR_WS || 'ws://43.142.76.172:8125';
const [, , username, password, deviceId] = process.argv;

if (!username || !password) {
  console.log(JSON.stringify({ ok: false, error: 'usage: ws_make_user.js <username> <password> [deviceId]' }));
  process.exit(2);
}

const ws = new WebSocket(WS);
const timer = setTimeout(() => {
  done({ ok: false, error: 'auth 超时（15s）' });
}, 15000);

function done(obj) {
  clearTimeout(timer);
  console.log(JSON.stringify(obj));
  try { ws.close(); } catch {}
  // 给 stdout 一点时间 flush 再退出
  setTimeout(() => process.exit(obj.ok ? 0 : 1), 60);
}

ws.on('open', () => ws.send(JSON.stringify({
  type: 'auth', username, password, deviceId: deviceId || ('devtest-' + username)
})));
ws.on('message', d => {
  let m; try { m = JSON.parse(d.toString()); } catch { return; }
  if (m.type === 'auth:ok') {
    done({ ok: true, userId: m.data.userId, name: (m.data.user || {}).name || username });
  } else if (m.type === 'error') {
    done({ ok: false, error: m.msg });
  }
});
ws.on('error', e => done({ ok: false, error: e.message }));
