/**
 * 场景测试集 —— 跑在本地隔离服务器上。
 *
 * 用法:  node devtest/run.js           （自动起本地服务器 → 跑全部 → 关掉）
 *        node devtest/scenarios.js     （对着已启动的服务器跑）
 *
 * 目标：把"改一行→打包→重装→手点→发现没修好"的循环，换成"改一行→3 秒出结果"。
 */
const http = require('http');
const zlib = require('zlib');
const crypto = require('crypto');
const { IOSClient, wait } = require('./ios-client');

const HOST = process.env.VR_HOST || '127.0.0.1:8126';

let pass = 0, fail = 0;
const failures = [];

function check(name, ok, extra) {
  if (ok) { pass++; console.log('  ✅ ' + name + (extra ? '   ' + extra : '')); }
  else { fail++; failures.push(name); console.log('  ❌ ' + name + (extra ? '   ' + extra : '')); }
}
function section(t) { console.log('\n── ' + t + ' ──'); }
const rnd = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 6);

// ---------- HTTP 辅助 ----------

function post(path, obj) {
  return new Promise((res) => {
    const body = JSON.stringify(obj);
    const [host, port] = HOST.split(':');
    const req = http.request({
      host, port: Number(port), path, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (r) => {
      let d = ''; r.on('data', (c) => { d += c; });
      r.on('end', () => res({ code: r.statusCode, body: d }));
    });
    req.on('error', (e) => res({ code: -1, body: 'ERR ' + e.message }));
    req.write(body); req.end();
  });
}
function get(path) {
  return new Promise((res) => {
    const [host, port] = HOST.split(':');
    http.get({ host, port: Number(port), path }, (r) => {
      let n = 0; r.on('data', (c) => { n += c.length; });
      r.on('end', () => res({ code: r.statusCode, len: n, ct: r.headers['content-type'] }));
    }).on('error', (e) => res({ code: -1, len: 0, ct: 'ERR ' + e.message }));
  });
}

/** 造一张指定体积、不可压缩的真 PNG（模拟用户真实照片） */
function makePng(targetBytes) {
  const idat = zlib.deflateSync(crypto.randomBytes(targetBytes), { level: 0 });
  const table = [...Array(256)].map((_, n) => {
    let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    return c >>> 0;
  });
  const crc = (b) => {
    let c = 0xFFFFFFFF;
    for (const x of b) c = table[(c ^ x) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const t = Buffer.from(type);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc(Buffer.concat([t, data])));
    return Buffer.concat([len, t, data, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(1, 0); ihdr.writeUInt32BE(1, 4); ihdr[8] = 8; ihdr[9] = 0;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---------- 场景 ----------

/** 1. 自动登录：建连后服务端要主动说话，客户端才能触发 silentAuth */
async function s1_自动登录() {
  section('自动登录（"只要不卸载就永远不掉线"的地基）');
  const c = new IOSClient({ host: HOST, label: 'auto', deviceId: 'dev-' + rnd() });
  const opened = await Promise.race([
    c.connect().then(() => 'ok'),
    wait(4000).then(() => 'timeout'),
  ]);
  check('建连成功', opened === 'ok');
  check('服务端主动下发 hello（silentAuth 的触发条件）', c.sawType('hello'), '收到: ' + JSON.stringify(c.types()));

  await c.signup('auto_' + rnd());
  check('静默登录成功 auth:ok', c.loggedIn);
  c.close();
}

/** 2. 切后台再回前台：同设备重连**不该**弹顶号 */
async function s2_切后台回来不误报顶号() {
  section('切后台 → 回前台（本次报的 bug）');
  const dev = 'dev-fixed-' + rnd();
  const c = new IOSClient({ host: HOST, label: 'bg', deviceId: dev });
  await c.connect();
  await c.signup('bgtest_' + rnd());
  const roomId = await c.createRoom('切后台测试房');
  await c.joinRoom(roomId);
  check('进房成功', !!c.roomId, 'roomId=' + c.roomId);

  c.background();
  await wait(400);
  await c.foreground();                       // 新版客户端：先拆旧连接再重连

  check('回前台后重新登录成功', c.loggedIn);
  check('回前台后自动回到原房间', c.roomId === roomId, 'roomId=' + c.roomId);
  check('未收到 room:kicked（同设备重连静默替换）', !c.kicked,
        '收到的帧: ' + JSON.stringify(c.types()));
  c.close();
}

/**
 * 3. 复现修复前的现象：客户端**不拆旧连接**就重连。
 * 旧服务端会把这条旧 socket 当"异地登录"顶掉，而它的消息回调还挂着 → 用户自己看到顶号提示。
 * 现在服务端按 deviceId 识别，同设备静默关闭，所以即使客户端不拆旧连接也不会误报。
 */
async function s3_旧客户端遗留连接也不误报() {
  section('遗留旧连接（模拟修复前的客户端行为）');
  const dev = 'dev-stale-' + rnd();
  const c = new IOSClient({ host: HOST, label: 'stale', deviceId: dev });
  await c.connect();
  await c.signup('stale_' + rnd());
  const roomId = await c.createRoom('遗留连接测试房');
  await c.joinRoom(roomId);

  c.background();
  await wait(400);
  await c.foreground({ keepOldSocket: true });  // 旧 socket 不拆，故意留隐患

  check('新连接正常登录', c.loggedIn);
  check('即使旧 socket 未拆除，也不弹顶号（服务端按 deviceId 静默替换）', !c.kicked,
        '收到的帧: ' + JSON.stringify(c.types()));
  c.close();
}

/** 4. 真的在另一台设备登录：必须顶号 */
async function s4_异地登录仍然顶号() {
  section('另一台设备登录（真顶号必须还能用）');
  const uname = 'kicktest_' + rnd();
  const devA = 'dev-a-' + rnd(), devB = 'dev-b-' + rnd();

  const a = new IOSClient({ host: HOST, label: 'A', deviceId: devA });
  await a.connect();
  a.username = uname; a.password = 'pw123456';
  await a.silentAuth();
  check('设备 A 登录成功', a.loggedIn);

  const b = new IOSClient({ host: HOST, label: 'B', deviceId: devB });
  await b.connect();
  b.username = uname; b.password = 'pw123456';
  await b.silentAuth();
  await wait(800);

  check('设备 B 登录成功', b.loggedIn);
  check('设备 A 收到 room:kicked（异地登录被顶下线）', a.kicked,
        'A 收到的帧: ' + JSON.stringify(a.types()));
  a.close(); b.close();
}

/** 5. 同设备重复登录（同一台机器连开两次）：静默替换，不弹顶号 */
async function s5_同设备重复登录不误报() {
  section('同一台设备重复登录');
  const uname = 'sametwice_' + rnd();
  const dev = 'dev-same-' + rnd();

  const a = new IOSClient({ host: HOST, label: 'A1', deviceId: dev });
  await a.connect();
  a.username = uname; a.password = 'pw123456';
  await a.silentAuth();

  const b = new IOSClient({ host: HOST, label: 'A2', deviceId: dev });
  await b.connect();
  b.username = uname; b.password = 'pw123456';
  await b.silentAuth();
  await wait(800);

  check('第二条连接登录成功', b.loggedIn);
  check('第一条连接未被判为异地登录', !a.kicked, 'A1 收到的帧: ' + JSON.stringify(a.types()));
  a.close(); b.close();
}

/** 6. 自定义背景：上传 → 房间快照更新 → 文件可下载 */
async function s6_自定义背景全链路() {
  section('自定义背景（上传 → 快照 → 可下载）');
  const c = new IOSClient({ host: HOST, label: 'bg', deviceId: 'dev-bg-' + rnd() });
  await c.connect();
  await c.signup('bgflow_' + rnd());
  const roomId = await c.createRoom('背景流程房');
  await c.joinRoom(roomId);
  check('房间初始背景为内置主题', c.roomState && c.roomState.room.background === 'aurora',
        'background=' + JSON.stringify(c.roomState && c.roomState.room.background));

  for (const kb of [400, 2000, 4500]) {
    const png = makePng(kb * 1024);
    const dataUrl = 'data:image/png;base64,' + png.toString('base64');
    const bodyMB = JSON.stringify({ userId: c.userId, dataUrl }).length / 1024 / 1024;
    const r = await post('/api/upload-bg', { userId: c.userId, dataUrl });
    const okJson = (() => { try { return JSON.parse(r.body); } catch { return {}; } })();
    check(`上传 ${kb}KB 图（请求体 ${bodyMB.toFixed(2)}MB）`, r.code === 200 && okJson.ok === true,
          'HTTP ' + r.code + ' ' + r.body.slice(0, 70));
    await wait(700);
  }

  const bg = c.roomState && c.roomState.room.background;
  check('上传后房间快照的 background 变成 /bg/…', typeof bg === 'string' && bg.startsWith('/bg/'),
        'background=' + JSON.stringify(bg));

  if (typeof bg === 'string' && bg.startsWith('/bg/')) {
    const f = await get(bg);
    check('背景文件能下载', f.code === 200 && f.len > 0,
          'HTTP ' + f.code + ' 大小 ' + f.len + ' ' + f.ct);
  }

  // 切回内置主题
  c.send({ type: 'room:bg', roomId, background: 'hearts' });
  await wait(700);
  check('能切回内置主题', c.roomState && c.roomState.room.background === 'hearts',
        'background=' + JSON.stringify(c.roomState && c.roomState.room.background));
  c.close();
}

/** 7. 音乐：多人 ended 只推进一首 */
async function s7_音乐同步() {
  section('音乐同步');
  const a = new IOSClient({ host: HOST, label: 'A', deviceId: 'dev-m1-' + rnd() });
  await a.connect();
  await a.signup('mus_a_' + rnd());
  const roomId = await a.createRoom('点歌房');
  await a.joinRoom(roomId);

  // 本地服务器的曲库是空的，用外链歌曲造数据（不需要曲库里有这首歌）
  for (const i of [1, 2, 3]) {
    a.send({ type: 'music:add', userId: a.userId, title: '测试歌' + i,
             artist: 'QA', url: 'https://example.com/qa' + i + '.mp3', by: 'A' });
    await wait(350);
  }
  check('歌单加入 3 首', a.roomState && a.roomState.playlist.length === 3,
        'len=' + (a.roomState && a.roomState.playlist.length));

  const b = new IOSClient({ host: HOST, label: 'B', deviceId: 'dev-m2-' + rnd() });
  await b.connect();
  await b.signup('mus_b_' + rnd());
  await b.joinRoom(roomId);
  await wait(700);

  const first = a.roomState.currentSong && a.roomState.currentSong.id;
  a.musicControl('ended');
  b.musicControl('ended');       // 两人几乎同时上报
  await wait(1200);
  const second = a.roomState.currentSong && a.roomState.currentSong.id;
  const idx = a.roomState.playlist.findIndex((s) => s.id === second);
  check('两人同时上报 ended 只推进 1 首（不跳歌）', idx === 1,
        '当前在第 ' + (idx + 1) + ' 首，first=' + !!first);

  a.musicControl('mode', null, 'single');
  await wait(500);
  check('能切到单曲循环', a.roomState.playMode === 'single' || a.roomState.mode === 'single',
        'playMode=' + a.roomState.playMode);
  a.close(); b.close();
}

/** 8. 服务端稳健性：畸形消息不能掀翻进程 */
async function s8_畸形消息不崩() {
  section('服务端稳健性');
  const c = new IOSClient({ host: HOST, label: 'bad', deviceId: 'dev-bad-' + rnd() });
  await c.connect();
  c.ws.send('这不是 JSON');
  c.ws.send(JSON.stringify({ type: 'music:control' }));
  c.ws.send(JSON.stringify({ type: 'room:join', roomId: null, no: null }));
  c.ws.send(JSON.stringify({ type: 'auth' }));
  await wait(900);

  const ping = new IOSClient({ host: HOST, label: 'ping', deviceId: 'dev-ping-' + rnd() });
  const ok = await Promise.race([ping.connect().then(() => true), wait(3000).then(() => false)]);
  check('发完畸形消息后服务端仍存活', ok);
  ping.close(); c.close();
}

/**
 * 9. 自定义背景的持久性：离开房间再进 / 切后台回来 / 重开 App 都不能变回默认。
 *
 * 这是用户报的「离开房间再进去背景就变默认了、不是永久的」的回归测试。
 * 修之前服务端其实是持久的，问题在客户端把图片状态放在了会被重建的视图里；
 * 这条场景锁住服务端这一侧的行为，客户端那侧靠 AppState 统一持有图片来保证。
 */
async function s9_背景进出房间仍在() {
  section('自定义背景持久性（退出重进 / 前后台 / 重开 App）');
  const uname = 'bgk_' + rnd();
  const dev = 'dev-bgk-' + rnd();

  const c = new IOSClient({ host: HOST, label: 'bgk', deviceId: dev, username: uname, password: 'pw123456' });
  await c.connect();
  await c.signup(uname);
  const roomId = await c.createRoom('背景持久房');
  await c.joinRoom(roomId);

  const png = makePng(200 * 1024);
  const dataUrl = 'data:image/png;base64,' + png.toString('base64');
  const up = await post('/api/upload-bg', { userId: c.userId, dataUrl });
  await wait(800);
  const bgUrl = c.roomState && c.roomState.room.background;
  check('上传后背景为自定义图', up.code === 200 && typeof bgUrl === 'string' && bgUrl.startsWith('/bg/'),
        'background=' + JSON.stringify(bgUrl));

  // 离开房间 → 再进
  c.send({ type: 'room:leave' });
  await wait(600);
  await c.joinRoom(roomId);
  check('离开再进房，背景仍是自定义图', c.roomState && c.roomState.room.background === bgUrl,
        'background=' + JSON.stringify(c.roomState && c.roomState.room.background));

  // 切后台 → 回前台（重连 + 自动回房）
  c.roomState = null;
  c.background();
  await c.foreground();
  check('切后台再回来，背景仍是自定义图', c.roomState && c.roomState.room.background === bgUrl,
        'background=' + JSON.stringify(c.roomState && c.roomState.room.background));

  // 杀进程重开：全新连接 + 全新客户端对象
  c.destroy();
  await wait(400);
  const c2 = new IOSClient({ host: HOST, label: 'bgk2', deviceId: dev, username: uname, password: 'pw123456' });
  await c2.connect();
  await c2.silentAuth();
  c2.send({ type: 'room:my', userId: c2.userId });
  await wait(700);
  const my = c2.received.filter((m) => m.type === 'room:my').pop();
  check('重开 App 后「我的房间」背景仍是自定义图',
        my && my.data && my.data.background === bgUrl,
        'background=' + JSON.stringify(my && my.data && my.data.background));

  await c2.joinRoom(roomId);
  check('重开 App 后进房，背景仍是自定义图', c2.roomState && c2.roomState.room.background === bgUrl,
        'background=' + JSON.stringify(c2.roomState && c2.roomState.room.background));

  // 背景文件本身必须能下载（客户端渲染才有图可显示）
  const f = await get(bgUrl);
  check('背景文件可下载', f.code === 200 && f.len > 0, 'HTTP ' + f.code + ' 大小 ' + f.len);

  c2.close();
}

/**
 * 10. 换房不先退房，回原房间不能出现「2 个我」。
 *
 * 用户报的场景：进别人房间再回自己房间 → 房间里出现两个我 → 点麦位名片无限开关。
 * 根因是客户端从大厅点房间是**直接 join**（LobbyView 就是这么调的），
 * 旧房间里的成员记录没被清掉，同一个 userId 留下两条记录、还共用同一条 socket：
 *   - 快照里"我"出现 2 次 → 界面两个我
 *   - 服务端把 peer:new 发给这条连接自己 → 客户端跟自己的幽灵建语音连接（信令自我回环）
 * 修复：room:join 先把这条 ws 从所有房间摘干净，并清掉目标房里同 userId 的死连接。
 */
async function s10_换房回来不出现两个我() {
  section('换房回房不出现「2 个我」');
  const uname = 'mul_' + rnd();
  const dev = 'dev-mul-' + rnd();

  const a = new IOSClient({ host: HOST, label: 'mul-A', deviceId: dev, username: uname, password: 'pw123456' });
  await a.connect();
  await a.signup(uname);
  const roomA = await a.createRoom('我的房间');

  // 另一个人建一个别的房间
  const b = new IOSClient({ host: HOST, label: 'mul-B', deviceId: 'dev-mul-b-' + rnd() });
  await b.connect();
  await b.signup('mulb_' + rnd());
  const roomB = await b.createRoom('别人的房间');

  const mine = (st) => (st && st.members ? st.members.filter((m) => m.user && m.user.id === a.userId) : []);

  await a.joinRoom(roomA);
  check('进自己房间：只有 1 个我', mine(a.roomState).length === 1, '出现 ' + mine(a.roomState).length + ' 次');

  // 不先 room:leave，直接进别的房间（与 App 的真实点击一致）
  await a.joinRoom(roomB);
  check('进别人房间：正常 1 个我', mine(a.roomState).length === 1);

  await a.joinRoom(roomA);
  const dup = mine(a.roomState);
  check('回自己房间：仍然只有 1 个我', dup.length === 1, '出现 ' + dup.length + ' 次');
  const seats = dup.map((m) => m.seat);
  check('麦位不重复占用', new Set(seats).size === seats.length, '麦位 = ' + JSON.stringify(seats));

  const myCid = new Set(dup.map((m) => m.clientId));
  const selfPeerNew = a.received.filter(
    (m) => m.type === 'peer:new' && m.data && myCid.has(m.data.clientId)
  );
  check('没有指向自己的 peer:new（不会跟自己建语音连接）', selfPeerNew.length === 0,
        selfPeerNew.length + ' 条');

  // 换麦位后主动 sync，必须能立刻拿到最新快照（背景/成员即时刷新用）
  const before = a.received.filter((m) => m.type === 'room:state').length;
  a.send({ type: 'room:sync' });
  await wait(700);
  const after = a.received.filter((m) => m.type === 'room:state').length;
  check('room:sync 能立刻拉回快照', after > before, before + ' → ' + after);

  // 顺手验证房主权限没有因为 0 号位而丢
  check('房主快照里 hostClientId 就是自己', a.roomState.hostClientId === a.roomState.members.find(
    (m) => m.user && m.user.id === a.userId).clientId);

  a.close(); b.close();
}

// ---------- 入口 ----------

async function main() {
  console.log('目标服务器: ' + HOST);
  await s1_自动登录();
  await s2_切后台回来不误报顶号();
  await s3_旧客户端遗留连接也不误报();
  await s4_异地登录仍然顶号();
  await s5_同设备重复登录不误报();
  await s6_自定义背景全链路();
  await s9_背景进出房间仍在();
  await s10_换房回来不出现两个我();
  await s7_音乐同步();
  await s8_畸形消息不崩();

  console.log('\n' + '='.repeat(46));
  console.log(`结果: ${pass} 通过 / ${fail} 失败`);
  if (fail) console.log('失败项:\n  - ' + failures.join('\n  - '));
  process.exit(fail === 0 ? 0 : 1);
}

if (require.main === module) main();
module.exports = { main };
