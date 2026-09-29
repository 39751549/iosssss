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
