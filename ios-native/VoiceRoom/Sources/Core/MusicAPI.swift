import Foundation

// MARK: - 曲库数据模型

/// 曲库里的一首歌（服务端 /api/music/search 返回）
struct VRLibrarySong: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let artist: String
    let size: Int

    /// 服务端给的相对路径，例如 /api/music/file/m1a2b3c
    let url: String

    init(id: String, title: String, artist: String, size: Int, url: String) {
        self.id = id
        self.title = title
        self.artist = artist
        self.size = size
        self.url = url
    }

    /// 显式声明键，避免依赖编译器自动合成（网络字段缺失时也能给出默认值）
    enum CodingKeys: String, CodingKey {
        case id, title, artist, size, url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "未知歌曲"
        artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
    }

    /// 完整可播放地址
    var playURL: URL? {
        if url.hasPrefix("http") { return URL(string: url) }
        guard let base = VRConfig.baseURL else { return nil }
        return URL(string: url, relativeTo: base)
    }

    /// 用于缓存的稳定种子（同一首歌永远映射到同一文件名）
    var cacheKey: String { "lib_\(id)" }

    var displayArtist: String { artist.isEmpty ? "未知歌手" : artist }

    var sizeText: String {
        guard size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// 最近播放 / 收藏记录（本地持久化，可脱离网络使用）
struct VRMusicRecord: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case library      // 来自服务器曲库
        case remote       // 外链
    }

    let songId: String
    let title: String
    let artist: String
    let url: String            // 完整 URL
    let source: Source
    var at: Double             // 最近一次播放时间
    var playCount: Int

    var id: String { songId }

    var playURL: URL? { URL(string: url) }

    var atText: String {
        let d = Date(timeIntervalSince1970: at / 1000)
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
            return "今天 " + f.string(from: d)
        } else if cal.isDateInYesterday(d) {
            f.dateFormat = "HH:mm"
            return "昨天 " + f.string(from: d)
        } else {
            f.dateFormat = "M月d日"
            return f.string(from: d)
        }
    }

    /// 从曲库歌曲构造记录
    static func from(library song: VRLibrarySong, at time: Double = Date().timeIntervalSince1970 * 1000) -> VRMusicRecord? {
        guard let u = song.playURL?.absoluteString else { return nil }
        return VRMusicRecord(songId: song.id, title: song.title, artist: song.artist,
                             url: u, source: .library, at: time, playCount: 1)
    }
}

// MARK: - 曲库 API

enum MusicAPI {

