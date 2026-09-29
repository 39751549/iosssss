/**
 * 真实浏览器验证：管理后台是否正常渲染「全部用户」+「设置头像」入口。
 *
 * 背景：common.js 删掉 bgIcon() 后，admin.html 的 renderRooms() 还在调它，
 * 一抛错就把 renderUsers() / loadMusic() 一起带走了 ——
 * 表现是「后台看不到用户、也找不到设置头像的地方」，但房间表格又正常。
 * 这个脚本就是防止这类「渲染链中断」再犯。
 *
 * 用法：node verify_admin_render.js
 */
const puppeteer = require('puppeteer-core');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const URL = 'http://43.142.76.172:8125/admin.html';
const PWD = process.env.ADMIN_PWD || 'admin888';

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log('  ✅ ' + name + (detail ? '  → ' + detail : '')); }
  else { fail++; console.log('  ❌ ' + name + (detail ? '  → ' + detail : '')); }
}

(async () => {
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: 'new',
    args: ['--no-sandbox', '--disable-dev-shm-usage']
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 1400 });

  const errors = [];
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));
  page.on('console', m => {
    if (m.type() !== 'error') return;
    // 探测接口可达性时故意发的 400，URL 里带 upload-avatar，不算页面 bug
    const url = (m.location() && m.location().url) || '';
    if (/upload-avatar/i.test(url)) return;
    errors.push('CONSOLE: ' + m.text() + (url ? '  @ ' + url : ''));
  });

  await page.goto(URL, { waitUntil: 'domcontentloaded' });
  await page.evaluate(p => sessionStorage.setItem('adminPwd', p), PWD);
  // 注意：后台有 setInterval 每 8 秒轮询一次，networkidle 永远等不到，
  // 所以用 domcontentloaded + 显式等待表格渲染完成。
  await page.reload({ waitUntil: 'domcontentloaded' });

  // 等「全部用户」渲染完成
  await page.waitForFunction(() => {
    const b = document.getElementById('userBody');
    return b && b.querySelectorAll('tr').length > 0;
  }, { timeout: 20000 }).catch(() => {});

  console.log('\n--- 登录状态 ---');
  const panelVisible = await page.evaluate(() =>
    getComputedStyle(document.getElementById('adminPanel')).display !== 'none');
  check('已进入后台（密码正确）', panelVisible);
  if (!panelVisible) {
    console.log('\n密码不是 admin888，可用 ADMIN_PWD=xxx node verify_admin_render.js 重试');
    await browser.close();
    process.exit(1);
  }

  console.log('\n--- 数据总览 ---');
  const stats = await page.$$eval('#stats .stat-card .v', els => els.map(e => e.textContent.trim()));
  check('数据总览已渲染', stats.length === 6, stats.join(' / '));

  console.log('\n--- 房间管理 ---');
  const roomInfo = await page.evaluate(() => {
    const rows = [...document.querySelectorAll('#roomBody tr')];
    return {
      count: rows.length,
      hasThumb: rows.some(r => r.querySelector('.bg-thumb')),
      firstBgText: rows[0] ? (rows[0].querySelectorAll('td')[2] || {}).textContent : ''
    };
  });
  check('房间表格已渲染', roomInfo.count > 0, roomInfo.count + ' 行');
  check('背景列显示缩略图（不再是 VR.bgIcon 文字）', roomInfo.hasThumb,
        roomInfo.firstBgText ? '示例：' + roomInfo.firstBgText.trim() : '');

  console.log('\n--- 全部用户（原故障点）---');
  const userInfo = await page.evaluate(() => {
    const rows = [...document.querySelectorAll('#userBody tr')];
    const real = rows.filter(r => r.querySelectorAll('td').length >= 2);
    return {
      rowCount: rows.length,
      realRows: real.length,
      colCount: real[0] ? real[0].querySelectorAll('td').length : 0,
      headerCols: document.querySelectorAll('#userBody').length
        ? document.querySelectorAll('table thead th').length : 0,
      hasAvCell: !!document.querySelector('#userBody .av-cell'),
      hasAvBtn: [...document.querySelectorAll('#userBody button')]
        .some(b => b.textContent.includes('更换')),
      hasEditBtn: [...document.querySelectorAll('#userBody button')]
        .some(b => b.textContent.includes('资料')),
      hasVipBtn: [...document.querySelectorAll('#userBody button')]
        .some(b => b.textContent.includes('VIP')),
      empty: document.getElementById('userBody').textContent.includes('还没有注册用户')
    };
  });
  check('用户表格有内容', userInfo.rowCount > 0, userInfo.rowCount + ' 行');
  check('不是「还没有注册用户」空态', !userInfo.empty);
  check('用户行有 7 列（新增头像列）', userInfo.colCount === 7, userInfo.colCount + ' 列');
  check('头像列已渲染（.av-cell）', userInfo.hasAvCell);
  check('「🖼️ 更换」头像按钮存在', userInfo.hasAvBtn);
  check('「✏️ 资料」按钮存在', userInfo.hasEditBtn);
  check('VIP 按钮存在', userInfo.hasVipBtn);

  console.log('\n--- 音乐曲库（同一个渲染链的下游）---');
  const musicSub = await page.evaluate(() =>
    (document.getElementById('musicSub') || {}).textContent || '');
  check('曲库区块已渲染', !!musicSub.trim(), musicSub.trim());

  console.log('\n--- 头像接口可达性（不改数据）---');
  const avatarApi = await page.evaluate(async (pwd) => {
    // 传一段非图片内容：若能走到「仅支持图片」说明路由+鉴权+分支都通了，且不会写入任何文件
    const res = await fetch('/api/admin/upload-avatar?password=' + encodeURIComponent(pwd) +
                            '&userId=u_admin', {
      method: 'POST', headers: { 'Content-Type': 'application/octet-stream' },
      body: new TextEncoder().encode('not-an-image')
    });
    return { status: res.status, body: await res.text() };
  }, PWD);
  check('upload-avatar 路由可达且鉴权通过', avatarApi.status === 400,
        'HTTP ' + avatarApi.status + ' ' + avatarApi.body.slice(0, 60));

  console.log('\n--- 控制台错误 ---');
  // 已知会被 Chrome 抱怨但不影响功能的噪声：
  //  - favicon / manifest 之类的 4xx
  //  - 上面那条故意发出去的 upload-avatar 400（探测接口可达性用的）
  const real = errors.filter(e =>
    !/favicon|manifest|upload-avatar|Failed to load resource.*40[34]/i.test(e));
  check('无 JS 运行时报错', real.length === 0, real.length ? real.join(' | ') : '干净');

  await page.screenshot({ path: 'admin_verify.png', fullPage: true });
  console.log('\n截图已保存：admin_verify.png');
  console.log('\n结果：%d 通过 / %d 失败', pass, fail);
  await browser.close();
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('脚本异常：', e); process.exit(1); });
