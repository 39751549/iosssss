/** 冒烟测试 v2：收藏/最近播放/VIP 自定义房间号/VIP 等级/我的背景
 *  可用环境变量 VR_URL 指定服务器，默认本地 ws://127.0.0.1:8199
 *  例：VR_URL=ws://43.142.76.172:8125 node test-features-v2.js
 */
const WebSocket = require('ws');
const http = require('http');
const URL = process.env.VR_URL || 'ws://127.0.0.1:8199';
const HTTP_BASE = URL.replace('ws', 'http');
const ADMIN_PWD = process.env.ADMIN_PWD || 'admin888';

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
        else if (Date.now() - t0 > ms) { clearInterval(iv); reject(new Error('waitFor timeout: ' + pred)); }
      }, 60);
    });
  };
  c.send = o => { try { ws.send(JSON.stringify(o)); } catch {} };
  c.close = () => { try { ws.close(); } catch {} };
  return c;
}

function httpPost(pathname, body, isBinary) {
  return new Promise((resolve, reject) => {
    const data = isBinary ? body : JSON.stringify(body || {});
    const req = http.request(HTTP_BASE + pathname, {
      method: 'POST',
      headers: { 'Content-Type': isBinary ? 'application/octet-stream' : 'application/json',
                 'Content-Length': Buffer.byteLength(data) }
    }, res => {
      let raw = '';
      res.on('data', c => raw += c);
      res.on('end', () => { try { resolve(JSON.parse(raw)); } catch { resolve({ ok: false, raw }); } });
    });
    req.on('error', reject);
    req.write(data); req.end();
  });
}

