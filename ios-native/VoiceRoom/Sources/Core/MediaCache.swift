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
    /// 取图专用队列：必须用 .userInitiated。
    /// 之前是 .utility，系统会把任务压到最低优先级 —— 进房那一刻正忙着渲染，
    /// 磁盘读迟迟排不上队，背景图要等好几秒才出来，这期间用户看到的是兜底渐变，
    /// 体感就是"背景变回默认了 / 要等好久才生效"。
    private let ioQueue = DispatchQueue(label: "vr.media.cache.io", qos: .userInitiated)
    /// 维护队列（LRU 时间戳、超限清理）与取图分离，
    /// 否则一次全目录扫描会把后面的读图请求全堵住。
    private let maintenanceQueue = DispatchQueue(label: "vr.media.cache.maint", qos: .background)
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

    /// 用 64 位 FNV-1a 摘要做文件名，避免 URL 里的非法字符
    /// （非加密哈希，但对「图片 URL → 文件名」足够；碰撞概率可忽略）
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
        maintenanceQueue.async {
            try? self.fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    // MARK: - 容量管理（LRU）

    private func enforceLimit() {
        maintenanceQueue.async { [weak self] in
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
struct CachedAsyncImage: View {

    /// Phase 必须放在「非泛型」结构体里。
    /// 若 CachedAsyncImage 带 <Content> 泛型，闭包参数 phase 的类型 Phase 就嵌套在泛型类型内部，
    /// 而 Content 又需要从闭包体反推 → 形成循环依赖，编译直接报
    /// "generic parameter 'Content' could not be inferred"。
    /// 这里把内容闭包统一擦除成 AnyView，结构体本身不再泛型，彻底规避该问题。
    enum Phase {
        case empty
        case success(UIImage)
        case failure
    }

    let url: URL?
    private let content: (Phase) -> AnyView

    /// 泛型只落在初始化器上（仅在调用点做局部推断）
    init<C: View>(url: URL?, @ViewBuilder content: @escaping (Phase) -> C) {
        self.url = url
        self.content = { AnyView(content($0)) }
    }

    @State private var image: UIImage?
    /// 当前正在加载的 URL。放在 @State 里（引用盒）才能被回调读到"最新值"，
    /// 否则闭包捕获的是结构体快照，判不出回调是否已经过期。
    @State private var loadingKey: String?

    var body: some View {
        ZStack {
            // 零尺寸的实体子视图。若这里只有 EmptyView，
            // 就没有任何"可出现的视图"，onAppear 不会触发，图片永远加载不出来。
            Color.clear.frame(width: 0, height: 0)

            if let image {
                content(.success(image))
            } else {
                content(.empty)
            }
        }
        .onAppear(perform: load)
        .onChange(of: url?.absoluteString) { _ in
            // 故意不清空 image：换背景 URL 时让旧图继续顶着，直到新图就位，
            // 否则中间会闪一下兜底渐变（用户看到的就是"背景变回默认了"）。
            load()
        }
    }

    private func load() {
        guard let url else {
            image = nil
            loadingKey = nil
            return
        }
        let key = url.absoluteString
        loadingKey = key
        if let hit = MediaCache.shared.cachedImage(for: url) {
            image = hit
            return
        }
        MediaCache.shared.image(for: url) { img in
            // 迟到的旧 URL 结果不要覆盖当前 URL 的图
            guard loadingKey == key else { return }
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
        // 让 UIImageView 不再坚持"我就要图片原始尺寸"，
        // iOS 15 上没有 sizeThatFits 时也能被父级拉伸铺满
        uiView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        uiView.setContentHuggingPriority(.defaultLow, for: .vertical)
        uiView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        uiView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    /// 必须显式声明尺寸：UIImageView 的固有尺寸就是图片的像素尺寸，
    /// 不声明的话背景会被按原图大小布局（小图不铺满、大图撑出屏幕），
    /// `scaleAspectFill` 也就无从发挥。
    /// 该 API 是 iOS 16 起才有的，部署目标是 15，所以要标注可用性。
    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UIImageView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? UIScreen.main.bounds.width,
               height: proposal.height ?? UIScreen.main.bounds.height)
    }
}
