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

/* 内置房间背景：写死 5 张，图片是同仓库的静态资源 public/presets/preset-N.gif，
 * 对外地址 /presets/preset-N.gif。iOS / Web 两端共用同一套 id，
 * 新建房间默认用第 1 张。 */
const DEFAULT_BG = '/presets/preset-1.gif';

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

async function gdResolveUrl(source, songId, br, force) {
  const key = source + '|' + songId + '|' + (br || 320);
  const hit = gdUrlCache.get(key);
  // 直链有时效：缓存 3 分钟（原先 10 分钟会把过期链接当有效返回）
  if (!force && hit && Date.now() - hit.at < 3 * 60 * 1000) return hit.url;
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
    song.resolvedAt = Date.now();
  } catch { /* 保留旧 url 或空 */ }
  return song.url;
}

/** 强制重解析（客户端播放失败时刷新直链用） */
async function forceResolveSongUrl(song) {
  if (!song || !song.remote || !song.libraryId) return song ? song.url : '';
  const [, source, songId] = String(song.libraryId).split('|');
  try {
    song.url = await gdResolveUrl(source, songId, 320, true);
    song.resolvedAt = Date.now();
  } catch { /* 保留旧 url */ }
  return song.url;
}

/**
 * 播放推进（播完自动切歌 / 手动下一首）。
 * 播放模式：
 *  - order  列表循环：播到最后一首后回到第一首
 *  - single 单曲循环：同一首无限重复
 *  - once   列表播完结束：最后一首播完停止
 */
async function advancePlaylist(rt, trigger) {
  if (!rt.playlist.length) { rt.playing = false; return; }
  const mode = rt.playMode || 'order';
  const idx = rt.playlist.findIndex(s => rt.currentSong && s.id === rt.currentSong.id);

  // 单曲循环（仅自动播完触发；手动下一首照常切换）
  if (mode === 'single' && trigger === 'ended' && rt.currentSong) {
    await resolveSongUrl(rt.currentSong);
    rt.playing = true;
    rt.startedAt = Date.now();
    rt.pauseOffsetMs = 0;
    return;
  }

  let next = null;
  if (trigger === 'ended' && mode === 'once') {
    next = (idx + 1 < rt.playlist.length) ? rt.playlist[idx + 1] : null; // 播完结束
  } else {
    next = rt.playlist[(idx + 1) % rt.playlist.length]; // 循环
  }
  if (!next) { rt.playing = false; rt.pauseOffsetMs = 0; return; }
  await resolveSongUrl(next);
  rt.currentSong = next;
  rt.playing = true;
  rt.startedAt = Date.now();
  rt.pauseOffsetMs = 0;
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
  // 全局房间背景模板（管理员上传，对所有房间通用；空串=未设置）
  defaultBg: '',
  giftList: [
    { id: 'rose',   name: '玫瑰', emoji: '🌹', price: 1,    charm: 1 },
    { id: 'beer',   name: '啤酒', emoji: '🍺', price: 5,    charm: 5 },
    { id: 'cake',   name: '蛋糕', emoji: '🎂', price: 20,   charm: 20 },
    { id: 'star',   name: '星星', emoji: '⭐', price: 50,   charm: 50 },
    { id: 'rocket', name: '火箭', emoji: '🚀', price: 100,  charm: 100 },
    { id: 'crown',  name: '皇冠', emoji: '👑', price: 500,  charm: 500 },
    { id: 'sport',  name: '跑车', emoji: '🏎️', price: 1000, charm: 1000 },
    { id: 'castle', name: '城堡', emoji: '🏰', price: 5000, charm: 5000 }
  ],
  /*
   * 头像框商城。加新头像框只要往这个数组里加一条 —— 客户端是通用的
   * 「渐变环 + 角标 + 可选外发光」渲染器，不用改代码也不用发版。
   * price = 0 是默认框（人人都有，不占背包位）。
   */
  avatarFrames: [
    { id: 'classic', name: '云白',   price: 0,     colors: ['FFFFFF', 'CFE0F5'],                     tier: 'normal' },
    { id: 'sakura',  name: '樱吹雪', price: 800,   colors: ['FFC2DC', 'FF7FAE'],   badge: '🌸', tier: 'normal' },
    { id: 'ocean',   name: '深海',   price: 1500,  colors: ['8FDCFF', '3FA9F5'],   badge: '🌊', tier: 'rare'   },
    { id: 'clover',  name: '四叶草', price: 2500,  colors: ['A8EFB6', '3ECFA0'],   badge: '🍀', tier: 'rare'   },
    { id: 'flame',   name: '烈焰',   price: 5000,  colors: ['FFB56B', 'FF5A3C'],   badge: '🔥', tier: 'epic',   glow: true },
    { id: 'galaxy',  name: '星河',   price: 12000, colors: ['A98CFF', '4A3FFF'],   badge: '✨', tier: 'epic',   glow: true },
    { id: 'royal',   name: '皇冠金', price: 30000, colors: ['FFE89A', 'FF9F1C'],   badge: '👑', tier: 'legend', glow: true },
    { id: 'aurora',  name: '极光',   price: 80000, colors: ['FF9AC8', 'FFD86B', '7ED0FF'], badge: '🌈', tier: 'legend', glow: true }
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
      // 老数据没有头像框清单 → 补上默认的，否则商城是空的
      if (!Array.isArray(store.config.avatarFrames) || !store.config.avatarFrames.length) {
        store.config.avatarFrames = DEFAULT_CONFIG.avatarFrames;
      }
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
/** 是否已有一轮落盘在写（写盘是异步的，避免并发写同一个文件） */
let savingNow = false;
/** 写盘期间又来了新改动 → 写完再补一轮，保证不丢最后一次修改 */
let saveDirty = false;

/** 标记「数据脏了」，400ms 内合并成一次落盘 */
function saveStore() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    flushStore();
  }, 400);
}

function warnSave(e) {
  if (saveWarned) return;
  saveWarned = true;
  console.warn('[store] 无法写入数据文件（云端只读文件系统？）：' + e.message);
  console.warn('[store] 数据将只保存在内存中，重启后丢失。建议挂载持久卷并设置 DATA_DIR。');
}