async function main() {
  const TAG = 'v' + Date.now().toString(36);
  const A = client('userA_' + TAG); // 房主（将设为 VIP12）
  const B = client('userB_' + TAG); // 宾客（普通）
  const C = client('userC_' + TAG); // 另一房主（测 VIP 拒绝/冲突）
  await A.connect(); await B.connect(); await C.connect();

  /* 1. auth */
  A.send({ type: 'auth', userId: A.userId, profile: { name: 'VIP房主' } });
  B.send({ type: 'auth', userId: B.userId, profile: { name: '普通用户' } });
  C.send({ type: 'auth', userId: C.userId, profile: { name: '挑战者' } });
  await A.waitFor(m => m.type === 'auth:ok');
  await B.waitFor(m => m.type === 'auth:ok');
  await C.waitFor(m => m.type === 'auth:ok');
  console.log('\n[1] 三客户端登录');

  /* 2. 管理后台把 A 设为 VIP 12 级 */
  const vipRes = await httpPost('/api/admin/set-vip', { password: ADMIN_PWD, userId: A.userId, vip: true, vipLevel: 12 });
  check('admin set-vip 成功且等级=12', vipRes.ok && vipRes.user && vipRes.user.vipLevel === 12, vipRes);

  /* 3. A 创建永久房间，A/B 都加入 */
  A.send({ type: 'room:create', userId: A.userId, name: '测试房V2' });
  const created = await A.waitFor(m => m.type === 'room:created');
  const roomId = created.data.id;
  A.send({ type: 'room:join', userId: A.userId, roomId });
  await A.waitFor(m => m.type === 'join:ok');
  B.send({ type: 'room:join', userId: B.userId, roomId });
  await B.waitFor(m => m.type === 'join:ok');
  console.log('\n[3] 建房 + 进房');

  /* 4. 非 VIP 自定义房间号被拒（C 自己先建房） */
  C.send({ type: 'room:create', userId: C.userId, name: '挑战者房' });
  await C.waitFor(m => m.type === 'room:created');
  C.send({ type: 'room:set-no', roomId: (await C.waitFor(m => m.type === 'room:created')).data.id, userId: C.userId, no: 'HACKER1' });
  const deny = await C.waitFor(m => m.type === 'error' && /VIP/.test(m.msg));
  console.log('\n[4] 非 VIP 改号');
  check('非 VIP 被拒（提示 VIP 专属）', !!deny.msg, deny);

  /* 5. VIP12 改号成功 + 快照同步 */
  const wantNo = 'V2TEST' + String(Date.now()).slice(-3);
  A.send({ type: 'room:set-no', roomId, userId: A.userId, no: wantNo });
  const noOk = await A.waitFor(m => m.type === 'room:no-ok');
  const customNo = noOk.data.no;
  const snap = await A.waitFor(m => m.type === 'room:state' && m.data.room.no === customNo, 4000);
  console.log('\n[5] VIP 改号');
  check('改号成功 room:no-ok', noOk.data.no === wantNo, noOk);
  check('快照房间号已同步', snap.data.room.no === customNo, snap.data.room.no);

  /* 6. 冲突房间号被拒（先把 C 也设为 VIP，否则会先被 VIP 检查拦截） */
  await httpPost('/api/admin/set-vip', { password: ADMIN_PWD, userId: C.userId, vip: true, vipLevel: 3 });
  await sleep(200);
  const cRoomId = (C.msgs.find(m => m.type === 'room:created')).data.id;
  C.send({ type: 'room:set-no', roomId: cRoomId, userId: C.userId, no: customNo });
  const conflict = await C.waitFor(m => m.type === 'error' && /占用/.test(m.msg));
  console.log('\n[6] 房间号冲突');
  check('被占用房间号被拒', !!conflict.msg, conflict);

  /* 7. 短房间号被拒 */
  C.send({ type: 'room:set-no', roomId: cRoomId, userId: C.userId, no: 'AB' });
  const short = await C.waitFor(m => m.type === 'error' && /4-10/.test(m.msg));
  console.log('\n[7] 非法格式');
  check('短于 4 位被拒', !!short.msg, short);

  /* 8. 上传一首本地测试歌（走管理 HTTP API） */
  const fakeMp3 = Buffer.concat([Buffer.from([0xFF, 0xFB, 0x90, 0x00]), Buffer.alloc(2048, 7)]);
  const up = await httpPost('/api/music/upload?password=' + ADMIN_PWD + '&title=测试歌V2&artist=测试歌手&ext=mp3', fakeMp3, true);
  check('上传测试歌曲成功', up.ok && up.item && up.item.id, up);
  const songId = up.item.id;

  /* 9. play-now 点播 → 双方收到快照 → B 的最近播放有记录 */
  A.send({ type: 'music:play-now', libraryId: songId, title: '测试歌V2', artist: '测试歌手', by: 'VIP房主' });
  await B.waitFor(m => m.type === 'room:state' && m.data.currentSong && m.data.currentSong.title === '测试歌V2');
  console.log('\n[9] 点播 + 最近播放');
  check('点播成功并同步', true);
  await sleep(400);
  A.send({ type: 'music:favs' });
  const bFavs = await A.waitFor(m => m.type === 'music:favs');
  check('点播者最近播放有这首歌', (bFavs.data.recent || []).some(x => x.libraryId === songId), bFavs.data.recent);
  check('最近播放字段完整', (bFavs.data.recent || []).every(x => x.libraryId && x.title && typeof x.at === 'number'));

  /* 10. 收藏：add → 查询有 → 重复 add 去重 → remove */
  A.msgs.length = 0; // 清掉旧 music:favs 响应，避免 waitFor 匹配到历史消息
  A.send({ type: 'music:fav', action: 'add', libraryId: songId, title: '测试歌V2', artist: '测试歌手' });
  let aFavs = await A.waitFor(m => m.type === 'music:favs');
  console.log('\n[10] 收藏');
  check('收藏成功', (aFavs.data.favorites || []).some(x => x.libraryId === songId), aFavs.data.favorites);
  A.send({ type: 'music:fav', action: 'add', libraryId: songId, title: '测试歌V2', artist: '测试歌手' });
  aFavs = await A.waitFor(m => m.type === 'music:favs' && m.data.favorites.filter(x => x.libraryId === songId).length === 1);
  check('重复收藏去重（仍 1 条）', aFavs.data.favorites.filter(x => x.libraryId === songId).length === 1);
  A.send({ type: 'music:fav', action: 'remove', libraryId: songId });
  aFavs = await A.waitFor(m => m.type === 'music:favs' && !(m.data.favorites || []).some(x => x.libraryId === songId));
  check('取消收藏成功', !(aFavs.data.favorites || []).some(x => x.libraryId === songId));

  /* 11. VIP 等级在快照成员里可见（先触发一次新快照，因为前面清过消息缓冲） */
  A.send({ type: 'mic:toggle', muted: false });
  await A.waitFor(m => m.type === 'room:state');
  const st12 = A.msgs.filter(m => m.type === 'room:state').pop();
  const hostUser = st12.data.members.find(m => m.user.id === A.userId);
  console.log('\n[11] VIP 等级');
  check('房主 vipLevel=12 出现在快照', hostUser && hostUser.user.vipLevel === 12, hostUser && hostUser.user.vipLevel);

  /* 12. 我的背景查询 */
  A.send({ type: 'user:mybgs', userId: A.userId });
  const bgs = await A.waitFor(m => m.type === 'mybgs');
  console.log('\n[12] 我的背景');
  check('mybgs 响应且为数组', Array.isArray(bgs.data.bgs), bgs.data);

  /* 13. 清理：解散两个测试房间 + 删除测试歌 */
  A.send({ type: 'room:destroy', userId: A.userId, roomId });
  await A.waitFor(m => m.type === 'room:destroyed');
  C.send({ type: 'room:destroy', userId: C.userId, roomId: cRoomId });
  await C.waitFor(m => m.type === 'room:destroyed');
  await httpPost('/api/admin/music-delete', { password: ADMIN_PWD, id: songId });
  console.log('\n[13] 清理完成');

  A.close(); B.close(); C.close();
  console.log('\n========== 结果: ' + (failures ? '❌ ' + failures + ' 项失败' : '✅ 全部通过') + ' ==========');
  process.exit(failures ? 1 : 0);
}

main().catch(e => { console.error('测试异常:', e.message); process.exit(1); });
