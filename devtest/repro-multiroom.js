/**
 * 复现：进别人房间 → 回自己房间 之后出现「2 个我」
 *
 *   node devtest/repro-multiroom.js
 *
 * 时序完全按 iOS 端的真实点击顺序：
 *   ① 建房（= 我的永久房间 A）
 *   ② 进房间 A            （第一次）
 *   ③ 从大厅点另一个房间 B （**不先离开 A**，LobbyView 就是这么调的）
 *   ④ 回房间 A            （第二次）
 * 然后检查房间 A 的快照里，同一个 userId 出现了几次。
 */
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const http = require('http');
const { IOSClient } = require('./ios-client');

const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.DEV_PORT || 8127);
const DATA_DIR = path.join(__dirname, '.data-multiroom');
const HOST = '127.0.0.1:' + PORT;

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function waitHealth(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      http.get({ host: '127.0.0.1', port, path: '/healthz' }, (r) => {
        let d = ''; r.on('data', (c) => { d += c; }); r.on('end', () => resolve(d));
      }).on('error', () => {
        if (Date.now() > deadline) reject(new Error('本地服务器启动超时'));
        else setTimeout(tick, 250);
      });
    };
    tick();
  });
}

/** 统计快照里某 userId 出现的成员条目（服务端下发的是 user.id） */
function dupesOf(state, userId) {
  if (!state || !state.members) return [];
  return state.members.filter((m) => (m.user && m.user.id) === userId);
}

(async () => {
  fs.rmSync(DATA_DIR, { recursive: true, force: true });
  fs.mkdirSync(DATA_DIR, { recursive: true });

  const child = spawn(process.execPath, [path.join(ROOT, 'server.js')], {
    cwd: ROOT,
    env: { ...process.env, PORT: String(PORT), DATA_DIR },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const log = [];
  child.stdout.on('data', (d) => log.push(d.toString()));
  child.stderr.on('data', (d) => log.push(d.toString()));
  const cleanup = () => { try { child.kill(); } catch (_) {} };
  process.on('exit', cleanup);

  try {
    await waitHealth(PORT, 15000);
    console.log('本地服务器就绪  ' + HOST + '\n');

    // 房主 A：建自己的永久房间
    const A = new IOSClient({ host: HOST, deviceId: 'dev-A', label: 'A' });
    await A.connect();
    await A.signup('reproA_' + Date.now().toString(36));
    const roomA = await A.createRoom('A 自己的房间');
    console.log('A 的永久房间 =', roomA);

    // 另一个人 B：建一个别的房间
    const B = new IOSClient({ host: HOST, deviceId: 'dev-B', label: 'B' });
    await B.connect();
    await B.signup('reproB_' + Date.now().toString(36));
    const roomB = await B.createRoom('B 的房间');
    console.log('B 的房间    =', roomB, '\n');

    // ② 进自己的房间 A
    await A.joinRoom(roomA);
    console.log('② 进 A 后  members =', A.roomState.members.length,
                '| 我自己出现', dupesOf(A.roomState, A.userId).length, '次');

    // ③ 大厅点房间 B（真实 App 就是这么调的：直接 join，不先 leave）
    await A.joinRoom(roomB);
    console.log('③ 进 B 后  B 房间 members =', A.roomState.members.length);
    console.log('   此时 A 房间里还留着我的旧成员记录吗？ —— 由 ④ 的结果体现\n');

    // ④ 回自己的房间 A
    await A.joinRoom(roomA);
    const dup = dupesOf(A.roomState, A.userId);
    const seats = dup.map((m) => m.seat);
    console.log('④ 回 A 后  A 房间 members =', A.roomState.members.length);
    console.log('   我自己出现', dup.length, '次，麦位 =', JSON.stringify(seats));
    console.log('   clientId =', JSON.stringify(dup.map((m) => m.clientId)));

    // 我的连接是否收到了针对「我自己残留 clientId」的 peer:new
    const myCids = new Set(dup.map((m) => m.clientId));
    const selfPeerNew = A.received.filter(
      (m) => m.type === 'peer:new' && m.data && myCids.has(m.data.clientId)
    );
    console.log('   收到指向自己残留 clientId 的 peer:new：', selfPeerNew.length, '条',
                selfPeerNew.length ? '← 会导致客户端跟自己的幽灵建立语音连接' : '');

    // 同一次 pushSnapshot 是否有重复投递（同一个 ws 挂了两条成员记录）
    const stateCount = A.types().filter((t) => t === 'room:state').length;
    console.log('   本次共收到 room:state', stateCount, '帧');

    const ok = dup.length === 1;
    console.log('\n' + (ok ? '✅ 未复现（每个人只出现 1 次）' : '❌ 已复现：出现 ' + dup.length + ' 个我'));

    A.destroy(); B.destroy();
  } catch (e) {
    console.log('❌ ' + e.message);
    console.log(log.join('').slice(-1500));
  } finally {
    cleanup();
  }
  process.exit(0);
})();
