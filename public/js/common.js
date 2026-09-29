/* ================= 公共工具库 ================= */
const VR = (() => {

  /* ---------- 本地存储 ---------- */
  const LS = {
    get(k, d) { try { const v = localStorage.getItem('vr_' + k); return v ? JSON.parse(v) : d; } catch { return d; } },
    set(k, v) { try { localStorage.setItem('vr_' + k, JSON.stringify(v)); } catch {} },
    del(k) { try { localStorage.removeItem('vr_' + k); } catch {} }
  };

  /* ---------- Toast ---------- */
  function toast(msg, type) {
    let box = document.getElementById('toasts');
    if (!box) { box = document.createElement('div'); box.id = 'toasts'; document.body.appendChild(box); }
    const el = document.createElement('div');
    el.className = 'toast' + (type ? ' ' + type : '');
    el.textContent = msg;
    box.appendChild(el);
    setTimeout(() => el.remove(), 2400);
  }

  /* ---------- 头像 ---------- */
  const AV_BG = ['#FF6B8B','#6BC5FF','#FFB86B','#8B7BFF','#5ED3A8','#FF8FB1','#7ED0FF','#FFD36B','#A78BFA','#34D399','#F472B6','#60A5FA'];
  function avatarColor(seed) {
    let h = 0; const s = String(seed || 'a');
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
    return AV_BG[h % AV_BG.length];
  }
  /** 生成一个 SVG 头像 dataURL（首字母 + 渐变底） */
  function genAvatar(name, idx) {
    const c1 = AV_BG[(idx == null ? seedNum(name) : idx) % AV_BG.length];
    const c2 = AV_BG[((idx == null ? seedNum(name) : idx) + 4) % AV_BG.length];
    const ch = (String(name || '?').trim()[0] || '?').toUpperCase();
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">
      <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="${c1}"/><stop offset="1" stop-color="${c2}"/>
      </linearGradient></defs>
      <rect width="120" height="120" fill="url(#g)"/>
      <text x="60" y="60" font-family="-apple-system,PingFang SC,sans-serif" font-size="54" font-weight="700"
        fill="#fff" text-anchor="middle" dominant-baseline="central">${esc(ch)}</text></svg>`;
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  }
  function seedNum(s) { let h = 0; const t = String(s || 'a'); for (let i = 0; i < t.length; i++) h = (h * 31 + t.charCodeAt(i)) >>> 0; return h; }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /** 渲染头像 HTML（自定义头像不垫底色，透明 PNG 保持透明） */
  function avatarHtml(user, size, extraStyle) {
    const u = user || {};
    const sz = size || 40;
    const style = `width:${sz}px;height:${sz}px;font-size:${Math.round(sz * 0.38)}px;` + (extraStyle || '');
    const src = u.avatar || genAvatar(u.name, null);
    const initial = esc((u.name || '?').trim()[0] || '?').toUpperCase();
    const bgc = u.avatar ? '' : `background-color:${avatarColor(u.id || u.name)};`;
    const fallback = `this.parentNode.style.background='${avatarColor(u.id || u.name)}';this.style.display='none';this.parentNode.textContent='${initial}'`;
    return `<div class="avatar" style="${style}${bgc}">
      <img src="${esc(src)}" alt="" onerror="${fallback}">
    </div>`;
  }

  /* ---------- 时间 ---------- */
  function hhmm(ts) {
    const d = new Date(ts || Date.now());
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }

  /* ---------- WebSocket 封装 ---------- */
  function connect(onMessage, onOpen, onClose) {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${proto}//${location.host}`);
    ws.onopen = () => onOpen && onOpen();
    ws.onmessage = (e) => { try { onMessage(JSON.parse(e.data)); } catch (err) { console.warn('bad msg', e.data); } };
    ws.onclose = () => onClose && onClose();
    ws.onerror = () => {};
    return ws;
  }

  /* ---------- 弹层控制 ---------- */
  function openSheet(id) {
    const m = document.getElementById('mask');
    const s = document.getElementById(id);
    if (m) m.classList.add('show');
    if (s) s.classList.add('show');
  }
  function closeSheet() {
    const m = document.getElementById('mask');
    if (m) m.classList.remove('show');
    document.querySelectorAll('.sheet').forEach(s => s.classList.remove('show'));
  }
  function openModal(id) {
    const s = document.getElementById(id);
    if (s) s.classList.add('show');
  }
  function closeModal(id) {
    if (id) { const s = document.getElementById(id); if (s) s.classList.remove('show'); }
    else document.querySelectorAll('.modal-mask').forEach(m => m.classList.remove('show'));
  }

  /* ---------- 图片压缩（上传用，格式感知） ----------
   * GIF  → 原样直传（保留动画，canvas 会把动图压成静态图）
   * PNG/WebP → canvas 缩放后导出 PNG（保留透明通道）
   * 其他(JPG 等) → canvas 缩放后导出 JPEG（体积小） */
  function fileToCompressedDataURL(file, maxSize = 256, quality = 0.82) {
    const type = (file && file.type || '').toLowerCase();
    if (type === 'image/gif') {
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
    }
    const outType = (type === 'image/png' || type === 'image/webp') ? 'image/png' : 'image/jpeg';
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const img = new Image();
        img.onload = () => {
          const scale = Math.min(1, maxSize / Math.max(img.width, img.height));
          const w = Math.round(img.width * scale), h = Math.round(img.height * scale);
          const c = document.createElement('canvas');
          c.width = w; c.height = h;
          const ctx = c.getContext('2d');
          ctx.drawImage(img, 0, 0, w, h);
          resolve(c.toDataURL(outType, quality));
        };
        img.onerror = reject;
        img.src = reader.result;
      };
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  }

  /* ---------- 性别 ---------- */
  const GENDER = {
    male:   { label: '男', icon: '♂', color: '#4FC3F7' },
    female: { label: '女', icon: '♀', color: '#FF5F98' },
    secret: { label: '保密', icon: '?', color: 'rgba(255,255,255,.5)' }
  };
  function genderIcon(g) {
    const it = GENDER[g] || GENDER.secret;
    return `<span style="color:${it.color};font-weight:800" title="${it.label}">${it.icon}</span>`;
  }

  /* ---------- 房间背景 ---------- */
  /* 内置背景固定 5 张，图片是同仓库的静态资源 public/presets/preset-N.gif，
     由服务端以 /presets/preset-N.gif 对外提供。
     id 和 iOS 端完全一致 —— 房主在哪一端换的背景，另一端看到的都是同一张图。
     用户上传的自定义背景走 /bg/xxx 路径，逻辑不变。 */
  const BACKGROUNDS = [
    { id: '/presets/preset-1.gif', name: '紫海' },
    { id: '/presets/preset-2.gif', name: '幻月' },
    { id: '/presets/preset-3.gif', name: '小鹿' },
    { id: '/presets/preset-4.gif', name: '星云' },
    { id: '/presets/preset-5.gif', name: '云海' }
  ];
  /** 默认背景：新房间、清掉自定义背景后都回到这张 */
  const DEFAULT_BG = BACKGROUNDS[0].id;

  function findBg(id) {
    return BACKGROUNDS.find(b => b.id === id) || null;
  }
  /** 是不是「图片背景」（内置的 5 张和自定义上传的都是路径） */
  function isImageBg(id) {
    return !!(id && (id.startsWith('/') || id.startsWith('http')));
  }
  /** 是不是用户上传的自定义背景（是路径，但不是内置的那 5 张） */
  function isCustomBg(id) {
    return isImageBg(id) && !findBg(id);
  }
  /** 缩略图内联样式：图片背景直接铺 background-image */
  function bgStyle(id) {
    return isImageBg(id)
      ? `background-image:url('${esc(id)}');background-size:cover;background-position:center`
      : '';
  }
  /** 真正要显示的图：老主题名（aurora / hearts）已下线 → 落到默认背景，不会白屏 */
  function resolveBg(id) {
    return isImageBg(id) ? id : DEFAULT_BG;
  }
  /** 页面 body 上可能残留的旧主题类，切背景时统一摘掉 */
  const BG_CLASSES = ['bg-aurora', 'bg-hearts', 'bg-sakura', 'bg-bubbles', 'bg-meteor', 'bg-custom'];

  /** 应用房间背景（内置 5 张图 / 自定义上传的图，统一按图片背景处理） */
  function applyBackground(id) {
    const body = document.body;
    BG_CLASSES.forEach(c => body.classList.remove(c));
    // 清理旧版主题残留的粒子层
    document.querySelectorAll('.bg-fx').forEach(el => el.remove());
    body.classList.add('bg-custom');
    body.style.backgroundImage = `url(${resolveBg(id)})`;
  }

  /* ---------- VIP 等级徽章（1-12 级） ---------- */
  function vipBadge(level, small) {
    const lv = Math.max(0, Math.min(12, Number(level) || 0));
    if (lv <= 0) return '';
    const hue = 45 - (lv - 1) * 3; // 等级越高越偏金红
    const bg = lv >= 10
      ? 'linear-gradient(135deg,#FF3B5C,#FF8A3D)'
      : lv >= 6
        ? 'linear-gradient(135deg,#F5A623,#FFD36B)'
        : 'linear-gradient(135deg,#7B6BFF,#4FC3F7)';
    const cls = small ? 'badge vipsm' : 'badge';
    return `<span class="${cls}" style="background:${bg}">💎V${lv}</span>`;
  }

  /* ---------- 数字简写 ---------- */
  function shortNum(n) {
    n = Number(n) || 0;
    if (n >= 100000000) return (n / 100000000).toFixed(1).replace(/\.0$/, '') + '亿';
    if (n >= 10000)     return (n / 10000).toFixed(1).replace(/\.0$/, '') + '万';
    return String(n);
  }

  /* ---------- 振动反馈 ---------- */
  function haptic(ms) { try { navigator.vibrate && navigator.vibrate(ms || 12); } catch {} }

  /* ---------- 复制 ---------- */
  async function copy(text) {
    try {
      await navigator.clipboard.writeText(String(text));
      toast('已复制：' + text, 'ok'); return true;
    } catch {
      const ta = document.createElement('textarea');
      ta.value = String(text); ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); toast('已复制：' + text, 'ok'); } catch { toast('复制失败，请手动记录', 'err'); }
      ta.remove();
    }
  }

  return { LS, toast, esc, avatarHtml, genAvatar, avatarColor, hhmm, connect,
           openSheet, closeSheet, openModal, closeModal, fileToCompressedDataURL,
           GENDER, genderIcon, BACKGROUNDS, DEFAULT_BG, findBg, isImageBg, isCustomBg,
           bgStyle, resolveBg, applyBackground, shortNum, haptic, copy, vipBadge };
})();
