/**
 * 轻量语音房 · 服务端（单文件）
 * HTTP 静态服务 + 管理 API + WebSocket 实时信令 + 内存房间状态
 * 依赖：仅 ws
 */
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 3000;
const PUBLIC_DIR = path.join(__dirname, 'public');
// 数据目录：云端可挂载持久卷时用 DATA_DIR 指定；未指定则用项目内 data/
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'store.json');
// 音乐文件存放目录（上传的音频）
const MUSIC_DIR = path.join(DATA_DIR, 'music');

/* ================= 在线曲库（GD Studio 免费 API） =================
 * 搜索: https://music-api.gdstudio.xyz/api.php?types=search&source=netease&name=xx&count=20
 * 取播放直链: https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=xx&br=320
 * 远端歌曲 libraryId 约定: "gd|<source>|<songId>"
 * 直链有时效（约 20 分钟），播放前实时解析并缓存 10 分钟。
 */
const GD_API = 'https://music-api.gdstudio.xyz/api.php';
const GD_SOURCES = [
  { id: 'netease', name: '网易云' },
  { id: 'tencent', name: 'QQ' },
  { id: 'kugou',   name: '酷狗' },
  { id: 'kuwo',    name: '酷我' },
  { id: 'migu',    name: '咪咕' }
];
const gdUrlCache = new Map(); // key: source|id|br -> { url, at }

function gdFetchJson(params) {
  return new Promise((resolve, reject) => {
    const qs = Object.entries(params).map(([k, v]) => k + '=' + encodeURIComponent(v)).join('&');
    const req = https.get(GD_API + '?' + qs, { timeout: 12000 }, res => {
      if (res.statusCode !== 200) { res.resume(); return reject(new Error('GD API HTTP ' + res.statusCode)); }
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', c => { raw += c; if (raw.length > 2e6) req.destroy(); });
      res.on('end', () => {
        try { resolve(JSON.parse(raw)); } catch (e) { reject(new Error('GD API 返回不是 JSON')); }
      });
    });
    req.on('timeout', () => { req.destroy(new Error('GD API 超时')); });
    req.on('error', reject);
  });
}

async function gdSearch(name, source, count) {
  const arr = await gdFetchJson({ types: 'search', source: source || 'netease', name, count: String(count || 20), pages: '1' });
  if (!Array.isArray(arr)) return [];
  return arr.map(m => ({
    id: 'gd|' + (m.source || source || 'netease') + '|' + m.id,
    title: String(m.name || '未知歌曲'),
    artist: Array.isArray(m.artist) ? m.artist.join(' / ') : String(m.artist || ''),
    album: String(m.album || ''),
    url: '', size: 0, remote: true, source: m.source || source || 'netease'
  }));
}

async function gdResolveUrl(source, songId, br) {
  const key = source + '|' + songId + '|' + (br || 320);
  const hit = gdUrlCache.get(key);
  if (hit && Date.now() - hit.at < 10 * 60 * 1000) return hit.url;
  const j = await gdFetchJson({ types: 'url', source, id: String(songId), br: String(br || 320) });
  if (!j || !j.url) throw new Error('拿不到播放地址');
  gdUrlCache.set(key, { url: j.url, at: Date.now() });
  if (gdUrlCache.size > 500) gdUrlCache.clear();
  return j.url;
}

/** 解析歌单条目的真实播放地址（远端歌实时解析，本地歌原样返回） */
async function resolveSongUrl(song) {
  if (!song || !song.remote || !song.libraryId) return song ? song.url : '';
  try {
    const [, source, songId] = String(song.libraryId).split('|');
    song.url = await gdResolveUrl(source, songId, 320);
  } catch { /* 保留旧 url 或空 */ }
  return song.url;
}

function parseGdLibraryId(libraryId) {
  const parts = String(libraryId || '').split('|');
  if (parts.length !== 3 || parts[0] !== 'gd') return null;
  return { source: parts[1], songId: parts[2] };
}

/* ---------- 个人音乐数据（收藏 / 最近播放，按 userId 持久化） ---------- */
function pushRecent(userId, song) {
  if (!userId || !song || !song.libraryId) return;
  const u = store.users[userId];
  if (!u) return;
  u.recent = (u.recent || []).filter(x => x.libraryId !== song.libraryId);
  u.recent.unshift({
    libraryId: song.libraryId, title: song.title || '未知歌曲',
    artist: song.artist || '', source: String(song.libraryId).split('|')[1] || '', at: Date.now()
  });
  if (u.recent.length > 30) u.recent.length = 30;
  saveStore();
}

/* ================= 数据 ================= */
const DEFAULT_CONFIG = {
  adminPassword: process.env.ADMIN_PASSWORD || 'admin888',
  vips: ['888888', '666666', '999999'],
  giftList: [
    { id: 'rose',   name: '玫瑰', emoji: '🌹', price: 1,    charm: 1 },
    { id: 'beer',   name: '啤酒', emoji: '🍺', price: 5,    charm: 5 },
    { id: 'cake',   name: '蛋糕', emoji: '🎂', price: 20,   charm: 20 },
    { id: 'star',   name: '星星', emoji: '⭐', price: 50,   charm: 50 },
    { id: 'rocket', name: '火箭', emoji: '🚀', price: 100,  charm: 100 },
    { id: 'crown',  name: '皇冠', emoji: '👑', price: 500,  charm: 500 },
    { id: 'sport',  name: '跑车', emoji: '🏎️', price: 1000, charm: 1000 },
    { id: 'castle', name: '城堡', emoji: '🏰', price: 5000, charm: 5000 }
  ]
};

let store = { users: {}, rooms: {}, accounts: {}, config: JSON.parse(JSON.stringify(DEFAULT_CONFIG)), library: [] };
/* accounts: { [username]: { pass: sha256hex, userId } } */
/* library: [{ id, title, artist, file, ext, size, duration?, uploadedAt }] */

function loadStore() {
  try {
    if (fs.existsSync(DATA_FILE)) {
      const raw = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
      store.users = raw.users || {};
      store.rooms = raw.rooms || {};
      store.accounts = (raw.accounts && typeof raw.accounts === 'object') ? raw.accounts : {};
      store.library = Array.isArray(raw.library) ? raw.library : [];
      store.config = Object.assign({}, DEFAULT_CONFIG, raw.config || {});
      if (!Array.isArray(store.config.giftList) || !store.config.giftList.length) store.config.giftList = DEFAULT_CONFIG.giftList;
    }
  } catch (e) { console.error('[store] 读取失败:', e.message); }
  // 预置管理员账号 admin / admin
  if (!store.accounts || typeof store.accounts !== 'object') store.accounts = {};
  if (!store.accounts.admin) store.accounts.admin = { pass: sha256('admin'), userId: 'u_admin' };
  // 校正历史脏昵称：u_admin 若被旧游客逻辑生成过「用户xx」随机名，改回 admin
  if (store.users.u_admin && /^用户/.test(store.users.u_admin.name || '')) {
    store.users.u_admin.name = 'admin';
  }
}
let saveTimer = null;
let saveWarned = false;
function saveStore() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      fs.mkdirSync(DATA_DIR, { recursive: true });
      fs.writeFileSync(DATA_FILE, JSON.stringify(store, null, 2), 'utf8');
    } catch (e) {
      if (!saveWarned) {
        saveWarned = true;
        console.warn('[store] 无法写入数据文件（云端只读文件系统？）：' + e.message);
        console.warn('[store] 数据将只保存在内存中，重启后丢失。建议挂载持久卷并设置 DATA_DIR。');
      }
    }
  }, 400);
}
loadStore();

