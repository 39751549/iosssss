// 「音乐扩展：榜单 / 歌词 / 封面」验收
//
// 本轮改动：
//   1. server.js：GD 限流（滑动窗口 45 次/300s + 429 长退避 60s）；
//      直链默认 br=999（24bit 无损），拿不到回落 320。
//   2. 新增 HTTP 接口：/api/music/top（榜单清单 + 榜单曲目，曲目带 picId 封面 ID）
//      /api/music/lyric（LRC 歌词）/api/music/pic（封面直链），全部走服务端缓存。
//   3. iOS：MusicSheet 加 🏆榜单 tab（本地缓存秒开 + 后台刷新指纹对比）+ 歌词浮层。
//   4. Web：room.html 音乐面板加榜单 tab，同样缓存秒开、封面懒加载。
//
// 验收分三段（消耗 GD 额度极少：榜单 1 次 + 歌词 1 次 + 封面 1 次）：
//   A. 本地起 server，真打 GD 接口验证三端点 + 缓存生效 + 错误处理。
//   B. Web 静态检查：tab/pane/缓存/指纹对比/封面懒加载都在。
//   C. Swift 静态检查：模型/缓存/榜单 UI/歌词视图 + 词法完整。
const http = require('http');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const PORT = 8197;
const API = `http://127.0.0.1:${PORT}`;
const ROOT = path.join(__dirname, '..');
const DATA_DIR = path.join(ROOT, 'data-test-music');