/**
 * 落盘（异步 + 原子替换）。
 *
 * 性能上改了两点：
 *   1. `JSON.stringify(store)` 不再带缩进 —— 缩进版体积约大 1.6 倍，序列化本身也更慢，
 *      而这个文件每次发言/送礼/进出房都要写一遍，是常驻热点。
 *   2. 从 `writeFileSync` 改成异步写「临时文件 → rename」。
 *      原来同步写会把 Node 的事件循环整个卡住（房间人一多、聊天记录一长，
 *      一次写盘就能让所有 WebSocket 消息延迟几百毫秒）；rename 在同一个文件系统内是原子的，
 *      顺带修掉「写到一半进程被杀 → store.json 变成半截 JSON → 重启直接丢全部数据」。
 */
function flushStore() {
  if (savingNow) { saveDirty = true; return; }
  savingNow = true;
  let text;
  try {
    text = JSON.stringify(store);
  } catch (e) {
    savingNow = false;
    console.error('[store] 序列化失败：' + e.message);
    return;
  }
  const tmp = DATA_FILE + '.tmp';
  fs.mkdir(DATA_DIR, { recursive: true }, () => {
    fs.writeFile(tmp, text, 'utf8', (err) => {
      if (err) {
        savingNow = false;
        warnSave(err);
        return;
      }
      fs.rename(tmp, DATA_FILE, (err2) => {
        savingNow = false;
        if (err2) warnSave(err2);
        if (saveDirty) { saveDirty = false; flushStore(); }
      });
    });
  });
}

/** 退出前同步补一次落盘：防抖窗口里的那次改动不会因为重启/被 kill 而丢 */
function flushStoreSync() {
  if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(DATA_FILE, JSON.stringify(store), 'utf8');
  } catch (e) {
    warnSave(e);
  }
}
process.on('SIGTERM', () => { flushStoreSync(); process.exit(0); });
process.on('SIGINT', () => { flushStoreSync(); process.exit(0); });

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

/**
 * 这条消息该操作哪个用户。
 *
 * 优先用**连接自己的身份**：auth 成功后服务端就把 userId 记在 `ws.authUserId` 上。
 * 这比让客户端每次在消息里塞一份可信得多 —— 否则改个 userId 就能花别人的金币。
 * `msg.userId` 只作兜底（尚未 auth 的连接 / 老客户端）。
 *
 * 这个函数是为修「商城和背包一直转圈」加的：`shop:list` / `shop:buy` / `frame:wear`
 * 原来只认 `msg.userId`，而客户端 payload 里压根没带这个字段，
 * 于是每次都回「请先登录」，商城清单永远是空数组 —— 界面就卡在"正在读取头像框…"，
 * 永远是转圈，也不会报错（收到的只是个 toast）。
 */
function currentUser(ws, msg) {
  const uid = (ws && ws.authUserId) || safeStr(msg && msg.userId, 40);
  return uid ? (store.users[uid] || null) : null;
}

function publicUser(u) {
  if (!u) return null;
  // 防御式输出：任何字段缺失/脏类型都兜底，保证客户端解析永不失败
  return { id: u.id, name: u.name || '用户', avatar: typeof u.avatar === 'string' ? u.avatar : '',
           gender: (u.gender === 'male' || u.gender === 'female') ? u.gender : 'secret',
           bio: typeof u.bio === 'string' ? u.bio : '',
           coins: Number.isInteger(u.coins) ? u.coins : 0,
           charm: Number.isInteger(u.charm) ? u.charm : 0,
           vip: !!u.vip, vipLevel: Number.isInteger(u.vipLevel) ? u.vipLevel : 0,
           // 当前穿戴的头像框 id（空 = 不戴）。背包列表不在这里下发 ——
           // 只有自己需要看到背包，走 shop:list 单独取，避免每个成员快照都驮一份数组。
           frame: typeof u.frame === 'string' ? u.frame : '' };
}

/* ================= VIP 等级（与刷礼物得到的魅力值挂钩） ================= */
// 魅力值阶梯：达到即自动晋升对应 VIP 等级（1-12），永久保留不掉级
const VIP_CHARM_STAIRS = [100, 500, 2000, 8000, 30000, 100000, 300000, 1000000, 3000000, 10000000, 30000000];
function vipLevelForCharm(charm) {
  let lv = 0;
  for (let i = 0; i < VIP_CHARM_STAIRS.length; i++) {
    if ((charm || 0) >= VIP_CHARM_STAIRS[i]) lv = i + 1;
  }
  return lv;
}
/** 刷礼物/设魅力后重算 VIP；返回新等级（未升级返回 null） */
function recomputeVip(u) {
  if (!u) return null;
  const lv = vipLevelForCharm(u.charm || 0);
  if (lv > (u.vipLevel || 0)) {
    u.vip = true;
    u.vipLevel = lv;
    return lv;
  }
  return null;
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
    runtime.set(roomId, { members: new Map(), playlist: [], currentSong: null, playing: false, startedAt: 0, chatLog: [],
      playMode: 'order', pauseOffsetMs: 0 });
  }
  const rt = runtime.get(roomId);
  if (!rt.playMode) rt.playMode = 'order';
  if (rt.pauseOffsetMs == null) rt.pauseOffsetMs = 0;
  return rt;
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
    room: { id: room.id, name: room.name, no: room.no, background: room.background,
            avatar: room.avatar || '', ownerId: room.ownerId,
            ownerVip: !!(store.users[room.ownerId] && store.users[room.ownerId].vip) },
    members, seats,
    hostClientId: host ? host.clientId : (members[0] ? members[0].clientId : null),
    playlist: rt.playlist, currentSong: rt.currentSong, playing: rt.playing, startedAt: rt.startedAt,
    playMode: rt.playMode || 'order',
    globalBg: store.config.defaultBg || '',
    now: Date.now(), chatLog: rt.chatLog.slice(-60), giftList: store.config.giftList
  };
}

