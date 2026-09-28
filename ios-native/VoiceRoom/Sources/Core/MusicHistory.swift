import Foundation
import Combine

/// 最近听歌记录 + 我的收藏（本地持久化）
///
/// - 最近听歌：最多 100 条，同一首歌只保留一条并更新播放次数与时间
/// - 收藏：手动加/取消，最多 500 条
/// 两者都存 UserDefaults（数据量小、无需文件管理）
final class MusicHistory: ObservableObject {

    static let shared = MusicHistory()

    @Published private(set) var recent: [VRMusicRecord] = []
    @Published private(set) var favorites: [VRMusicRecord] = []

    private let recentKey = "vr_music_recent"
    private let favKey = "vr_music_favorites"

    private let recentLimit = 100
    private let favLimit = 500

    private init() {
        load()
    }

    // MARK: - 最近听歌

    /// 记录一次播放
    func recordPlay(songId: String, title: String, artist: String, url: String,
                    source: VRMusicRecord.Source) {
        let now = Date().timeIntervalSince1970 * 1000

        if var existing = recent.first(where: { $0.songId == songId }) {
            existing.at = now
            existing.playCount += 1
            recent.removeAll { $0.songId == songId }
            recent.insert(existing, at: 0)
        } else {
            let r = VRMusicRecord(songId: songId, title: title, artist: artist,
                                  url: url, source: source, at: now, playCount: 1)
            recent.insert(r, at: 0)
        }

        if recent.count > recentLimit {
            recent.removeLast(recent.count - recentLimit)
        }
        saveRecent()
    }

    /// 便捷：从曲库歌曲记录
    func recordPlay(library song: VRLibrarySong) {
        guard let u = song.playURL?.absoluteString else { return }
        recordPlay(songId: song.id, title: song.title, artist: song.artist,
                   url: u, source: .library)
    }

    /// 便捷：从房间同步的歌曲记录（VRSong 不带 artist 为可选）
    func recordPlay(roomSong: VRSong) {
        guard roomSong.url.hasPrefix("http") else { return }
        recordPlay(songId: roomSong.id, title: roomSong.title, artist: "",
                   url: roomSong.url, source: roomSong.url.contains("/api/music/file/") ? .library : .remote)
    }

    func clearRecent() {
        recent.removeAll()
        saveRecent()
    }

    func removeRecent(_ songId: String) {
        recent.removeAll { $0.songId == songId }
        saveRecent()
    }

    // MARK: - 收藏

    func isFavorite(songId: String) -> Bool {
        favorites.contains { $0.songId == songId }
    }

    /// 切换收藏，返回切换后的状态
    @discardableResult
    func toggleFavorite(songId: String, title: String, artist: String, url: String,
                        source: VRMusicRecord.Source) -> Bool {
        if isFavorite(songId: songId) {
            favorites.removeAll { $0.songId == songId }
            saveFavorites()
            return false
        }
        let r = VRMusicRecord(songId: songId, title: title, artist: artist,
                              url: url, source: source,
                              at: Date().timeIntervalSince1970 * 1000, playCount: 0)
        favorites.insert(r, at: 0)
        if favorites.count > favLimit {
            favorites.removeLast(favorites.count - favLimit)
        }
        saveFavorites()
        return true
    }

    @discardableResult
    func toggleFavorite(library song: VRLibrarySong) -> Bool {
        guard let u = song.playURL?.absoluteString else { return false }
        return toggleFavorite(songId: song.id, title: song.title, artist: song.artist,
                              url: u, source: .library)
    }

    func removeFavorite(_ songId: String) {
        favorites.removeAll { $0.songId == songId }
        saveFavorites()
    }

    // MARK: - 持久化

    private func load() {
        if let data = UserDefaults.standard.data(forKey: recentKey),
           let list = try? JSONDecoder().decode([VRMusicRecord].self, from: data) {
            recent = list
        }
        if let data = UserDefaults.standard.data(forKey: favKey),
           let list = try? JSONDecoder().decode([VRMusicRecord].self, from: data) {
            favorites = list
        }
    }

    private func saveRecent() {
        guard let data = try? JSONEncoder().encode(recent) else { return }
        UserDefaults.standard.set(data, forKey: recentKey)
    }

    private func saveFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: favKey)
    }
}
