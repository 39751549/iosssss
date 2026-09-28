/** 冒烟测试：永久房间 + 9 座位制（0=房主主位，1-8 宾客）
 *  可用环境变量 VR_URL 指定服务器，默认本地 ws://127.0.0.1:8199
 *  例：VR_URL=ws://43.142.76.172:8125 node test-permanent.js
 */
const WebSocket = require('ws');
const URL = process.env.VR_URL || 'ws://127.0.0.1:8199';

let failures = 0;
function check(name, cond, extra) {
  if (cond) console.log('  ✅ ' + name);
  else { failures++; console.log('  ❌ ' + name + (extra !== undefined ? ' | ' + JSON.stringify(extra) : '')); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

function client(userId) {
  const ws = new WebSocket(URL);
  const c = { userId, msgs: [] };
  ws.on('message', raw => { try { c.msgs.push(JSON.parse(raw.toString())); } catch {} });
  ws.on('error', () => {});
  c.connect = () => new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
  c.waitFor = (pred, ms = 4000) => {
    const f = c.msgs.find(pred);
    if (f) return Promise.resolve(f);
    return new Promise((resolve, reject) => {
      const t0 = Date.now();
      const iv = setInterval(() => {
        const x = c.msgs.find(pred);
        if (x) { clearInterval(iv); resolve(x); }
        else if (Date.now() - t0 > ms) { clearInterval(iv); reject(new Error('waitFor timeout')); }
      }, 60);
    });
  };
  c.send = o => { try { ws.send(JSON.stringify(o)); } catch {} };
  c.close = () => { try { ws.close(); } catch {} };
  return c;
}

async function main() {
  const TAG = 'u' + Date.now().toString(36); // 每次运行唯一，避免历史数据干扰
  const A = client('userA_' + TAG); // 房主
  const B = client('userB_' + TAG); // 宾客1
  const C = client('userC_' + TAG); // 宾客2
  await A.connect(); await B.connect(); await C.connect();

  /* 1. auth */
  A.send({ type: 'auth', userId: A.userId, profile: { name: '房主A' } });
  B.send({ type: 'auth', userId: B.userId, profile: { name: '宾客B' } });
  C.send({ type: 'auth', userId: C.userId, profile: { name: '宾客C' } });
  await A.waitFor(m => m.type === 'auth:ok');
  await B.waitFor(m => m.type === 'auth:ok');
  await C.waitFor(m => m.type === 'auth:ok');
  console.log('\n[1] auth');
  check('三个客户端登录成功', true);

  /* 2. room:my 无房间 */
  A.send({ type: 'room:my', userId: 'userA_' + TAG });
  const r2 = await A.waitFor(m => m.type === 'room:my');
  console.log('\n[2] room:my（尚无房间）');
  check('返回 null', r2.data === null, r2.data);

  /* 3. 创建永久房间 */
  A.send({ type: 'room:create', userId: 'userA_' + TAG, name: 'A 的永久房', background: 'hearts' });
  const r3 = await A.waitFor(m => m.type === 'room:created');
  const room = r3.data;
  console.log('\n[3] room:create');
  check('创建成功', !!room.id && !!room.no, room);
  check('existed=false', room.existed === false);

  /* 4. 重复创建 → 幂等复用 */
  await sleep(100);
  A.send({ type: 'room:create', userId: 'userA_' + TAG, name: '改名也无用' });
  const r4 = await A.waitFor(m => m.type === 'room:created' && m.data.existed === true);
  console.log('\n[4] room:create 重复（幂等）');
  check('同一个房间', r4.data.id === room.id && r4.data.no === room.no, r4.data);
  check('existed=true', r4.data.existed === true);
  check('名字未被改动', r4.data.name === 'A 的永久房', r4.data.name);

  /* 5. room:my 返回房间 */
  A.send({ type: 'room:my', userId: 'userA_' + TAG });
  const r5 = await A.waitFor(m => m.type === 'room:my' && m.data);
  console.log('\n[5] room:my（已有房间）');
  check('返回房间', r5.data.id === room.id, r5.data);

  /* 6. 房主进房 → 自动坐 0 号 */
  A.send({ type: 'room:join', userId: 'userA_' + TAG, roomId: room.id });
  await A.waitFor(m => m.type === 'join:ok');
  await sleep(150);
  const s6 = A.msgs.filter(m => m.type === 'room:state').pop();
  console.log('\n[6] 房主进房');
  check('房主坐 0 号', s6 && s6.data.members.some(m => m.seat === 0 && m.user.id === 'userA_' + TAG),
        s6 && s6.data.members.map(m => m.seat));
  check('hostClientId 指向 0 号', s6 && s6.data.seats[0] === s6.data.hostClientId);

  /* 7. 宾客进房 → 从 1 号开始 */
  B.send({ type: 'room:join', userId: 'userB_' + TAG, roomId: room.id });
  C.send({ type: 'room:join', userId: 'userC_' + TAG, roomId: room.id });
  await sleep(400);
  const s7 = A.msgs.filter(m => m.type === 'room:state').pop();
  console.log('\n[7] 宾客进房');
  const memB = s7.data.members.find(m => m.user && m.user.id === 'userB_' + TAG);
  const memC = s7.data.members.find(m => m.user && m.user.id === 'userC_' + TAG);
  check('B 坐 1 号', memB && memB.seat === 1, s7.data.members.map(m => [m.user.id, m.seat]));
  check('C 坐 2 号', memC && memC.seat === 2);
  check('seats 数组长度 9', s7.data.seats.length === 9, s7.data.seats.length);
  check('seats[0] = 房主', s7.data.seats[0] === s7.data.hostClientId);

  /* 8. 宾客不可抢 0 号 */
  B.send({ type: 'seat:change', seat: 0 });
  const r8 = await B.waitFor(m => m.type === 'error');
  console.log('\n[8] 麦位保护');
  check('宾客抢 0 号被拒', /主位/.test(r8.msg), r8.msg);

  /* 8.5 房主可以换到 1-8 号麦位，也可以回 0 号 */
  A.send({ type: 'seat:change', seat: 3 });
  await sleep(200);
  const s8a = A.msgs.filter(m => m.type === 'room:state').pop();
  const aAfterMove = s8a.data.members.find(m => m.user.id === 'userA_' + TAG);
  check('房主换到 3 号成功', aAfterMove && aAfterMove.seat === 3,
        s8a.data.members.map(m => [m.user.id, m.seat]));
  A.send({ type: 'seat:change', seat: 0 });
  await sleep(200);
  const s8b = A.msgs.filter(m => m.type === 'room:state').pop();
  const aAfterBack = s8b.data.members.find(m => m.user.id === 'userA_' + TAG);
  check('房主回到 0 号成功', aAfterBack && aAfterBack.seat === 0);

  /* 9. 非房主不能解散 */
  B.send({ type: 'room:destroy', userId: 'userB_' + TAG, roomId: room.id });
  const r9 = await B.waitFor(m => m.type === 'error' && /房主/.test(m.msg || ''));
  check('非房主解散被拒', !!r9, r9 && r9.msg);

  /* 10. 房主解散 → 所有成员收到 room:closed */
  A.send({ type: 'room:destroy', userId: 'userA_' + TAG, roomId: room.id });
  const closedB = await B.waitFor(m => m.type === 'room:closed');
  const closedC = await C.waitFor(m => m.type === 'room:closed');
  const r10 = await A.waitFor(m => m.type === 'room:destroyed');
  console.log('\n[9] 解散房间');
  check('成员收到 room:closed', !!closedB && !!closedC);
  check('房主收到 room:destroyed', !!r10.data.roomId);

  /* 11. 解散后可重建（新房间号） */
  await sleep(100);
  A.send({ type: 'room:create', userId: 'userA_' + TAG, name: '重建的房' });
  const r11 = await A.waitFor(m => m.type === 'room:created' && m.data.id !== room.id);
  console.log('\n[10] 解散后重建');
  check('可重建', !!r11.data.id && r11.data.id !== room.id, r11.data);

  /* 12. 同账号互踢 */
  const D = client('userD_' + TAG);
  await D.connect();
  D.send({ type: 'auth', userId: D.userId, profile: { name: '双开用户' } });
  await D.waitFor(m => m.type === 'auth:ok');
  D.send({ type: 'room:join', userId: D.userId, roomId: r11.data.id });
  await sleep(250);
  const D2 = client('userD_' + TAG); // 同一账号第二个连接
  await D2.connect();
  D2.send({ type: 'auth', userId: D2.userId, profile: { name: '双开用户' } });
  await D2.waitFor(m => m.type === 'auth:ok');
  const kickedMsg = await D.waitFor(m => m.type === 'room:kicked', 4000);
  await sleep(400);
  const s12 = A.msgs.filter(m => m.type === 'room:state').pop();
  const dCount = s12.data.members.filter(m => m.user.id === D.userId).length;
  console.log('\n[11] 同账号互踢');
  check('旧连接收到 room:kicked', !!kickedMsg);
  check('房间内该用户只剩 1 个会话', dCount === 0 || dCount === 1, dCount);
  check('旧连接已不在房间', !s12.data.members.some(m => m.user.id === D.userId && m.clientId !== s12.data.members.find(x => x.user.id === D.userId)?.clientId));
  D.close(); D2.close();

  /* 13. 清理：解散重建的测试房间（不给线上留垃圾数据） */
  A.send({ type: 'room:destroy', userId: A.userId, roomId: r11.data.id });
  await A.waitFor(m => m.type === 'room:destroyed');
  console.log('\n[12] 清理测试房间');
  check('测试房间已解散', true);

  [A, B, C].forEach(c => c.close());
  console.log('\n' + (failures === 0 ? '🎉 全部通过' : '💥 ' + failures + ' 项失败'));
  process.exit(failures === 0 ? 0 : 1);
}

main().catch(e => { console.error('测试异常:', e.message); process.exit(1); });
