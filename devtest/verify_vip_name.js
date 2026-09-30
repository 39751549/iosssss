// 「VIP 名字特权」线上验收
//
// 本轮改动：等级数字从头像 / 麦位 / 公屏 / 成员列表撤掉，只在名片里保留；
// 身份改成名字的颜色与流光表达（1-4 银蓝 / 5-7 金色 / 8-10 紫+扫光 / 11+ 三色流动）。
//
// 验收分两段：
//   A. 服务端：等级数据仍然完整下发（麦位成员、公屏消息都带 vip + vipLevel）——
//      渲染全靠这两个字段，它们错了前端再好也白搭。
//   B. 真实 Chrome：把 Web 端页面拉起来，验证每个等级真的套上了对应档位的样式、
//      动画真的在跑、头像旁不再出现「V11」数字，而名片里数字还在。
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
  // 先扫已缓冲的消息：join:ok 和紧随其后的 room:state 常常同一批到达
  ws.wait = (pred, ms = 6000) => new Promise(res => {
    const hit = all.find(pred);
    if (hit) return res(hit);
    const w = { pred, res }; waiters.push(w); setTimeout(() => res(null), ms);
  });
  ws.send2 = o => ws.send(JSON.stringify(o));
  return new Promise(r => ws.on('open', () => r(ws)));
}