let pass = 0, fail = 0;
function ok(cond, label) {
  if (cond) { pass++; console.log('  ✓', label); }
  else { fail++; console.log('  ✗', label); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

function get(p) {
  return new Promise((res, rej) => {
    const t0 = Date.now();
    http.get(API + p, r => {
      const chunks = [];
      r.on('data', c => chunks.push(c));
      r.on('end', () => res({ status: r.statusCode, buf: Buffer.concat(chunks), ms: Date.now() - t0 }));
    }).on('error', rej);
  });
}
const getJSON = async p => {
  const r = await get(p);
  try { return { ...r, j: JSON.parse(r.buf.toString('utf8')) }; }
  catch { return { ...r, j: null }; }
};

async function main() {
  fs.rmSync(DATA_DIR, { recursive: true, force: true });
  fs.mkdirSync(DATA_DIR, { recursive: true });

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

    console.log('\n== A1. 榜单清单（静态，不耗 GD 额度） ==');
    const charts = await getJSON('/api/music/top');
    ok(charts.j && charts.j.ok, '/api/music/top 返回 ok');
    const cl = (charts.j && charts.j.charts) || [];
    ok(cl.length >= 5, `榜单清单 ≥5 份（实为 ${cl.length}）`);
    ok(cl.every(c => c.id && c.name && c.icon), '每份榜单都有 id/name/icon');
    ok(charts.j.br === 999, '音质 br=999（24bit 无损）');

    console.log('\n== A2. 榜单曲目（真打 GD，1 次请求） ==');
    const hot = await getJSON('/api/music/top?id=3778678');
    ok(hot.j && hot.j.ok, '热歌榜返回 ok');
    const tracks = (hot.j && hot.j.tracks) || [];
    ok(tracks.length >= 20, `曲目 ≥20 首（实为 ${tracks.length}）`);
    ok(tracks.every(t => /^gd\|netease\|\d+$/.test(t.id)), '曲目 id 都是 gd|netease|<数字>（可直接点播）');
    ok(tracks.every(t => t.title), '曲目都有歌名');
    ok(tracks.every(t => typeof t.picId === 'string'), 'picId 是字符串（避免 JS 大数精度截断）');
    const withPic = tracks.filter(t => t.picId).length;
    ok(withPic >= tracks.length * 0.8, `大部分曲目带封面 ID（${withPic}/${tracks.length}）`);
    const first = tracks[0];
    ok(!!first, `第一名：${first ? first.title + ' - ' + first.artist : '?'}`);

    console.log('\n== A3. 榜单服务端缓存生效（第二次必须秒回） ==');
    const hot2 = await getJSON('/api/music/top?id=3778678');
    ok(hot2.j && hot2.j.ok && hot2.j.tracks.length === tracks.length, '第二次返回一致');
    ok(hot2.ms < 800, `第二次 ${hot2.ms}ms（命中 30 分钟缓存）`);

    console.log('\n== A4. 歌词（真打 GD，1 次请求） ==');
    const songId = first.id.split('|')[2];
    const lyric = await getJSON('/api/music/lyric?id=' + encodeURIComponent(first.id));
    ok(lyric.j && lyric.j.ok, '歌词返回 ok');
    ok(lyric.j && /\[\d{1,2}:\d{1,2}/.test(lyric.j.lyric || ''), '歌词是 LRC 格式（带时间戳）');

    console.log('\n== A5. 封面（真打 GD，1 次请求） ==');
    const pic = await getJSON('/api/music/pic?id=' + encodeURIComponent(first.picId) + '&size=300');
    ok(pic.j && pic.j.ok && /^https:\/\//.test(pic.j.url || ''), '封面返回 https 直链');
    ok(pic.j && /music\.126\.net/.test(pic.j.url || ''), '封面直链在网易 CDN');
    const pic2 = await getJSON('/api/music/pic?id=' + encodeURIComponent(first.picId) + '&size=300');
    ok(pic2.j && pic2.j.ok && pic2.j.url === pic.j.url, '第二次命中缓存且直链一致');

    console.log('\n== A6. 错误处理 ==');
    const badLib = await getJSON('/api/music/lyric?id=lib_abc123');
    ok(badLib.j && badLib.j.ok === false, '本地曲库 ID 请求歌词被拒（仅在线歌曲）');
    const badChart = await getJSON('/api/music/top?id=99999999');
    ok(badChart.j && badChart.j.ok === false, '未知榜单返回 ok:false 而不是 500');
    const badPic = await getJSON('/api/music/pic?id=abcxyz');
    ok(badPic.j && badPic.j.ok === false, '非法封面 ID 返回 ok:false');

    console.log('\n== B. Web 静态检查 ==');
    const room = fs.readFileSync(path.join(ROOT, 'public/room.html'), 'utf8');
    ok(room.includes('data-tab="top"') && room.includes('pane-top'), '音乐面板有 🏆榜单 tab 和 pane');
    ok(room.includes('function loadChart(') && room.includes('function loadTopCharts()'), '有榜单加载逻辑');
    ok(room.includes("VR.LS.get(chartCacheKey(id)"), '榜单走 localStorage 缓存（秒开）');
    ok(room.includes('chartFingerprint'), '有指纹对比（后台刷新有变化才重绘）');
    ok(room.includes("if (kind === 'top') return chartTracks[i];"), '点播/加入支持榜单条目（itemOf top）');
    ok(room.includes('IntersectionObserver'), '封面进视口才加载（不刷爆额度）');
    const css = fs.readFileSync(path.join(ROOT, 'public/css/app.css'), 'utf8');
    ok(css.includes('.rank-item') && css.includes('.rank-num.r1'), '榜单行样式（前三名奖牌色）');

    console.log('\n== C. Swift 静态检查 ==');
    const api = fs.readFileSync(path.join(ROOT, 'ios-native/VoiceRoom/Sources/Core/MusicAPI.swift'), 'utf8');
    ok(api.includes('struct VRChartInfo') && api.includes('struct VRChartTrack'), '榜单模型齐全');
    ok(api.includes('enum VRChartCache') && api.includes('static func load('), '榜单本地缓存（秒开）');
    ok(api.includes('enum VRLyric') && api.includes('NSRegularExpression'), 'LRC 解析（NSRegularExpression，兼容 iOS15）');
    ok(api.includes('static func chart(_ id: String') && api.includes('static func lyric(libraryId:'), '榜单/歌词请求齐全');
    const sheet = fs.readFileSync(path.join(ROOT, 'ios-native/VoiceRoom/Sources/Features/Room/MusicSheet.swift'), 'utf8');
    ok(/case charts, search, playlist/.test(sheet), '榜单 tab 排第一位');
    ok(sheet.includes('chartsSection') && sheet.includes('chartRow(rank:'), '榜单 UI（chips + 排名行）');
    ok(sheet.includes('VRChartCache.load(id)') && sheet.includes('chartFingerprint'), '缓存秒开 + 指纹对比更新');
    ok(sheet.includes('LyricScrollView') && sheet.includes('lyricsSheet'), '歌词浮层（当前行高亮滚动）');
    ok(sheet.includes('showLyrics = true'), '播放条有「词」入口');

    const { execSync } = require('child_process');
    try {
      execSync(`"${process.env.PY || 'python'}" check_swift_lex.py`, { cwd: ROOT, stdio: 'pipe' });
      ok(true, 'check_swift_lex.py 词法完整');
    } catch (e) {
      ok(false, 'check_swift_lex.py: ' + String(e.stderr || e.message).slice(0, 200));
    }

    console.log('\n== D. 服务端限流静态检查（不真打满 45 次） ==');
    const sv = fs.readFileSync(path.join(ROOT, 'server.js'), 'utf8');
    ok(sv.includes('GD_WINDOW_MAX = 45') && sv.includes('GD_WINDOW_MS = 300 * 1000'), '滑动窗口 45 次/300 秒');
    ok(sv.includes('gdThrottle()') && sv.includes('gdBlockUntil'), '请求前过闸 + 429 长退避');
    ok(/for \(const b of \[want, 320\]\)/.test(sv), '999 无损拿不到时回落 320');
  } finally {
    srv.kill();
    await sleep(300);
    try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch {}
  }

  console.log(`\n===== 结果：${pass} 通过 / ${fail} 失败 =====`);
  process.exit(fail ? 1 : 0);
}

main().catch(e => { console.error('FATAL', e); process.exit(1); });
