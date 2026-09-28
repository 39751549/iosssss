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
  /* fx: 需要动态粒子层的主题（CSS 动画实现）。默认只保留 2 个，更多靠自定义背景图 */
  const BACKGROUNDS = [
    { id: 'aurora',  name: '极光',   cls: 'bg-aurora',  icon: '🌌', fx: null },
    { id: 'hearts',  name: '爱心雨', cls: 'bg-hearts',  icon: '💖', fx: 'hearts' }
  ];
  function findBg(id) {
    return BACKGROUNDS.find(b => b.id === id) || null;
  }
  function bgClass(id) {
    const b = findBg(id);
    return b ? b.cls : 'bg-custom';
  }
  function bgIcon(id) {
    const b = findBg(id);
    return b ? b.icon : '🖼️';
  }
  const BG_CLASSES = BACKGROUNDS.map(b => b.cls).concat(['bg-custom']);

  const FX_CONTENT = {
    stars:   () => Array.from({ length: 16 }, (_, i) => `<span class="fx-star" style="left:${(i * 61) % 100}%;top:${(i * 37) % 60}%;animation-delay:${(i % 6) * 0.7}s"></span>`).join(''),
    hearts:  () => Array.from({ length: 10 }, (_, i) => `<span class="fx-hearts" style="left:${(i * 11 + 4) % 96}%;animation-delay:${(i * 1.7).toFixed(1)}s;animation-duration:${(9 + (i % 4) * 2.2).toFixed(1)}s;font-size:${14 + (i % 3) * 8}px">💖</span>`).join(''),
    sakura:  () => Array.from({ length: 12 }, (_, i) => `<span class="fx-sakura" style="left:${(i * 8.5 + 3) % 96}%;animation-delay:${(i * 1.3).toFixed(1)}s;animation-duration:${(8 + (i % 5) * 1.8).toFixed(1)}s;font-size:${13 + (i % 3) * 6}px">🌸</span>`).join(''),
    bubbles: () => Array.from({ length: 14 }, (_, i) => `<span class="fx-bubble" style="left:${(i * 7.3 + 2) % 95}%;animation-delay:${(i * 1.1).toFixed(1)}s;animation-duration:${(7 + (i % 4) * 2).toFixed(1)}s;width:${10 + (i % 4) * 7}px;height:${10 + (i % 4) * 7}px"></span>`).join(''),
    meteor:  () => Array.from({ length: 3 }, (_, i) => `<span class="fx-meteor" style="left:${18 + i * 30}%;animation-delay:${(i * 2.6).toFixed(1)}s"></span>`).join('')
  };

  /** 应用房间背景（支持主题 id 或自定义图片 URL，如 /bg/xxx.jpg） */
  function applyBackground(id) {
    const body = document.body;
    BG_CLASSES.forEach(c => body.classList.remove(c));
    body.style.backgroundImage = '';
    // 清理旧的动态粒子层
    document.querySelectorAll('.bg-fx').forEach(el => el.remove());
    const fxBox = document.createElement('div');
    fxBox.className = 'bg-fx';

    if (id && id.startsWith('/')) {
      // 自定义背景图（上传到服务器的）
      body.classList.add('bg-custom');
      body.style.backgroundImage = `url(${id})`;
    } else {
      const b = findBg(id) || BACKGROUNDS[0];
      body.classList.add(b.cls);
      if (b.fx && FX_CONTENT[b.fx]) fxBox.innerHTML = FX_CONTENT[b.fx]();
    }
    body.appendChild(fxBox);
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
           GENDER, genderIcon, BACKGROUNDS, bgClass, bgIcon, applyBackground, shortNum, haptic, copy, vipBadge };
})();
