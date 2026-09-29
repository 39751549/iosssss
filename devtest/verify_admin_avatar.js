/**
 * 端到端验证：管理后台的「设置头像」链路真的能用。
 *
 * 流程（全程不碰真实用户）：
 *   1. 用 WebSocket 注册一个临时测试账号 → 拿 userId
 *   2. 调 /api/admin/upload-avatar 上传一张真实 PNG
 *   3. 校验返回的 /avatar/xxx 能 200 取回、且 Content-Type 是图片
 *   4. 校验 admin overview 里该用户的 avatar 字段已更新
 *   5. 删除这个临时账号，收工
 *
 * 用法：node verify_admin_avatar.js
 */
const WebSocket = require('ws');

const HTTP = 'http://43.142.76.172:8125';
const WS = 'ws://43.142.76.172:8125';
const PWD = process.env.ADMIN_PWD || 'admin888';

// 一张真实的 1x1 红色 PNG（服务端会嗅探魔数，必须是合法图片）
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64');

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('  ✅ ' + name + (detail ? '  → ' + detail : '')); }
  else { fail++; console.log('  ❌ ' + name + (detail ? '  → ' + detail : '')); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function adminApi(action, body) {
  const res = await fetch(HTTP + '/api/admin/' + action, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(Object.assign({ password: PWD }, body || {}))
  });
  return res.json();
}

/** 建一个临时账号，返回 { userId, close } */
function makeTestUser() {
  return new Promise((resolve, reject) => {
    const name = 'avtest' + Date.now().toString(36);
    const ws = new WebSocket(WS);
    const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error('auth 超时')); }, 15000);
    ws.on('open', () => ws.send(JSON.stringify({
      type: 'auth', username: name, password: 'pw123456', deviceId: 'devtest-avatar'
    })));
    ws.on('message', d => {
      let m; try { m = JSON.parse(d.toString()); } catch { return; }
      if (m.type === 'auth:ok') {
        clearTimeout(timer);
        resolve({ userId: m.data.userId, name, close: () => { try { ws.close(); } catch {} } });
      } else if (m.type === 'error') {
        clearTimeout(timer); try { ws.close(); } catch {}; reject(new Error(m.msg));
      }
    });
    ws.on('error', e => { clearTimeout(timer); reject(e); });
  });
}

(async () => {
  console.log('--- 1. 创建临时测试账号 ---');
  const u = await makeTestUser();
  check('临时账号已登录', !!u.userId, u.name + ' / ' + u.userId);

  try {
    console.log('\n--- 2. 上传头像 ---');
    const up = await fetch(HTTP + '/api/admin/upload-avatar?password=' + encodeURIComponent(PWD) +
                           '&userId=' + encodeURIComponent(u.userId), {
      method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: PNG
    });
    const upJson = await up.json();
    check('上传接口返回 ok', upJson.ok === true, JSON.stringify(upJson).slice(0, 90));
    check('返回了 /avatar/ 路径', typeof upJson.url === 'string' && upJson.url.startsWith('/avatar/'),
          upJson.url || '');

    console.log('\n--- 3. 头像可被取回 ---');
    const got = await fetch(HTTP + upJson.url);
    const buf = Buffer.from(await got.arrayBuffer());
    check('GET 头像 200', got.status === 200, 'HTTP ' + got.status);
    check('Content-Type 是图片', /^image\//.test(got.headers.get('content-type') || ''),
          got.headers.get('content-type') || '');
    check('内容与上传一致（长度）', buf.length === PNG.length,
          buf.length + ' vs ' + PNG.length);

    console.log('\n--- 4. 后台数据已更新 ---');
    const ov = await adminApi('overview', {});
    const row = ((ov.data || {}).users || []).find(x => x.id === u.userId);
    check('该用户出现在后台用户列表', !!row, row ? row.name : '未找到');
    check('avatar 字段已写入', !!row && row.avatar === upJson.url, row ? row.avatar : '');

  } finally {
    console.log('\n--- 5. 清理临时账号 ---');
    const del = await adminApi('clear-user', { userId: u.userId });
    check('临时账号已删除', del.ok === true);
    const ov2 = await adminApi('overview', {});
    const gone = !((ov2.data || {}).users || []).some(x => x.id === u.userId);
    check('确认已从列表消失', gone);
    u.close();
  }

  console.log('\n结果：%d 通过 / %d 失败', pass, fail);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('脚本异常：', e.message); process.exit(1); });