    /// 搜索曲库。q 为空时返回全部（最多 40 首）
    ///
    /// 返回值是那条 URLSession 任务：**调用方要负责在发起新搜索前把它 cancel 掉**，
    /// 否则快速连续输入会同时挂好几个在飞的请求，谁先回来还不一定 ——
    /// 界面会先闪一下旧关键词的结果，再被新结果盖掉。
    @discardableResult
    static func search(_ query: String,
                       completion: @escaping (Result<[VRLibrarySong], Error>) -> Void) -> URLSessionDataTask? {
        guard let base = VRConfig.baseURL else {
            completion(.failure(VRAPIError.noServer))
            return nil
        }

        var comps = URLComponents(url: base.appendingPathComponent("api/music/search"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else {
            completion(.failure(VRAPIError.badURL))
            return nil
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let task = URLSession.shared.dataTask(with: req) { data, _, err in
            if let err {
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(VRAPIError.empty)) }
                return
            }
            do {
                let resp = try JSONDecoder().decode(SearchResponse.self, from: data)
                DispatchQueue.main.async { completion(.success(resp.list)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        task.resume()
        return task
    }

    private struct SearchResponse: Decodable {
        let ok: Bool
        let total: Int
        let list: [VRLibrarySong]
    }
}

// MARK: - 榜单 / 歌词（GD Studio 在线曲库扩展）

/// 一份榜单（服务端 /api/music/top 不带 id 时返回的清单）
struct VRChartInfo: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String

    enum CodingKeys: String, CodingKey { case id, name, icon }

    init(id: String, name: String, icon: String) {
        self.id = id; self.name = name; self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? "榜单"
        icon = (try? c.decode(String.self, forKey: .icon)) ?? "🏆"
    }
}

/// 榜单里的一首歌。id 就是远端 libraryId（gd|netease|<sid>），
/// 直接喂给 playLibrarySong / addLibrarySong 就能点播，不需要额外转换请求。
struct VRChartTrack: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let picId: String
    let duration: Int      // 毫秒

    enum CodingKeys: String, CodingKey { case id, title, artist, album, picId, duration }

    init(id: String, title: String, artist: String, album: String, picId: String, duration: Int) {
        self.id = id; self.title = title; self.artist = artist
        self.album = album; self.picId = picId; self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "未知歌曲"
        artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
        album = (try? c.decode(String.self, forKey: .album)) ?? ""
        picId = (try? c.decode(String.self, forKey: .picId)) ?? ""
        duration = (try? c.decode(Int.self, forKey: .duration)) ?? 0
    }

    var displayArtist: String { artist.isEmpty ? "未知歌手" : artist }

    var durationText: String {
        guard duration > 0 else { return "" }
        let s = duration / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 封面（走服务端代理：服务端缓存直链，客户端只管加载图片）
    var coverURL: URL? {
        guard !picId.isEmpty, let base = VRConfig.baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("api/music/pic"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "id", value: picId),
                             URLQueryItem(name: "size", value: "300")]
        return comps?.url
    }

    /// 转成曲库歌曲，复用搜歌页那套点播 / 加入歌单 / 收藏逻辑
    var asLibrarySong: VRLibrarySong {
        VRLibrarySong(id: id, title: title, artist: artist, size: 0, url: "")
    }
}

/// 一份榜单的完整内容（服务端 /api/music/top?id=xx）
struct VRChartDetail: Codable {
    let ok: Bool
    let id: String
    let name: String
    let icon: String
    let tracks: [VRChartTrack]
    let msg: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? "榜单"
        icon = (try? c.decode(String.self, forKey: .icon)) ?? "🏆"
        tracks = (try? c.decode([VRChartTrack].self, forKey: .tracks)) ?? []
        msg = try? c.decode(String.self, forKey: .msg)
    }

    enum CodingKeys: String, CodingKey { case ok, id, name, icon, tracks, msg }
}

// MARK: - LRC 歌词解析

struct VRLyricLine: Equatable {
    let time: Double   // 秒
    let text: String
}

enum VRLyric {
    /// 解析标准 LRC（[mm:ss.xx] 或 [mm:ss.xxx]，可多时间戳同行）
    static func parse(_ raw: String) -> [VRLyricLine] {
        var out: [VRLyricLine] = []
        // NSRegularExpression：正则运行库 iOS 11+ 稳定可用（Swift Regex 的运行时要求更高，不冒险）
        guard let re = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#) else { return out }
        for line in raw.split(separator: "\n") {
            let s = String(line)
            let ns = s as NSString
            let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // 歌词文本 = 最后一个时间戳之后的内容
            let lastEnd = matches[matches.count - 1].range.upperBound
            var text = ""
            if lastEnd < ns.length {
                text = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            }
            for m in matches {
                let min = Double(m.range(at: 1).length > 0 ? ns.substring(with: m.range(at: 1)) : "") ?? 0
                let sec = Double(m.range(at: 2).length > 0 ? ns.substring(with: m.range(at: 2)) : "") ?? 0
                var frac = 0.0
                let fr = m.range(at: 3)
                if fr.length > 0 {
                    let fracRaw = ns.substring(with: fr)
                    frac = (Double(fracRaw) ?? 0) / pow(10, Double(fracRaw.count))
                }
                out.append(VRLyricLine(time: min * 60 + sec + frac, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// 给定当前播放秒数，返回应高亮的行下标（没有命中返回 -1）
    static func activeIndex(in lines: [VRLyricLine], at position: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        var idx = -1
        for (i, l) in lines.enumerated() where l.time <= position + 0.25 {
            idx = i
        }
        return idx
    }
}

/// 榜单本地缓存：点开面板秒出上次的榜单（不转圈），后台刷新有变化才更新。
/// 存 UserDefaults，30 首字符串体积很小；缓存永不过期——旧数据也比转圈强。
enum VRChartCache {
    private static let key = "vr_chart_cache_v1"
    private static let queue = DispatchQueue(label: "vr.chartcache")

    static func load(_ chartId: String) -> VRChartDetail? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Data],
              let data = dict[chartId] else { return nil }
        return try? JSONDecoder().decode(VRChartDetail.self, from: data)
    }

    static func save(_ detail: VRChartDetail) {
        guard let data = try? JSONEncoder().encode(detail) else { return }
        queue.async {
            var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
            dict[detail.id] = data
            UserDefaults.standard.set(dict, forKey: key)
        }
    }
}

// MARK: - 扩展 API

extension MusicAPI {

    /// 榜单清单（不触发 GD 请求，服务端静态返回）
    @discardableResult
    static func charts(completion: @escaping (Result<[VRChartInfo], Error>) -> Void) -> URLSessionDataTask? {
        fetchJSON(path: "api/music/top", query: [], completion: completion)
    }

    /// 拉一份榜单的曲目（服务端缓存 30 分钟）
    @discardableResult
    static func chart(_ id: String,
                      completion: @escaping (Result<VRChartDetail, Error>) -> Void) -> URLSessionDataTask? {
        fetchJSON(path: "api/music/top", query: [URLQueryItem(name: "id", value: id)], completion: completion)
    }

    /// 歌词（libraryId 形如 gd|netease|123，服务端缓存 1 小时）
    @discardableResult
    static func lyric(libraryId: String,
                      completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        fetchJSON(path: "api/music/lyric",
                  query: [URLQueryItem(name: "id", value: libraryId)]) { (r: Result<LyricResponse, Error>) in
            switch r {
            case .success(let d):
                if d.ok { completion(.success(d.lyric)) }
                else { completion(.failure(VRAPIError.empty)) }
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    private struct LyricResponse: Decodable {
        let ok: Bool
        let lyric: String?
    }

    /// 通用 GET + JSON 解码。返回在飞任务，调用方可在刷新前 cancel。
    @discardableResult
    private static func fetchJSON<T: Decodable>(path: String,
                                                query: [URLQueryItem],
                                                completion: @escaping (Result<T, Error>) -> Void) -> URLSessionDataTask? {
        guard let base = VRConfig.baseURL else {
            completion(.failure(VRAPIError.noServer))
            return nil
        }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.queryItems = query.isEmpty ? nil : query
        guard let url = comps?.url else {
            completion(.failure(VRAPIError.badURL))
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let task = URLSession.shared.dataTask(with: req) { data, _, err in
            if let err {
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(VRAPIError.empty)) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                DispatchQueue.main.async { completion(.success(decoded)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        task.resume()
        return task
    }
}

enum VRAPIError: LocalizedError {
    case noServer
    case badURL
    case empty
    case offline

    var errorDescription: String? {
        switch self {
        case .noServer: return "还没设置服务器地址"
        case .badURL:   return "服务器地址格式不对"
        case .empty:    return "服务器没有返回数据"
        case .offline:  return "网络不可用"
        }
    }
}
