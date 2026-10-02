#!/usr/bin/env node
/* -*- 网页版登录/进房全链路验收 -*-
 * 模拟 index.html / room.html 改造后的真实消息流：
 *   1. hello → 账号密码 auth（新号自动注册）→ auth:ok
 *   2. room:create → room:created（幂等，第二次返回同一间）
 *   3. room:join → join:ok → room:state
 *   4. room:my → 我的永久房间
 *   5. 第二条连接同凭据登录 → auth:ok（同 deviceId 静默顶替不踢）
 *   6. 按房间号 join → join:ok
 *   7. 旧协议 {type:'auth', userId} 必须被拒（回归确认）
 */
const { spawn } = require('child_process');
const WebSocket = require('ws');

const PORT = 8201;
let passed = 0, failed = 0;
function ok(cond, name) {
  if (cond) { passed++; console.log('  ✅', name); }
  else { failed++; console.log('  ❌', name); }
}

function mkWS() {
  return new Promise((res, rej) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const queue = [];
    const waiters = [];
    ws.on('message', d => {
      const m = JSON.parse(d.toString());
      const i = waiters.findIndex(w => w.pred(m));
      if (i >= 0) waiters.splice(i, 1)[0].resolve(m);
      else queue.push(m);
    });
    ws.on('open', () => res({
      ws,
      send: o => ws.send(JSON.stringify(o)),
      wait: (pred, ms = 6000) => {
        const qi = queue.findIndex(pred);
        if (qi >= 0) return Promise.resolve(queue.splice(qi, 1)[0]);
        return new Promise((resolve, reject) => {
          waiters.push({ pred, resolve });
          setTimeout(() => reject(new Error('wait timeout')), ms);
        });
      }
    }));
    ws.on('error', rej);
  });
}

(async () => {
  // 起服务端（独立数据目录，不污染线上）
  const srv = spawn('node', ['server.js'], {
    env: { ...process.env, PORT: String(PORT), VR_DATA_DIR: '.data-webtest' },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  await new Promise(r => setTimeout(r, 1200));

  try {
    const USER = 'webtest_user';
    const PWD = 'pw123456';

    console.log('\n== A. 账号密码登录（新号自动注册，网页端真实发法）==');
    const c1 = await mkWS();
    await c1.wait(m => m.type === 'hello');
    c1.send({ type: 'auth', username: USER, password: PWD, deviceId: 'web_test_dev' });
    const a1 = await c1.wait(m => m.type === 'auth:ok' || m.type === 'error');
    ok(a1.type === 'auth:ok', '新账号自动注册并登录成功');
    const uid = a1.data && a1.data.userId;
    ok(!!uid, 'auth:ok 带回 userId');

    console.log('\n== B. 建房（幂等）与我的房间 ==');
    c1.send({ type: 'room:create', userId: uid, name: '网页测试房', background: 'aurora' });
    const cr = await c1.wait(m => m.type === 'room:created' || m.type === 'error');
    ok(cr.type === 'room:created', '创建房间成功');
    const roomId = cr.data.id, roomNo = cr.data.no;
    c1.send({ type: 'room:create', userId: uid, name: '换个名字' });
    const cr2 = await c1.wait(m => m.type === 'room:created');
    ok(cr2.data.id === roomId && cr2.data.existed === true, '重复创建返回同一间（幂等）');
    c1.send({ type: 'room:my', userId: uid });
    const my = await c1.wait(m => m.type === 'room:my');
    ok(my.data && my.data.id === roomId, 'room:my 查到我的永久房间');

    console.log('\n== C. 进房（网页端 room.html 真实时序：auth:ok 后才 join）==');
    const c2 = await mkWS();
    await c2.wait(m => m.type === 'hello');
    c2.send({ type: 'auth', username: USER, password: PWD, deviceId: 'web_test_dev2' });
    const a2 = await c2.wait(m => m.type === 'auth:ok' || m.type === 'error');
    ok(a2.type === 'auth:ok', '第二条连接同凭据登录成功');
    c2.send({ type: 'user:mybgs', userId: a2.data.userId });
    c2.send({ type: 'room:join', userId: a2.data.userId, roomId });
    const j = await c2.wait(m => m.type === 'join:ok' || m.type === 'join:fail');
    ok(j.type === 'join:ok', 'join → join:ok');
    const st = await c2.wait(m => m.type === 'room:state');
    ok(!!st.data && Array.isArray(st.data.members), '收到 room:state 快照');

    console.log('\n== D. 按房间号加入（大厅输入 6 位号）==');
    const c3 = await mkWS();
    await c3.wait(m => m.type === 'hello');
    // 用一个真正的第二账号登录：服务端「同账号多端互踢」是正确行为，
    // 之前这里错拿第二个连接的 userId join，等于把自己顶掉了
    c3.send({ type: 'auth', username: 'webtest_second', password: PWD, deviceId: 'web_test_dev3' });
    const a3 = await c3.wait(m => m.type === 'auth:ok');
    ok(!!a3.data.userId, '第二账号登录成功');
    c3.send({ type: 'room:join', no: roomNo, userId: a3.data.userId });
    const j3 = await c3.wait(m => m.type === 'join:ok' || m.type === 'join:fail');
    ok(j3.type === 'join:ok', `按房间号 ${roomNo} 进房成功`);
    const st3 = await c3.wait(m => m.type === 'room:state');
    // 快照成员的用户标识是 m.user.id（publicUser），不是 m.userId
    const uniqUsers = new Set(st3.data.members.map(m => m.user && m.user.id));
    ok(uniqUsers.size >= 2, `房内 ${uniqUsers.size} 个不同用户（房主+宾客）`);

    console.log('\n== E. 回归：旧版裸 userId 登录必须被拒 ==');
    const c4 = await mkWS();
    await c4.wait(m => m.type === 'hello');
    c4.send({ type: 'auth', userId: uid });
    const e4 = await c4.wait(m => m.type === 'error' || m.type === 'auth:ok');
    ok(e4.type === 'error', '旧协议被拒（服务端只认账号密码）');

    console.log('\n== F. 大厅 room:list ==');
    const c5 = await mkWS();
    await c5.wait(m => m.type === 'hello');
    c5.send({ type: 'auth', username: 'webtest_third', password: PWD, deviceId: 'web_dev5' });
    await c5.wait(m => m.type === 'auth:ok');
    c5.send({ type: 'room:list' });
    const ls = await c5.wait(m => m.type === 'room:list');
    ok(Array.isArray(ls.data) && ls.data.some(r => r.id === roomId), '大厅列表包含刚建的房');

  } catch (e) {
    failed++;
    console.log('  ❌ 异常:', e.message);
  } finally {
    srv.kill();
  }
  console.log(`\n结果: ${passed} 通过 / ${failed} 失败`);
  process.exit(failed ? 1 : 0);
})();