/* ================= 工具 ================= */
function uid(p = 'u') { return p + crypto.randomBytes(5).toString('hex'); }
function safeStr(v, max = 40) {
  if (typeof v !== 'string') return '';
  return v.replace(/[<>]/g, '').replace(/\s+/g, ' ').trim().slice(0, max);
}
function randRoomNo() {
  let no;
  do { no = String(Math.floor(100000 + Math.random() * 900000)); }
  while (Object.values(store.rooms).some(r => r.no === no));
  return no;
}
/** 通过文件头识别图片类型 */
function sniffImageExt(buf) {
  if (!buf || buf.length < 12) return null;
  if (buf[0] === 0xFF && buf[1] === 0xD8 && buf[2] === 0xFF) return 'jpg';
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47) return 'png';
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38) return 'gif';
  if (buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') return 'webp';
  return null;
}
function sha256(s) {
  return crypto.createHash('sha256').update(String(s), 'utf8').digest('hex');
}

function publicUser(u) {
  if (!u) return null;
  // 防御式输出：任何字段缺失/脏类型都兜底，保证客户端解析永不失败
  return { id: u.id, name: u.name || '用户', avatar: typeof u.avatar === 'string' ? u.avatar : '',
           gender: (u.gender === 'male' || u.gender === 'female') ? u.gender : 'secret',
           bio: typeof u.bio === 'string' ? u.bio : '',
           coins: Number.isInteger(u.coins) ? u.coins : 0,
           charm: Number.isInteger(u.charm) ? u.charm : 0,
           vip: !!u.vip, vipLevel: Number.isInteger(u.vipLevel) ? u.vipLevel : 0 };
}
function ensureUser(id, patch) {
  let u = store.users[id];
  if (!u) {
    u = store.users[id] = {
      id, name: '用户' + id.slice(-4), avatar: '', gender: 'secret', bio: '',
      coins: 1000, charm: 0, vip: false, vipLevel: 0, createdAt: Date.now()
    };
  }
  // 字段兜底：修复历史脏数据（曾因 patch 带 undefined 被 Object.assign 污染）
  if (typeof u.name !== 'string' || !u.name) u.name = '用户' + id.slice(-4);
  if (typeof u.avatar !== 'string') u.avatar = '';
  if (typeof u.bio !== 'string') u.bio = '';
  if (u.gender !== 'male' && u.gender !== 'female') u.gender = 'secret';
  if (!Number.isInteger(u.coins)) u.coins = 1000;
  if (!Number.isInteger(u.charm)) u.charm = 0;
  if (typeof u.vip !== 'boolean') u.vip = false;
  if (!Number.isInteger(u.vipLevel)) u.vipLevel = 0;
  if (patch) Object.assign(u, patch);
  saveStore();
  return u;
}

/* 账号表：username → { pass, userId }。密码只存 sha256。新账号自动注册。 */
function ensureAccount(username, password) {
  if (!store.accounts) store.accounts = {};
  const acc = store.accounts[username];
  if (acc) return { ok: acc.pass === sha256(password), userId: acc.userId, isNew: false };
  const userId = 'u_' + username;
  store.accounts[username] = { pass: sha256(password), userId };
  return { ok: true, userId, isNew: true };
}

/* ================= 房间运行时 ================= */
const runtime = new Map(); // roomId -> { members:Map, playlist:[], currentSong, playing, startedAt, chatLog:[] }
/* 全局在线注册表：userId -> Set<ws>（大厅 + 房间都算在线，互踢用） */
const onlineUsers = new Map();
function addOnline(userId, ws) {
  if (!onlineUsers.has(userId)) onlineUsers.set(userId, new Set());
  onlineUsers.get(userId).add(ws);
}
function removeOnline(userId, ws) {
  const s = onlineUsers.get(userId);
  if (!s) return;
  s.delete(ws);
  if (s.size === 0) onlineUsers.delete(userId);
}
function getRuntime(roomId) {
  if (!runtime.has(roomId)) {
    runtime.set(roomId, { members: new Map(), playlist: [], currentSong: null, playing: false, startedAt: 0, chatLog: [] });
  }
  return runtime.get(roomId);
}
function roomSnapshot(roomId) {
  const room = store.rooms[roomId];
  if (!room) return null;
  const rt = getRuntime(roomId);
  const members = [];
  // 9 座位制：0 号 = 房主专位（顶部主位），1-8 = 宾客麦位（2x4 网格）
  const seats = new Array(9).fill(null);
  for (const m of rt.members.values()) {
    members.push({ clientId: m.clientId, user: publicUser(store.users[m.userId]), seat: m.seat, muted: m.muted, joinedAt: m.joinedAt });
    if (m.seat >= 0 && m.seat < 9) seats[m.seat] = m.clientId;
  }
  const host = (seats[0] && rt.members.get(seats[0])) ||
               members.find(m => m.user && m.user.id === room.ownerId);
  return {
    room: { id: room.id, name: room.name, no: room.no, background: room.background, ownerId: room.ownerId },
    members, seats,
    hostClientId: host ? host.clientId : (members[0] ? members[0].clientId : null),
    playlist: rt.playlist, currentSong: rt.currentSong, playing: rt.playing, startedAt: rt.startedAt,
    now: Date.now(), chatLog: rt.chatLog.slice(-60), giftList: store.config.giftList
  };
}

