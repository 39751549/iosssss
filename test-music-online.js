/* 在线曲库（GD Studio API）全链路测试 */
const WebSocket = require('ws');
const http = require('http');
const HOST = process.env.VR_HOST || '127.0.0.1:8199';
const BASE = 'http://' + HOST;
let failures = 0;
const check = (n, c, x) => { if (c) console.log('  ✅ ' + n); else { failures++; console.log('  ❌ ' + n + (x !== undefined ? ' | ' + JSON.stringify(x).slice(0,200) : '')); } };
const sleep = ms => new Promise(r => setTimeout(r, ms));

function wsClient(userId) {
  const ws = new WebSocket('ws://' + HOST);
  const c = { userId, msgs: [] };
  c.open = new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
  ws.on('message', raw => { try { c.msgs.push(JSON.parse(raw.toString())); } catch {} });
  ws.on('error', () => {});
  c.send = o => ws.send(JSON.stringify(o));
  c.waitFor = (pred, ms = 15000) => new Promise((res, rej) => {
    const t0 = Date.now();
    const iv = setInterval(() => {
      const x = c.msgs.find(pred);
      if (x) { clearInterval(iv); res(x); }
      else if (Date.now() - t0 > ms) { clearInterval(iv); rej(new Error('waitFor 超时: ' + pred)); }
    }, 80);
  });
  return c;
}
function getJson(path) {
  return new Promise((res, rej) => {
    http.get(BASE + path, r => { let d=''; r.on('data', c=>d+=c); r.on('end', () => { try { res(JSON.parse(d)); } catch(e){ rej(e); } }); }).on('error', rej);
  });
}

async function main() {
  /* 1. 搜索：本地 + 在线合并 */
  console.log('\n[1] 搜索合并');
  const s = await getJson('/api/music/search?q=' + encodeURIComponent('周杰伦') + '&source=netease');
  check('搜索 ok', s.ok === true);
  check('返回音源列表', Array.isArray(s.sources) && s.sources.length >= 5);
  const gdItems = s.list.filter(m => m.remote);
  check('包含在线结果（>=3 首）', gdItems.length >= 3, gdItems.length);
  check('在线歌曲 id 格式 gd|源|歌id', gdItems.length && /^gd\|netease\|\d+$/.test(gdItems[0].id), gdItems[0] && gdItems[0].id);
  check('在线歌曲带歌名/歌手', gdItems.length && gdItems[0].title && typeof gdItems[0].artist === 'string', gdItems[0]);

  /* 2. WS 点播在线歌曲 */
  console.log('\n[2] 点播在线歌曲');
  const A = wsClient('mu' + Date.now().toString(36));
  await A.open;
  A.send({ type: 'auth', userId: A.userId, profile: { name: '点播员' } });
  await A.waitFor(m => m.type === 'auth:ok');
  A.send({ type: 'room:create', userId: A.userId, name: '在线曲库测试' });
  const created = await A.waitFor(m => m.type === 'room:created');
  A.send({ type: 'room:join', userId: A.userId, roomId: created.data.id });
  await A.waitFor(m => m.type === 'join:ok');
  await sleep(200);

  const target = gdItems[0];
  A.send({ type: 'music:play-now', libraryId: target.id, title: target.title, artist: target.artist, by: A.userId });
  const snap = await A.waitFor(m => m.type === 'room:state' && m.data.currentSong, 20000);
  check('currentSong 有标题', snap.data.currentSong.title === target.title, snap.data.currentSong.title);
  check('currentSong 是云端直链', /^https?:\/\//.test(snap.data.currentSong.url), snap.data.currentSong.url);
  check('libraryId 保留（切歌可重新解析）', snap.data.currentSong.libraryId === target.id);

  /* 3. 加入歌单（远端歌，先不播放） */
  console.log('\n[3] 加入第二首到歌单');
  const target2 = gdItems[1];
  A.send({ type: 'music:add', libraryId: target2.id, title: target2.title, artist: target2.artist, by: A.userId });
  await sleep(400);
  const snap2 = A.msgs.filter(m => m.type === 'room:state').pop();
  check('歌单里有 2 首', snap2.data.playlist.length === 2, snap2.data.playlist.length);
  check('第二首 remote 引用已入列', snap2.data.playlist.some(x => x.libraryId === target2.id));

  /* 4. 切到下一首（远端歌实时解析） */
  console.log('\n[4] next 切歌重新解析');
  A.send({ type: 'music:control', action: 'next' });
  const snap3 = await A.waitFor(m => m.type === 'room:state' && m.data.currentSong && m.data.currentSong.libraryId === target2.id, 20000);
  check('切到第二首', snap3.data.currentSong.libraryId === target2.id);
  check('第二首拿到直链', /^https?:\/\//.test(snap3.data.currentSong.url), snap3.data.currentSong.url);

  /* 5. 解散房间清理 */
  A.send({ type: 'room:destroy', userId: A.userId, roomId: created.data.id });
  await A.waitFor(m => m.type === 'room:destroyed');
  console.log('\n[5] 清理测试房间 ✅');

  console.log('\n' + (failures === 0 ? '🎉 在线曲库全链路通过' : '💥 ' + failures + ' 项失败'));
  process.exit(failures === 0 ? 0 : 1);
}
main().catch(e => { console.error('测试异常:', e.message); process.exit(1); });
