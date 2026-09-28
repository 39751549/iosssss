import Foundation
import AVFoundation
import Combine

/// 房间同步音乐播放器
///
/// 同步原理：
/// 服务端广播 currentSong + startedAt（播放起点时间戳），
/// 各客户端用 (now - startedAt) 计算应播放到的进度，
/// 偏差超过 3 秒就 seek 校正，实现"多人同时听同一首歌"。
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

    private var player: AVPlayer?
    private var currentUrl: String = ""
    private var muted = false

    /// 播放到本地缓存后的通知（用于 UI 刷新"已缓存"徽标）
    private var cacheFlipKey: String?

    private override init() {
        super.init()
        configureSession()
    }

    private func configureSession() {
        // 音乐播放允许与其他音频共存（比如语音房的语音）
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
        } catch {
            print("[Music] 音频会话配置失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 同步入口

    func sync(with state: VRRoomState, speakerOn: Bool) {
        guard let song = state.currentSong else {
            stop()
            return
        }

        // 切歌
        if currentUrl != song.url {
            currentUrl = song.url
            currentTitle = song.title
            currentId = song.id
            load(urlString: song.url)
            // 记录到最近听歌
            recordHistory(song)
        }

        guard let player else { return }

        if state.playing {
            // 计算目标进度，实现多人同步
            let elapsed = state.startedAt > 0 ? (state.now - state.startedAt) / 1000.0 : 0
            let current = CMTimeGetSeconds(player.currentTime())
            if current.isFinite, abs(current - elapsed) > 3 {
                let target = CMTime(seconds: max(0, elapsed), preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if player.rate == 0, speakerOn, !isLoading {
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

    private func load(urlString: String) {
        isLoading = true

        // 1) 命中缓存 → 直接播本地文件
        if let key = cacheKey(for: urlString), let local = MusicCache.shared.cachedFile(for: key) {
            attach(playerItem: AVPlayerItem(url: local))
            isLoading = false
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

    private func attach(playerItem: AVPlayerItem) {
        player?.pause()
        // 清掉上一首的状态订阅，避免切歌多次后累积
        observers.removeAll()
        player = nil

        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = true
        p.isMuted = muted

        // 缓冲/失败状态观察
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in
                switch st {
                case .readyToPlay: self?.isLoading = false
                case .failed:      self?.isLoading = false
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
        p.play()
        isPlaying = true
    }

    private var observers = Set<AnyCancellable>()

    @objc private func itemDidFinish() {
        isPlaying = false
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

        let task = URLSession.shared.downloadTask(with: remote) { temp, resp, err in
            guard let temp, err == nil else {
                MusicCache.shared.endDownload(key)
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
                MusicCache.shared.endDownload(key)
            }
        }

        let obs = task.progress.observe(\.fractionCompleted) { p, _ in
            MusicCache.shared.updateProgress(key, p.fractionCompleted)
        }
        progressObservers[key] = obs
        task.resume()
    }

    private var progressObservers: [String: NSKeyValueObservation] = [:]

    // MARK: - 最近听歌

    private func recordHistory(_ song: VRSong) {
        // 只记录能定位到具体歌曲的（曲库或外链 http）
        let source: VRMusicRecord.Source =
            song.url.contains("/api/music/file/") ? .library : .remote
        guard song.url.hasPrefix("http") || source == .library else { return }

        let absolute: String
        if let u = resolve(song.url) { absolute = u.absoluteString } else { return }

        MusicHistory.shared.recordPlay(
            songId: song.id, title: song.title, artist: "",
            url: absolute, source: source
        )
    }

    // MARK: - 控制

    func setMuted(_ m: Bool) {
        muted = m
        player?.isMuted = m
    }

    /// 悬浮音乐控件用：本地暂停 / 继续（全房状态以下一次房间快照校准）
    func togglePlayPause() {
        guard let player else { return }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func stop() {
        player?.pause()
        player = nil
        currentUrl = ""
        currentTitle = ""
        currentId = ""
        isPlaying = false
        isLoading = false
        observers.removeAll()
    }
}
