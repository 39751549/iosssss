/**
 * 无头 iOS 客户端 —— 按 VRConnection.swift + AppState.swift 的真实时序复刻。
 *
 * 为什么要它：iOS 侧改一次就要走 CI 打 IPA、重装，一轮十几分钟。
 * 而绝大多数 bug（登录态、顶号、进房、音乐同步、背景）本质是**协议时序**问题，
 * 用这个模拟器几秒就能在本地服务器上复现/验证，确认没问题了再打一次包。
 *
 * 与真实客户端一一对应的行为：
 *   connect()      → 建 WS，等服务端首帧 hello / ping 往返后标记 connected
 *   silentAuth()   → 链路就绪后自动用保存的凭据登录（带持久化 deviceId）
 *   background()   → 模拟切后台：系统静默掐掉连接（客户端还不知情）
 *   foreground()   → 模拟回前台：拆掉旧连接重建 + 重连后自动回房
 *                    （旧连接不主动关，正是当初"假顶号"的复现条件）
 */
const WebSocket = require('ws');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

class IOSClient {
  /**
   * @param {object} opt
   * @param {string} opt.host      形如 127.0.0.1:8126
   * @param {string} [opt.deviceId] 设备标识；同一台设备重连必须一致
   * @param {string} [opt.label]    日志名
   */
  constructor(opt = {}) {
    this.host = opt.host || '127.0.0.1:8126';
    this.deviceId = opt.deviceId || null;
    this.label = opt.label || 'client';
    this.username = opt.username || null;
    this.password = opt.password || 'pw123456';

    this.ws = null;
    this.connected = false;
    this.loggedIn = false;
    this.userId = null;
    this.roomId = null;         // 当前所在房间
    this.lastRoomId = null;     // 最近所在房间（重连后自动回房用）
    this.savedUsername = null;  // 落盘的凭据
    this.savedPassword = null;

    this.received = [];         // 收到的全部帧 {type, data}
    this.kicked = false;        // 是否收到 room:kicked
    this.kickReason = null;
    this.errors = [];
    this.roomState = null;
    this.toasts = [];
    this._gen = 0;              // 连接代数：用来识别过期连接（对应 Swift 里的 task 身份校验）
  }

  // ---------- 连接 ----------

  connect() {
    this._gen += 1;
    const gen = this._gen;
    const ws = new WebSocket('ws://' + this.host);
    this.ws = ws;

    ws.on('message', (raw) => {
      // 对应 receiveLoop 的 `guard self.task === t`：过期连接的帧一律丢弃
      if (gen !== this._gen) {
        this.received.push({ type: '(stale-dropped)', gen });
        return;
      }
      let j;
      try { j = JSON.parse(raw.toString()); } catch { return; }
      this._handle(j);
    });
    ws.on('close', () => { if (gen === this._gen) this.connected = false; });
    ws.on('error', () => {});

    return new Promise((resolve) => {
      const done = () => { this.connected = true; resolve(); };
      ws.on('open', () => {
        // 服务端建连就发 hello；等价于客户端的"首帧即视为连通 + ping 探测"兜底
        const t = setTimeout(done, 800);
        ws.once('message', () => { clearTimeout(t); done(); });
      });
    });
  }

  _handle(j) {
    this.received.push(j);
    switch (j.type) {
      case 'hello':
        break;
      case 'auth:ok':
        this.loggedIn = true;
        this.userId = j.data.userId;
        if (this.username) { this.savedUsername = this.username; this.savedPassword = this.password; }
        break;
      case 'room:kicked':
        this.kicked = true;
        this.kickReason = (j.data && j.data.reason) || '';
        // 与 AppState 一致：停会话、清登录态
        this.loggedIn = false;
        this.toasts.push(this.kickReason);
        break;
      case 'room:state':
        this.roomState = j.data;
        break;
      case 'join:ok':
        this.roomId = j.data.roomId;
        this.lastRoomId = j.data.roomId;
        break;
      case 'room:created':
        this.createdRoomId = j.data.id;
        break;
      case 'error':
        this.errors.push(j.msg);
        break;
      default:
        break;
    }
  }