(async () => {
  const R = [];
  const chk = (n, ok, i = '') => { R.push({ n, ok, i }); console.log(`${ok ? '✅' : '❌'} ${n}${i ? '  — ' + i : ''}`); };
  const note = t => console.log(`\n【${t}】`);

  // 每个等级一个账号，覆盖全部四档 + 一个非 VIP 作对照
  const PLAN = [
    { key: 'lv3',  lvl: 3,  tier: 'v-silver' },
    { key: 'lv5',  lvl: 5,  tier: 'v-gold' },
    { key: 'lv8',  lvl: 8,  tier: 'v-violet' },
    { key: 'lv11', lvl: 11, tier: 'v-aurora' },
    { key: 'lv0',  lvl: 0,  tier: null },        // 非 VIP
  ];
  const names = {}, ids = {}, clients = {};
  const wsList = [];
  let roomId = null, browser = null;

  try {
    /* ================= A. 服务端数据 ================= */
    note('A. 服务端 · 等级数据下发');

    for (const p of PLAN) {
      const un = 'vn' + p.key + TAG;
      names[p.key] = un;
      const ws = await mkWS(); wsList.push(ws);
      ws.send2({ type: 'auth', username: un, password: 'p123456' });
      const a = await ws.wait(m => m.type === 'auth:ok' || m.type === 'error');
      if (a?.type !== 'auth:ok') throw new Error('auth 失败 ' + un + ': ' + (a?.msg || ''));
      ids[p.key] = a.data.userId;
    }
    chk('5 个测试账号注册并登录', Object.keys(ids).length === 5);

    for (const p of PLAN) {
      if (p.lvl <= 0) continue;
      const r = await post('/api/admin/set-vip', { password: PWD, userId: ids[p.key], vip: true, vipLevel: p.lvl });
      if (!r?.user?.vipLevel) throw new Error('set-vip 失败 ' + p.key);
    }
    chk('4 个账号升到 VIP 3/5/8/11', true);

    const w11 = wsList[3];
    w11.send2({ type: 'room:create', userId: ids.lv11, name: '名字特权验收房' + TAG });
    const rc = await w11.wait(m => m.type === 'room:created');
    roomId = rc?.data?.id;
    if (!roomId) throw new Error('建房失败');

    for (let i = 0; i < PLAN.length; i++) {
      const p = PLAN[i];
      wsList[i].send2({ type: 'room:join', userId: ids[p.key], roomId });
      const j = await wsList[i].wait(m => m.type === 'join:ok');
      clients[p.key] = j?.data?.clientId;
      if (!clients[p.key]) throw new Error('进房失败 ' + p.key);
    }
    chk('5 人全部进房（房主占 0 号位，其余 1-4 号）', Object.keys(clients).length === 5);

    const st = await (async () => {
      // room:state 是"广播快照"，最后一个 join 的 join:ok 到快照到达 w11 之间有时差，
      // 立刻取会拿到只有 4 人的旧快照。轮询到 5 人再继续。
      for (let i = 0; i < 30; i++) {
        const s = w11.all.filter(m => m.type === 'room:state').pop();
        if ((s?.data?.members || []).length >= 5) return s;
        await sleep(200);
      }
      return w11.all.filter(m => m.type === 'room:state').pop();
    })();
    const members = st?.data?.members || [];
    const byUser = Object.fromEntries(members.map(m => [m.user.id, m.user]));
    for (const p of PLAN) {
      const u = byUser[ids[p.key]];
      const wantVip = p.lvl > 0;
      const ok = !!u && !!u.vip === wantVip && (u.vipLevel || 0) === p.lvl;
      chk(`room:state 里 ${p.key} 的 vip/vipLevel = ${wantVip}/${p.lvl}`, ok,
          u ? `实际 ${u.vip}/${u.vipLevel}` : '成员缺失');
    }

    // 公屏消息也要带等级 —— 公屏名字的颜色就靠它。
    // 注意匹配条件要排除系统消息：系统消息的文案里带着**房间名**，而房间名含 TAG，
    // 只按 TAG 匹配会抓到"xxx 创建了房间「…TAG」"这条，它本来就没有 vip 字段。
    const CHAT_TEXT = 'VIPNAME-' + TAG;
    w11.send2({ type: 'chat', userId: ids.lv11, text: CHAT_TEXT });
    const cm = await w11.wait(m => m.type === 'chat' && m.data && !m.data.isSystem && m.data.text === CHAT_TEXT);
    const cd = cm?.data || {};
    chk('公屏消息带 vip + vipLevel=11', cd.vip === true && (cd.vipLevel || 0) === 11,
        `vip=${cd.vip} vipLevel=${cd.vipLevel}`);

    /* ================= B. 真实浏览器渲染 ================= */
    note('B. 真实 Chrome · 渲染验证');

    browser = await puppeteer.launch({
      executablePath: CHROME, headless: 'new',
      args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--mute-audio'],
    });
    const page = await browser.newPage();
    await page.setViewport({ width: 430, height: 932, deviceScaleFactor: 2 });

    const jsErrors = [];
    page.on('pageerror', e => jsErrors.push(String(e.message || e)));
    page.on('console', m => { if (m.type() === 'error') jsErrors.push('console: ' + m.text()); });

    const me = byUser[ids.lv11];
    await page.goto(`${API}/index.html`, { waitUntil: 'domcontentloaded' });
    await page.evaluate((uid, user) => {
      localStorage.setItem('vr_userId', JSON.stringify(uid));
      localStorage.setItem('vr_user', JSON.stringify(user));
    }, ids.lv11, me);

    await page.goto(`${API}/room.html?room=${roomId}`, { waitUntil: 'networkidle2' });
    await sleep(1400);

    chk('房间页无 JS 报错', jsErrors.length === 0, jsErrors.slice(0, 3).join(' | '));

    // ---- 名字：每个等级都要落在对应档位 ----
    // 房主不在 .seat 里，他单独渲染成 .host-seat / .hn-text，两处都要收。
    const rows = await page.evaluate(() => {
      const out = [];
      const push = (scope, el) => {
        const v = el.querySelector('.vname');
        const cs = v ? getComputedStyle(v) : null;
        const box = v ? v.getBoundingClientRect() : null;
        out.push({
          scope, text: el.textContent.trim(), raw: el.innerHTML,
          cls: v ? v.className : null,
          width: box ? Math.round(box.width) : 0,
          clip: cs ? (cs.webkitBackgroundClip || cs.backgroundClip) : null,
          fill: cs ? cs.webkitTextFillColor : null,
          anim: cs ? cs.animationName : null,
          bg: cs ? cs.backgroundImage.slice(0, 60) : null,
        });
      };
      document.querySelectorAll('.host-seat .hn-text').forEach(e => push('host', e));
      document.querySelectorAll('.seat .sname').forEach(e => push('seat', e));
      return out;
    });
    chk('麦位 + 主位共渲染出 5 个名字', rows.length === 5, `实际 ${rows.length} 个`);

    for (const p of PLAN) {
      const un = names[p.key];
      const row = rows.find(r => r.text.includes(un));
      if (!row) { chk(`麦位 ${p.key}(${un}) 出现在麦上`, false, '未找到'); continue; }
      if (p.tier) {
        chk(`${p.key} 名字套上 ${p.tier}`, (row.cls || '').includes(p.tier),
            `实际 ${row.cls}（${row.scope}）`);
      } else {
        chk(`${p.key}（非 VIP）不加任何档位`, row.cls === null, `实际 ${row.cls}`);
      }
    }

    const aur = rows.find(r => (r.cls || '').includes('v-aurora'));
    // 两个背景层（扫光 + 底色）都被裁到字形，所以 background-clip 计算值是 "text, text"
    chk('三色名字是真的渐变填字（background-clip:text + 透明字色）',
        !!aur && /^text(,\s*text)*$/.test(aur.clip || '')
        && /^rgba\(0,\s*0,\s*0,\s*0\)$|^transparent$/.test(aur.fill || ''),
        JSON.stringify({ found: !!aur, clip: aur?.clip, fill: aur?.fill }));
    chk('三色名字的流光动画在跑', !!aur && aur.anim === 'vname-aurora', aur ? aur.anim : '');
    chk('三色名字有实际宽度（不是塌成 0）', !!aur && aur.width > 8, aur ? aur.width + 'px' : '');

    // ---- 等级数字必须从麦位消失 ----
    const numeric = rows.filter(r => /💎|VIP\s*\d|V11|V8/.test(r.text));
    chk('麦位文字里不再出现等级数字', numeric.length === 0,
        numeric.map(r => r.text).join(' / '));

    // ---- 公屏 ----
    const chat = await page.evaluate(t => {
      const els = [...document.querySelectorAll('#chatList .msg-name')];
      const el = els.find(e => e.textContent.includes(t)) || els[els.length - 1];
      const v = el ? el.querySelector('.vname') : null;
      return { total: els.length, text: el ? el.textContent.trim() : null,
               cls: v ? v.className : null,
               anim: v ? getComputedStyle(v).animationName : null };
    }, names.lv11);
    chk('公屏 VIP11 名字套上 v-aurora', (chat.cls || '').includes('v-aurora'), JSON.stringify(chat));

    // ---- 成员列表：名字带档位、等级数字不再出现 ----
    await page.evaluate(() => openSheet('sheetMembers'));
    await sleep(500);
    const sheetVisible = await page.evaluate(() => {
      const s = document.getElementById('sheetMembers');
      return !!s && s.classList.contains('show') && s.getBoundingClientRect().height > 10;
    });
    chk('成员面板真的打开了（不是读隐藏 DOM）', sheetVisible);
    const mem = await page.evaluate(() => {
      const out = [];
      document.querySelectorAll('#memberList .member-item').forEach(it => {
        const mn = it.querySelector('.mn');
        out.push({ text: mn.textContent.trim(), hasVname: !!mn.querySelector('.vname'),
                   cls: mn.querySelector('.vname')?.className || null });
      });
      return out;
    });
    chk('成员列表 5 行都渲染出来了', mem.length === 5, `实际 ${mem.length}`);
    chk('成员列表里 VIP 名字都带档位', mem.filter(x => x.cls).length === 4,
        JSON.stringify(mem.map(x => x.cls)));
    chk('成员列表里不再有等级数字', mem.every(x => !/💎|VIP\d/.test(x.text)),
        mem.map(x => x.text).join(' / '));

    // ---- 名片：等级数字唯一保留的地方 ----
    // 用页面自己看到的 clientId，而不是 WS 那次的：
    // 网页一登录，服务端会按"一人一连接"把前面的 WS 踢掉并重新分配 clientId。
    // 注意 STATE 是 `let` 声明的全局词法绑定，不是 window 属性，只能直接引用。
    const who = await page.evaluate(un => {
      const list = (typeof STATE !== 'undefined' && STATE && STATE.members) || [];
      const m = list.find(x => x.user && x.user.name === un);
      return { cid: m ? m.clientId : null, total: list.length, names: list.map(x => x.user && x.user.name) };
    }, names.lv11);
    chk('页面自己能拿到房主的 clientId', !!who.cid, JSON.stringify(who));

    await page.evaluate(cid => {
      VR.closeSheet();
      openCard(cid);
    }, who.cid);
    await sleep(600);
    const card = await page.evaluate(() => {
      const b = document.getElementById('cardBody');
      const v = b.querySelector('.vname');
      return { text: b.textContent.replace(/\s+/g, ' ').trim().slice(0, 120),
               hasBadge: /💎\s*V11/.test(b.textContent),
               vcls: v ? v.className : null };
    });
    chk('名片里保留 VIP11 等级数字', card.hasBadge, card.text);
    chk('名片里名字也有特权色', (card.vcls || '').includes('v-aurora'), String(card.vcls));

    // ---- 截图留证 ----
    const shot = path.join(SHOT_DIR, 'vipname_web.png');
    const shotCard = path.join(SHOT_DIR, 'vipname_card.png');
    await page.screenshot({ path: shotCard });          // 名片（等级数字保留处）
    await page.evaluate(() => { VR.closeModal(); VR.closeSheet(); });
    await sleep(500);
    await page.screenshot({ path: shot });              // 干净的房间页

    // 单独给三色名字拍一张放大的图，方便人眼确认渐变真的画上去了
    await page.evaluate(() => {
      const host = document.createElement('div');
      host.id = 'vname-bench';
      host.style.cssText = 'position:fixed;left:0;top:0;z-index:99999;background:#0B1020;padding:18px 22px;font:600 26px/1.9 -apple-system,sans-serif';
      host.innerHTML = [
        [0, false], [3, true], [5, true], [8, true], [11, true],
      ].map(([lv, vip]) => `<div>L${lv}：${VR.vipName('岛岛大人', vip, lv)}</div>`).join('');
      document.body.appendChild(host);
    });
    await sleep(700);
    const bench = path.join(SHOT_DIR, 'vipname_bench.png');
    const el = await page.$('#vname-bench');
    await el.screenshot({ path: bench });
    await page.evaluate(() => document.getElementById('vname-bench').remove());
    chk('截图已保存（房间页 + 四档对照）', fs.existsSync(shot) && fs.existsSync(bench));

  } catch (e) {
    chk('执行过程无异常', false, String(e && e.message || e));
  } finally {
    try { if (browser) await browser.close(); } catch {}
    for (const w of wsList) { try { w.close(); } catch {} }
    // ---- 清场 ----
    try {
      if (roomId) await post('/api/admin/delete-room', { password: PWD, roomId });
      for (const k of Object.keys(ids)) {
        if (ids[k]) await post('/api/admin/clear-user', { password: PWD, userId: ids[k] });
      }
      const ov = await post('/api/admin/overview', { password: PWD });
      const d = ov?.data || ov || {};
      const leftUsers = Object.values(d.users || {}).filter(u => String(u.name || '').includes('vn') && String(u.name || '').includes(TAG)).length;
      const leftRooms = Object.values(d.rooms || {}).filter(r => String(r.name || '').includes(TAG)).length;
      console.log(`\n【清场】残留测试账号 ${leftUsers} / 残留测试房间 ${leftRooms}`);
    } catch (e) { console.log('清场异常:', String(e && e.message || e)); }
  }

  const pass = R.filter(r => r.ok).length;
  console.log(`\n===== ${pass}/${R.length} 通过 =====`);
  R.filter(r => !r.ok).forEach(r => console.log('失败：' + r.n + (r.i ? ' → ' + r.i : '')));
  process.exit(pass === R.length ? 0 : 1);
})();
