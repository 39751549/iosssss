import SwiftUI

/// 一起听歌面板
///
/// 五个分区：歌曲排行榜 · 搜索曲库 · 房间歌单 · 最近听歌 · 我的收藏
struct MusicSheet: View {

    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case charts, search, playlist, recent, favorites
        var id: String { rawValue }
        var label: String {
            switch self {
            case .charts:    return "🏆 榜单"
            case .search:    return "🔍 搜歌"
            case .playlist:  return "📃 歌单"
            case .recent:    return "🕘 最近"
            case .favorites: return "⭐ 收藏"
            }
        }
    }

    @State private var tab: Tab = .charts

    // 搜索
    @State private var query = ""
    @State private var results: [VRLibrarySong] = []
    @State private var searchState: SearchState = .idle
    @State private var searchTask: Task<Void, Never>?
    /// 上一次还在飞的搜索请求（输入新内容前先取消）
    @State private var searchDataTask: URLSessionDataTask?
    /// 请求序号：只认最后一次发起的那条，迟到的旧结果直接丢弃
    @State private var searchSeq = 0

    /// 键盘焦点。有了它才能"点任意地方就收起键盘"——
    /// 之前搜索框没有焦点绑定，输入法弹出来之后除了按键盘上的"搜索"没有别的办法收掉，
    /// 在小屏上键盘正好盖住结果列表，看起来就像"卡住了关不掉"。
    @FocusState private var searchFocused: Bool

    enum SearchState: Equatable {
        case idle, loading, empty, failed(String)
    }

    // 榜单
    enum ChartState: Equatable {
        case idle, loading, failed(String)
    }
    @State private var chartList: [VRChartInfo] = []
    @State private var chartId = ""
    @State private var chartTracks: [VRChartTrack] = []
    @State private var chartState: ChartState = .idle
    @State private var chartsLoaded = false
    @State private var chartTask: URLSessionDataTask?

    // 歌词
    @State private var showLyrics = false
    @State private var lyricText: String?
    @State private var lyricLoading = false
    @State private var lyricTask: URLSessionDataTask?
    /// 记住上次加载歌词的歌，切歌时重新拉
    @State private var lyricForLibraryId = ""

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
                        case .charts:    chartsSection
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
        // 点面板任意位置都收起键盘。
        // 用 simultaneousGesture 而不是 onTapGesture：并联识别不会被列表/按钮吃掉，
        // 点空白、点歌、点标签页都会顺手把输入法收掉；而按钮自己的动作照常执行。
        .simultaneousGesture(TapGesture().onEnded {
            if searchFocused { searchFocused = false }
        })
        // 键盘上方再给一个明确的「完成」，这是最不容易被误解的收起方式
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { searchFocused = false }
            }
        }
        .vrSheet()
        .onAppear {
            cache.refreshStats()
            if results.isEmpty { runSearch("") }
            loadChartsIfNeeded()
        }
        .onDisappear {
            // 面板关掉就别让请求继续跑（尤其是用户已经离开房间的场景）
            searchTask?.cancel()
            searchDataTask?.cancel()
            chartTask?.cancel()
            lyricTask?.cancel()
        }
        .sheet(isPresented: $showLyrics) { lyricsSheet }
        .onChange(of: showLyrics) { open in
            if open { loadLyricIfNeeded() }
        }
        // 切歌后重置歌词缓存：下次打开歌词浮层会重新拉新歌的
        .onChange(of: state.currentSong?.id) { _ in
            lyricForLibraryId = ""
            lyricText = nil
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
                    // 歌词（在线歌才有）
                    if (state.currentSong?.libraryId ?? "").hasPrefix("gd|") {
                        Button {
                            showLyrics = true
                        } label: {
                            Text("词")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(VRTheme.brand)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Color.white.opacity(0.85)))
                                .overlay(Circle().strokeBorder(VRTheme.brand.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
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

    // MARK: - 歌曲排行榜

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 榜单切换条
            if !chartList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chartList) { c in
                            Button {
                                guard chartId != c.id else { return }
                                loadChart(c.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(c.icon).font(.system(size: 13))
                                    Text(c.name).font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(chartId == c.id ? .white : VRTheme.textDim)
                                .padding(.horizontal, 13)
                                .frame(height: 32)
                                .background(
                                    Group {
                                        if chartId == c.id {
                                            Capsule().fill(VRTheme.brandGradient)
                                        } else {
                                            Capsule().fill(Color(hex: "27436B").opacity(0.07))
                                        }
                                    }
                                )
                                .overlay(Capsule().strokeBorder(chartId == c.id ? .clear : VRTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            switch chartState {
            case .loading:
                hintBox("榜单加载中…")
            case .failed(let msg):
                VStack(spacing: 10) {
                    hintBox(msg)
                    Button("重新加载") { loadChart(chartId.isEmpty ? "3778678" : chartId) }
                        .buttonStyle(VRButtonStyle(fullWidth: true))
                }
            case .idle:
                if chartTracks.isEmpty {
                    hintBox(chartList.isEmpty ? "榜单还没加载\n稍等一下就好" : "这份榜单暂时拉不到\n换一份试试")
                } else {
                    chartTrackList
                }
            }
        }
    }

    private var chartTrackList: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            Text("\(chartTracks.count) 首 · 每日更新")
                .font(.system(size: 12))
                .foregroundColor(VRTheme.textDim)

            ForEach(Array(chartTracks.enumerated()), id: \.element.id) { idx, track in
                chartRow(rank: idx + 1, track: track)
            }
        }
    }

    /// 榜单行：名次（前三名奖牌色）+ 封面 + 歌名/歌手 + 点播/加入
    private func chartRow(rank: Int, track: VRChartTrack) -> some View {
        let isCurrent = state.currentSong?.libraryId == track.id
        let rankColor: Color = {
            switch rank {
            case 1: return Color(hex: "F5B83D")   // 金
            case 2: return Color(hex: "A8B4C4")   // 银
            case 3: return Color(hex: "D08A5A")   // 铜
            default: return VRTheme.textMute
            }
        }()

        return HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: rank <= 3 ? 16 : 13, weight: .heavy, design: .rounded))
                .foregroundColor(rankColor)
                .frame(width: 24)

            // 封面（服务端代理缓存，占位用音符底）
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [VRTheme.brand.opacity(0.18), VRTheme.brand2.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                if let url = track.coverURL {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Text("🎵").font(.system(size: 17))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text("🎵").font(.system(size: 17))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isCurrent ? VRTheme.brand : VRTheme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(track.displayArtist)
                        .font(.system(size: 11))
                        .foregroundColor(VRTheme.textDim)
                        .lineLimit(1)
                    if !track.durationText.isEmpty {
                        Text(track.durationText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(VRTheme.textMute)
                    }
                }
            }

            Spacer()

            Button("点播") { playNow(track.asLibrarySong) }
                .buttonStyle(VRButtonStyle(kind: .primary))

            Button("➕") { addToPlaylist(track.asLibrarySong) }
                .buttonStyle(VRButtonStyle())
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? VRTheme.brand.opacity(0.14) : Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isCurrent ? VRTheme.brand.opacity(0.6) : VRTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 歌词

    @ViewBuilder
    private var lyricsSheet: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "1B1530"), Color(hex: "2A1746")],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.currentSong?.title ?? "")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let song = state.currentSong {
                            Text("由 \(song.by) 点播")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                    Spacer()
                    Button { showLyrics = false } label: {
                        Text("✕")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 32, height: 32)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

                if lyricLoading {
                    Spacer()
                    Text("歌词加载中…").foregroundColor(.white.opacity(0.5))
                    Spacer()
                } else if let lines = lyricLines, !lines.isEmpty {
                    LyricScrollView(lines: lines, player: player)
                } else {
                    Spacer()
                    Text(lyricText != nil ? "纯音乐，请欣赏 🎧" : "这首歌暂时拿不到歌词")
                        .foregroundColor(.white.opacity(0.55))
                    Spacer()
                }
            }
        }
    }

    /// 当前歌的解析后歌词（ song 变了就置空，触发重新拉取）
    private var lyricLines: [VRLyricLine]? {
        guard let raw = lyricText else { return nil }
        return VRLyric.parse(raw)
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
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            runSearch(query)
                            // 按下键盘上的"搜索"就顺手收起键盘，直接看结果
                            searchFocused = false
                        }
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

                Button("搜索") {
                    runSearch(query)
                    searchFocused = false
                }
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

            // LazyVStack 而不是 VStack：一次搜索最多返回 40 首，
            // 用 VStack 会把 40 行（每行都带头像/按钮）一次性全建出来，
            // 搜索刚出结果那一帧就会明显卡一下。懒加载只建屏幕内的几行。
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(results) { song in
                    songRow(song)
                }
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

    /// 歌词浮层里的滚动歌词（高亮当前行 + 自动居中滚动）
    private struct LyricScrollView: View {
        let lines: [VRLyricLine]
        @ObservedObject var player: MusicPlayer

        var body: some View {
            let active = VRLyric.activeIndex(in: lines, at: player.position)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 18) {
                        Color.clear.frame(height: 40).id(-1)
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: i == active ? 17 : 14.5,
                                              weight: i == active ? .bold : .medium))
                                .foregroundColor(i == active ? .white : .white.opacity(0.45))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .id(i)
                                .animation(.easeOut(duration: 0.25), value: active)
                        }
                        Color.clear.frame(height: 160).id(9999)
                    }
                    .padding(.horizontal, 26)
                }
                .onChange(of: active) { a in
                    guard a >= 0 else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(a, anchor: .center)
                    }
                }
                .onAppear {
                    // 打开时先对准当前进度
                    let now = VRLyric.activeIndex(in: lines, at: player.position)
                    if now >= 0 { proxy.scrollTo(now, anchor: .center) }
                }
            }
        }
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

    /// 拉榜单清单（静态接口，一次就好），然后默认选第一份
    private func loadChartsIfNeeded() {
        guard !chartsLoaded else { return }
        chartsLoaded = true
        MusicAPI.charts { result in
            switch result {
            case .success(let list):
                chartList = list
                if chartId.isEmpty {
                    loadChart(list.first?.id ?? "3778678")
                }
            case .failure:
                loadChart("3778678")   // 清单拿不到也直接试热歌榜
            }
        }
    }

    /// 榜单指纹：用来对比「后台刷新」和「缓存/当前显示」是否真的变了。
    /// 榜单每日更新，绝大多数时候两次拉取完全一致 —— 一致就什么都不动，
    /// 避免打开面板时列表闪一下重排（封面图重新加载会像「闪屏」）。
    private static func chartFingerprint(_ tracks: [VRChartTrack]) -> String {
        tracks.map { $0.id }.joined(separator: ",")
    }

    /// 拉一份榜单曲目：本地缓存秒出 → 后台刷新 → 内容有变化才替换。
    /// 服务端还有一层 30 分钟缓存，所以即使反复进面板也几乎不耗 GD 额度。
    private func loadChart(_ id: String) {
        chartTask?.cancel()
        chartId = id

        // 1) 缓存优先：立即渲染，绝不转圈
        if let cached = VRChartCache.load(id), !cached.tracks.isEmpty {
            chartTracks = cached.tracks
            chartState = .idle
        } else {
            chartState = .loading   // 完全没来过才有这个状态
        }

        // 2) 后台刷新（静默：失败不打断已显示的内容）
        chartTask = MusicAPI.chart(id) { result in
            guard chartId == id else { return }   // 期间已切到别的榜
            switch result {
            case .success(let detail):
                guard detail.ok else {
                    if chartTracks.isEmpty {
                        chartState = .failed(detail.msg ?? "榜单拉取失败")
                    }
                    return
                }
                if Self.chartFingerprint(detail.tracks) != Self.chartFingerprint(chartTracks) {
                    chartTracks = detail.tracks
                    VRChartCache.save(detail)
                }
                chartState = .idle
            case .failure(let err):
                if (err as NSError).code == NSURLErrorCancelled { return }
                if chartTracks.isEmpty {
                    chartState = .failed(err.localizedDescription)
                }
                // 已有缓存内容就静默忽略 —— 旧榜单比报错卡片好用
            }
        }
    }

    /// 拉当前歌的歌词（在线歌才有）
    private func loadLyricIfNeeded() {
        guard let song = state.currentSong, let libId = song.libraryId, !libId.isEmpty else {
            lyricText = nil
            return
        }
        guard lyricForLibraryId != libId else { return }
        lyricForLibraryId = libId
        lyricText = nil
        guard libId.hasPrefix("gd|") else { return }   // 本地曲库没有歌词
        lyricLoading = true
        lyricTask?.cancel()
        lyricTask = MusicAPI.lyric(libraryId: libId) { result in
            lyricLoading = false
            switch result {
            case .success(let raw): lyricText = raw
            case .failure: lyricText = ""   // 空串 = 拿不到，显示兜底文案
            }
        }
    }

    private func runSearch(_ q: String) {
        searchState = .loading
        let key = q.trimmingCharacters(in: .whitespaces)
        // 序号 + 取消：保证"界面上的结果"永远属于"最后一次输入"。
        // 光靠防抖不够 —— 防抖只取消那个还没到点的定时器，已经在飞的网络请求不会停，
        // 于是敲得快一点就会有 3~4 个请求同时跑，先回来的旧关键词结果会先闪一下。
        searchSeq += 1
        let seq = searchSeq
        searchDataTask?.cancel()
        searchDataTask = MusicAPI.search(key) { result in
            guard seq == searchSeq else { return }   // 迟到的旧结果，丢掉
            switch result {
            case .success(let list):
                results = list
                searchState = list.isEmpty ? .empty : .idle
            case .failure(let err):
                // 我们自己 cancel 掉的那次不算失败，不弹错误
                if (err as NSError).code == NSURLErrorCancelled { return }
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