  /** 对应 AppState 的 status 回调：链路就绪 → 静默登录 */
  async silentAuth() {
    const u = this.username || this.savedUsername;
    const p = this.password || this.savedPassword;
    if (!u || !p) return;
    this.send({ type: 'auth', username: u, password: p, deviceId: this.deviceId });
    await wait(600);
  }

  send(obj) {
    if (!this.ws || this.ws.readyState !== 1) return false;
    this.ws.send(JSON.stringify(obj));
    return true;
  }

  /** 注册并登录一个新账号 */
  async signup(username) {
    this.username = username;
    this.savedUsername = username;
    this.savedPassword = this.password;
    await this.silentAuth();
    return this.loggedIn;
  }

  // ---------- 房间 ----------

  async createRoom(name = '测试房') {
    this.send({ type: 'room:create', userId: this.userId, name, background: 'aurora' });
    await wait(800);
    return this.createdRoomId;
  }

  async joinRoom(roomId) {
    this.send({ type: 'room:join', userId: this.userId, roomId });
    await wait(800);
    return this.roomId;
  }

  // ---------- 前后台切换（复现"切后台再回来"） ----------

  /**
   * 切后台：进程被挂起，客户端收不到任何回调，socket 在客户端看来还"活着"，
   * 但服务端那边的旧连接仍然注册着 —— 这就是假顶号的温床。
   */
  background() {
    if (this.ws) { try { this.ws.pause(); } catch (_) {} }
    return this;
  }

  /**
   * 回前台：真实客户端会走 connect()（先 teardownCurrent 拆旧连接）
   * 然后自动静默登录 + 回到原房间。
   * @param {boolean} keepOldSocket 是否模拟旧版"不拆旧连接"的行为（用于复现 bug）
   */
  async foreground(opts = {}) {
    const keepOld = opts.keepOldSocket === true;
    const old = this.ws;
    if (!keepOld && old) {
      // 新版行为：connect() 开头 teardownCurrent()，旧连接确实被 cancel
      try { old.terminate(); } catch (_) {}
    }
    // 旧连接如果没被拆掉，它的消息回调依然挂着 —— 这正是 bug 的关键
    const stale = keepOld ? old : null;

    await this.connect();
    await this.silentAuth();
    if (this.lastRoomId) await this.joinRoom(this.lastRoomId);

    // 旧连接迟到的顶号提示（只有 keepOld 时才会出现，模拟修复前的现象）
    if (stale) {
      const got = [];
      stale.on('message', (r) => { try { got.push(JSON.parse(r.toString()).type); } catch (_) {} });
      // 进程回到前台，旧连接又开始投递积压的消息（修复前的客户端就是这样把
      // 服务端发给旧连接的 room:kicked 当成自己的消息弹出来的）
      try { stale.resume(); } catch (_) {}
      await wait(1200);
      this.staleFrames = got;
      const hit = got.includes('room:kicked');
      if (hit) { this.kicked = true; this.kickReason = '（来自未拆除的旧连接）'; }
    }
    return this;
  }

  // ---------- 音乐 ----------

  addLibrarySong(libraryId, by) {
    this.send({ type: 'music:add', libraryId, by, title: '', artist: '', url: '' });
  }
  musicControl(action, songId, mode) {
    this.send({ type: 'music:control', action, songId: songId ?? null, mode: mode ?? null });
  }

  // ---------- 观测 ----------

  types() { return this.received.map((m) => m.type); }
  sawType(t) { return this.received.some((m) => m.type === t); }

  close() { try { this.ws && this.ws.close(); } catch (_) {} }
  destroy() { try { this.ws && this.ws.terminate(); } catch (_) {} }
}

module.exports = { IOSClient, wait };
