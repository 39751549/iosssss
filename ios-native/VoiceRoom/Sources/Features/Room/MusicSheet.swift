import SwiftUI

/// 一起听歌面板
///
/// 四个分区：搜索曲库 · 房间歌单 · 最近听歌 · 我的收藏
struct MusicSheet: View {

    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case search, playlist, recent, favorites
        var id: String { rawValue }
        var label: String {
            switch self {
            case .search:    return "🔍 搜歌"
            case .playlist:  return "📃 歌单"
            case .recent:    return "🕘 最近"
            case .favorites: return "⭐ 收藏"
            }
        }
    }

    @State private var tab: Tab = .search

    // 搜索
    @State private var query = ""
    @State private var results: [VRLibrarySong] = []
    @State private var searchState: SearchState = .idle
    @State private var searchTask: Task<Void, Never>?

    enum SearchState: Equatable {
        case idle, loading, empty, failed(String)
    }

    @ObservedObject private var cache = MusicCache.shared
    @ObservedObject private var history = MusicHistory.shared
    @ObservedObject private var player = MusicPlayer.shared

    /// 歌单上限（与服务端一致）
    private let playlistLimit = 20

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                tabBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 播放器主控（有歌时常驻，含模式/音量/进度）
                        playerBar

                        switch tab {
                        case .search:    searchSection
                        case .playlist:  playlistSection
                        case .recent:    recentSection
                        case .favorites: favoritesSection
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 26)
                }
                .vrScrollHidden()
                .vrScrollDismissKeyboard()
            }
        }
        .vrSheet()
        .onAppear {
            cache.refreshStats()
            if results.isEmpty { runSearch("") }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text("一起听歌 🎵")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(VRTheme.text)
            if !state.playlist.isEmpty {
                Text("\(state.playlist.count)/\(playlistLimit)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(state.playlist.count >= playlistLimit ? VRTheme.red : VRTheme.textDim)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(hex: "27436B").opacity(0.08)))
            }
            Spacer()
            Button { dismiss() } label: {
                Text("✕")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(VRTheme.textMute)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases) { t in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { tab = t }
                    } label: {
                        Text(t.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(tab == t ? .white : VRTheme.textDim)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(
                                Group {
                                    if tab == t {
                                        Capsule().fill(VRTheme.brandGradient)
                                    } else {
                                        Capsule().fill(Color(hex: "27436B").opacity(0.07))
                                    }
                                }
                            )
                            .overlay(
                                Capsule().strokeBorder(tab == t ? .clear : VRTheme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
        }
    }

    // MARK: - 播放器主控条（歌名 / 倒计时 / 模式 / 音量）

    @ViewBuilder
    private var playerBar: some View {
        if let song = state.currentSong {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(state.playing ? "🔊" : "⏸").font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(VRTheme.text)
                            .lineLimit(1)
                        Text("由 \(song.by) 点播")
                            .font(.system(size: 11))
                            .foregroundColor(VRTheme.textDim)
                    }
                    Spacer()
                    // 收藏
                    Button {
                        let added = history.toggleFavorite(
                            songId: stableFavId(song), title: song.title,
                            artist: song.artist ?? "",
                            url: absoluteURL(song.url), source: .library)
                        app.showToast(added ? "已收藏 ⭐" : "已取消收藏")
                    } label: {
                        Text(history.isFavorite(songId: stableFavId(song)) ? "⭐" : "☆")
                            .font(.system(size: 19))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }

                // 进度条 + 时间倒计时
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(hex: "27436B").opacity(0.12))
                            Capsule()
                                .fill(VRTheme.brandGradient)
                                .frame(width: max(2, geo.size.width * player.progressFraction))
                        }
                    }
                    .frame(height: 5)

                    HStack {
                        Text(player.positionText)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(VRTheme.textDim)
                        Spacer()
                        Text(player.durationText)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(VRTheme.textDim)
                    }
                }

                // 控制：播放/暂停 · 下一首 · 播放模式
                HStack(spacing: 9) {
                    Button(state.playing ? "⏸ 暂停" : "▶️ 播放") {
                        app.musicControl(state.playing ? "pause" : "play")
                    }
                    .buttonStyle(VRButtonStyle())

                    Button("⏭ 下一首") { app.musicControl("next") }
                        .buttonStyle(VRButtonStyle())

                    // 三种模式循环切换
                    Button {
                        app.cyclePlayMode()
                    } label: {
                        HStack(spacing: 4) {
                            Text(state.mode.icon).font(.system(size: 13))
                            Text(state.mode.label).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(VRTheme.text)
                        .frame(minHeight: 46)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.85))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(VRTheme.brand.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                // 音量
                HStack(spacing: 9) {
                    Text("🔈").font(.system(size: 13))
                    Slider(value: Binding(
                        get: { Double(player.volume) },
                        set: { player.setVolume(Float($0)) }
                    ), in: 0...1)
                    .tint(VRTheme.brand)
                    Text("\(Int(player.volume * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(VRTheme.textDim)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(colors: [VRTheme.brand.opacity(0.28), VRTheme.brand2.opacity(0.16)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(VRTheme.brand.opacity(0.6), lineWidth: 1)
            )
        }
    }

    // MARK: - 搜索

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.currentSong == nil {
                hintBox("还没有人点播歌曲\n搜一首试试 🎵")
            }

            // 搜索框
            HStack(spacing: 9) {
                HStack(spacing: 6) {
                    Text("🔍").font(.system(size: 13))
                    TextField("输入歌名或歌手", text: $query)
                        .font(.system(size: 14))
                        .foregroundColor(VRTheme.text)
                        .submitLabel(.search)
                        .onSubmit { runSearch(query) }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            runSearch("")
                        } label: {
                            Text("✕").font(.system(size: 12)).foregroundColor(VRTheme.textMute)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: "27436B").opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(VRTheme.border, lineWidth: 1)
                )

                Button("搜索") { runSearch(query) }
                    .buttonStyle(VRButtonStyle(kind: .primary))
            }
            .onChange(of: query) { _ in
                // 输入防抖 420ms
                searchTask?.cancel()
                let q = query
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 420_000_000)
                    if Task.isCancelled { return }
                    await MainActor.run { runSearch(q) }
                }
            }

            // 结果
            switch searchState {
            case .loading:
                hintBox("搜索中…")

            case .empty:
                hintBox(query.isEmpty
                        ? "曲库还是空的\n让管理员在后台上传歌曲吧 🎧"
                        : "没有找到「\(query)」\n换个关键词试试")

            case .failed(let msg):
                VStack(spacing: 10) {
                    hintBox(msg)
                    Button("重新搜索") { runSearch(query) }
                        .buttonStyle(VRButtonStyle(fullWidth: true))
                }

            case .idle:
                if !results.isEmpty { resultList }
            }

            cacheCard
        }
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("找到 \(results.count) 首")
                .font(.system(size: 12))
                .foregroundColor(VRTheme.textDim)

            ForEach(results) { song in
                songRow(song)
            }
        }
    }

    /// 曲库歌曲行（点播 / 加入歌单 / 收藏 / 缓存）
    private func songRow(_ song: VRLibrarySong) -> some View {
        let cached = cache.isCached(song.cacheKey)
        let downloading = cache.isDownloading(song.cacheKey)
        let fav = history.isFavorite(songId: "lib_\(song.id)")
        let isCurrent = state.currentSong?.libraryId == song.id
            || state.currentSong?.url.contains(song.id) == true

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isCurrent ? VRTheme.brandGradient : LinearGradient(
                            colors: [Color(hex: "27436B").opacity(0.1), Color(hex: "27436B").opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Text(isCurrent ? "🔊" : "🎵").font(.system(size: 17))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VRTheme.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(song.displayArtist)
                            .font(.system(size: 11))
                            .foregroundColor(VRTheme.textDim)
                            .lineLimit(1)
                        if cached {
                            Text("已缓存")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(VRTheme.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(VRTheme.green.opacity(0.16)))
                        } else if downloading {
                            Text("缓存中 \(Int((cache.progress[song.cacheKey] ?? 0) * 100))%")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(VRTheme.brand2)
                        } else if !song.sizeText.isEmpty {
                            Text(song.sizeText)
                                .font(.system(size: 10))
                                .foregroundColor(VRTheme.textMute)
                        }
                    }
                }

                Spacer()

                // 收藏
                Button {
                    let added = history.toggleFavorite(library: song)
                    app.showToast(added ? "已收藏 ⭐" : "已取消收藏")
                } label: {
                    Text(fav ? "⭐" : "☆")
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button("▶️ 点播") { playNow(song) }
                    .buttonStyle(VRButtonStyle(kind: .primary))

                Button("➕ 加入歌单") { addToPlaylist(song) }
                    .buttonStyle(VRButtonStyle())

                if !cached && !downloading {
                    Button("⬇️ 缓存") { download(song) }
                        .buttonStyle(VRButtonStyle())
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(isCurrent ? VRTheme.brand.opacity(0.14) : Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(isCurrent ? VRTheme.brand.opacity(0.6) : VRTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 房间歌单

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.playlist.isEmpty {
                hintBox("歌单是空的\n搜索歌曲点「加入歌单」吧")
            } else {
                HStack {
                    Text("共 \(state.playlist.count)/\(playlistLimit) 首")
                        .font(.system(size: 12))
                        .foregroundColor(VRTheme.textDim)
                    Spacer()
                    Button("清空") { app.musicControl("clear") }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(VRTheme.red.opacity(0.9))
                }

                ForEach(Array(state.playlist.enumerated()), id: \.element.id) { idx, song in
                    let isCurrent = state.currentSong?.id == song.id
                    HStack(spacing: 10) {
                        Text(isCurrent ? "🔊" : "\(idx + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(isCurrent ? VRTheme.green : VRTheme.textMute)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.system(size: 14, weight: isCurrent ? .bold : .medium))
                                .foregroundColor(VRTheme.text)
                                .lineLimit(1)
                            Text("由 \(song.by) 点播")
                                .font(.system(size: 11))
                                .foregroundColor(VRTheme.textDim)
                        }

                        Spacer()

                        if !isCurrent {
                            Button("播放") { app.musicControl("select", songId: song.id) }
                                .buttonStyle(VRButtonStyle())
                        }
                        Button {
                            app.musicControl("remove", songId: song.id)
                        } label: {
                            Text("✕")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(VRTheme.textMute)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color(hex: "27436B").opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isCurrent ? VRTheme.brand.opacity(0.14) : Color(hex: "27436B").opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isCurrent ? VRTheme.brand.opacity(0.6) : VRTheme.border, lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - 最近听歌

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(history.recent.isEmpty ? "" : "共 \(history.recent.count) 首")
                    .font(.system(size: 12))
                    .foregroundColor(VRTheme.textDim)
                Spacer()
                if !history.recent.isEmpty {
                    Button("清空") { history.clearRecent() }
                        .font(.system(size: 12))
                        .foregroundColor(VRTheme.red.opacity(0.9))
                }
            }

            if history.recent.isEmpty {
                hintBox("还没有听歌记录\n点播一首歌就会出现在这里")
            } else {
                ForEach(history.recent) { r in
                    recordRow(r, showDate: true)
                }
            }
        }
    }

    // MARK: - 我的收藏

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(history.favorites.isEmpty ? "" : "共 \(history.favorites.count) 首")
                .font(.system(size: 12))
                .foregroundColor(VRTheme.textDim)

            if history.favorites.isEmpty {
                hintBox("还没有收藏\n在搜歌里点 ☆ 就能收藏")
            } else {
                ForEach(history.favorites) { r in
                    recordRow(r, showDate: false)
                }
            }
        }
    }

    /// 记录行（最近 / 收藏共用）—— 带收藏按钮，可直接切换
    private func recordRow(_ r: VRMusicRecord, showDate: Bool) -> some View {
        let fav = history.isFavorite(songId: r.songId)
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(hex: "27436B").opacity(0.08))
                    .frame(width: 40, height: 40)
                Text(showDate ? "🕘" : "⭐").font(.system(size: 16))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(r.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(VRTheme.text)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(r.artist.isEmpty ? "未知歌手" : r.artist)
                        .font(.system(size: 11))
                        .foregroundColor(VRTheme.textDim)
                        .lineLimit(1)
                    if showDate {
                        Text(r.atText)
                            .font(.system(size: 10))
                            .foregroundColor(VRTheme.textMute)
                        if r.playCount > 1 {
                            Text("听过 \(r.playCount) 次")
                                .font(.system(size: 10))
                                .foregroundColor(VRTheme.textMute)
                        }
                    }
                }
            }

            Spacer()

            // 收藏 / 取消收藏
            Button {
                let added = history.toggleFavorite(
                    songId: r.songId, title: r.title, artist: r.artist,
                    url: r.url, source: r.source)
                app.showToast(added ? "已收藏 ⭐" : "已取消收藏")
            } label: {
                Text(fav ? "⭐" : "☆")
                    .font(.system(size: 17))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            // 点播到房间
            Button("点播") { playRecord(r) }
                .buttonStyle(VRButtonStyle(kind: .primary))

            Button {
                if showDate {
                    history.removeRecent(r.songId)
                } else {
                    history.removeFavorite(r.songId)
                }
            } label: {
                Text("✕")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VRTheme.textMute)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(hex: "27436B").opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 缓存管理入口

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("📦 离线缓存")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(VRTheme.text)
                Spacer()
                Text("\(cache.usedText) / \(cache.limitText)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(VRTheme.textDim)
            }

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: "27436B").opacity(0.1))
                    Capsule()
                        .fill(cache.usedFraction > 0.9
                              ? LinearGradient(colors: [VRTheme.red, Color(hex: "FF8A5B")],
                                               startPoint: .leading, endPoint: .trailing)
                              : VRTheme.brandGradient)
                        .frame(width: max(3, geo.size.width * cache.usedFraction))
                }
            }
            .frame(height: 7)

            HStack {
                Text("\(cache.entryCount) 首歌 · 超出上限自动清理最旧的")
                    .font(.system(size: 11))
                    .foregroundColor(VRTheme.textMute)
                Spacer()
                if cache.entryCount > 0 {
                    Button("清空缓存") { cache.clearAll() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(VRTheme.red.opacity(0.9))
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 组件

    private func hintBox(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(VRTheme.textMute)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(hex: "27436B").opacity(0.045))
            )
    }

    // MARK: - 动作

    private func runSearch(_ q: String) {
        searchState = .loading
        let key = q.trimmingCharacters(in: .whitespaces)
        MusicAPI.search(key) { result in
            switch result {
            case .success(let list):
                results = list
                searchState = list.isEmpty ? .empty : .idle
            case .failure(let err):
                searchState = .failed(err.localizedDescription)
            }
        }
    }

    /// 立即点播：全房间同步切歌，并写入最近听歌
    private func playNow(_ song: VRLibrarySong) {
        app.playLibrarySong(libraryId: song.id, by: app.me?.name ?? "我",
                            title: song.title, artist: song.artist)
        if let url = song.playURL?.absoluteString {
            history.recordPlay(songId: "lib_\(song.id)", title: song.title,
                               artist: song.artist, url: url, source: .library)
        }
        app.showToast("正在为全房间点播…", kind: .success)
    }

    /// 加入歌单：不打断当前播放（超过 20 首给出明确提示）
    private func addToPlaylist(_ song: VRLibrarySong) {
        if state.playlist.count >= playlistLimit {
            app.showToast("歌单最多 \(playlistLimit) 首，先移除几首吧", kind: .error)
            return
        }
        app.addLibrarySong(libraryId: song.id, title: song.title, artist: song.artist,
                           by: app.me?.name ?? "我")
        app.showToast("已加入歌单", kind: .success)
    }

    /// 手动缓存
    private func download(_ song: VRLibrarySong) {
        guard !song.url.isEmpty else {
            app.showToast("在线歌曲边播边听，无需缓存", kind: .info)
            return
        }
        cache.download(song, base: VRConfig.baseURL)
    }

    /// 点播一条本地记录
    private func playRecord(_ r: VRMusicRecord) {
        // 在线曲库记录：songId 形如 gd_<libraryId>。
        // 这类歌本地存的是「当时的直链」，可能早就过期、甚至已解析不成 URL，
        // 必须交给服务端重新解析，不能依赖本地地址 —— 否则收藏/最近里的歌点不动。
        if r.songId.hasPrefix("gd_") {
            let lid = String(r.songId.dropFirst(3))
            app.playLibrarySong(libraryId: lid, by: app.me?.name ?? "我",
                                title: r.title, artist: r.artist)
        } else if let url = r.playURL, r.source == .library, let libId = libraryId(from: url) {
            // 本地曲库：地址稳定（/api/music/file/<libId>）
            app.playLibrarySong(libraryId: libId, by: app.me?.name ?? "我",
                                title: r.title, artist: r.artist)
        } else if let url = r.playURL {
            // 外链：只能用保存下来的地址
            app.addSongByURL(title: r.title, url: url.absoluteString)
        } else {
            app.showToast("这首歌的地址已失效，请重新搜索", kind: .error)
            return
        }
        history.recordPlay(songId: r.songId, title: r.title, artist: r.artist,
                           url: r.url, source: r.source)
        app.showToast("正在为全房间点播…", kind: .success)
    }

    /// 从 /api/music/file/m1a2b3c 里取出 m1a2b3c
    private func libraryId(from url: URL) -> String? {
        let s = url.absoluteString
        guard let range = s.range(of: "/api/music/file/") else { return nil }
        let id = String(s[range.upperBound...])
        return id.isEmpty ? nil : id
    }

    /// 收藏用的稳定 id（与 MusicPlayer 记录一致）
    private func stableFavId(_ song: VRSong) -> String {
        if let lid = song.libraryId, !lid.isEmpty {
            return song.url.contains("/api/music/file/") ? "lib_\(lid)" : "gd_\(lid)"
        }
        let abs = absoluteURL(song.url)
        if let r = abs.range(of: "/api/music/file/") {
            let libId = String(abs[r.upperBound...])
            if !libId.isEmpty { return "lib_\(libId)" }
        }
        return "url_\(abs.split(separator: "?").first.map(String.init) ?? abs)"
    }

    private func absoluteURL(_ s: String) -> String {
        if s.hasPrefix("http") { return s }
        guard let base = VRConfig.baseURL, let u = URL(string: s, relativeTo: base) else { return s }
        return u.absoluteString
    }
}
