import Foundation
import AVFoundation
import Combine
import UIKit
import QuartzCore

/// 房间同步音乐播放器
///
/// 同步原理：
/// 服务端广播 currentSong + startedAt（播放起点时间戳），
/// 各客户端用 (now - startedAt) 计算应播放到的进度，
/// 偏差超过阈值就 seek 校正，实现"多人同时听同一首歌"。
///
/// 缓存：
/// 播放前先查 MusicCache，命中则直接用本地文件（省流量、拖动秒开）；
/// 未命中时边下边播，播完自动落盘（上限 5G，LRU 淘汰）。
final class MusicPlayer: NSObject, ObservableObject {

    static let shared = MusicPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var currentId: String = ""
    @Published private(set) var isLoading = false
    /// 当前播放进度（秒）
    @Published var position: Double = 0
    /// 当前歌曲总时长（秒），未知为 0
    @Published var duration: Double = 0
    /// 播放音量 0...1（默认 0.7，用户可调；改了会持久化，重启 App 保留）
    @Published var volume: Float = 0.7 {
        didSet {
            player?.volume = volume
            UserDefaults.standard.set(volume, forKey: MusicPlayer.volumeKey)
        }
    }

    private static let volumeKey = "vr_music_volume"

    /// 播放结束回调（AppState 上报服务端推进歌单）
    var onPlaybackEnded: (() -> Void)?
    /// 播放失败回调（直链过期时请求服务端重解析）
    var onPlaybackFailed: (() -> Void)?
    /// 已因失败请求过重解析的 URL —— 同一个 URL 只请求一次，避免异常时无限循环
    private var reloadRequestedFor: Set<String> = []

    private var player: AVPlayer?
    /// 当前正在播放的歌曲标识（用 songId，比 url 稳定：直链会刷新但歌不变）
    private var currentSongKey: String = ""
    private var currentUrl: String = ""
    private var muted = false
    private var timeObserver: Any?

    /// 当前这首已经播到结尾。
    /// AVPlayer 播到末尾后 rate 变 0 且 currentTime 停在结尾，
    /// 此时直接 play() 不会从头再来 —— 必须先 seek 回起点。
    /// 单曲循环 / 只有一首歌的列表循环都依赖这个标记，否则会「播完就哑了」。
    private var reachedEnd = false

    /// 当前 AVPlayerItem 已失败（多为直链过期）。
    /// 失败后即使服务端下发的 URL 没变，也必须重新 attach 新 item，
    /// 因为坏掉的 item 再 play() 也不会恢复。
    private var needsReload = false

    /// 期望的播放/暂停状态（由最近的房间快照决定）。
    /// attach 时 item 可能还没 ready，先把意图记下，ready 后再起播。
    private var wantPlaying = false

    // MARK: 进度锚点（修复「切后台回来跳回旧时间点」）
    //
    // 快照里的 state.now 只代表**快照生成那一刻**的进度。回前台时 RoomView 会拿
    // 缓存快照再 sync 一次 —— 若直接拿旧 now 算 elapsed，会得出一个落后于实际的
    // 「应播进度」，drift>2s 的校正就把播放器 seek 回了旧时间点。
    //
    // 方案：快照到达时记录 (elapsed, 单调钟)，之后用单调钟插值得出「此刻应播进度」，
    // 与快照是否陈旧彻底解耦。**只有严格更新的快照才允许重设锚点**，
    // 同一份旧快照反复 sync 只会复用现有锚点，不会再把进度往回拨。
    private var anchorElapsed: Double = 0
    private var anchorAt: CFTimeInterval = 0
    private var anchorNowMs: Double = 0
    /// 最近一次 sync 的输入，供中断结束/回前台时重放
    private var lastState: VRRoomState?
    private var lastSpeakerOn = true

    /// 此刻应该播到的进度 = 锚点 + 单调钟插值
    private func expectedElapsed() -> Double {
        guard anchorAt > 0 else { return 0 }
        return max(0, anchorElapsed + CACurrentMediaTime() - anchorAt)
    }

