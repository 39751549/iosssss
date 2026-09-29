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
        // 按解码后的真实字节数记账：一张 40 帧的 GIF 就是几十 MB，
        // 只按"张数"限流的话很容易在几张动图上就把内存吃穿，
        // 换来的是系统内存警告 + 缓存被清空（图忽有忽无）。
        c.totalCostLimit = 96 * 1024 * 1024
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
    func cachedImage(for url: URL, profile: DecodeProfile = .generic) -> UIImage? {
        memory.object(forKey: (key(url) + profile.keySuffix) as NSString)
    }

    /// 异步取图：内存 → 磁盘 → 网络
    /// - Parameter profile: 解码档位。同一 URL 按不同档位解码的结果分开缓存。
    func image(for url: URL, profile: DecodeProfile = .generic,
               completion: @escaping (UIImage?) -> Void) {
        let fileKey = key(url)                 // 磁盘文件名（原始数据，与档位无关）
        let memKey = fileKey + profile.keySuffix
        let nsKey = memKey as NSString

        if let img = memory.object(forKey: nsKey) {
            completion(img)
            return
        }

        let disk = diskURL(for: fileKey, ext: url.pathExtension)
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let data = try? Data(contentsOf: disk), let img = Self.decode(data, profile: profile) {
                self.touch(disk)   // 更新 LRU
                self.memory.setObject(img, forKey: nsKey, cost: Self.byteCost(img))
                DispatchQueue.main.async { completion(img) }
                return
            }
            // 磁盘没有 → 下载（并发去重）
            self.download(url: url, fileKey: fileKey, profile: profile, completion: completion)
        }
    }

    /// 解码档位：决定解码出来的最大边长、以及动图最多保留几帧。
    ///
    /// 为什么必须分档：用户上传的头像/背景动辄是 4MB、40~50 帧的 GIF。
    /// 按原尺寸全帧解码，**一张就吃掉 35~45MB 内存**
    /// （例：399×572×4B × 41 帧 ≈ 37MB；352×624×4B × 50 帧 ≈ 44MB）。
    /// 头像+背景两张一起 80MB+，系统立刻发内存警告 → NSCache 被清空 →
    /// 图"本来有，突然又不见了"，同时解码本身还很慢（表现为"要等好久才生效"）。
    /// 按实际显示尺寸解码 + 限制帧数，才是对症的做法。
    enum DecodeProfile {
        /// 麦位/名片头像：屏幕上最大也就 82pt，解码到 256px 足够清晰
        case avatar
        /// 房间背景：铺满屏幕，但源图本身很小，帧数上限比尺寸更关键
        case background
        /// 列表/选择器里的缩略图（背景瓦片、房间卡片）：只要一帧静态图，
        /// 尺寸小、只解一帧，滚动时不占内存
        case thumb
        case generic

        var maxPixel: CGFloat {
            switch self {
            case .avatar:     return 256
            case .background: return 1024
            case .thumb:      return 320
            case .generic:    return 1024
            }
        }

        var maxFrames: Int {
            switch self {
            case .avatar:     return 48
            case .background: return 20
            case .thumb:      return 1
            case .generic:    return 24
            }
        }

        /// 进内存缓存键：同一 URL 按不同档位解码的结果不能互相覆盖
        var keySuffix: String {
            switch self {
            case .avatar:     return "#a"
            case .background: return "#b"
            case .thumb:      return "#t"
            case .generic:    return "#g"
            }
        }
    }

    /// 从原始数据解码图片。
    /// 注意：`UIImage(data:)` 对 GIF 只取首帧，必须走 ImageIO 才能拿到动图。
    /// - Parameters:
    ///   - profile: 按用途限制最大边长与帧数，避免超大 GIF 撑爆内存
    static func decode(_ data: Data, profile: DecodeProfile = .generic) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(src)
        if count <= 1 {
            if let cg = scaledFrame(src, 0, profile.maxPixel) { return UIImage(cgImage: cg) }
            return UIImage(data: data)
        }

        // 抽帧步长：帧数超上限时按固定步长抽样，并把被跨过帧的时长累加到保留帧上，
        // 这样总时长（也就是播放速度）保持不变，只是不那么"丝滑"。
        let step = max(1, Int(ceil(Double(count) / Double(profile.maxFrames))))
        var frames: [UIImage] = []
        var total = 0.0
        var i = 0
        while i < count {
            if let cg = scaledFrame(src, i, profile.maxPixel) {
                frames.append(UIImage(cgImage: cg))
            }
            var span = 0.0
            for k in i..<min(i + step, count) { span += frameDelay(src, k) }
            total += span
            i += step
        }
        guard !frames.isEmpty else { return UIImage(data: data) }
        // 只保留一帧（thumb 档）时没必要包成动图：给个普通 UIImage，
        // SwiftUI 直接当静态图渲染，省掉一层定时器与帧表
        if frames.count == 1 { return frames[0] }
        return UIImage.animatedImage(with: frames, duration: total > 0 ? total : Double(frames.count) * 0.1)
    }

    /// 取第 index 帧并缩放到 maxPixel 以内（源图本身就小的话直接原样取出）
    private static func scaledFrame(_ src: CGImageSource, _ index: Int, _ maxPixel: CGFloat) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, index, nil)
    }

    /// 单帧延时（GIF 帧延时为百分之一秒）
    private static func frameDelay(_ src: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any],
              let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }

    /// 解码后占用的字节数（用于 NSCache 的 cost 记账，超限时优先淘汰大图）
    static func byteCost(_ img: UIImage) -> Int {
        let frames = max(1, img.images?.count ?? 1)
        return Int(img.size.width * img.size.height) * 4 * frames
    }

    private func download(url: URL, fileKey: String, profile: DecodeProfile,
                          completion: @escaping (UIImage?) -> Void) {
        // 去重键要带上档位：同一 URL 的头像档与背景档是两次不同的解码任务
        let taskKey = fileKey + profile.keySuffix
        inflightLock.lock()
        if var waiters = inflight[taskKey] {
            waiters.append(completion)
            inflight[taskKey] = waiters
            inflightLock.unlock()
            return
        }
        inflight[taskKey] = [completion]
        inflightLock.unlock()

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        // URL 即内容指纹 → 可用缓存；但若服务端换了文件，URL 也会变
        req.cachePolicy = .returnCacheDataElseLoad

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            var image: UIImage?
            if let data, let img = Self.decode(data, profile: profile) {
                image = img
                let disk = self.diskURL(for: fileKey, ext: url.pathExtension)
                try? data.write(to: disk, options: .atomic)
            }
            self.inflightLock.lock()
            let waiters = self.inflight[taskKey] ?? []
            self.inflight.removeValue(forKey: taskKey)
            self.inflightLock.unlock()

            if let image {
                self.memory.setObject(image, forKey: taskKey as NSString, cost: Self.byteCost(image))
            }
            self.enforceLimit()
            DispatchQueue.main.async { waiters.forEach { $0(image) } }
        }.resume()
    }

    // MARK: - 主动预取（进房前把背景下好，切房不闪）

    func prefetch(_ url: URL, profile: DecodeProfile = .generic) {
        if cachedImage(for: url, profile: profile) != nil { return }
        image(for: url, profile: profile) { _ in }
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
    /// 解码档位：列表缩略图传 .thumb（只解一帧），房间背景传 .background
    let profile: DecodeProfile
    private let content: (Phase) -> AnyView

    /// 泛型只落在初始化器上（仅在调用点做局部推断）
    init<C: View>(url: URL?, profile: DecodeProfile = .generic,
                  @ViewBuilder content: @escaping (Phase) -> C) {
        self.url = url
        self.profile = profile
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
        if let hit = MediaCache.shared.cachedImage(for: url, profile: profile) {
            image = hit
            return
        }
        MediaCache.shared.image(for: url, profile: profile) { img in
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
