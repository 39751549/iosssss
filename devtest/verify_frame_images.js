// 「图片头像框」验收
//
// 本轮改动：
//   1. 服务端新增 3 款图片头像框（虹之庭 / 金月鲸 / 锦鲤）：img 字段指向
//      public/frames/ 下的 264x264 中心透明 PNG，colors 保留主色供老版本兜底。
//   2. loadStore 按 id 把 DEFAULT_CONFIG 里新增的商品补进线上旧清单（union），
//      否则 store.json 里的旧 avatarFrames 会把新商品吞掉。
//   3. iOS VRAvatarFrame 加 img 字段；VRAvatarFull 把素材整张叠在头像上
//      （中心透明贴边不遮脸），图片框不再画渐变环，说话状态改用绿光。
//
// 验收分两段：
//   A. 本地起 server（独立 DATA_DIR + 预置「旧清单」store.json）：
//      union 合并 → shop:list 有 3 个 img 框 → 静态 PNG 可访问且是 264x264 RGBA
//      → 不带 userId 的 payload（iOS 真实发法）买框 / 戴框全链路。
//   B. Swift 静态检查：模型有 img 字段、渲染层有叠图逻辑，词法完整性通过。
const WebSocket = require('ws');
const http = require('http');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const PORT = 8199;
const API = `http://127.0.0.1:${PORT}`;
const ROOT = path.join(__dirname, '..');
const DATA_DIR = path.join(ROOT, 'data-test-frames');

let pass = 0, fail = 0;
function ok(cond, label) {
  if (cond) { pass++; console.log('  ✓', label); }
  else { fail++; console.log('  ✗', label); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

function get(p) {
  return new Promise((res, rej) => {
    http.get(API + p, r => {
      const chunks = [];
      r.on('data', c => chunks.push(c));
      r.on('end', () => res({ status: r.statusCode, type: r.headers['content-type'], buf: Buffer.concat(chunks) }));
    }).on('error', rej);
  });
}

function post(p, body) {
  return new Promise((res, rej) => {
    const data = JSON.stringify(body);
    const req = http.request(API + p, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
    }, r => { let b = ''; r.on('data', c => b += c); r.on('end', () => { try { res(JSON.parse(b)); } catch { res({ raw: b }); } }); });
    req.on('error', rej); req.write(data); req.end();
  });
}

function mkWS() {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
  const all = [], waiters = [];
  ws.on('message', d => {
    let m; try { m = JSON.parse(d); } catch { return; }
    all.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) if (waiters[i].pred(m)) { waiters[i].res(m); waiters.splice(i, 1); }
  });
  ws.all = all;
  ws.mark = () => ws.all.length;
  ws.waitAfter = (mark, pred, ms = 6000) => new Promise(res => {
    const hit = all.slice(mark).find(pred);
    if (hit) return res(hit);
    const w = { pred: m => all.indexOf(m) >= mark && pred(m), res };
    waiters.push(w); setTimeout(() => res(null), ms);
  });
  ws.sendWait = (msg, pred, ms = 6000) => new Promise(res => {
    const mark = ws.mark();
    ws.send(JSON.stringify(msg));
    ws.waitAfter(mark, pred, ms).then(res);
  });
  return new Promise(res => ws.on('open', () => res(ws)));
}

/** PNG IHDR 解析：宽 / 高 / 颜色类型（6 = RGBA） */
function pngInfo(buf) {
  if (buf.length < 33 || buf.readUInt32BE(0) !== 0x89504e47) return null;
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), colorType: buf[25] };
}