    /// 播放到本地缓存后的通知（用于 UI 刷新"已缓存"徽标）
    private var observers = Set<AnyCancellable>()
    private var progressObservers: [String: NSKeyValueObservation] = [:]

    private override init() {
        super.init()
        // 恢复用户上次调好的音量
        if let saved = UserDefaults.standard.object(forKey: MusicPlayer.volumeKey) as? Float {
            volume = saved
        }
        configureSession()
        observeInterruptions()
    }

    private func configureSession() {
        // 音乐播放允许与其他音频共存（比如语音房的语音）
        //
        // ⚠️ 若 WebRTC 语音已在跑（会话已是 playAndRecord），**绝不能**再把
        // category 切回 .playback —— WebRTC 音频单元运行中改 category 会直接
        // 闪退（房里有人 + 晚创建本单例时的隐形炸弹）。playAndRecord 档下
        // AVPlayer 照常能播，这里直接短路。
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else { return }
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
        } catch {
            print("[Music] 音频会话配置失败: \(error.localizedDescription)")
        }
    }

    /// 监听系统中断（来电等）、路由变化与前后台切换，避免回前台后状态错乱
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        // 回前台自己恢复：不依赖视图层（RoomView 可能还没挂载），也绝不在这里 seek
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            // 别的 App 抢占音频（开视频/放歌）：AVPlayer 已被系统暂停，同步一下 UI
            isPlaying = false
            return
        }
        // 中断结束：系统说 shouldResume 才自动续播（用户主动去放别的 App 时不抢）。
        // 之前只在回调里把 isPlaying 置 false、从不清醒会话，
        // AVPlayer.play() 面对一个被中断挂起的会话是唤不醒的 —— 这就是
        // 「切去别的软件再回来音乐停着不动」的根因。
        guard type == .ended else { return }
        let optRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
        guard opts.contains(.shouldResume) else { return }
        // 稍等系统收尾，再重新激活会话并接着播；进度交给下一次 sync 校准
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.recoverAfterForeground()
        }
    }

    @objc private func appBecameActive() {
        recoverAfterForeground()
    }

    /// 切后台回来 / 中断恢复：重新激活音频会话并接着播。
    ///
    /// 铁律：**这里绝不 seek**。本地缓存快照的 now 是旧的，拿它校正是
    /// 「回跳到某个时间点」的根源。真正的进度对齐交给 AppState 回前台
    /// requestRoomSync() 拉到的新鲜快照，由 sync() 的锚点机制静默完成。
    func recoverAfterForeground() {
        guard player != nil, !currentSongKey.isEmpty else { return }
        // 说话模式（playAndRecord）下会话本来就是活的，重复激活无害；
        // 只听模式下被系统挂起后必须重新 setActive，否则 play() 不出声
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { /* 忽略 */ }
        if wantPlaying, player?.rate == 0, !isLoading {
            player?.play()
            isPlaying = true
        }
    }

    /// 切换 player 时重建进度观察（player 是懒创建的，attach 时挂到具体 player 上）
    private func bindTimeObserver(_ p: AVPlayer) {
        if let old = timeObserver { oldPlayer?.removeTimeObserver(old); timeObserver = nil }
        let interval = CMTime(seconds: 0.4, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            let sec = CMTimeGetSeconds(t)
            if sec.isFinite, sec >= 0 { self.position = sec }
            if self.duration <= 0,
               let item = p.currentItem,
               item.status == .readyToPlay {
                let d = CMTimeGetSeconds(item.duration)
                if d.isFinite, d > 0 { self.duration = d }
            }
        }
        oldPlayer = p
    }
    private weak var oldPlayer: AVPlayer?

    private func removeTimeObserver() {
        if let ob = timeObserver, let p = oldPlayer { p.removeTimeObserver(ob) }
        timeObserver = nil
        oldPlayer = nil
    }

    // MARK: - 同步入口

    /// 与房间状态对齐。
    ///
    /// 关键：**同一首歌不重新加载**（修复"切后台回来重播"的 bug）。
    /// 只有歌真的换了（songId/url 变化）才重新 attach；否则只做进度校正。
    func sync(with state: VRRoomState, speakerOn: Bool) {
        guard let song = state.currentSong else {
            if !currentSongKey.isEmpty { stop() }
            return
        }

        // 切歌判断：优先比 songId（稳定），其次比 url
        let newKey = song.id.isEmpty ? song.url : song.id
        let songChanged = (newKey != currentSongKey)
        // 同一首歌但直链刷新了（服务端 reload 重解析后下发的全新 URL）也要重新加载，
        // 否则会一直拿着过期直链放不出来 —— 这是"重进房间音乐不放"的根因。
        let urlChanged = !song.url.isEmpty && song.url != currentUrl
        // 上一次播放失败（直链过期）也要重新 attach：坏掉的 item 唤不醒
        let changed = songChanged || urlChanged || needsReload

        // 记下本轮的播放意图（speaker 关掉是「静音」，不是「暂停」——这样再打开能接着听）
        wantPlaying = state.playing
        // 扬声器开关以房间状态为准（避免重启/重连后静音态与 UI 不一致）
        muted = !speakerOn
        player?.isMuted = muted
        // 留一份最近快照，中断结束/回前台时重放 sync 用
        lastState = state
        lastSpeakerOn = speakerOn

        if changed {
            needsReload = false
            currentSongKey = newKey
            currentUrl = song.url
            currentTitle = song.title
            currentId = song.id
            if songChanged {
                position = 0
                duration = 0
            }
            load(urlString: song.url, autoPlay: state.playing)
            if songChanged { recordHistory(song) }
        }

        guard let player else { return }

        if state.playing {
            if !changed {
                // 同一首歌：只做进度校准，绝不重新加载。
                // 应播进度用「锚点 + 单调钟插值」，而不是快照里的旧 now ——
                // 旧快照重复 sync（回前台场景）不会把锚点拨回过去，也就不会回跳。
                let elapsed = state.startedAt > 0 ? (state.now - state.startedAt) / 1000.0 : 0
                if state.now > anchorNowMs {
                    anchorNowMs = state.now
                    anchorElapsed = elapsed
                    anchorAt = CACurrentMediaTime()
                }
                let expected = expectedElapsed()
                let current = CMTimeGetSeconds(player.currentTime())
                if reachedEnd {
                    // 播完又要求播放（单曲循环 / 单曲歌单循环）：
                    // AVPlayer 停在末尾，必须显式回到起点（或服务端给的进度）才能重新出声
                    let target = CMTime(seconds: max(0, expected), preferredTimescale: 600)
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    reachedEnd = false
                } else {
                    let drift = abs(current - expected)
                    // 误差超过 2 秒且已过 3 秒缓冲才校正，避免频繁 seek 造成卡顿
                    if expected > 3, current.isFinite, drift > 2 {
                        let target = CMTime(seconds: max(0, expected), preferredTimescale: 600)
                        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            } else {
                // 换了新歌/新直链：锚点跟着重置（elapsed 已按新歌计算，接近 0）
                anchorNowMs = state.now
                anchorElapsed = state.startedAt > 0 ? (state.now - state.startedAt) / 1000.0 : 0
                anchorAt = CACurrentMediaTime()
            }
            if player.rate == 0, !isLoading {
                player.play()
                isPlaying = true
            }
        } else {
            if player.rate != 0 {
                player.pause()
                isPlaying = false
            }
        }
    }

    // MARK: - 载入

    private func load(urlString: String, autoPlay: Bool) {
        isLoading = true
        wantPlaying = autoPlay

        // 1) 命中缓存 → 直接播本地文件
        if let key = cacheKey(for: urlString), let local = MusicCache.shared.cachedFile(for: key) {
            attach(playerItem: AVPlayerItem(url: local))
            isLoading = false
            if autoPlay { playIfPossible() }
            return
        }

        // 2) 没命中 → 用远端地址播，同时后台下好存缓存
        guard let remote = resolve(urlString) else {
            isLoading = false
            return
        }
        attach(playerItem: AVPlayerItem(url: remote))

        if let key = cacheKey(for: urlString), !MusicCache.shared.isCached(key) {
            backgroundCache(key: key, remote: remote)
        }
    }

    /// 若本轮的意图是「播放」，就把 player 起播（ready 前调用也安全，AVPlayer 会等缓冲）
    private func playIfPossible() {
        guard wantPlaying, let player else { return }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        }
    }

    private func attach(playerItem: AVPlayerItem) {
        player?.pause()
        // 清掉上一首的状态订阅，避免切歌多次后累积
        observers.removeAll()
        removeTimeObserver()
        player = nil
        reachedEnd = false

        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = true
        p.isMuted = muted
        p.volume = volume

        // 缓冲/失败状态观察
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in
                guard let self else { return }
                switch st {
                case .readyToPlay:
                    self.isLoading = false
                    let d = CMTimeGetSeconds(playerItem.duration)
                    if d.isFinite, d > 0 { self.duration = d }
                    // item ready 之前调用 play() 会被 AVPlayer 排队，这里再补一次更稳
                    self.playIfPossible()
                case .failed:
                    self.isLoading = false
                    self.isPlaying = false
                    self.wantPlaying = false
                    // 标记需要重新 attach：即使服务端下发的 URL 没变，
                    // 已经 failed 的 item 也唤不醒，必须换一个新 item
                    self.needsReload = true
                    // 直链可能已过期 → 请服务端重解析（同一 URL 只请求一次，防死循环）
                    let failedUrl = playerItem.asset.description
                    if !self.reloadRequestedFor.contains(failedUrl) {
                        self.reloadRequestedFor.insert(failedUrl)
                        if self.reloadRequestedFor.count > 20 { self.reloadRequestedFor.removeAll() }
                        self.onPlaybackFailed?()
                    }
                default: break
                }
            }
            .store(in: &observers)

        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        player = p
        bindTimeObserver(p)
        // 注意：这里不再无条件 play()。
        // 由 sync 根据房间状态（state.playing）决定是否起播，
        // 避免「房间是暂停状态，进房却先响一声再被暂停」。
    }

    @objc private func itemDidFinish() {
        isPlaying = false
        position = duration
        // 标记已播到结尾：同一首歌再次要求播放时需要先 seek 回起点
        reachedEnd = true
        // 上报服务端按播放模式推进（列表循环 / 单曲循环 / 播完结束）
        onPlaybackEnded?()
    }

    /// 把相对路径补成绝对地址
    private func resolve(_ s: String) -> URL? {
        if s.hasPrefix("http") { return URL(string: s) }
        guard let base = VRConfig.baseURL else { return nil }
        return URL(string: s, relativeTo: base)
    }

    /// 从 /api/music/file/xxx 取出缓存 key
    private func cacheKey(for urlString: String) -> String? {
        guard let range = urlString.range(of: "/api/music/file/") else { return nil }
        let id = String(urlString[range.upperBound...])
        return id.isEmpty ? nil : "lib_\(id)"
    }

    /// 后台把整首歌拉到本地缓存
    private func backgroundCache(key: String, remote: URL) {
        guard !MusicCache.shared.isDownloading(key) else { return }
        MusicCache.shared.beginDownload(key)

        // 下载结束（成功或失败）都要摘掉进度观察，否则会随切歌不断累积
        let cleanup: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.progressObservers.removeValue(forKey: key)
                MusicCache.shared.endDownload(key)
            }
        }

        let task = URLSession.shared.downloadTask(with: remote) { temp, resp, err in
            guard let temp, err == nil else {
                cleanup()
                return
            }
            let ext: String
            switch resp?.mimeType {
            case "audio/mp4", "audio/m4a", "audio/x-m4a": ext = "m4a"
            case "audio/wav", "audio/x-wav": ext = "wav"
            case "audio/aac": ext = "aac"
            case "audio/ogg": ext = "ogg"
            case "audio/flac", "audio/x-flac": ext = "flac"
            default: ext = "mp3"
            }
            MusicCache.shared.store(tempFile: temp, key: key, ext: ext) { _ in
                cleanup()
            }
        }

        let obs = task.progress.observe(\.fractionCompleted) { p, _ in
            MusicCache.shared.updateProgress(key, p.fractionCompleted)
        }
        progressObservers[key] = obs
        task.resume()
    }

    // MARK: - 最近听歌

    private func recordHistory(_ song: VRSong) {
        // 只记录能定位到具体歌曲的（曲库或外链 http）
        let source: VRMusicRecord.Source =
            song.url.contains("/api/music/file/") ? .library : .remote
        guard song.url.hasPrefix("http") || source == .library else { return }

        let absolute: String
        if let u = resolve(song.url) { absolute = u.absoluteString } else { return }

        // 去重键必须稳定：服务端每次播放都会生成新的 song.id(uid('s'))，
        // 直接用会导致同一首歌重复出现多行。这里优先用曲库 id / 稳定 URL。
        let stableId = stableHistoryId(song: song, absoluteURL: absolute)

        MusicHistory.shared.recordPlay(
            songId: stableId, title: song.title, artist: song.artist ?? "",
            url: absolute, source: source
        )
    }

    /// 生成稳定的历史记录去重键
    private func stableHistoryId(song: VRSong, absoluteURL: String) -> String {
        // 1) 曲库文件地址：/api/music/file/<libId> → 用 libId
        if let r = absoluteURL.range(of: "/api/music/file/") {
            let libId = String(absoluteURL[r.upperBound...])
            if !libId.isEmpty { return "lib_\(libId)" }
        }
        // 2) 在线曲库：用 libraryId（gd|源|歌id）比 URL 稳定
        if let lid = song.libraryId, !lid.isEmpty { return "gd_\(lid)" }
        // 3) 兜底：用去掉 query 的 URL（很多外链带时效参数）
        let base = absoluteURL.split(separator: "?").first.map(String.init) ?? absoluteURL
        return "url_\(base)"
    }

    // MARK: - 控制

    func setMuted(_ m: Bool) {
        muted = m
        player?.isMuted = m
    }

    func setVolume(_ v: Float) {
        volume = min(1, max(0, v))
    }

    /// 悬浮音乐控件用：本地暂停 / 继续（全房状态以下一次房间快照校准）
    func togglePlayPause() {
        guard let player else { return }
        if player.rate == 0 {
            // 已播到结尾时先回到起点，否则 play() 不会出声
            if reachedEnd {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                reachedEnd = false
            }
            player.play()
            isPlaying = true
            wantPlaying = true
        } else {
            player.pause()
            isPlaying = false
            wantPlaying = false
        }
    }

    func stop() {
        player?.pause()
        removeTimeObserver()
        player = nil
        currentSongKey = ""
        currentUrl = ""
        currentTitle = ""
        currentId = ""
        position = 0
        duration = 0
        isPlaying = false
        isLoading = false
        reachedEnd = false
        needsReload = false
        wantPlaying = false
        anchorElapsed = 0
        anchorAt = 0
        anchorNowMs = 0
        lastState = nil
        lastSpeakerOn = true
        observers.removeAll()
        progressObservers.removeAll()
        reloadRequestedFor.removeAll()
    }

    /// 进度文本 mm:ss
    var positionText: String { Self.timeText(position) }
    var durationText: String { duration > 0 ? Self.timeText(duration) : "--:--" }
    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    static func timeText(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "00:00" }
        let s = Int(sec)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    deinit {
        removeTimeObserver()
        NotificationCenter.default.removeObserver(self)
    }
}
