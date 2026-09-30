// 「头像零遮挡 + 商城修复」线上验收
//
// 本轮改动：
//   1. 服务端 shop:list / shop:buy / frame:wear 从 ws.authUserId 取用户（原来只认 msg.userId，
//      而 iOS 客户端的 payload 根本不带 userId → 永远回「请先登录」→ 商城/背包无限转圈）。
//   2. 头像上什么都不压了：皇冠、VIP 等级章、头像框角标、🎤/🔇 麦克风圆标全部撤掉。
//      静音挪到名字行的小 🔇 + 头像变暗（.self-muted）；房主标识是名字后的「房」标。
//
// 验收分两段：
//   A. 服务端：用**不带 userId** 的 payload（= iOS 客户端的真实发法）走完
//      拉清单 → 买框 → 脱下 → 戴回 → 非法穿戴被拒 的全链路。
//   B. 真实 Chrome：头像 DOM 里只有一张图、页面上没有 mic-state / 👑 / 等级数字，
//      房主名字带「房」标、静音用户名字前有 🔇 且头像变暗、VIP 名字档位仍然生效。
//
// 用完即清：测试账号与测试房间在 finally 里通过 admin API 删除。
const WebSocket = require('ws');
const http = require('http');
const path = require('path');
const fs = require('fs');
const puppeteer = require('puppeteer-core');

const HOST = '43.142.76.172', PORT = 8125;
const API = `http://${HOST}:${PORT}`;
const PWD = 'admin888';
const TAG = Date.now().toString().slice(-7);
const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const SHOT_DIR = path.join(__dirname, 'shots');
fs.mkdirSync(SHOT_DIR, { recursive: true });

const sleep = ms => new Promise(r => setTimeout(r, ms));

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
  const ws = new WebSocket(`ws://${HOST}:${PORT}/ws`);
  const all = [], waiters = [];
  ws.on('message', d => {
    let m; try { m = JSON.parse(d); } catch { return; }
    all.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) if (waiters[i].pred(m)) { waiters[i].res(m); waiters.splice(i, 1); }
  });
  ws.all = all;
  // mark + waitAfter：只认 mark 之后到的消息。
  // 商城的买/脱/戴回包都是 shop:owned，靠标记挡住上一条被当成下一条匹配。
  ws.mark = () => ws.all.length;
  ws.wait = (pred, ms = 6000) => new Promise(res => {
    const hit = all.find(pred);
    if (hit) return res(hit);
    const w = { pred, res }; waiters.push(w); setTimeout(() => res(null), ms);
  });
  ws.waitAfter = (mark, pred, ms = 6000) => new Promise(res => {
    const hit = all.slice(mark).find(pred);
    if (hit) return res(hit);
    const w = { pred: m => all.indexOf(m) >= mark && pred(m), res };
    waiters.push(w); setTimeout(() => res(null), ms);
  });
  ws.send2 = o => ws.send(JSON.stringify(o));
  return new Promise(r => ws.on('open', () => r(ws)));
}