/* ================= HTTP ================= */
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
  '.webp': 'image/webp',
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
        const match = /^data:image\/(png|jpe?g|gif|webp);base64,(.+)$/.exec(dataUrl);
        if (!match) return send(res, 400, JSON.stringify({ ok: false, msg: '仅支持图片' }));
        const buf = Buffer.from(match[2], 'base64');
        if (buf.length > 8 * 1024 * 1024) return send(res, 413, JSON.stringify({ ok: false, msg: '头像不能超过 8MB' }));
        // 存为文件（保留透明通道与 GIF 动画；URL 每次全新 → 客户端缓存按 URL 失效）
        fs.mkdirSync(path.join(DATA_DIR, 'avatar'), { recursive: true });
        const ext = match[1] === 'jpeg' ? 'jpg' : match[1];
        const name = 'av_' + crypto.randomBytes(6).toString('hex') + '.' + ext;
        fs.writeFileSync(path.join(DATA_DIR, 'avatar', name), buf);
        u.avatar = '/avatar/' + name;
        saveStore();
        // 用户所在房间即时刷新名片/麦位头像
        for (const rid of runtime.keys()) {
          const rt = runtime.get(rid);
          if ([...rt.members.values()].some(m => m.userId === userId)) pushSnapshot(rid);
        }
        send(res, 200, JSON.stringify({ ok: true, url: u.avatar }));
      } catch { send(res, 500, JSON.stringify({ ok: false, msg: '上传失败' })); }
    }, 12e6);
  }

  /* ---------- 管理后台给用户设置头像（文件式，支持透明/GIF） ---------- */
  if (pathname === '/api/admin/upload-avatar' && req.method === 'POST') {
    const pwd = url.searchParams.get('password');
    if (pwd !== store.config.adminPassword) return send(res, 401, JSON.stringify({ ok: false, msg: '密码错误' }));
    const userId = safeStr(url.searchParams.get('userId') || '', 40);
    const u = store.users[userId];
    if (!u) return send(res, 400, JSON.stringify({ ok: false, msg: '用户不存在' }));
    return readBinaryBody(req, buf => {
      if (!buf || buf.length === 0) return send(res, 400, JSON.stringify({ ok: false, msg: '文件为空' }));
      if (buf.length > 8 * 1024 * 1024) return send(res, 413, JSON.stringify({ ok: false, msg: '头像不能超过 8MB' }));
      const ext = sniffImageExt(buf);
      if (!ext) return send(res, 400, JSON.stringify({ ok: false, msg: '仅支持 jpg/png/gif/webp 图片' }));
      try {
        fs.mkdirSync(path.join(DATA_DIR, 'avatar'), { recursive: true });
        const name = 'av_' + crypto.randomBytes(6).toString('hex') + '.' + ext;
        fs.writeFileSync(path.join(DATA_DIR, 'avatar', name), buf);
        u.avatar = '/avatar/' + name;
        saveStore();
        for (const rid of runtime.keys()) {
          const rt = runtime.get(rid);
          if ([...rt.members.values()].some(m => m.userId === userId)) pushSnapshot(rid);
        }
        send(res, 200, JSON.stringify({ ok: true, url: u.avatar }));
      } catch (e) { send(res, 500, JSON.stringify({ ok: false, msg: '保存失败：' + e.message })); }
    }, 10e6);
  }

  /* ---------- 头像静态服务（长缓存：URL 变化才重新下载） ---------- */
  if (pathname.startsWith('/avatar/')) {
    const avFile = path.join(DATA_DIR, 'avatar', path.basename(pathname));
    if (!avFile.startsWith(path.join(DATA_DIR, 'avatar'))) return send(res, 403, 'Forbidden');
    return fs.readFile(avFile, (err, data) => {
      if (err) return send(res, 404, 'Not Found');
      const ext = path.extname(avFile).toLowerCase();
      send(res, 200, data, { 'Content-Type': MIME[ext] || 'image/png', 'Cache-Control': 'public, max-age=2592000, immutable' });
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

  /* ---------- 上传房间头像（只有房主能改；存为文件，圆形裁剪由客户端做） ---------- */
  if (pathname === '/api/upload-room-avatar' && req.method === 'POST') {
    return readBody(req, body => {
      try {
        const { userId, roomId, dataUrl } = JSON.parse(body);
        const room = store.rooms[roomId];
        if (!room) return send(res, 404, JSON.stringify({ ok: false, msg: '房间不存在' }));
        if (room.ownerId !== userId) return send(res, 403, JSON.stringify({ ok: false, msg: '只有房主能改房间头像' }));

        const old = room.avatar || '';

        // 传空 = 清除头像，客户端退回「房间名首字」兜底图标
        if (!dataUrl) {
          room.avatar = '';
          saveStore();
          if (old.startsWith('/room-avatar/')) {
            fs.unlink(path.join(DATA_DIR, 'room-avatar', path.basename(old)), () => {});
          }
          pushSnapshot(room.id);
          notifyLobby();
          return send(res, 200, JSON.stringify({ ok: true, url: '' }));
        }

        const match = /^data:image\/(png|jpe?g|gif|webp);base64,(.+)$/.exec(dataUrl);
        if (!match) return send(res, 400, JSON.stringify({ ok: false, msg: '仅支持图片' }));
        const buf = Buffer.from(match[2], 'base64');
        if (buf.length > 4 * 1024 * 1024) return send(res, 413, JSON.stringify({ ok: false, msg: '房间头像不能超过 4MB' }));

        fs.mkdirSync(path.join(DATA_DIR, 'room-avatar'), { recursive: true });
        const ext = match[1] === 'jpeg' ? 'jpg' : match[1];
        const name = 'ra_' + crypto.randomBytes(6).toString('hex') + '.' + ext;
        fs.writeFileSync(path.join(DATA_DIR, 'room-avatar', name), buf);
        room.avatar = '/room-avatar/' + name;
        saveStore();

        // 换了新的就把旧文件删掉，否则换十次头像 data 目录里就躺十张废图
        if (old.startsWith('/room-avatar/')) {
          fs.unlink(path.join(DATA_DIR, 'room-avatar', path.basename(old)), () => {});
        }

        pushSnapshot(room.id);   // 房内即时生效（顶栏 + 悬浮球）
        notifyLobby();           // 大厅卡片同步
        send(res, 200, JSON.stringify({ ok: true, url: room.avatar }));
      } catch (e) { send(res, 500, JSON.stringify({ ok: false, msg: '上传失败：' + e.message })); }
    }, 8e6);
  }

  /* ---------- 房间头像静态服务 ---------- */
  if (pathname.startsWith('/room-avatar/')) {
    const dir = path.join(DATA_DIR, 'room-avatar');
    const f = path.join(dir, path.basename(pathname));
    if (!f.startsWith(dir)) return send(res, 403, 'Forbidden');
    return fs.readFile(f, (err, data) => {
      if (err) return send(res, 404, 'Not Found');
      const ext = path.extname(f).toLowerCase();
      // 头像 URL 每次上传都是新文件名 → 可以放心长缓存，客户端按 URL 自然失效
      send(res, 200, data, { 'Content-Type': MIME[ext] || 'image/png', 'Cache-Control': 'public, max-age=2592000, immutable' });
    });
  }

  /* ---------- 全局房间背景模板（管理员上传，对所有房间通用，GIF 会动） ---------- */
  if (pathname === '/api/admin/upload-default-bg' && req.method === 'POST') {
    const pwd = url.searchParams.get('password');
    if (pwd !== store.config.adminPassword) return send(res, 401, JSON.stringify({ ok: false, msg: '密码错误' }));
    return readBinaryBody(req, buf => {
      if (!buf || buf.length === 0) return send(res, 400, JSON.stringify({ ok: false, msg: '文件为空' }));
      if (buf.length > 6 * 1024 * 1024) return send(res, 413, JSON.stringify({ ok: false, msg: '背景图不能超过 6MB' }));
      const ext = sniffImageExt(buf);
      if (!ext) return send(res, 400, JSON.stringify({ ok: false, msg: '仅支持 jpg/png/gif/webp 图片' }));
      try {
        fs.mkdirSync(path.join(DATA_DIR, 'bg'), { recursive: true });
        const name = 'bg_' + crypto.randomBytes(6).toString('hex') + '.' + ext;
        fs.writeFileSync(path.join(DATA_DIR, 'bg', name), buf);
        store.config.defaultBg = '/bg/' + name;
        saveStore();
        // 所有房间立即生效
        for (const rid of Object.keys(store.rooms)) pushSnapshot(rid);
        send(res, 200, JSON.stringify({ ok: true, url: store.config.defaultBg }));
      } catch (e) { send(res, 500, JSON.stringify({ ok: false, msg: '保存失败：' + e.message })); }
    }, 8e6);
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
        rooms, online, users, vips: store.config.vips, giftList: store.config.giftList,
        defaultBg: store.config.defaultBg || ''
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
      const upLv = recomputeVip(u); // 魅力值变化联动 VIP 等级
      saveStore(); return ok({ user: publicUser(u), vipUp: upLv || 0 });
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
      const uid = p.userId;
      delete store.users[uid];
      // 账号记录必须一起清 —— 只删 store.users 的话，被删的用户
      // 用原来的账号密码还能重新登录，账号直接「复活」。
      // 但 admin 账号要保护：删了管理员用户就再也进不去后台了。
      if (uid && uid !== 'u_admin') {
        for (const un of Object.keys(store.accounts || {})) {
          const acc = store.accounts[un];
          if (acc && acc.userId === uid) delete store.accounts[un];
        }
      }
      saveStore(); return ok();
    }
    case 'delete-room': {
      if (store.rooms[p.roomId]) { delete store.rooms[p.roomId]; runtime.delete(p.roomId); saveStore(); }
      return ok();
    }
    case 'update-room': {
      const r = store.rooms[p.roomId]; if (!r) return bad('房间不存在');
      if (typeof p.name === 'string' && p.name.trim()) r.name = safeStr(p.name, 22);
      if (typeof p.background === 'string') r.background = safeStr(p.background, 40);
      saveStore(); pushSnapshot(r.id); notifyLobby(); return ok();
    }
    case 'set-vips': {
      if (Array.isArray(p.vips)) { store.config.vips = p.vips.map(v => safeStr(v, 20)).filter(Boolean); saveStore(); }
      return ok({ vips: store.config.vips });
    }
    case 'clear-default-bg': {
      store.config.defaultBg = '';
      saveStore();
      for (const rid of Object.keys(store.rooms)) pushSnapshot(rid);
      return ok({ defaultBg: '' });
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

/**
 * 通知所有在线连接「房间列表有变化」（建房 / 解散 / 改房名 / 改房间头像）。
 * 只是让客户端去重拉一次 room:list，不下发数据本身 —— 大厅卡片数量少，
 * 重拉一次比维护增量补丁简单得多，也不会漏字段。
 */
function notifyLobby() {
  const raw = JSON.stringify({ type: 'rooms:changed' });
  for (const c of wss.clients) {
    if (c.readyState === 1) { try { c.send(raw); } catch {} }
  }
}

/**
 * 用户资料变化（头像框 / 金币 / 头像）→ 只通知他所在的房间。
 * 复用 charm:update 的批量格式：客户端本来就有"就地更新这几个成员"的逻辑，
 * 不用为头像框再造一条协议，老客户端也不会崩。
 */
function broadcastUserUpdate(u) {
  if (!u) return;
  for (const rid of runtime.keys()) {
    const rt = runtime.get(rid);
    let hit = false;
    for (const m of rt.members.values()) if (m.userId === u.id) { hit = true; break; }
    if (hit) broadcast(rid, { type: 'charm:update', data: { users: [publicUser(u)] } });
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

/**
 * 公屏写入 + 长度上限。
 *
 * 房间是长期的（qq 群式永久房），原来只有用户聊天那条分支做了 200 条截断，
 * 「进入房间 / 离开房间 / 送礼升级」这几类系统消息是只进不出的 ——
 * 房间开一天下来 chatLog 能涨到几万条，而每次 pushSnapshot 都要 slice 一遍、
 * 内存也一直被占着。这里统一收口。
 */
const CHAT_LOG_MAX = 200;
function pushChatLog(rt, msg) {
  rt.chatLog.push(msg);
  if (rt.chatLog.length > CHAT_LOG_MAX) {
    rt.chatLog.splice(0, rt.chatLog.length - CHAT_LOG_MAX);
  }
  return msg;
}

function leaveRoom(clientId, roomId) {
  const rt = runtime.get(roomId); if (!rt) return;
  const me = rt.members.get(clientId); if (!me) return;
  const u = store.users[me.userId];
  rt.members.delete(clientId);
  broadcast(roomId, { type: 'peer:bye', data: { clientId } });
  if (u) {
    const sys = { id: uid('m'), sys: true, text: `${u.name} 离开了房间`, at: Date.now() };
    pushChatLog(rt, sys); broadcast(roomId, { type: 'chat', data: sys });
  }
  if (rt.members.size === 0) runtime.delete(roomId);
  else pushSnapshot(roomId);
}

/**
 * 把一条连接从它残留的所有房间里摘干净。
 *
 * 为什么需要：客户端从大厅点另一个房间时是**直接 room:join**、不会先发 room:leave
 * （LobbyView 的每个房间入口都是这么调的）。于是原来的成员记录以"幽灵"形式留在旧房间 ——
 * 同一个 userId 两条成员记录、而且两条共用同一条 socket。后果：
 *   1. 回到原房间时界面上出现「2 个我」（成员数 +1、麦位被占住）；
 *   2. 服务端会把 peer:new 发给这条连接自己（幽灵的 clientId），
 *      客户端于是"跟自己建立语音连接"，信令自我回环。
 * 所以进房前必须先把这条 ws 的旧身份清掉。
 */
function detachWsFromRooms(ws) {
  let removed = 0;
  for (const [roomId, rt] of [...runtime]) {
    const stale = [...rt.members.values()].filter(m => m.ws === ws);
    for (const m of stale) { leaveRoom(m.clientId, roomId); removed++; }
  }
  return removed;
}

/**
 * 清掉目标房间里属于该 userId 的"死连接"成员记录。
 *
 * 服务端本就保证同一账号只保留最新连接（kickExistingSessions），
 * 所以目标房里如果还有别人 socket 顶着同一个 userId，那条一定是残留。
 * 一并摘掉，保证「房间里永远只有 1 个我」。
 */
function detachStaleSessionsOfUser(roomId, userId, keepWs) {
  const rt = runtime.get(roomId); if (!rt) return 0;
  let removed = 0;
  for (const m of [...rt.members.values()]) {
    if (m.userId !== userId || m.ws === keepWs) continue;
    leaveRoom(m.clientId, roomId);
    removed++;
  }
  return removed;
}

/** 判断某条旧连接是否与本次登录来自同一台设备 */
function isSameDevice(oldWs, deviceId) {
  if (!deviceId || !oldWs || !oldWs.deviceId) return false;
  return oldWs.deviceId === deviceId;
}

/**
 * 同账号互踢：同一 userId 只保留最新连接（大厅挂机的也算在线），旧连接从所在房间移除并断开。
 *
 * 关键区分（修复"切后台再回来提示在别处登录"）：
 *   同一台设备的旧连接 = 断网/切后台留下的残留 socket → **静默关闭**，不给它发 room:kicked。
 *   只有 deviceId 不同（真的换了台手机登录）才下发顶号提示。
 *
 * 之前不看设备标识、见同账号就顶，导致本机重连时自己的旧连接被判为"异地登录"，
 * 而那条旧连接的消息通道还挂在同一个 AppState 上，用户就在自己屏幕上看到了顶号提示。
 */
function kickExistingSessions(userId, exceptWs, deviceId) {
  let kicked = 0;
  // 1) 全局在线注册表（覆盖大厅挂机连接）
  const sessions = onlineUsers.get(userId);
  if (sessions) {
    for (const old of [...sessions]) {
      if (old === exceptWs) continue;
      const sameDevice = isSameDevice(old, deviceId);
      if (!sameDevice && old.readyState === 1) {
        try { old.send(JSON.stringify({ type: 'room:kicked', data: { reason: '你的账号在其他地方登录了' } })); } catch {}
      }
      if (old.joinedRoom) leaveRoom(old.clientId, old.joinedRoom);
      try { old.close(); } catch {}
      removeOnline(userId, old);
      if (!sameDevice) kicked++;
    }
  }
  // 2) 兜底：房间 runtime 里 userId 相同但未走注册表的残留会话
  for (const [roomId, rt] of runtime) {
    for (const m of [...rt.members.values()]) {
      if (m.userId === userId && m.ws !== exceptWs) {
        const sameDevice = isSameDevice(m.ws, deviceId);
        try { m.ws.close(); } catch {}
        leaveRoom(m.clientId, roomId);
        if (!sameDevice) kicked++;
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

  // 立刻回一帧 hello。
  // 客户端把「收到第一帧」当作链路已就绪的信号，进而触发自动登录；
  // 如果这里不说话，客户端会一直停在 connecting 状态、永远不发起 auth
  // （表现就是：每次重开 App 都要手动登录）。
  reply({ type: 'hello', data: { server: 'voice-room', ts: Date.now() } });

  ws.on('message', async (buf) => {
    let msg;
    try { msg = JSON.parse(buf.toString()); } catch { return reply({ type: 'error', msg: '消息格式错误' }); }

    // 整段处理包在 try 里：任何一处意外异常都不该掀翻整个进程。
    // （Node 15+ 未捕获的 Promise rejection 默认会直接终止进程 = 全房掉线）
    try {
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
        // deviceId 由客户端持久化生成：同 deviceId 的旧连接视为本机残留，静默替换不提示顶号
        ws.authUserId = userId;
        ws.deviceId = safeStr(msg.deviceId, 64);
        addOnline(userId, ws);
        kickExistingSessions(userId, ws, ws.deviceId);
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
            background: exist.background, avatar: exist.avatar || '', existed: true
          }});
        }
        const id = uid('r');
        const room = { id, no: randRoomNo(),
          name: safeStr(msg.name, 22) || (store.users[ownerId].name + ' 的房间'),
          background: typeof msg.background === 'string' ? safeStr(msg.background, 60) : DEFAULT_BG,
          ownerId, createdAt: Date.now() };
        store.rooms[id] = room; saveStore();
        notifyLobby();   // 新建的房间要立刻出现在别人的大厅里
        return reply({ type: 'room:created', data: {
          id: room.id, no: room.no, name: room.name,
          background: room.background, avatar: room.avatar || '', existed: false
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
          avatar: mine.avatar || '',
          ownerId: mine.ownerId, count: rt.members.size, createdAt: mine.createdAt,
          ownerVip: !!(store.users[mine.ownerId] && store.users[mine.ownerId].vip)
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
        notifyLobby();   // 解散了要从别人的大厅列表里消失
        return reply({ type: 'room:destroyed', data: { roomId: room.id } });
      }

      case 'room:list': {
        const list = Object.values(store.rooms).map(r => {
          const rt = getRuntime(r.id);
          return { id: r.id, no: r.no, name: r.name, background: r.background,
                   avatar: r.avatar || '', count: rt.members.size, ownerId: r.ownerId,
                   ownerVip: !!(store.users[r.ownerId] && store.users[r.ownerId].vip) };
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

        // 关键顺序：先把这条连接的旧身份（可能残留在别的房间）摘干净，再算麦位。
        // 客户端换房/回房是直接 join、不先 leave，不摘的话就会出现"2 个我"。
        detachWsFromRooms(ws);
        detachStaleSessionsOfUser(room.id, userId, ws);

        clientId = uid('c'); joinedRoom = room.id;
        ws.clientId = clientId; ws.joinedRoom = joinedRoom; // 互踢移出房间用
        const rt = getRuntime(room.id);
        const isOwner = room.ownerId === userId;
        const used = new Set([...rt.members.values()].map(m => m.seat));
        let seat = -1;
        if (isOwner) {
          // 房主固定坐 0 号主位（顶部带头像框）。
          // 兜底：若 0 号位还被人占着（历史残留），先把占位者挪下麦，
          // 否则会出现两条成员记录挤在同一个麦位上。
          for (const m of rt.members.values()) if (m.seat === 0) m.seat = -1;
          seat = 0;
        } else {
          // 宾客从 1-8 号麦位找空位，坐满则站观众席
          for (let i = 1; i < 9; i++) if (!used.has(i)) { seat = i; break; }
        }
        rt.members.set(clientId, { clientId, userId, ws, seat, muted: false, joinedAt: Date.now() });

        // 进房时把「当前歌曲」的直链刷新一遍：
        // 在线曲库直链有时效（约分钟级），久放后 URL 已失效，
        // 若直接下发旧 URL 客户端会放不出来（表现为"重进房间音乐不放，
        // 重新搜歌再点播放才行"）。这里按 resolvedAt 判断，过期就重解析。
        if (rt.currentSong && rt.currentSong.remote) {
          const age = Date.now() - (rt.currentSong.resolvedAt || 0);
          if (!rt.currentSong.url || age > 4 * 60 * 1000) {
            await resolveSongUrl(rt.currentSong);
          }
        }

        reply({ type: 'join:ok', data: { clientId, roomId: room.id, userId } });
        for (const m of rt.members.values()) {
          // 注意 m.ws !== ws：同一条连接可能在房间里有多条历史记录，
          // 少了这个判断就会把 peer:new 发给"自己"，客户端会跟自己的幽灵建语音连接
          if (m.clientId !== clientId && m.ws !== ws && m.ws && m.ws.readyState === 1) {
            m.ws.send(JSON.stringify({ type: 'peer:new', data: { clientId, userId } }));
          }
        }
        pushSnapshot(room.id);
        const sys = { id: uid('m'), sys: true, text: `${user.name} 进入了房间`, at: Date.now() };
        pushChatLog(rt, sys); broadcast(room.id, { type: 'chat', data: sys });
        break;
      }

      case 'room:leave':
        if (joinedRoom) leaveRoom(clientId, joinedRoom);
        joinedRoom = null; clientId = null;
        ws.joinedRoom = null; ws.clientId = null;
        break;

      /* 客户端主动拉一次快照。
         用途：设置房间背景、换麦序、从后台回前台之后，界面要立刻跟上最新房间状态，
         不必等下一次被动推送（以前只能退出房间重进才能刷新）。只回给请求方，不打扰别人。 */
      case 'room:sync': {
        const rid = joinedRoom || safeStr(msg.roomId, 40);
        if (!rid) return;
        const snap = roomSnapshot(rid);
        if (snap) reply({ type: 'room:state', data: snap });
        break;
      }

      case 'room:rename': {
        const room = store.rooms[safeStr(msg.roomId, 40)];
        if (!room) return reply({ type: 'error', msg: '房间不存在' });
        if (room.ownerId !== msg.userId) return reply({ type: 'error', msg: '只有房主可以修改' });
        room.name = safeStr(msg.name, 22) || room.name;
        saveStore(); pushSnapshot(room.id); notifyLobby();
        break;
      }

      case 'room:bg': {
        const room = store.rooms[safeStr(msg.roomId, 40)];
        if (!room) return reply({ type: 'error', msg: '房间不存在' });
        room.background = safeStr(msg.background, 60) || room.background;
        saveStore(); pushSnapshot(room.id); notifyLobby();
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
        room.no = no; saveStore(); pushSnapshot(room.id); notifyLobby();
        return reply({ type: 'room:no-ok', data: { no } });
      }

      /* ================= 头像框：商城 / 背包 ================= */

      /* 商城列表 + 我的背包 + 当前穿戴 + 金币余额（一次拿全，商城页只发一条请求） */
      case 'shop:list': {
        const u = currentUser(ws, msg);
        if (!u) return reply({ type: 'error', msg: '请先登录' });
        return reply({ type: 'shop:list', data: {
          frames: store.config.avatarFrames || [],
          owned: Array.isArray(u.frames) ? u.frames : [],
          wearing: typeof u.frame === 'string' ? u.frame : '',
          coins: Number.isInteger(u.coins) ? u.coins : 0
        }});
      }

      /* 买头像框：扣金币 → 进背包 → 顺手戴上（买框就是为了戴，省一步操作） */
      case 'shop:buy': {
        const u = currentUser(ws, msg);
        if (!u) return reply({ type: 'error', msg: '请先登录' });
        const f = (store.config.avatarFrames || []).find(x => x.id === safeStr(msg.frameId, 30));
        if (!f) return reply({ type: 'error', msg: '头像框不存在' });
        if (!f.price) return reply({ type: 'error', msg: '这个是默认头像框，人人都有，不用买' });

        u.frames = Array.isArray(u.frames) ? u.frames : [];
        if (u.frames.includes(f.id)) return reply({ type: 'error', msg: '你已经拥有这个头像框了' });

        const coins = Number.isInteger(u.coins) ? u.coins : 0;
        if (coins < f.price) return reply({ type: 'error', msg: `金币不够，还差 ${f.price - coins}` });

        u.coins = coins - f.price;
        u.frames.push(f.id);
        u.frame = f.id;
        saveStore();
        broadcastUserUpdate(u);
        return reply({ type: 'shop:owned', data: {
          owned: u.frames, wearing: u.frame, coins: u.coins, bought: f.id, frame: publicUser(u)
        }});
      }

      /* 穿戴 / 脱下头像框（frameId 传空串 = 脱下） */
      case 'frame:wear': {
        const u = currentUser(ws, msg);
        if (!u) return reply({ type: 'error', msg: '请先登录' });
        const id = safeStr(msg.frameId, 30);
        if (id) {
          const f = (store.config.avatarFrames || []).find(x => x.id === id);
          if (!f) return reply({ type: 'error', msg: '头像框不存在' });
          // 默认框不需要购买；付费框必须在背包里
          if (f.price > 0 && !(Array.isArray(u.frames) && u.frames.includes(id)))
            return reply({ type: 'error', msg: '你还没有这个头像框' });
        }
        u.frame = id;
        saveStore();
        broadcastUserUpdate(u);
        return reply({ type: 'shop:owned', data: {
          owned: Array.isArray(u.frames) ? u.frames : [], wearing: u.frame,
          coins: Number.isInteger(u.coins) ? u.coins : 0, frame: publicUser(u)
        }});
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
        pushChatLog(rt, m);
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

        // 收礼人：带 clientId 就只送那一个；**空的表示"全房间"** → 房间里除自己之外的所有人。
        // （以前客户端把"全房间"退化成 members.first，界面上写着全房、实际只送给第一个人。）
        const all = [...rt.members.values()];
        const targets = msg.toClientId
          ? all.filter(m => m.clientId === msg.toClientId)
          : all.filter(m => m.userId !== from.id);

        const gain = gift.charm * count;
        from.coins -= cost;
        from.charm += gain;

        // VIP 等级与刷礼物（魅力值）挂钩：达标自动晋升并全房广播
        const sysMsgs = [];
        const upFrom = recomputeVip(from);
        if (upFrom) sysMsgs.push(`🎉 ${from.name} 魅力值达到 ${from.charm}，晋升 VIP${upFrom}！`);

        // 谁的数据变了 → 合并成**一条**消息推给全房，而不是每人一条全房广播。
        // 全房送礼时 changed = 送礼人 + 每个收礼人，逐个 broadcast 是 O(n) 条全员消息
        // （9 人房送一次礼 = 9 条 × 9 收件人 = 81 次 send）。合并后只有 1 条。
        const changed = new Set([from.id]);
        // 收礼人按 userId 去重：既挡住"送给自己"时魅力值翻倍，也挡住同账号残留记录重复加
        const paid = new Set();
        for (const m of targets) {
          if (m.userId === from.id || paid.has(m.userId)) continue;
          paid.add(m.userId);
          const to = store.users[m.userId];
          if (!to) continue;
          to.charm += gain;
          changed.add(to.id);
          const upTo = recomputeVip(to);
          if (upTo) sysMsgs.push(`🎉 ${to.name} 收礼升级，晋升 VIP${upTo}！`);
        }

        saveStore();
        broadcast(joinedRoom, { type: 'gift', data: {
          id: uid('g'), from: publicUser(from), toClientId: msg.toClientId || '',
          gift: { id: gift.id, name: gift.name, emoji: gift.emoji }, count, at: Date.now()
        }});

        /*
         * 这里原来跟了一句 pushSnapshot(joinedRoom)，已去掉。
         *
         * pushSnapshot 会向全房推一份**完整快照**（9 个成员 + 60 条聊天记录 + 歌单 + 礼物表），
         * 而礼物是连击操作 —— 送 99 个礼物就是 99 次全量序列化 + 99 次全员下发，
         * 房间里人多的时候会明显卡顿（这就是"送礼物卡"的主因）。
         * 金币/魅力值本来就只需要广播给"变了的那几个人"，用 charm:update 精确推送即可：
         * 客户端收到后会就地更新该成员的金币与魅力值（不收礼的人一个字节都不用收）。
         */
        const updates = [];
        for (const uid2 of changed) {
          const u = store.users[uid2];
          if (u) updates.push(publicUser(u));
        }
        if (updates.length) {
          broadcast(joinedRoom, { type: 'charm:update', data: { users: updates } });
        }

        for (const t of sysMsgs) {
          const sm = { id: uid('m'), sys: true, text: t, at: Date.now() };
          pushChatLog(rt, sm);
          broadcast(joinedRoom, { type: 'chat', data: sm });
        }
        reply({ type: 'coins:update', data: { coins: from.coins, charm: from.charm } });
        break;
      }

      /* 加入歌单：支持本地曲库 / 在线曲库（gd|源|歌id）/ 外链 */
      case 'music:add': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        // 点歌人：直接用**这条连接**在房间里的身份，不信任报文里的 userId。
        // 客户端要按它把「正在播放的歌是谁点的」那个麦位点亮，所以必须落进歌曲对象里。
        const asker = (rt.members.get(clientId) || {}).userId || safeStr(msg.userId, 40);

        let song = null;
        const gd = parseGdLibraryId(msg.libraryId);
        if (gd) {
          // 在线曲库：歌单里存引用，播放时才解析直链（直链有时效）
          song = {
            id: uid('s'), title: safeStr(msg.title, 60) || '在线歌曲',
            artist: safeStr(msg.artist, 80),
            url: '', libraryId: String(msg.libraryId), remote: true,
            by: safeStr(msg.by, 20), byUserId: asker, at: Date.now()
          };
          const exist = rt.playlist.find(s => s.libraryId === song.libraryId);
          if (exist) {
            await resolveSongUrl(exist);
            exist.byUserId = asker; exist.by = song.by;
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
            byUserId: asker,
            at: Date.now()
          };
        } else {
          const url2 = safeStr(msg.url, 500);
          if (!/^https?:\/\//i.test(url2)) return reply({ type: 'error', msg: '请填写 http(s) 开头的音频地址' });
          song = { id: uid('s'), title: safeStr(msg.title, 60) || '未知歌曲',
                   artist: safeStr(msg.artist, 60), url: url2, by: safeStr(msg.by, 20),
                   byUserId: asker, at: Date.now() };
        }

        // 本地/外链歌曲按 url 去重
        if (!song.remote) {
          const exist = rt.playlist.find(s => s.url === song.url);
          if (exist) {
            exist.byUserId = asker; exist.by = song.by;
            rt.currentSong = exist; rt.playing = true; rt.startedAt = Date.now();
            pushSnapshot(joinedRoom);
            return reply({ type: 'music:playing', data: { title: exist.title } });
          }
        }

        // 歌单上限 20 首（超出提示，避免无限堆积）
        if (rt.playlist.length >= 20) {
          return reply({ type: 'error', msg: '歌单最多 20 首，先移除几首吧' });
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
        const asker = (rt.members.get(clientId) || {}).userId || safeStr(msg.userId, 40);
        const gd = parseGdLibraryId(msg.libraryId);
        let song;
        if (gd) {
          song = {
            id: uid('s'), title: safeStr(msg.title, 60) || '在线歌曲',
            artist: safeStr(msg.artist, 80),
            url: '', libraryId: String(msg.libraryId), remote: true,
            by: safeStr(msg.by, 20), byUserId: asker, at: Date.now()
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
            by: safeStr(msg.by, 20), byUserId: asker, at: Date.now()
          };
        }
        const exist = rt.playlist.find(s => s.libraryId && s.libraryId === song.libraryId);
        if (!exist) rt.playlist.push(song);
        rt.currentSong = exist || song;
        rt.currentSong.url = song.url; // 重新解析，避免直链过期
        rt.currentSong.byUserId = asker; rt.currentSong.by = song.by;
        rt.playing = true; rt.startedAt = Date.now();
        pushRecent((rt.members.get(clientId) || {}).userId, rt.currentSong);
        pushSnapshot(joinedRoom);
        break;
      }

      case 'music:control': {
        const rt = runtime.get(joinedRoom); if (!rt) return;
        const a = msg.action;
        if (a === 'play' && rt.currentSong) {
          const off = rt.pauseOffsetMs || 0;
          rt.playing = true;
          rt.startedAt = Date.now() - off;   // 接着暂停处继续
          rt.pauseOffsetMs = 0;
        }
        if (a === 'pause') {
          rt.pauseOffsetMs = rt.playing && rt.startedAt > 0 ? (Date.now() - rt.startedAt) : (rt.pauseOffsetMs || 0);
          rt.playing = false;
        }
        // 播放模式：order 列表循环 / single 单曲循环 / once 列表播完结束
        if (a === 'mode' && ['order', 'single', 'once'].includes(msg.mode)) {
          rt.playMode = msg.mode;
        }
        // 客户端播完自动上报 → 按模式推进；once 模式播完最后一首即停止
        if (a === 'ended') {
          // 全房同步播放时，所有客户端几乎同时播完、各自都会上报一次 ended。
          // 不去重的话房里有 N 个人就会连跳 N 首。这里只认「距本曲起播已超过 1.5 秒」的那一次：
          // 重复上报到达时 startedAt 刚被下面的语句刷新，会被自然挡掉。
          const now = Date.now();
          if (now - (rt.startedAt || 0) > 1500) {
            rt.startedAt = now;              // 立即占位，挡住并发到达的重复上报
            await advancePlaylist(rt, 'ended');
          }
        }
        if (a === 'next') {
          await advancePlaylist(rt, 'next');
        }
        if (a === 'select' && msg.songId) {
          const s = rt.playlist.find(x => x.id === msg.songId);
          if (s) { await resolveSongUrl(s); rt.currentSong = s; rt.playing = true; rt.startedAt = Date.now(); rt.pauseOffsetMs = 0; }
        }
        if (a === 'remove' && msg.songId) {
          rt.playlist = rt.playlist.filter(x => x.id !== msg.songId);
          if (rt.currentSong && rt.currentSong.id === msg.songId) {
            rt.currentSong = rt.playlist[0] || null; rt.playing = !!rt.currentSong;
            rt.startedAt = Date.now(); rt.pauseOffsetMs = 0;
            if (rt.currentSong) await resolveSongUrl(rt.currentSong);
          }
        }
        // 清空歌单
        if (a === 'clear') {
          rt.playlist = []; rt.currentSong = null; rt.playing = false; rt.startedAt = 0; rt.pauseOffsetMs = 0;
        }
        // 直链失效重解析（客户端播放报错时调用，重解析后从头播放该曲）
        if (a === 'reload' && rt.currentSong) {
          await forceResolveSongUrl(rt.currentSong);
          rt.playing = true; rt.startedAt = Date.now(); rt.pauseOffsetMs = 0;
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
    } catch (e) {
      console.error('[ws] 处理消息出错: type=' + (msg && msg.type), (e && e.stack) || e);
      try { reply({ type: 'error', msg: '服务端处理出错，请重试' }); } catch (_) {}
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

/* 兜底：Node 15+ 未捕获的 Promise rejection 默认会直接终止进程。
   语音房是常驻服务，一个偶发的异步异常不该让全房掉线 —— 记录后继续运行。 */
process.on('unhandledRejection', (reason) => {
  console.error('[unhandledRejection]', (reason && reason.stack) || reason);
});
/* 未捕获异常属于不可预期的状态损坏，记录后交给 systemd 重启，避免带病运行 */
process.on('uncaughtException', (err) => {
  console.error('[uncaughtException]', (err && err.stack) || err);
  process.exit(1);
});

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
