import Foundation
import SwiftUI
import UIKit
import ImageIO

/// 通用媒体缓存（头像 / 背景图 / GIF）
///
/// 设计要点：
/// - 目录：Caches/VoiceRoomMedia/，文件名 = URL 的 SHA 摘要 + 原扩展名
/// - **URL 变化才重新下载**：服务端上传新图会生成新文件名（新 URL），
///   因此"同一 URL = 同一内容"，可长期命中；URL 变了自然就是新文件。
/// - 内存缓存 + 磁盘缓存两级，列表滚动不重复解码。
/// - 上限 200MB，超限按最后访问时间 LRU 淘汰（系统空间紧张也可能被回收，符合缓存语义）。
final class MediaCache: NSObject {

    static let shared = MediaCache()

    /// 内存缓存（NSCache 自带内存压力回收）
    private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    private let fm = FileManager.default
    private let ioQueue = DispatchQueue(label: "vr.media.cache.io", qos: .utility)
    private var root: URL!
    private let limitBytes: Int64 = 200 * 1024 * 1024

    /// 正在进行的下载（同一 URL 只下一次）
    private var inflight: [String: [(UIImage?) -> Void]] = [:]
    private let inflightLock = NSLock()

    private override init() {
        super.init()
        setupRoot()
    }

    private func setupRoot() {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("VoiceRoomMedia", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
    }

    // MARK: - 取图

    /// 同步取内存命中（用于 SwiftUI 首帧无闪烁）
    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: key(url) as NSString)
    }

    /// 异步取图：内存 → 磁盘 → 网络
    func image(for url: URL, completion: @escaping (UIImage?) -> Void) {
        let k = key(url)
        let nsKey = k as NSString

        if let img = memory.object(forKey: nsKey) {
            completion(img)
            return
        }

        let disk = diskURL(for: k, ext: url.pathExtension)
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let data = try? Data(contentsOf: disk), let img = Self.decode(data) {
                self.touch(disk)   // 更新 LRU
                self.memory.setObject(img, forKey: nsKey)
                DispatchQueue.main.async { completion(img) }
                return
            }
            // 磁盘没有 → 下载（并发去重）
            self.download(url: url, key: k, completion: completion)
        }
    }

    /// 从原始数据解码图片；GIF 保留全部帧（UIImageView 会自动逐帧播放）
    /// 注意：UIImage(data:) 对 GIF 只取首帧，必须走 ImageIO 才能拿到动图
    static func decode(_ data: Data) -> UIImage? {
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(src) > 1 {
            return UIImage.animatedImage(with: frames(from: src), duration: gifDuration(src))
        }
        return UIImage(data: data)
    }

    private static func frames(from src: CGImageSource) -> [UIImage] {
        let count = CGImageSourceGetCount(src)
        var out: [UIImage] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                out.append(UIImage(cgImage: cg))
            }
        }
        return out
    }

    /// 累加每帧延时（GIF 帧延时为百分之一秒）
    private static func gifDuration(_ src: CGImageSource) -> Double {
        let count = CGImageSourceGetCount(src)
        var total = 0.0
        for i in 0..<count {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any],
                  let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] else { continue }
            let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
            total += delay < 0.02 ? 0.1 : delay
        }
        return total > 0 ? total : Double(count) * 0.1
    }

    private func download(url: URL, key: String, completion: @escaping (UIImage?) -> Void) {
        inflightLock.lock()
        if var waiters = inflight[key] {
            waiters.append(completion)
            inflight[key] = waiters
            inflightLock.unlock()
            return
        }
        inflight[key] = [completion]
        inflightLock.unlock()

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        // URL 即内容指纹 → 可用缓存；但若服务端换了文件，URL 也会变
        req.cachePolicy = .returnCacheDataElseLoad

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            var image: UIImage?
            if let data, let img = Self.decode(data) {
                image = img
                let disk = self.diskURL(for: key, ext: url.pathExtension)
                try? data.write(to: disk, options: .atomic)
            }
            self.inflightLock.lock()
            let waiters = self.inflight[key] ?? []
            self.inflight.removeValue(forKey: key)
            self.inflightLock.unlock()

            if let image { self.memory.setObject(image, forKey: key as NSString) }
            self.enforceLimit()
            DispatchQueue.main.async { waiters.forEach { $0(image) } }
        }.resume()
    }

    // MARK: - 主动预取（进房前把背景下好，切房不闪）

    func prefetch(_ url: URL) {
        if cachedImage(for: url) != nil { return }
        image(for: url) { _ in }
    }

    // MARK: - 路径与键

    /// 用 SHA 摘要做文件名，避免 URL 里的非法字符
    private func key(_ url: URL) -> String {
        var hash = UInt64(1469598103934665603)
        for b in Array(url.absoluteString.utf8) {
            hash ^= UInt64(b)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func diskURL(for key: String, ext: String) -> URL {
        let e = ext.isEmpty ? "img" : ext.lowercased()
        return root.appendingPathComponent("\(key).\(e)")
    }

    private func touch(_ url: URL) {
        ioQueue.async {
            try? self.fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    // MARK: - 容量管理（LRU）

    private func enforceLimit() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let files = try? self.fm.contentsOfDirectory(
                at: self.root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { return }

            var items: [(url: URL, size: Int64, at: Date)] = []
            var total: Int64 = 0
            for f in files {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(v?.fileSize ?? 0)
                total += size
                items.append((f, size, v?.contentModificationDate ?? .distantPast))
            }
            guard total > self.limitBytes else { return }
            let target = Int64(Double(self.limitBytes) * 0.85)
            for it in items.sorted(by: { $0.at < $1.at }) {
                guard total > target else { break }
                try? self.fm.removeItem(at: it.url)
                total -= it.size
            }
        }
    }

    /// 清空全部媒体缓存
    func clearAll() {
        memory.removeAllObjects()
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let files = try? self.fm.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
                for f in files { try? self.fm.removeItem(at: f) }
            }
        }
    }

    /// 当前占用（字节）
    func usedBytes() -> Int64 {
        guard let files = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { acc, f in
            let v = try? f.resourceValues(forKeys: [.fileSizeKey])
            return acc + Int64(v?.fileSize ?? 0)
        }
    }
}

// MARK: - 支持 GIF 动图的异步图片视图

/// 类似 AsyncImage，但：
/// 1) 走 MediaCache 两级缓存（内存 + 磁盘，URL 不变不重复下载）
/// 2) 支持 GIF 动图（AsyncImage 只显示第一帧）
struct CachedAsyncImage<Content: View>: View {

    let url: URL?
    @ViewBuilder var content: (Phase) -> Content

    enum Phase {
        case empty
        case success(UIImage)
        case failure
    }

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                content(.success(image))
            } else if url == nil {
                content(.empty)
            } else {
                content(.empty)
            }
        }
        .onAppear(perform: load)
        .onChange(of: url?.absoluteString) { _ in
            image = nil
            load()
        }
    }

    private func load() {
        guard let url else { return }
        if let hit = MediaCache.shared.cachedImage(for: url) {
            image = hit
            return
        }
        MediaCache.shared.image(for: url) { img in
            image = img
        }
    }
}

// MARK: - GIF 动图视图（背景用）

/// 显示 GIF 动图（逐帧播放）；非 GIF 图退化为静态图
struct GIFImageView: UIViewRepresentable {
    let image: UIImage
    let contentMode: UIView.ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = contentMode
        v.clipsToBounds = true
        return v
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode
        // UIImage 若是动图（多帧），UIImageView 会自动播放
        uiView.image = image
        uiView.startAnimating()
    }
}