/* ================= HTTP ================= */
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json',
  '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.wav': 'audio/wav', '.txt': 'text/plain; charset=utf-8'
};
function send(res, code, body, headers) {
  res.writeHead(code, Object.assign({ 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-cache' }, headers || {}));
  res.end(body);
}
function readBody(req, cb, limit = 3e6) {
  let body = '';
  req.on('data', c => { body += c; if (body.length > limit) req.destroy(); });
  req.on('end', () => cb(body));
}
/** 读取二进制请求体（上传音频用） */
function readBinaryBody(req, cb, limit = 30 * 1024 * 1024) {
  const chunks = [];
  let size = 0;
  let aborted = false;
  req.on('data', c => {
    if (aborted) return;
    size += c.length;
    if (size > limit) { aborted = true; req.destroy(); return; }
    chunks.push(c);
  });
  req.on('end', () => { if (!aborted) cb(Buffer.concat(chunks)); });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const pathname = decodeURIComponent(url.pathname);

  if (pathname === '/healthz') {
    return send(res, 200, JSON.stringify({
      ok: true, uptime: Math.round(process.uptime()),
      rooms: Object.keys(store.rooms).length, users: Object.keys(store.users).length
    }), { 'Content-Type': 'application/json; charset=utf-8' });
  }
  if (pathname === '/api/config') return send(res, 200, JSON.stringify({ ok: true, giftList: store.config.giftList }));

  /* ---------- 曲库搜索（本地曲库 + 在线曲库，无需密码） ---------- */
  if (pathname === '/api/music/search') {
    const q = (url.searchParams.get('q') || '').trim().toLowerCase();
    const gdSource = url.searchParams.get('source') || 'netease';
    let list = store.library;
    if (q) {
      list = list.filter(m =>
        (m.title || '').toLowerCase().includes(q) ||
        (m.artist || '').toLowerCase().includes(q)
      );
    }
    // 本地曲库（最多 40 条）
    const local = list.slice(0, 40).map(m => ({
      id: m.id, title: m.title, artist: m.artist || '',
      url: '/api/music/file/' + m.id, size: m.size || 0, remote: false
    }));
    // 在线曲库（有关键词时追加 GD Studio 结果）
    const finish = (gd, gdErr) => {
      const result = local.concat(gd || []);
      send(res, 200, JSON.stringify({ ok: true, total: result.length, list: result, sources: GD_SOURCES, gdError: gdErr || '' }));
    };
    if (!q) return finish([], '');
    return gdSearch(q, gdSource, 20)
      .then(gd => finish(gd, ''))
      .catch(e => finish([], e.message || '在线曲库暂不可用'));
  }

  /* ---------- 音频流式播放（支持 Range，iOS 需要） ---------- */
  if (pathname.startsWith('/api/music/file/')) {
    const id = pathname.replace('/api/music/file/', '');
    const item = store.library.find(m => m.id === id);
    if (!item) return send(res, 404, 'Not Found');
    const filePath = path.join(MUSIC_DIR, item.file);
    if (!filePath.startsWith(MUSIC_DIR)) return send(res, 403, 'Forbidden');

    return fs.stat(filePath, (err, stat) => {
      if (err) return send(res, 404, 'Not Found');
      const total = stat.size;
      const range = req.headers.range;
      const mime = MIME['.' + (item.ext || 'mp3')] || 'audio/mpeg';

      // iOS AVPlayer 依赖 Range 请求来拖动进度
      if (range) {
        const match = /bytes=(\d*)-(\d*)/.exec(range);
        let start = match && match[1] ? parseInt(match[1], 10) : 0;
        let end = match && match[2] ? parseInt(match[2], 10) : total - 1;
        if (isNaN(start) || start < 0) start = 0;
        if (isNaN(end) || end >= total) end = total - 1;
        if (start > end) { start = 0; end = total - 1; }

        res.writeHead(206, {
          'Content-Range': `bytes ${start}-${end}/${total}`,
          'Accept-Ranges': 'bytes',
          'Content-Length': end - start + 1,
          'Content-Type': mime,
          'Access-Control-Allow-Origin': '*',
          'Cache-Control': 'public, max-age=86400'
        });
        fs.createReadStream(filePath, { start, end }).pipe(res);
      } else {
        res.writeHead(200, {
          'Content-Length': total,
          'Content-Type': mime,
          'Accept-Ranges': 'bytes',
          'Access-Control-Allow-Origin': '*',
          'Cache-Control': 'public, max-age=86400'
        });
        fs.createReadStream(filePath).pipe(res);
      }
    });
  }

  /* ---------- 上传音频（管理后台，需密码） ---------- */
  if (pathname === '/api/music/upload' && req.method === 'POST') {
    const pwd = url.searchParams.get('password');
    if (pwd !== store.config.adminPassword) {
      return send(res, 401, JSON.stringify({ ok: false, msg: '密码错误' }));
    }
    return readBinaryBody(req, buf => {
      if (!buf || buf.length === 0) return send(res, 400, JSON.stringify({ ok: false, msg: '文件为空' }));
      if (buf.length > 30 * 1024 * 1024) return send(res, 413, JSON.stringify({ ok: false, msg: '文件不能超过 30MB' }));

      // 从查询参数取歌名与歌手（避免 multipart 解析）
      const title = safeStr(url.searchParams.get('title') || '', 80);
      const artist = safeStr(url.searchParams.get('artist') || '', 60);
      const extRaw = (url.searchParams.get('ext') || 'mp3').toLowerCase().replace(/[^a-z0-9]/g, '');
      const ext = ['mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'].includes(extRaw) ? extRaw : 'mp3';

      if (!title) return send(res, 400, JSON.stringify({ ok: false, msg: '请填写歌名' }));

      try {
        fs.mkdirSync(MUSIC_DIR, { recursive: true });
        const id = 'm' + crypto.randomBytes(6).toString('hex');
        const safeFileName = id + '.' + ext;
        fs.writeFileSync(path.join(MUSIC_DIR, safeFileName), buf);

        const item = {
          id, title, artist,
          file: safeFileName, ext, size: buf.length,
          uploadedAt: Date.now()
        };
        store.library.push(item);
        saveStore();
        send(res, 200, JSON.stringify({ ok: true, item }));
      } catch (e) {
        console.error('[music] 保存失败:', e.message);
        send(res, 500, JSON.stringify({ ok: false, msg: '保存失败：' + e.message }));
      }
    });
  }

  if (pathname === '/api/upload-avatar' && req.method === 'POST') {
    return readBody(req, body => {
      try {
        const { userId, dataUrl } = JSON.parse(body);
        if (!userId || typeof dataUrl !== 'string' || !dataUrl.startsWith('data:image/'))
          return send(res, 400, JSON.stringify({ ok: false, msg: '参数错误' }));
        const u = store.users[userId];
        if (!u) return send(res, 404, JSON.stringify({ ok: false, msg: '用户不存在' }));
        u.avatar = dataUrl.slice(0, 800000); saveStore();
        send(res, 200, JSON.stringify({ ok: true }));
      } catch { send(res, 500, JSON.stringify({ ok: false, msg: '上传失败' })); }
    });
  }

  /* ---------- 上传房间背景图（存为文件，房间永久可复用） ---------- */
  if (pathname === '/api/upload-bg' && req.method === 'POST') {
    return readBody(req, body => {
      try {
        const { userId, dataUrl } = JSON.parse(body);
        const u = store.users[userId];
        if (!u) return send(res, 400, JSON.stringify({ ok: false, msg: '请先登录' }));
        const match = /^data:image\/(png|jpe?g|gif|webp);base64,(.+)$/.exec(dataUrl || '');
        if (!match) return send(res, 400, JSON.stringify({ ok: false, msg: '仅支持图片' }));
        const buf = Buffer.from(match[2], 'base64');
        if (buf.length > 6 * 1024 * 1024) return send(res, 413, JSON.stringify({ ok: false, msg: '背景图不能超过 6MB' }));
        fs.mkdirSync(path.join(DATA_DIR, 'bg'), { recursive: true });
        const ext = match[1] === 'jpeg' ? 'jpg' : match[1];
        const name = 'bg_' + crypto.randomBytes(6).toString('hex') + '.' + ext;
        fs.writeFileSync(path.join(DATA_DIR, 'bg', name), buf);
        const bgUrl = '/bg/' + name;
        // 记忆到"我的背景"，下次可一键复用
        u.myBgs = Array.isArray(u.myBgs) ? u.myBgs : [];
        u.myBgs = [bgUrl].concat(u.myBgs.filter(x => x !== bgUrl)).slice(0, 8);
        saveStore();
        // 自动应用到该用户的永久房间
        const room = Object.values(store.rooms).find(r => r.ownerId === userId);
        if (room) { room.background = bgUrl; saveStore(); pushSnapshot(room.id); }
        send(res, 200, JSON.stringify({ ok: true, url: bgUrl, myBgs: u.myBgs }));
      } catch (e) { send(res, 500, JSON.stringify({ ok: false, msg: '上传失败：' + e.message })); }
    }, 12e6);
  }

  /* ---------- 管理后台上传房间背景（指定房间） ---------- */
  if (pathname === '/api/admin/upload-bg' && req.method === 'POST') {
    const pwd = url.searchParams.get('password');
    if (pwd !== store.config.adminPassword) return send(res, 401, JSON.stringify({ ok: false, msg: '密码错误' }));
    const roomId = safeStr(url.searchParams.get('roomId') || '', 40);
    const room = store.rooms[roomId];
    if (!room) return send(res, 400, JSON.stringify({ ok: false, msg: '房间不存在' }));
    return readBinaryBody(req, buf => {
      if (!buf || buf.length === 0) return send(res, 400, JSON.stringify({ ok: false, msg: '文件为空' }));
      if (buf.length > 6 * 1024 * 1024) return send(res, 413, JSON.stringify({ ok: false, msg: '背景图不能超过 6MB' }));
      const ext = sniffImageExt(buf);
      if (!ext) return send(res, 400, JSON.stringify({ ok: false, msg: '仅支持 jpg/png/gif/webp 图片' }));
      try {
        fs.mkdirSync(path.join(DATA_DIR, 'bg'), { recursive: true });
        const name = 'bg_' + crypto.randomBytes(6).toString('hex') + '.' + ext;
        fs.writeFileSync(path.join(DATA_DIR, 'bg', name), buf);
        room.background = '/bg/' + name;
        saveStore(); pushSnapshot(room.id);
        send(res, 200, JSON.stringify({ ok: true, url: room.background }));
      } catch (e) {
        send(res, 500, JSON.stringify({ ok: false, msg: '保存失败：' + e.message }));
      }
    }, 8e6);
  }

  /* ---------- 访问上传的房间背景图 ---------- */
  if (pathname.startsWith('/bg/')) {
    const bgFile = path.join(DATA_DIR, 'bg', path.basename(pathname));
    if (!bgFile.startsWith(path.join(DATA_DIR, 'bg'))) return send(res, 403, 'Forbidden');
    return fs.readFile(bgFile, (err, data) => {
      if (err) return send(res, 404, 'Not Found');
      const ext = path.extname(bgFile).toLowerCase();
      send(res, 200, data, { 'Content-Type': MIME[ext] || 'image/png', 'Cache-Control': 'public, max-age=604800' });
    });
  }

  if (pathname.startsWith('/api/admin/')) {
    return readBody(req, body => {
      let p = {};
      try { p = body ? JSON.parse(body) : {}; } catch {}
      const pwd = p.password || url.searchParams.get('password');
      if (pwd !== store.config.adminPassword) return send(res, 401, JSON.stringify({ ok: false, msg: '密码错误' }));
      handleAdmin(pathname.replace('/api/admin/', ''), p, res);
    });
  }

  // 静态文件
  let p2 = pathname === '/' ? '/index.html' : pathname;
  const filePath = path.join(PUBLIC_DIR, p2);
  if (!filePath.startsWith(PUBLIC_DIR)) return send(res, 403, 'Forbidden');
  fs.readFile(filePath, (err, data) => {
    if (err) {
      return fs.readFile(path.join(PUBLIC_DIR, 'index.html'), (e2, d2) => {
        if (e2) return send(res, 404, 'Not Found');
        send(res, 200, d2, { 'Content-Type': MIME['.html'] });
      });
    }
    const ext = path.extname(filePath).toLowerCase();
    send(res, 200, data, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
  });
});

/* ================= 管理 API ================= */
function handleAdmin(action, p, res) {
  const ok = (obj) => send(res, 200, JSON.stringify(Object.assign({ ok: true }, obj || {})));
  const bad = (msg) => send(res, 400, JSON.stringify({ ok: false, msg }));

  switch (action) {
    case 'overview': {
      const rooms = Object.values(store.rooms).map(r => {
        const rt = getRuntime(r.id);
        return { id: r.id, no: r.no, name: r.name, background: r.background, count: rt.members.size, ownerId: r.ownerId, createdAt: r.createdAt };
      }).sort((a, b) => b.count - a.count);
      const online = [];
      for (const r of Object.values(store.rooms)) {
        const rt = getRuntime(r.id);
        for (const m of rt.members.values()) {
          const u = store.users[m.userId];
          if (u) online.push(Object.assign({ clientId: m.clientId, roomNo: r.no, roomName: r.name, seat: m.seat }, publicUser(u)));
        }
      }
      const users = Object.values(store.users).map(u => Object.assign(publicUser(u), { createdAt: u.createdAt }))
        .sort((a, b) => (b.coins + b.charm) - (a.coins + a.charm));
      return ok({ data: {
        stats: {
          userCount: users.length, roomCount: rooms.length, onlineCount: online.length,
          totalCoins: users.reduce((s, u) => s + u.coins, 0),
          totalCharm: users.reduce((s, u) => s + u.charm, 0),
          vipCount: users.filter(u => u.vip).length
        },
        rooms, online, users, vips: store.config.vips, giftList: store.config.giftList
      }});
    }
    case 'give-coins': {
      const u = store.users[p.userId]; if (!u) return bad('用户不存在');
      u.coins = Math.max(0, u.coins + Math.floor(Number(p.amount) || 0));
      saveStore(); return ok({ user: publicUser(u) });
    }
    case 'set-charm': {
      const u = store.users[p.userId]; if (!u) return bad('用户不存在');
      u.charm = Math.max(0, Math.floor(Number(p.amount) || 0));
      saveStore(); return ok({ user: publicUser(u) });
    }
    case 'set-vip': {
      const u = store.users[p.userId]; if (!u) return bad('用户不存在');
      u.vip = !!p.vip; u.vipLevel = u.vip ? (Number(p.vipLevel) || 1) : 0;
      saveStore(); return ok({ user: publicUser(u) });
    }
    case 'update-user': {
      const u = store.users[p.userId]; if (!u) return bad('用户不存在');
      if (typeof p.name === 'string' && p.name.trim()) u.name = safeStr(p.name, 20);
      if (['male', 'female', 'secret'].includes(p.gender)) u.gender = p.gender;
      if (typeof p.bio === 'string') u.bio = safeStr(p.bio, 60);
      saveStore(); return ok({ user: publicUser(u) });
    }
    case 'clear-user': {
      delete store.users[p.userId]; saveStore(); return ok();
    }
    case 'delete-room': {
      if (store.rooms[p.roomId]) { delete store.rooms[p.roomId]; runtime.delete(p.roomId); saveStore(); }
      return ok();
    }
    case 'update-room': {
      const r = store.rooms[p.roomId]; if (!r) return bad('房间不存在');
      if (typeof p.name === 'string' && p.name.trim()) r.name = safeStr(p.name, 22);
      if (typeof p.background === 'string') r.background = safeStr(p.background, 40);
      saveStore(); pushSnapshot(r.id); return ok();
    }
    case 'set-vips': {
      if (Array.isArray(p.vips)) { store.config.vips = p.vips.map(v => safeStr(v, 20)).filter(Boolean); saveStore(); }
      return ok({ vips: store.config.vips });
    }
    case 'set-admin-password': {
      if (typeof p.newPassword === 'string' && p.newPassword.length >= 4) {
        store.config.adminPassword = p.newPassword; saveStore(); return ok();
      }
      return bad('密码至少 4 位');
    }

    /* ---------- 曲库管理 ---------- */
    case 'music-list': {
      const kw = (p.q || '').toString().trim().toLowerCase();
      let list = store.library;
      if (kw) {
        list = list.filter(m => (m.title || '').toLowerCase().includes(kw) ||
                                (m.artist || '').toLowerCase().includes(kw));
      }
      const totalSize = store.library.reduce((s, m) => s + (m.size || 0), 0);
      return ok({ list: list.slice().sort((a, b) => b.uploadedAt - a.uploadedAt),
                  total: store.library.length,
                  totalSize });
    }
    case 'music-rename': {
      const item = store.library.find(m => m.id === p.id);
      if (!item) return bad('曲目不存在');
      if (typeof p.title === 'string' && p.title.trim()) item.title = safeStr(p.title, 80);
      if (typeof p.artist === 'string') item.artist = safeStr(p.artist, 60);
      saveStore();
      return ok({ item });
    }
    case 'music-delete': {
      const idx = store.library.findIndex(m => m.id === p.id);
      if (idx < 0) return bad('曲目不存在');
      const item = store.library[idx];
      // 删除物理文件
      try { fs.unlinkSync(path.join(MUSIC_DIR, item.file)); } catch {}
      store.library.splice(idx, 1);
      saveStore();
      return ok();
    }
    case 'music-clear-all': {
      store.library.forEach(m => {
        try { fs.unlinkSync(path.join(MUSIC_DIR, m.file)); } catch {}
      });
      store.library = [];
      saveStore();
      return ok();
    }

    default: return bad('未知操作: ' + action);
  }
}

/* ================= WebSocket ================= */
const wss = new WebSocketServer({ server, maxPayload: 2 * 1024 * 1024 });

function broadcast(roomId, msg, exceptClientId) {
  const rt = runtime.get(roomId); if (!rt) return;
  const raw = JSON.stringify(msg);
  for (const m of rt.members.values()) {
    if (m.clientId === exceptClientId) continue;
    if (m.ws && m.ws.readyState === 1) m.ws.send(raw);
  }
}
function sendTo(clientId, roomId, msg) {
  const rt = runtime.get(roomId); if (!rt) return;
  const m = rt.members.get(clientId);
  if (m && m.ws && m.ws.readyState === 1) m.ws.send(JSON.stringify(msg));
}
function pushSnapshot(roomId) {
  const snap = roomSnapshot(roomId);
  if (snap) broadcast(roomId, { type: 'room:state', data: snap });
}

function leaveRoom(clientId, roomId) {
  const rt = runtime.get(roomId); if (!rt) return;
  const me = rt.members.get(clientId); if (!me) return;
  const u = store.users[me.userId];
  rt.members.delete(clientId);
  broadcast(roomId, { type: 'peer:bye', data: { clientId } });
  if (u) {
    const sys = { id: uid('m'), sys: true, text: `${u.name} 离开了房间`, at: Date.now() };
    rt.chatLog.push(sys); broadcast(roomId, { type: 'chat', data: sys });
  }
  if (rt.members.size === 0) runtime.delete(roomId);
  else pushSnapshot(roomId);
}

/** 同账号互踢：同一 userId 只保留最新连接（大厅挂机的也算在线），旧连接从所在房间移除并断开 */
function kickExistingSessions(userId, exceptWs) {
  let kicked = 0;
  // 1) 全局在线注册表（覆盖大厅挂机连接）
  const sessions = onlineUsers.get(userId);
  if (sessions) {
    for (const old of [...sessions]) {
      if (old === exceptWs) continue;
      try { old.send(JSON.stringify({ type: 'room:kicked', data: { reason: '你的账号在其他地方登录了' } })); } catch {}
      if (old.joinedRoom) leaveRoom(old.clientId, old.joinedRoom);
      try { old.close(); } catch {}
      removeOnline(userId, old);
      kicked++;
    }
  }
  // 2) 兜底：房间 runtime 里 userId 相同但未走注册表的残留会话
  for (const [roomId, rt] of runtime) {
    for (const m of [...rt.members.values()]) {
      if (m.userId === userId && m.ws !== exceptWs) {
        try { m.ws.close(); } catch {}
        leaveRoom(m.clientId, roomId);
        kicked++;
      }
    }
  }
  return kicked;
}

wss.on('connection', (ws) => {
  let clientId = null;
  let joinedRoom = null;
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  const reply = (m) => { if (ws.readyState === 1) ws.send(JSON.stringify(m)); };

  ws.on('message', async (buf) => {
    let msg;
    try { msg = JSON.parse(buf.toString()); } catch { return reply({ type: 'error', msg: '消息格式错误' }); }

    switch (msg.type) {
      case 'auth': {
        // 账号密码登录：新账号自动注册，老账号校验密码（sha256），同账号多端互踢
        const username = String(msg.username || '').trim().toLowerCase();
        const password = typeof msg.password === 'string' ? msg.password : '';
        if (!/^[0-9a-z_\u4e00-\u9fa5]{2,24}$/.test(username)) {
          return reply({ type: 'error', msg: '账号需 2-24 位字母/数字/下划线/中文' });
        }
        if (!password || password.length > 64) {
          return reply({ type: 'error', msg: '请输入密码（最长 64 位）' });
        }
        const acc = ensureAccount(username, password);
        if (!acc.ok) return reply({ type: 'error', msg: '密码错误' });
        const userId = acc.userId;
        // 新账号以账号为昵称；老用户保留已改过的名片昵称
        const user = ensureUser(userId, acc.isNew ? { name: username } : null);
        // 注册到在线表，再踢旧会话（覆盖大厅挂机的连接）
        ws.authUserId = userId;
        addOnline(userId, ws);
        kickExistingSessions(userId, ws);
        saveStore();
        return reply({ type: 'auth:ok', data: { userId, user: publicUser(user), giftList: store.config.giftList } });
      }

      case 'profile:update': {
        const u = store.users[safeStr(msg.userId, 40)];
        if (!u) return reply({ type: 'error', msg: '用户不存在' });
        const p = msg.patch || {};
        if (typeof p.name === 'string' && p.name.trim()) u.name = safeStr(p.name, 20);
        if (typeof p.avatar === 'string') u.avatar = p.avatar.slice(0, 800000);
        if (['male', 'female', 'secret'].includes(p.gender)) u.gender = p.gender;
        if (typeof p.bio === 'string') u.bio = safeStr(p.bio, 60);
        saveStore();
        reply({ type: 'profile:ok', data: publicUser(u) });
        if (joinedRoom) pushSnapshot(joinedRoom);
        break;
      }

      case 'vip:login': {
        const code = safeStr(msg.code, 20);
        const u = store.users[safeStr(msg.userId, 40)];
        if (!u) return reply({ type: 'vip:fail', msg: '请先登录' });
        if (!store.config.vips.includes(code)) return reply({ type: 'vip:fail', msg: 'VIP 码无效' });
        u.vip = true; u.vipLevel = Math.max(u.vipLevel || 0, 3); u.coins += 5000;
        saveStore();
        reply({ type: 'vip:ok', data: publicUser(u) });
        if (joinedRoom) pushSnapshot(joinedRoom);
        break;
      }

      case 'room:create': {
        const ownerId = safeStr(msg.userId, 40);
        if (!store.users[ownerId]) return reply({ type: 'error', msg: '请先登录' });
        // 永久房间：每人只能有一个，已存在则直接复用（幂等）
        const exist = Object.values(store.rooms).find(r => r.ownerId === ownerId);
        if (exist) {
          return reply({ type: 'room:created', data: {
            id: exist.id, no: exist.no, name: exist.name,
            background: exist.background, existed: true
          }});
        }
        const id = uid('r');
        const room = { id, no: randRoomNo(),
          name: safeStr(msg.name, 22) || (store.users[ownerId].name + ' 的房间'),
          background: typeof msg.background === 'string' ? safeStr(msg.background, 60) : 'aurora',
          ownerId, createdAt: Date.now() };
        store.rooms[id] = room; saveStore();
        return reply({ type: 'room:created', data: {
          id: room.id, no: room.no, name: room.name,
          background: room.background, existed: false
        }});
      }

      case 'room:my': {
        // 查询我的永久房间（大厅"我的房间"卡片用）
        const userId = safeStr(msg.userId, 40);
        const mine = Object.values(store.rooms).find(r => r.ownerId === userId);
        if (!mine) return reply({ type: 'room:my', data: null });
        const rt = getRuntime(mine.id);
        return reply({ type: 'room:my', data: {
          id: mine.id, no: mine.no, name: mine.name, background: mine.background,
          ownerId: mine.ownerId, count: rt.members.size, createdAt: mine.createdAt
        }});
      }

      case 'room:destroy': {
        // 房主解散自己的永久房间（之后可重建）
        const userId = safeStr(msg.userId, 40);
        const room = store.rooms[safeStr(msg.roomId, 40)];
        if (!room) return reply({ type: 'error', msg: '房间不存在' });
        if (room.ownerId !== userId) return reply({ type: 'error', msg: '只有房主可以解散房间' });
        broadcast(room.id, { type: 'room:closed', data: { reason: '房主解散了房间' } });
        delete store.rooms[room.id];
        runtime.delete(room.id);
        saveStore();
        return reply({ type: 'room:destroyed', data: { roomId: room.id } });
      }

      case 'room:list': {
        const list = Object.values(store.rooms).map(r => {
          const rt = getRuntime(r.id);
          return { id: r.id, no: r.no, name: r.name, background: r.background, count: rt.members.size, ownerId: r.ownerId };
        }).sort((a, b) => b.count - a.count).slice(0, 60);
        return reply({ type: 'room:list', data: list });
      }

      case 'room:join': {
        const userId = safeStr(msg.userId, 40);
        const user = store.users[userId];
        if (!user) return reply({ type: 'join:fail', msg: '请先登录' });
        const room = msg.roomId ? store.rooms[msg.roomId]
                                : Object.values(store.rooms).find(r => r.no === safeStr(msg.no, 10));
        if (!room) return reply({ type: 'join:fail', msg: '房间不存在，请检查房间号' });

        clientId = uid('c'); joinedRoom = room.id;
        ws.clientId = clientId; ws.joinedRoom = joinedRoom; // 互踢移出房间用
        const rt = getRuntime(room.id);
        const isOwner = room.ownerId === userId;
        const used = new Set([...rt.members.values()].map(m => m.seat));
        let seat = -1;
        if (isOwner) {
          // 房主固定坐 0 号主位（顶部带头像框）
          seat = 0;
        } else {
          // 宾客从 1-8 号麦位找空位，坐满则站观众席
          for (let i = 1; i < 9; i++) if (!used.has(i)) { seat = i; break; }
        }
        rt.members.set(clientId, { clientId, userId, ws, seat, muted: false, joinedAt: Date.now() });

        reply({ type: 'join:ok', data: { clientId, roomId: room.id, userId } });
        for (const m of rt.members.values()) {
          if (m.clientId !== clientId && m.ws && m.ws.readyState === 1) {
            m.ws.send(JSON.stringify({ type: 'peer:new', data: { clientId, userId } }));
          }
        }
        pushSnapshot(room.id);
        const sys = { id: uid('m'), sys: true, text: `${user.name} 进入了房间`, at: Date.now() };
        rt.chatLog.push(sys); broadcast(room.id, { type: 'chat', data: sys });
        break;
      }

      case 'room:leave':
        if (joinedRoom) leaveRoom(clientId, joinedRoom);
        joinedRoom = null; clientId = null;
        ws.joinedRoom = null; ws.clientId = null;
        break;

      case 'room:rename': {
        const room = store.rooms[safeStr(msg.roomId, 40)];
        if (!room) return reply({ type: 'error', msg: '房间不存在' });
        if (room.ownerId !== msg.userId) return reply({ type: 'error', msg: '只有房主可以修改' });
        room.name = safeStr(msg.name, 22) || room.name;
        saveStore(); pushSnapshot(room.id);
        break;
      }

      case 'room:bg': {
        const room = store.rooms[safeStr(msg.roomId, 40)];
        if (!room) return reply({ type: 'error', msg: '房间不存在' });
        room.background = safeStr(msg.background, 60) || room.background;
        saveStore(); pushSnapshot(room.id);
        break;
      }

      /* VIP 自定义房间号（永久保存，全服唯一） */
      case 'room:set-no': {
        const room = store.rooms[safeStr(msg.roomId, 40)];
        if (!room) return reply({ type: 'error', msg: '房间不存在' });
        if (room.ownerId !== msg.userId) return reply({ type: 'error', msg: '只有房主可以修改房间号' });
        const u = store.users[msg.userId];
        if (!u || !u.vip) return reply({ type: 'error', msg: '自定义房间号是 VIP 专属功能 💎' });
        const no = safeStr(msg.no, 12).toUpperCase().replace(/[^0-9A-Z]/g, '');
        if (no.length < 4 || no.length > 10) return reply({ type: 'error', msg: '房间号需为 4-10 位数字或字母' });
        if (Object.values(store.rooms).some(r => r.id !== room.id && r.no === no))
          return reply({ type: 'error', msg: '该房间号已被别人占用' });
        room.no = no; saveStore(); pushSnapshot(room.id);
        return reply({ type: 'room:no-ok', data: { no } });
      }

      /* 我的背景图（上传过的记录，下次一键复用） */
      case 'user:mybgs': {
        const u = store.users[safeStr(msg.userId, 40)];
        return reply({ type: 'mybgs', data: { bgs: (u && Array.isArray(u.myBgs)) ? u.myBgs : [] } });
      }

      /* 收藏歌曲（按 userId 持久化） */
      case 'music:fav': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const me = rt.members.get(clientId); if (!me) return;
        const u = store.users[me.userId]; if (!u) return;
        const libId = String(msg.libraryId || '');
        if (msg.action === 'add' && libId) {
          u.favorites = (u.favorites || []).filter(x => x.libraryId !== libId);
          u.favorites.unshift({
            libraryId: libId, title: safeStr(msg.title, 60) || '未知歌曲',
            artist: safeStr(msg.artist, 80), source: libId.split('|')[1] || '', at: Date.now()
          });
          if (u.favorites.length > 100) u.favorites.length = 100;
        } else if (msg.action === 'remove' && libId) {
          u.favorites = (u.favorites || []).filter(x => x.libraryId !== libId);
        }
        saveStore();
        return reply({ type: 'music:favs', data: { favorites: u.favorites || [], recent: u.recent || [] } });
      }

      /* 查询收藏 + 最近播放 */
      case 'music:favs': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const me = rt.members.get(clientId); if (!me) return;
        const u = store.users[me.userId];
        return reply({ type: 'music:favs', data: {
          favorites: (u && u.favorites) || [], recent: (u && u.recent) || []
        }});
      }

      case 'seat:change': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const me = rt.members.get(clientId); if (!me) return;
        const room = store.rooms[joinedRoom];
        if (!room) return;
        const target = Number(msg.seat);
        if (!(target >= -1 && target <= 8)) return;
        const isOwner = room.ownerId === me.userId;
        if (target === 0 && !isOwner) return reply({ type: 'error', msg: '0 号主位是房主专位' });
        // 房主也可以换到 1-8 号麦位（0 号空出来时宾客仍不能坐）
        if (target >= 0 && [...rt.members.values()].some(m => m.seat === target && m.clientId !== clientId))
          return reply({ type: 'error', msg: '该麦位已被占用' });
        me.seat = target;
        if (target === -1) me.muted = true;
        pushSnapshot(joinedRoom);
        break;
      }

      case 'mic:toggle': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const me = rt.members.get(clientId); if (!me) return;
        me.muted = !!msg.muted;
        pushSnapshot(joinedRoom);
        break;
      }

      case 'chat': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const u = store.users[safeStr(msg.userId, 40)]; if (!u) return;
        const text = safeStr(msg.text, 200);
        if (!text) return;
        const m = { id: uid('m'), userId: u.id, name: u.name, avatar: u.avatar, vip: u.vip, vipLevel: u.vipLevel, text, at: Date.now() };
        rt.chatLog.push(m); if (rt.chatLog.length > 200) rt.chatLog.shift();
        broadcast(joinedRoom, { type: 'chat', data: m });
        break;
      }

      case 'gift:send': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const from = store.users[safeStr(msg.userId, 40)];
        const gift = store.config.giftList.find(g => g.id === msg.giftId);
        if (!from || !gift) return reply({ type: 'error', msg: '礼物不存在' });
        const count = Math.max(1, Math.min(99, Number(msg.count) || 1));
        const cost = gift.price * count;
        if (from.coins < cost) return reply({ type: 'error', msg: '金币不足，去后台领一点吧' });

        from.coins -= cost; from.charm += gift.charm * count;
        const toMember = [...rt.members.values()].find(m => m.clientId === msg.toClientId);
        if (toMember) {
          const to = store.users[toMember.userId];
          if (to) to.charm += gift.charm * count;
        }
        saveStore();
        broadcast(joinedRoom, { type: 'gift', data: {
          id: uid('g'), from: publicUser(from), toClientId: msg.toClientId,
          gift: { id: gift.id, name: gift.name, emoji: gift.emoji }, count, at: Date.now()
        }});
        reply({ type: 'coins:update', data: { coins: from.coins, charm: from.charm } });
        if (toMember) sendTo(toMember.clientId, joinedRoom, { type: 'charm:update', data: { user: publicUser(store.users[toMember.userId]) } });
        pushSnapshot(joinedRoom);
        break;
      }

      /* 加入歌单：支持本地曲库 / 在线曲库（gd|源|歌id）/ 外链 */
      case 'music:add': {
        const rt = runtime.get(joinedRoom); if (!rt) return;

        let song = null;
        const gd = parseGdLibraryId(msg.libraryId);
        if (gd) {
          // 在线曲库：歌单里存引用，播放时才解析直链（直链有时效）
          song = {
            id: uid('s'), title: safeStr(msg.title, 60) || '在线歌曲',
            artist: safeStr(msg.artist, 80),
            url: '', libraryId: String(msg.libraryId), remote: true,
            by: safeStr(msg.by, 20), at: Date.now()
          };
          const exist = rt.playlist.find(s => s.libraryId === song.libraryId);
          if (exist) {
            await resolveSongUrl(exist);
            rt.currentSong = exist; rt.playing = true; rt.startedAt = Date.now();
            pushSnapshot(joinedRoom);
            return reply({ type: 'music:playing', data: { title: exist.title } });
          }
        } else if (msg.libraryId) {
          const item = store.library.find(m => m.id === String(msg.libraryId));
          if (!item) return reply({ type: 'error', msg: '歌曲不存在' });
          song = {
            id: uid('s'),
            title: safeStr(msg.title, 60) || item.title,
            artist: safeStr(msg.artist, 80) || item.artist || '',
            url: '/api/music/file/' + item.id,
            libraryId: item.id,
            by: safeStr(msg.by, 20),
            at: Date.now()
          };
        } else {
          const url2 = safeStr(msg.url, 500);
          if (!/^https?:\/\//i.test(url2)) return reply({ type: 'error', msg: '请填写 http(s) 开头的音频地址' });
          song = { id: uid('s'), title: safeStr(msg.title, 60) || '未知歌曲',
                   artist: safeStr(msg.artist, 60), url: url2, by: safeStr(msg.by, 20), at: Date.now() };
        }

        // 本地/外链歌曲按 url 去重
        if (!song.remote) {
          const exist = rt.playlist.find(s => s.url === song.url);
          if (exist) {
            rt.currentSong = exist; rt.playing = true; rt.startedAt = Date.now();
            pushSnapshot(joinedRoom);
            return reply({ type: 'music:playing', data: { title: exist.title } });
          }
        }

        rt.playlist.push(song);
        if (!rt.currentSong) {
          await resolveSongUrl(song);
          rt.currentSong = song; rt.playing = true; rt.startedAt = Date.now();
        }
        pushRecent((rt.members.get(clientId) || {}).userId, rt.currentSong);
        pushSnapshot(joinedRoom);
        break;
      }

      /* 立即点播（替换当前歌曲；本地曲库 / 在线曲库均可） */
      case 'music:play-now': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const gd = parseGdLibraryId(msg.libraryId);
        let song;
        if (gd) {
          song = {
            id: uid('s'), title: safeStr(msg.title, 60) || '在线歌曲',
            artist: safeStr(msg.artist, 80),
            url: '', libraryId: String(msg.libraryId), remote: true,
            by: safeStr(msg.by, 20), at: Date.now()
          };
          try { song.url = await gdResolveUrl(gd.source, gd.songId, 320); }
          catch { return reply({ type: 'error', msg: '这首歌曲暂时拿不到播放地址，换一首试试' }); }
        } else {
          const item = store.library.find(m => m.id === String(msg.libraryId));
          if (!item) return reply({ type: 'error', msg: '歌曲不存在' });
          song = {
            id: uid('s'),
            title: safeStr(msg.title, 60) || item.title,
            artist: safeStr(msg.artist, 80) || item.artist || '',
            url: '/api/music/file/' + item.id, libraryId: item.id,
            by: safeStr(msg.by, 20), at: Date.now()
          };
        }
        const exist = rt.playlist.find(s => s.libraryId && s.libraryId === song.libraryId);
        if (!exist) rt.playlist.push(song);
        rt.currentSong = exist || song;
        rt.currentSong.url = song.url; // 重新解析，避免直链过期
        rt.playing = true; rt.startedAt = Date.now();
        pushRecent((rt.members.get(clientId) || {}).userId, rt.currentSong);
        pushSnapshot(joinedRoom);
        break;
      }

      case 'music:control': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const a = msg.action;
        if (a === 'play' && rt.currentSong) { rt.playing = true; rt.startedAt = Date.now(); }
        if (a === 'pause') rt.playing = false;
        if (a === 'next' && rt.playlist.length) {
          const idx = rt.playlist.findIndex(s => rt.currentSong && s.id === rt.currentSong.id);
          rt.currentSong = rt.playlist[(idx + 1) % rt.playlist.length];
          await resolveSongUrl(rt.currentSong); // 远端歌重取直链
          rt.playing = true; rt.startedAt = Date.now();
          pushRecent((rt.members.get(clientId) || {}).userId, rt.currentSong);
        }
        if (a === 'select' && msg.songId) {
          const s = rt.playlist.find(x => x.id === msg.songId);
          if (s) { await resolveSongUrl(s); rt.currentSong = s; rt.playing = true; rt.startedAt = Date.now(); pushRecent((rt.members.get(clientId) || {}).userId, s); }
        }
        if (a === 'remove' && msg.songId) {
          rt.playlist = rt.playlist.filter(x => x.id !== msg.songId);
          if (rt.currentSong && rt.currentSong.id === msg.songId) {
            rt.currentSong = rt.playlist[0] || null; rt.playing = !!rt.currentSong; rt.startedAt = Date.now();
          }
        }
        pushSnapshot(joinedRoom);
        break;
      }

      /* WebRTC 信令转发（P2P 语音） */
      case 'rtc:offer': case 'rtc:answer': case 'rtc:ice': case 'rtc:bye':
        if (joinedRoom) sendTo(safeStr(msg.to, 40), joinedRoom, { type: msg.type, from: clientId, data: msg.data });
        break;

      default:
        reply({ type: 'error', msg: '未知消息: ' + msg.type });
    }
  });

  ws.on('close', () => {
    if (ws.authUserId) removeOnline(ws.authUserId, ws);
    if (joinedRoom) leaveRoom(clientId, joinedRoom);
  });
  ws.on('error', () => {});
});

/* 心跳 */
setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) { ws.terminate(); continue; }
    ws.isAlive = false;
    try { ws.ping(); } catch {}
  }
}, 30000);

/* 房间为永久房间（每人一个），不再自动清理空房间。
   房主可主动通过 room:destroy 解散自己的房间。 */

server.listen(PORT, '0.0.0.0', () => {
  const nets = require('os').networkInterfaces();
  const ips = [];
  for (const k of Object.keys(nets)) for (const n of nets[k]) if (n.family === 'IPv4' && !n.internal) ips.push(n.address);
  console.log('\n🎙️  语音房已启动');
  console.log('   本机访问:  http://localhost:' + PORT);
  console.log('   管理后台:  http://localhost:' + PORT + '/admin.html   (默认密码 admin888)');
  ips.forEach(ip => console.log('   手机访问:  http://' + ip + ':' + PORT + '   (需与电脑同一 WiFi)'));
  console.log('');
});