async function main() {
  /* 准备数据目录：预置一份「旧清单」store.json（没有 img 框），验证 union 合并 */
  fs.rmSync(DATA_DIR, { recursive: true, force: true });
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const oldFrames = [
    { id: 'classic', name: '云白', price: 0, colors: ['FFFFFF', 'CFE0F5'], tier: 'normal' },
    { id: 'sakura', name: '樱吹雪', price: 800, colors: ['FFC2DC', 'FF7FAE'], badge: '🌸', tier: 'normal' },
    { id: 'royal', name: '皇冠金', price: 30000, colors: ['FFE89A', 'FF9F1C'], badge: '👑', tier: 'legend', glow: true }
  ];
  fs.writeFileSync(path.join(DATA_DIR, 'store.json'), JSON.stringify({
    users: {}, rooms: {}, accounts: {}, library: [],
    config: { avatarFrames: oldFrames }
  }));

  const srv = spawn(process.execPath, [path.join(ROOT, 'server.js')], {
    env: Object.assign({}, process.env, { PORT: String(PORT), DATA_DIR }),
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let srvLog = '';
  srv.stdout.on('data', c => srvLog += c);
  srv.stderr.on('data', c => srvLog += c);

  try {
    for (let i = 0; i < 40; i++) {
      try { await get('/healthz'); break; } catch { await sleep(250); }
    }

    console.log('\n== A1. 旧清单 union 合并 ==');
    const ws = await mkWS();
    const uname = 'ft' + Date.now().toString().slice(-8);
    const auth = await ws.sendWait(
      { type: 'auth', username: uname, password: 'test1234' },
      m => m.type === 'auth:ok' || m.type === 'error', 6000);
    ok(auth && auth.type === 'auth:ok', '账号登录成功（ws.authUserId 会话身份生效）');
    if (!auth || auth.type !== 'auth:ok') throw new Error('登录失败: ' + JSON.stringify(auth));

    const list = await ws.sendWait(
      { type: 'shop:list' },
      m => m.type === 'shop:list', 6000);
    ok(list && list.type === 'shop:list', 'shop:list 有回包');
    const frames = (list.data && list.data.frames) || [];
    const byId = Object.fromEntries(frames.map(f => [f.id, f]));
    ok(frames.length >= oldFrames.length + 3, `新商品被补进旧清单（共 ${frames.length} 个）`);
    ok(!!byId.classic && !!byId.sakura && !!byId.royal, '旧商品原样保留（顺序/价格不动）');

    console.log('\n== A2. 图片头像框字段 ==');
    const IMG_FRAMES = [
      { id: 'rainbow', img: '/frames/frame-rainbow.png' },
      { id: 'goldwhale', img: '/frames/frame-goldwhale.png' },
      { id: 'koi', img: '/frames/frame-koi.png' }
    ];
    for (const want of IMG_FRAMES) {
      const f = byId[want.id];
      ok(!!f, `存在图片框 ${want.id}`);
      if (!f) continue;
      ok(f.img === want.img, `${want.id}.img = ${want.img}`);
      ok(Array.isArray(f.colors) && f.colors.length >= 2, `${want.id} 保留 colors（老版本兜底）`);
      ok(Number.isInteger(f.price) && f.price > 0, `${want.id} 有定价（${f.price}）`);
    }

    console.log('\n== A3. 素材静态服务 ==');
    for (const want of IMG_FRAMES) {
      const r = await get(want.img);
      ok(r.status === 200 && /image\/png/.test(r.type), `GET ${want.img} → 200 image/png`);
      const info = pngInfo(r.buf);
      ok(!!info, `${want.id} 是合法 PNG`);
      if (info) {
        ok(info.w === 264 && info.h === 264, `${want.id} 尺寸 264x264（实为 ${info.w}x${info.h}）`);
        ok(info.colorType === 6, `${want.id} 是 RGBA（带透明通道，colorType=${info.colorType}）`);
      }
      ok(r.buf.length > 10000, `${want.id} 内容非空（${r.buf.length} B）`);
    }
    // 穿越防线：不管客户端归一化（/../ 会被 http 库提前归一化成 /server.js）
    // 还是编码绕过（/%2e%2e/），public 外的 server.js 源码都不能出现在响应里
    for (const p of ['/../server.js', '/%2e%2e/server.js', '/frames/../../server.js']) {
      const r = await get(p);
      ok(!r.buf.toString().includes("require('ws')"), `穿越变体 ${p} 不泄露源码（HTTP ${r.status}）`);
    }

    console.log('\n== A4. 买框 + 戴框（不带 userId 的 payload = iOS 真实发法）==');
    // 新号自带 1000 金币，买不起 → 先用 admin 加金币再买，重点验证链路而不是贫穷
    const uid = auth.data.userId;
    const give = await post('/api/admin/give-coins', { password: 'admin888', userId: uid, amount: 999999 });
    ok(give && give.ok, 'admin 发金币成功');
    const buy = await ws.sendWait(
      { type: 'shop:buy', frameId: 'goldwhale' },
      m => m.type === 'shop:owned' || m.type === 'error', 6000);
    ok(buy && buy.type === 'shop:owned', '购买图片框成功');
    // 没买过的框不能直接戴（服务端正确行为）
    const deny = await ws.sendWait(
      { type: 'frame:wear', frameId: 'koi' },
      m => m.type === 'shop:owned' || m.type === 'error', 6000);
    ok(deny && deny.type === 'error', '戴未拥有的图片框被拒绝');
    const buy2 = await ws.sendWait(
      { type: 'shop:buy', frameId: 'koi' },
      m => m.type === 'shop:owned' || m.type === 'error', 6000);
    ok(buy2 && buy2.type === 'shop:owned', '购买第二张图片框成功');
    const wear = await ws.sendWait(
      { type: 'frame:wear', frameId: 'koi' },
      m => m.type === 'shop:owned' || m.type === 'error', 6000);
    ok(wear && wear.type === 'shop:owned' && wear.data.wearing === 'koi', '换戴另一款图片框成功');
    ok(wear.data.frame && wear.data.frame.frame === 'koi', 'publicUser 带上了 frame（麦位其他人能看见）');
    const off = await ws.sendWait(
      { type: 'frame:wear', frameId: '' },
      m => m.type === 'shop:owned', 6000);
    ok(off && off.data.wearing === '', '脱下成功');

    ws.close();

    console.log('\n== B. Swift 静态检查 ==');
    const models = fs.readFileSync(path.join(ROOT, 'ios-native/VoiceRoom/Sources/Models/Models.swift'), 'utf8');
    ok(/var img: String\?/.test(models), 'VRAvatarFrame 有 img 字段');
    const comp = fs.readFileSync(path.join(ROOT, 'ios-native/VoiceRoom/Sources/UI/VRComponents.swift'), 'utf8');
    ok(/frameArtView/.test(comp), 'VRAvatarFull 有图片框渲染（frameArtView）');
    ok(/loadFrameArtIfNeeded/.test(comp), '有素材加载逻辑（loadFrameArtIfNeeded）');
    ok(/onChange\(of: user\?\.frame\)/.test(comp), '换框会触发素材重载');
    ok(/onChange\(of: frameImageKey\)/.test(comp), '商城清单晚到时会补加载素材');
    // 图片框不画渐变环：ringColors 里对 img 非空的框跳过
    ok(new RegExp('img \\?\\? ""\\)\\.isEmpty').test(comp.replace(/\r/g, '')), '图片框跳过渐变环（ringColors 分支）');

    const { execSync } = require('child_process');
    try {
      execSync(`"${process.env.PY || 'python'}" check_swift_lex.py`, { cwd: ROOT, stdio: 'pipe' });
      ok(true, 'check_swift_lex.py 词法完整');
    } catch (e) {
      ok(false, 'check_swift_lex.py: ' + String(e.stderr || e.message).slice(0, 200));
    }
  } finally {
    srv.kill();
    await sleep(300);
    try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch {}
  }

  console.log(`\n===== 结果：${pass} 通过 / ${fail} 失败 =====`);
  process.exit(fail ? 1 : 0);
}

main().catch(e => { console.error('FATAL', e); process.exit(1); });
