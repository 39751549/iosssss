/**
 * 验证「同设备重连不误判顶号 / 异设备登录仍顶号」
 *
 * 场景对应线上 bug：用户切后台再回前台 → 客户端重连 → 旧 socket 还没注销 →
 * 服务端若无条件按"同账号"顶号，用户就会在自己手机上看到"账号在其他地方登录"。
 *
 * T1 同 deviceId 重连  → 新连接 auth:ok，旧连接被静默关闭（**不应**收到 room:kicked）
 * T2 异 deviceId 登录  → 旧连接**应**收到 room:kicked
 * T3 无 deviceId 的旧客户端（兼容）→ 仍按顶号处理，行为不变
 */
const WebSocket = require('ws');
const URL = 'ws://43.142.76.172:8125';

const ACCOUNT = 'devtest_' + Date.now().toString(36);
const PASSWORD = 'pw123456';
const DEV_A = 'device-aaaa-1111';
const DEV_B = 'device-bbbb-2222';

function open(label, deviceId) {
  const ws = new WebSocket(URL);
  const state = { label, got: [], kicked: false, closed: false, authOk: false };
  ws.on('message', (r) => {
    let j; try { j = JSON.parse(r.toString()); } catch { return; }
    state.got.push(j.type);
    if (j.type === 'auth:ok') state.authOk = true;
    if (j.type === 'room:kicked') state.kicked = true;
  });
  ws.on('close', () => { state.closed = true; });
  ws.on('error', () => {});
  state.ws = ws;
  state.auth = () => ws.send(JSON.stringify({
    type: 'auth', username: ACCOUNT, password: PASSWORD,
    ...(deviceId ? { deviceId } : {}),
  }));
  return state;
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0, fail = 0;
function check(name, ok, extra = '') {
  console.log((ok ? '  ✅ ' : '  ❌ ') + name + (extra ? '   ' + extra : ''));
  ok ? pass++ : fail++;
}

(async () => {
  // 首次注册账号（同时拿到 userId）
  const first = open('first', DEV_A);
  await wait(600); first.auth();
  await wait(1200);
  check('T0 首次注册/登录成功', first.authOk);

  // ---- T1：同 deviceId 重连 ----
  const same = open('same-device', DEV_A);
  await wait(600); same.auth();
  await wait(1500);
  check('T1 新连接登录成功', same.authOk);
  check('T1 旧连接未收到 room:kicked（同设备静默替换）', !first.kicked,
        '旧连接收到: ' + JSON.stringify(first.got));
  check('T1 旧连接已被服务端关闭', first.closed);

  // ---- T2：另一台设备登录 ----
  const other = open('other-device', DEV_B);
  await wait(600); other.auth();
  await wait(1500);
  check('T2 新设备登录成功', other.authOk);
  check('T2 旧连接收到 room:kicked（异地登录仍顶号）', same.kicked,
        '旧连接收到: ' + JSON.stringify(same.got));

  // ---- T3：无 deviceId 的旧客户端兼容 ----
  const legacy = open('legacy', null);
  await wait(600); legacy.auth();
  await wait(1200);
  const legacyNew = open('legacy-new', null);
  await wait(600); legacyNew.auth();
  await wait(1500);
  check('T3 不带 deviceId 时仍按顶号处理（兼容旧客户端）', legacy.kicked,
        '旧连接收到: ' + JSON.stringify(legacy.got));

  [first, same, other, legacy, legacyNew].forEach((s) => { try { s.ws.close(); } catch {} });
  await wait(300);
  console.log(`\n结果: ${pass} 通过 / ${fail} 失败`);
  process.exit(fail === 0 ? 0 : 1);
})();