(async () => {
  const R = [];
  const chk = (n, ok, i = '') => { R.push({ n, ok, i }); console.log(`${ok ? '✅' : '❌'} ${n}${i ? '  — ' + i : ''}`); };
  const note = t => console.log(`\n【${t}】`);

  // host = VIP11 房主（顺带验证名字档位与「房」标）；g1/g2 普通宾客，g1 用来测静音
  const PLAN = [
    { key: 'host', lvl: 11 },
    { key: 'g1',   lvl: 0 },
    { key: 'g2',   lvl: 0 },
  ];
  const names = {}, ids = {}, clients = {};
  const wsList = [];
  let roomId = null, browser = null;

  try {
    /* ================= A. 服务端：iOS 式 payload（不带 userId）================= */
    note('A. 服务端 · 商城链路（payload 不带 userId = iOS 真实发法）');

    for (const p of PLAN) {
      const un = 'ca' + p.key + TAG;
      names[p.key] = un;
      const ws = await mkWS(); wsList.push(ws); p.ws = ws;
      ws.send2({ type: 'auth', username: un, password: 'p123456' });
      const a = await ws.wait(m => m.type === 'auth:ok' || m.type === 'error');
      if (a?.type !== 'auth:ok') throw new Error('auth 失败 ' + un + ': ' + (a?.msg || ''));
      ids[p.key] = a.data.userId;
    }
    chk('3 个测试账号注册并登录', Object.keys(ids).length === 3);

    await post('/api/admin/set-vip', { password: PWD, userId: ids.host, vip: true, vipLevel: 11 });

    const wsH = PLAN[0].ws;
    wsH.send2({ type: 'room:create', userId: ids.host, name: '干净头像验收房' + TAG });
    const rc = await wsH.wait(m => m.type === 'room:created');
    roomId = rc?.data?.id;
    if (!roomId) throw new Error('建房失败');
    for (const p of PLAN) {
      p.ws.send2({ type: 'room:join', userId: ids[p.key], roomId });
      const j = await p.ws.wait(m => m.type === 'join:ok');
      clients[p.key] = j?.data?.clientId;
      if (!clients[p.key]) throw new Error('进房失败 ' + p.key);
    }
    chk('房主 + 2 宾客全部进房', Object.keys(clients).length === 3);

    // ---- 商城：payload **不带 userId**，模拟 iOS 客户端 ----
    let mark = wsH.mark();
    wsH.send2({ type: 'shop:list' });
    const listMsg = await wsH.waitAfter(mark, m => m.type === 'shop:list' || m.type === 'error');
    const frames = listMsg?.data?.frames || [];
    chk('★ shop:list 不带 userId 也能拿到清单（修复前回「请先登录」）',
        listMsg?.type === 'shop:list' && frames.length >= 8, `实际 ${frames.length} 个框`);

    await post('/api/admin/give-coins', { password: PWD, userId: ids.host, amount: 1000 });

    // 买最便宜的付费框
    const cheap = frames.filter(f => f.price > 0).sort((a, b) => a.price - b.price)[0];
    mark = wsH.mark();
    wsH.send2({ type: 'shop:buy', frameId: cheap.id });
    const bought = await wsH.waitAfter(mark, m => m.type === 'shop:owned' || m.type === 'error');
    chk('★ shop:buy 不带 userId 也能购买', bought?.type === 'shop:owned' && !!bought?.data?.bought,
        JSON.stringify(bought?.data || bought).slice(0, 120));
    // 注册送 1000 + 管理员再给 1000 = 2000，买 800 → 1200
    chk(`★ 金币被正确扣除 (1000+1000)-${cheap.price} → ${2000 - cheap.price}`,
        bought?.data?.coins === 2000 - cheap.price, `实际 ${bought?.data?.coins}`);
    chk('买完自动穿戴', bought?.data?.wearing === cheap.id, `实际 ${bought?.data?.wearing}`);

    mark = wsH.mark();
    wsH.send2({ type: 'frame:wear', frameId: '' });
    const off = await wsH.waitAfter(mark, m => m.type === 'shop:owned' || m.type === 'error');
    chk('空 frameId 脱下成功', off?.type === 'shop:owned' && (off?.data?.wearing === '' || off?.data?.wearing == null),
        `实际 ${JSON.stringify(off?.data?.wearing)}`);

    mark = wsH.mark();
    wsH.send2({ type: 'frame:wear', frameId: cheap.id });
    const on = await wsH.waitAfter(mark, m => m.type === 'shop:owned' || m.type === 'error');
    chk('重新穿戴成功', on?.type === 'shop:owned' && on?.data?.wearing === cheap.id, `实际 ${on?.data?.wearing}`);

    mark = wsH.mark();
    wsH.send2({ type: 'frame:wear', frameId: 'galaxy' });
    const bad = await wsH.waitAfter(mark, m => m.type === 'error' || m.type === 'shop:owned');
    chk('穿戴未拥有的框被拒', bad?.type === 'error', bad?.msg || JSON.stringify(bad?.data).slice(0, 80));

    /* ================= B. 真实浏览器：头像零遮挡 ================= */
    note('B. 真实 Chrome · 头像零遮挡');

    browser = await puppeteer.launch({
      executablePath: CHROME, headless: 'new',
      args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--mute-audio'],
    });
    const page = await browser.newPage();
    await page.setViewport({ width: 430, height: 932, deviceScaleFactor: 2 });

    const jsErrors = [];
    page.on('pageerror', e => jsErrors.push(String(e.message || e)));
    page.on('console', m => { if (m.type() === 'error') jsErrors.push('console: ' + m.text()); });

    // 用宾客 g1 打开页面（页面登录会把 g1 的测试 WS 踢掉 —— 后续操作全走页面自己的 send）
    await page.goto(`${API}/index.html`, { waitUntil: 'domcontentloaded' });
    await page.evaluate((uid, name) => {
      localStorage.setItem('vr_userId', JSON.stringify(uid));
      localStorage.setItem('vr_user', JSON.stringify({ id: uid, name }));
    }, ids.g1, names.g1);

    await page.goto(`${API}/room.html?room=${roomId}`, { waitUntil: 'networkidle2' });
    await sleep(1500);
    chk('房间页无 JS 报错', jsErrors.length === 0, jsErrors.slice(0, 3).join(' | '));

    // 1) 页面上不存在压在头像上的旧元素
    const legacy = await page.evaluate(() => ({
      micState: document.querySelectorAll('.mic-state').length,
      crownEls: document.querySelectorAll('.host-crown, .seat-crown').length,
      crownEmoji: [...document.querySelectorAll('.host-seat, .seat')].map(e => e.innerHTML).join('').split('👑').length - 1,
    }));
    chk('页面上没有 🎤/🔇 麦克风圆标（mic-state 已删）', legacy.micState === 0, `${legacy.micState} 个`);
    chk('页面上没有皇冠（元素与 emoji 都没有）',
        legacy.crownEls === 0 && legacy.crownEmoji === 0,
        `元素 ${legacy.crownEls} / emoji ${legacy.crownEmoji}`);

    // 2) 每个头像 DOM 里只有一张图 —— 不允许任何子元素角标/文字
    const avatars = await page.evaluate(() => {
      const out = [];
      document.querySelectorAll('.avatar').forEach(a => {
        out.push({ kids: [...a.children].map(c => c.tagName).join(','), text: a.textContent.trim() });
      });
      return out;
    });
    chk(`所有头像内部只有 <img>（共 ${avatars.length} 个，无角标/文字遮挡）`,
        avatars.length >= 3 && avatars.every(a => a.kids === 'IMG' && a.text === ''),
        JSON.stringify(avatars.slice(0, 4)));

    // 3) 房主名字后带「房」标；VIP 名字档位仍生效
    const hostRow = await page.evaluate(() => {
      const t = document.querySelector('.host-seat .hn-text');
      const v = t?.querySelector('.vname');
      return { text: t?.textContent.trim(), hasFang: !!t?.querySelector('.vname-host'),
               fangText: t?.querySelector('.vname-host')?.textContent,
               tier: v?.className || null };
    });
    chk('房主名字后有红色「房」标', hostRow.hasFang && hostRow.fangText === '房',
        JSON.stringify(hostRow));
    chk('房主(VIP11)名字仍是三色档 v-aurora', (hostRow.tier || '').includes('v-aurora'), hostRow.tier);

    // 4) 静音：页面自己发 mic:toggle（走真实链路：页面 WS → 服务端 → 快照广播 → 重渲染）
    await page.evaluate(() => send({ type: 'mic:toggle', muted: true }));
    await sleep(1000);
    const mutedRow = await page.evaluate(() => {
      const seat = document.querySelector('.seat.mine') || document.querySelector('.host-seat');
      const nameEl = seat?.querySelector('.sname') || seat?.querySelector('.host-name');
      const av = seat?.querySelector('.avatar');
      return { hasTag: !!nameEl?.querySelector('.mute-tag'),
               tagText: nameEl?.querySelector('.mute-tag')?.textContent,
               avatarKids: av ? [...av.children].map(c => c.tagName).join(',') : null,
               seatCls: seat?.className || null };
    });
    chk('静音后名字行出现 🔇', mutedRow.hasTag && mutedRow.tagText === '🔇', JSON.stringify(mutedRow));
    chk('静音后头像上仍然只有 <img>（没贴新标）', mutedRow.avatarKids === 'IMG', String(mutedRow.avatarKids));
    chk('静音座位带 self-muted 类（头像变暗）', /self-muted/.test(mutedRow.seatCls || ''), mutedRow.seatCls);

    // 5) 取消静音后 🔇 消失
    await page.evaluate(() => send({ type: 'mic:toggle', muted: false }));
    await sleep(1000);
    const unmuted = await page.evaluate(() => {
      const seat = document.querySelector('.seat.mine') || document.querySelector('.host-seat');
      const nameEl = seat?.querySelector('.sname') || seat?.querySelector('.host-name');
      return { hasTag: !!nameEl?.querySelector('.mute-tag'), seatCls: seat?.className || null };
    });
    chk('取消静音后 🔇 消失、self-muted 移除',
        !unmuted.hasTag && !/self-muted/.test(unmuted.seatCls || ''), JSON.stringify(unmuted));

    // 6) 宾客（非 VIP）名字不带档位；麦位上没有等级数字
    const seatNames = await page.evaluate(() => {
      const out = [];
      document.querySelectorAll('.seat .sname, .host-seat .hn-text').forEach(e => {
        out.push({ text: e.textContent.trim(), vcls: e.querySelector('.vname')?.className || null });
      });
      return out;
    });
    chk('麦位/主位文字里没有等级数字', seatNames.every(s => !/💎|VIP\s*\d|V11/.test(s.text)),
        seatNames.map(s => s.text).join(' / '));
    const g1name = seatNames.find(s => s.text.includes(names.g1));
    chk('非 VIP 宾客名字不加档位', !!g1name && g1name.vcls === null, String(g1name?.vcls));

    // 7) 截图留证
    const shot = path.join(SHOT_DIR, 'clean_avatar.png');
    await page.evaluate(() => { try { VR.closeSheet(); VR.closeModal(); } catch {} });
    await sleep(400);
    await page.screenshot({ path: shot });
    chk('截图已保存', fs.existsSync(shot));

  } catch (e) {
    chk('执行过程无异常', false, String(e && e.message || e));
  } finally {
    try { if (browser) await browser.close(); } catch {}
    for (const w of wsList) { try { w.close(); } catch {} }
    try {
      if (roomId) await post('/api/admin/delete-room', { password: PWD, roomId });
      for (const k of Object.keys(ids)) {
        if (ids[k]) await post('/api/admin/clear-user', { password: PWD, userId: ids[k] });
      }
      const ov = await post('/api/admin/overview', { password: PWD });
      const d = ov?.data || ov || {};
      const leftUsers = Object.values(d.users || {}).filter(u => String(u.name || '').includes('ca') && String(u.name || '').includes(TAG)).length;
      const leftRooms = Object.values(d.rooms || {}).filter(r => String(r.name || '').includes(TAG)).length;
      console.log(`\n【清场】残留测试账号 ${leftUsers} / 残留测试房间 ${leftRooms}`);
    } catch (e) { console.log('清场异常:', String(e && e.message || e)); }
  }

  const pass = R.filter(r => r.ok).length;
  console.log(`\n===== ${pass}/${R.length} 通过 =====`);
  R.filter(r => !r.ok).forEach(r => console.log('失败：' + r.n + (r.i ? ' → ' + r.i : '')));
  process.exit(pass === R.length ? 0 : 1);
})();
