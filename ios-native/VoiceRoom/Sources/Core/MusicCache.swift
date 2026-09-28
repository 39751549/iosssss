import Foundation
import AVFoundation

/// 音频本地缓存（上限默认 5GB，LRU 自动淘汰）
///
/// 设计要点：
/// - 缓存目录：Caches/VoiceRoomMusic/，系统空间紧张时可被 iOS 回收，符合"缓存"语义
/// - 每个条目 = 音频文件 + 同名 `.meta.json`（记录大小与最后访问时间）
/// - 播放在线音频时用 `AVAssetResourceLoaderDelegate` 边下边存，
///   命中缓存时直接读本地文件，省流量且拖动秒开
/// - 总大小超过上限时按"最后访问时间"从旧到新删除，直到降到上限的 90%
final class MusicCache: NSObject, ObservableObject {

    static let shared = MusicCache()

    /// 缓存上限：5GB
    static let limitBytes: Int64 = 5 * 1024 * 1024 * 1024

    @Published private(set) var usedBytes: Int64 = 0
    @Published private(set) var entryCount: Int = 0

    private let fm = FileManager.default
    private let ioQueue = DispatchQueue(label: "vr.music.cache.io", qos: .utility)
    private var root: URL!

    /// 正在下载的任务（key -> 进度），UI 可显示"缓存中"
    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]

    private override init() {
        super.init()
        setupRoot()
        refreshStats()
    }

    // MARK: - 目录

    private func setupRoot() {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("VoiceRoomMusic", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
    }

    private func fileURL(for key: String, ext: String = "mp3") -> URL {
        root.appendingPathComponent("\(safe(key)).\(ext)")
    }

    private func metaURL(for key: String) -> URL {
        root.appendingPathComponent("\(safe(key)).meta.json")
    }

    private func safe(_ key: String) -> String {
        // 只保留字母数字和少数符号，避免路径穿越
        key.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { return ch }
            return "_"
        }.reduce(into: "") { $0.append($1) }
    }

    // MARK: - 命中查询

    /// 如果已缓存，返回本地文件地址
    func cachedFile(for key: String) -> URL? {
        guard let meta = readMeta(key) else { return nil }
        let url = root.appendingPathComponent(meta.file)
        guard fm.fileExists(atPath: url.path) else {
            // 文件被系统清理了，清掉脏 meta
            try? fm.removeItem(at: metaURL(for: key))
            return nil
        }
        touch(key)
        return url
    }

    func isCached(_ key: String) -> Bool {
        cachedFile(for: key) != nil
    }

    func isDownloading(_ key: String) -> Bool {
        downloading.contains(key)
    }

    // MARK: - 写入

    /// 把一个已下载完成的临时文件移到缓存里
    func store(tempFile: URL, key: String, ext: String = "mp3", completion: ((URL?) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let dest = self.fileURL(for: key, ext: ext)
            do {
                try? self.fm.removeItem(at: dest)
                try self.fm.moveItem(at: tempFile, to: dest)
                let attrs = try? self.fm.attributesOfItem(atPath: dest.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                self.writeMeta(CacheMeta(file: dest.lastPathComponent,
                                         size: size,
                                         ext: ext,
                                         at: Date().timeIntervalSince1970))
                self.enforceLimit()
                DispatchQueue.main.async {
                    self.refreshStats()
                    completion?(dest)
                }
            } catch {
                DispatchQueue.main.async { completion?(nil) }
            }
        }
    }

    /// 标记开始/结束下载（供 UI 展示进度）
    func beginDownload(_ key: String) {
        DispatchQueue.main.async {
            self.downloading.insert(key)
            self.progress[key] = 0
        }
    }

    func updateProgress(_ key: String, _ p: Double) {
        DispatchQueue.main.async { self.progress[key] = min(1, max(0, p)) }
    }

    func endDownload(_ key: String) {
        DispatchQueue.main.async {
            self.downloading.remove(key)
            self.progress.removeValue(forKey: key)
        }
    }

    // MARK: - 主动下载（"离线缓存"按钮）

    /// 主动把一首歌缓存到本地
    func download(_ song: VRLibrarySong, base: URL?) {
        let key = song.cacheKey
        guard !isCached(key), !isDownloading(key) else { return }
        guard let url = song.playURL else { return }

        beginDownload(key)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] temp, resp, err in
            guard let self else { return }
            guard let temp, err == nil else {
                self.endDownload(key)
                return
            }
            let ext = self.extFromResponse(resp) ?? "mp3"
            self.store(tempFile: temp, key: key, ext: ext) { _ in
                self.endDownload(key)
            }
        }

        // 进度观察
        let obs = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            self?.updateProgress(key, p.fractionCompleted)
        }
        progressObservers[key] = obs
        task.resume()
    }

    private var progressObservers: [String: NSKeyValueObservation] = [:]

    private func extFromResponse(_ resp: URLResponse?) -> String? {
        guard let mime = resp?.mimeType else { return nil }
        switch mime {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "audio/flac", "audio/x-flac": return "flac"
        default: return nil
        }
    }

    // MARK: - 容量管理

    func refreshStats() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let (total, count) = self.scan()
            DispatchQueue.main.async {
                self.usedBytes = total
                self.entryCount = count
            }
        }
    }

    private func scan() -> (Int64, Int) {
        var total: Int64 = 0
        var count = 0
        guard let files = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }
        for f in files where f.pathExtension == "json" {
            if let meta = readMeta(file: f) { total += meta.size; count += 1 }
        }
        return (total, count)
    }

    /// 超过上限就按 LRU 淘汰（保留 90%）
    private func enforceLimit() {
        var (total, _) = scan()
        guard total > Self.limitBytes else { return }

        let target = Int64(Double(Self.limitBytes) * 0.9)
        let entries = allMetas().sorted { $0.meta.at < $1.meta.at }   // 最旧的在前

        for e in entries {
            guard total > target else { break }
            let fileURL = root.appendingPathComponent(e.meta.file)
            try? fm.removeItem(at: fileURL)
            try? fm.removeItem(at: e.url)
            total -= e.meta.size
        }
    }

    /// 手动清空全部缓存
    func clearAll() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let files = try? self.fm.contentsOfDirectory(at: self.root,
                                                            includingPropertiesForKeys: nil) {
                for f in files { try? self.fm.removeItem(at: f) }
            }
            try? self.fm.createDirectory(at: self.root, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                self.usedBytes = 0
                self.entryCount = 0
                self.downloading.removeAll()
                self.progress.removeAll()
            }
        }
    }

    /// 删除单条缓存
    func remove(key: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let meta = self.readMeta(key) {
                try? self.fm.removeItem(at: self.root.appendingPathComponent(meta.file))
            }
            try? self.fm.removeItem(at: self.metaURL(for: key))
            self.enforceLimit()
            DispatchQueue.main.async { self.refreshStats() }
        }
    }

    // MARK: - 用量展示

    var usedText: String {
        ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
    }

    var limitText: String {
        ByteCountFormatter.string(fromByteCount: Self.limitBytes, countStyle: .file)
    }

    var usedFraction: Double {
        guard Self.limitBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(Self.limitBytes))
    }

    // MARK: - meta 读写

    private struct CacheMeta: Codable {
        var file: String
        var size: Int64
        var ext: String
        var at: Double          // 最后访问时间
    }

    private func writeMeta(_ m: CacheMeta) {
        guard let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: metaURL(for: keyFromFile(m.file)), options: .atomic)
    }

    /// 文件名去掉扩展名就是 key
    private func keyFromFile(_ file: String) -> String {
        (file as NSString).deletingPathExtension
    }

    private func readMeta(_ key: String) -> CacheMeta? {
        readMeta(file: metaURL(for: key))
    }

    private func readMeta(file: URL) -> CacheMeta? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(CacheMeta.self, from: data)
    }

    private func allMetas() -> [(meta: CacheMeta, url: URL)] {
        guard let files = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { u in
            guard let m = readMeta(file: u) else { return nil }
            return (m, u)
        }
    }

    /// 更新最后访问时间，保证 LRU 正确
    private func touch(_ key: String) {
        ioQueue.async { [weak self] in
            guard let self, var m = self.readMeta(key) else { return }
            m.at = Date().timeIntervalSince1970
            self.writeMeta(m)
        }
    }
}
