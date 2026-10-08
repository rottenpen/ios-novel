import SwiftUI
import ReaderCore

/// 阅读器主题
struct ReadTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: Color
    let text: Color

    static let all: [ReadTheme] = [
        .init(id: "paper", name: "纸白", background: Color(hex: 0xF8F6F1), text: Color(hex: 0x2B2B2B)),
        .init(id: "warm", name: "暖黄", background: Color(hex: 0xF5E9D0), text: Color(hex: 0x3A3228)),
        .init(id: "green", name: "护眼", background: Color(hex: 0xCCE8CF), text: Color(hex: 0x2C3A2E)),
        .init(id: "gray", name: "灰白", background: Color(hex: 0xE8E8E8), text: Color(hex: 0x303030)),
        .init(id: "night", name: "夜间", background: Color(hex: 0x1A1A1A), text: Color(hex: 0xB0B0B0)),
        .init(id: "black", name: "纯黑", background: Color(hex: 0x000000), text: Color(hex: 0x9A9A9A))
    ]

    static func theme(for id: String) -> ReadTheme {
        all.first { $0.id == id } ?? all[0]
    }
}

/// 阅读正文可选字体（iOS 自带中文字体）。
struct ReaderFont: Identifiable {
    let name: String
    let postScript: String
    var id: String { postScript }

    static let all: [ReaderFont] = [
        .init(name: "宋体", postScript: "Songti SC"),
        .init(name: "苹方", postScript: "PingFang SC"),
        .init(name: "楷体", postScript: "Kaiti SC"),
        .init(name: "黑体", postScript: "Heiti SC")
    ]
}

/// 按屏幕逐页阅读，保留章内文字位置并支持跨章翻页。
struct ReaderView: View {
    let book: Book
    let chapters: [BookChapter]
    let onSourceChange: (Book, [BookChapter], Int) -> Void

    @EnvironmentObject private var shelf: BookshelfRepository
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @EnvironmentObject private var downloader: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("reader.themeId") private var themeId = "paper"
    @AppStorage("reader.fontSize") private var fontSize: Double = 19
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 9
    @AppStorage("reader.pageMargin") private var pageMargin: Double = 20
    @AppStorage("reader.keepScreenOn") private var keepScreenOn = true
    @AppStorage("reader.fontName") private var fontName = "Songti SC"
    /// 阅读页内亮度覆盖，0 = 不变暗，最多压暗到 0.55
    @AppStorage("reader.dim") private var dim: Double = 0
    /// 阅读模式：false = 翻页，true = 上下滚动
    @AppStorage("reader.scrollMode") private var scrollMode = false
    @State private var showBookmarks = false
    @State private var bookmarkList: [Bookmark] = []

    @StateObject private var reader: ReadingSession
    @StateObject private var imageStore = ImageStore()
    @State private var showControls = false
    @State private var showSettings = false
    @State private var showCatalog = false
    @State private var showSourceSwitch = false
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var settlingOffset: Double?
    @State private var settlingID = UUID()
    @State private var showCopyActions = false
    @State private var copyText = ""
    /// 滚动模式阅读进度（0~1）
    @State private var scrollProgress: Double = 0
    /// 阅读统计：本次会话开始时间
    @State private var sessionStart = Date()
    /// 阅读统计：本次会话浏览过的章节（去重）
    @State private var visitedChapters = Set<Int>()

    private var currentIndex: Int { reader.chapterIndex }

    /// 结算本次阅读会话：时长 >= 3 秒才记账，防误触抖动
    private func settleSession() {
        let elapsed = Int(Date().timeIntervalSince(sessionStart))
        guard elapsed >= 3 else { return }
        ReadingStatsStore.shared.recordReading(seconds: elapsed, chapters: visitedChapters.count)
        visitedChapters.removeAll()
    }

    private var theme: ReadTheme { ReadTheme.theme(for: themeId) }

    init(book: Book, chapters: [BookChapter], startIndex: Int, startPosition: Int = 0,
         onSourceChange: @escaping (Book, [BookChapter], Int) -> Void) {
        self.book = book
        self.chapters = chapters
        self.onSourceChange = onSourceChange
        _reader = StateObject(wrappedValue: ReadingSession(
            chapterCount: chapters.count, startIndex: startIndex, startOffset: startPosition
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            let margin = min(44, max(10, pageMargin))
            let layout = PageLayout(
                width: max(1, geometry.size.width - margin * 2),
                height: max(1, geometry.size.height - 84),
                fontSize: min(30, max(14, fontSize)), lineSpacing: min(20, max(2, lineSpacing)),
                fontName: fontName
            )
            ZStack {
                theme.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(chapters[safe: currentIndex]?.title ?? "正文")
                        .font(.caption).foregroundStyle(theme.text.opacity(0.6))
                        .lineLimit(1)
                        .frame(height: 20)
                        // 与正文左边缘对齐，不再居中
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if scrollMode {
                        scrollReader(layout: layout)
                            .frame(width: layout.width, height: layout.height)
                    } else {
                        page(layout: layout)
                            .frame(width: layout.width, height: layout.height)
                    }
                    HStack {
                        // 目录位置，不写成"第 N 章"：书源目录含卷末感言等非正文条目，
                        // 位置序号与标题里的作品章号本就不同，并列显示会被误读为错位。
                        Text("\(currentIndex + 1) / \(chapters.count)")
                        Spacer()
                        if scrollMode {
                            Text("已读 \(Int(scrollProgress * 100))%")
                        } else if let pages = reader.pagination {
                            Text("\(reader.pageIndex + 1) / \(pages.ranges.count) 页")
                        }
                        ReaderBattery()
                    }
                    // 时钟独立居中，不受两侧文字宽度变化影响
                    .overlay {
                        // 阅读时状态栏隐藏，这里补回当前时间
                        ReaderClock()
                    }
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(theme.text.opacity(0.6)).frame(height: 16)
                }
                .padding(.horizontal, margin).padding(.vertical, 12)
                // 阅读页调光：纯黑覆盖层压暗，不影响点击（allowsHitTesting false）
                if dim > 0 {
                    Color.black.opacity(min(0.55, max(0, dim)))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                if showControls { controlOverlay }
            }
            // 主题切换时正文/背景颜色平滑渐变
            .animation(DS.Motion.gentle, value: theme.id)
            .task(id: layout) {
                resetDrag()
                startSession()
                reader.configure(layout)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
            sessionStart = Date()
            visitedChapters.insert(currentIndex)
        }
        .onDisappear {
            resetDrag()
            UIApplication.shared.isIdleTimerDisabled = false
            reader.stop()
            shelf.flush()
            settleSession()
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active && keepScreenOn
            if phase != .active {
                resetDrag()
                shelf.flush()
                settleSession()
                sessionStart = Date()
            }
        }
        .onChange(of: reader.pagination.map(ObjectIdentifier.init)) { _, _ in resetDrag() }
        .confirmationDialog("正文操作", isPresented: $showCopyActions, titleVisibility: .hidden) {
            Button("复制本页正文") { UIPasteboard.general.string = copyText }
            Button("生成本页书签") { addBookmarkHere() }
            Button("复制章节标题") {
                UIPasteboard.general.string = chapters[safe: currentIndex]?.title ?? ""
                reader.message = "已复制章节标题"
            }
            Button("复制书名") {
                UIPasteboard.general.string = book.name
                reader.message = "已复制书名"
            }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showCatalog) { catalogSheet }
        .sheet(isPresented: $showBookmarks) { bookmarksSheet }
        .sheet(isPresented: $showSourceSwitch) {
            SourceSwitchView(book: book, chapterTitle: chapters[safe: currentIndex]?.title ?? "",
                             chapterIndex: currentIndex) { target, catalog, index, content in
                reader.stop()
                if let updated = shelf.replaceSource(bookUrl: book.bookUrl, with: target,
                                                     chapters: catalog, chapterIndex: index, content: content) {
                    onSourceChange(updated, catalog, index)
                } else {
                    reader.retry()
                    reader.message = "换源未完成，请重新进入阅读后再试"
                }
            }
        }
        .toast($reader.message)
    }

    // MARK: - 上下滚动阅读模式

    /// 滚动位置与内容高度的流式上报（minY 相对滚动容器、总内容高）。
    private struct ScrollMetrics: Equatable {
        var minY: CGFloat = 0
        var contentHeight: CGFloat = 0
    }

    private struct ScrollMetricsKey: PreferenceKey {
        static var defaultValue = ScrollMetrics()
        static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
            value = nextValue()
        }
    }

    private func scrollReader(layout: PageLayout) -> some View {
        let text = reader.pagination?.text ?? ""
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if text.isEmpty && reader.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    ForEach(Array(Self.splitByImages(text, anchors: reader.currentImageAnchors()).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let str):
                            Text(str)
                                .font(Font(PageLayout.font(name: fontName, size: fontSize)))
                                .lineSpacing(lineSpacing)
                                .foregroundStyle(theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .image(let url):
                            AsyncImage(url: URL(string: url)) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFit()
                                } else {
                                    ZStack {
                                        theme.background.opacity(0.6)
                                        ProgressView().controlSize(.small)
                                    }
                                    .frame(height: 160)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                        }
                    }
                }
                if currentIndex < chapters.count - 1 {
                    Button {
                        scrollProgress = 0
                        reader.goToChapter(currentIndex + 1)
                    } label: {
                        Label("下一章", systemImage: "chevron.down.circle")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: DS.Radius.md))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)
                    .padding(.top, 8)
                }
            }
            .padding(.vertical, 12)
            .background(GeometryReader { geo in
                Color.clear.preference(
                    key: ScrollMetricsKey.self,
                    value: ScrollMetrics(minY: geo.frame(in: .named("readerScroll")).minY,
                                         contentHeight: geo.size.height)
                )
            })
        }
        .coordinateSpace(name: "readerScroll")
        .onPreferenceChange(ScrollMetricsKey.self) { metrics in
            let viewport = layout.height
            let content = max(metrics.contentHeight, viewport + 1)
            let maxScroll = content - viewport
            let raw = maxScroll > 0 ? -metrics.minY / maxScroll : 0
            let clamped = min(1, max(0, raw))
            guard abs(clamped - scrollProgress) > 0.005 else { return }
            scrollProgress = clamped
            let len = (text as NSString).length
            reader.markProgress(offset: len > 0 ? Int(clamped * Double(len - 1)) : 0)
        }
        .onChange(of: currentIndex) { _, _ in
            visitedChapters.insert(currentIndex)
            scrollProgress = 0
        }
    }

    private func page(layout: PageLayout) -> some View {
        ZStack {
            if reader.isLoading {
                ProgressView("正在加载正文…").tint(theme.text)
            } else if let error = reader.errorMessage {
                VStack(spacing: 16) {
                    Text(error).font(.footnote).multilineTextAlignment(.center)
                    Button("重新加载") { reader.retry() }.buttonStyle(.bordered)
                    Button("换源") { showSourceSwitch = true }.buttonStyle(.bordered)
                }
            } else if let pages = reader.pagination {
                renderedPage(pages, layout: layout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.text)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { location in
            guard settlingOffset == nil, !showCopyActions else { return }
            if showControls { withAnimation(DS.Motion.quick) { showControls = false } }
            else if location.x < layout.width * 0.3 { turn(-1) }
            else if location.x > layout.width * 0.7 { turn(1) }
            else { withAnimation(DS.Motion.quick) { showControls = true } }
        }
        .gesture(DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, translation, transaction in
                guard settlingOffset == nil, !showCopyActions, !showControls,
                      !reader.isLoading, reader.pagination != nil else { return }
                transaction.animation = nil
                translation = value.translation
            }
            .onEnded { value in finishDrag(value.translation, layout: layout) })
        // 同时识别，不让点击和拖动等待系统 contextMenu 的长按判定。
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45, maximumDistance: 8)
            .onEnded { _ in
                guard settlingOffset == nil, !showControls,
                      let pages = reader.pagination else { return }
                copyText = pages.text(at: reader.pageIndex)
                showCopyActions = true
            })
    }

    @ViewBuilder
    private func pageContent(_ pages: TextPagination, page: Int) -> some View {
        if pages.text.isEmpty {
            Text("本章暂无正文").foregroundStyle(theme.text.opacity(0.6))
        } else {
            TextPageView(
                pagination: pages, page: page, color: theme.text,
                imageProvider: { [weak imageStore] url in imageStore?.image(for: url) },
                imageVersion: imageStore.loadedCount
            )
        }
    }

    private func renderedPage(_ pages: TextPagination, layout: PageLayout) -> some View {
        let pageNumber = reader.pageIndex
        let label = pages.text.isEmpty ? "本章暂无正文" : pages.text(at: pageNumber)
        let offset = reduceMotion ? 0 : settlingOffset ?? PageTurnGesture.offset(
            horizontal: dragTranslation.width, vertical: dragTranslation.height, width: layout.width)
        let visual = ZStack {
            ForEach(-1...1, id: \.self) { relative in
                Group {
                    if pages.ranges.indices.contains(pageNumber + relative) {
                        pageContent(pages, page: pageNumber + relative)
                    } else {
                        Text(relative < 0 ? "上一章" : "下一章")
                            .font(.caption).foregroundStyle(theme.text.opacity(0.6))
                    }
                }
                .frame(width: layout.width, height: layout.height)
                .background(theme.background)
                .offset(x: Double(relative) * layout.width + offset)
                .accessibilityHidden(relative != 0)
            }
        }
        let accessible = visual
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text("第 \(pageNumber + 1) 页，共 \(pages.ranges.count) 页"))
            .accessibilityAction(named: Text("上一页")) { turn(-1) }
            .accessibilityAction(named: Text("下一页")) { turn(1) }
            .accessibilityAction(named: Text("阅读菜单")) { showControls.toggle() }
        return accessible
            .accessibilityScrollAction { (edge: Edge) in
                if edge == Edge.trailing { turn(1) }
                if edge == Edge.leading { turn(-1) }
            }
            .accessibilityAction(named: Text("复制本页正文")) {
                UIPasteboard.general.string = pages.text(at: pageNumber)
            }
    }

    // MARK: - 整本下载（阅读页入口）

    private var downloadingThis: Bool {
        downloader.isDownloading(bookUrl: book.bookUrl)
    }

    private func toggleDownload() {
        if downloadingThis {
            downloader.cancel()
            return
        }
        guard downloader.isDownloading == false else {
            reader.message = "已有下载任务在进行，请稍后再试"
            return
        }
        guard let source = sourceRepo.source(for: book.origin) else {
            reader.message = "找不到对应书源，无法下载"
            return
        }
        guard !chapters.isEmpty else { return }
        downloader.start(book: book, chapters: chapters, source: source, shelf: shelf)
        reader.message = "开始下载整本，可在书架查看进度"
    }

    private func turn(_ direction: Int) {
        resetDrag()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { reader.turn(direction) }
    }

    private func resetDrag() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            settlingID = UUID()
            settlingOffset = nil
        }
    }

    private func finishDrag(_ translation: CGSize, layout: PageLayout) {
        guard settlingOffset == nil, !showCopyActions, !showControls,
              !reader.isLoading, let pages = reader.pagination else { return }
        var direction = PageTurnGesture.direction(horizontal: translation.width, vertical: translation.height)
        if reduceMotion {
            if direction != 0 { turn(direction) }
            return
        }
        // 全书边界只回弹；章内展示已分页的相邻页，跨章仍交给 ReadingSession 加载。
        if direction != 0, !pages.ranges.indices.contains(reader.pageIndex + direction),
           !chapters.indices.contains(currentIndex + direction) {
            reader.turn(direction)
            direction = 0
        }
        let offset = PageTurnGesture.offset(horizontal: translation.width, vertical: translation.height, width: layout.width)
        guard offset != 0 else { return }
        let id = UUID()
        settlingID = id
        settlingOffset = offset
        let chapter = currentIndex
        let page = reader.pageIndex
        // 手指离开后仅补完剩余位移；点击翻页不经过此动画。
        withAnimation(.easeOut(duration: 0.1), completionCriteria: .removed) {
            settlingOffset = direction == 0 ? 0 : -Double(direction) * layout.width
        } completion: {
            guard settlingID == id else { return }
            if reader.pagination === pages, currentIndex == chapter, reader.pageIndex == page, direction != 0 {
                turn(direction)
            } else {
                resetDrag()
            }
        }
    }

    // MARK: - 控制层

    private var controlOverlay: some View {
        VStack(spacing: 0) {
            // 顶栏从顶部滑入
            if showControls {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            // 底栏从底部滑入
            if showControls {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: DS.Spacing.lg) {
            Button { shelf.flush(); dismiss() } label: {
                Image(systemName: "chevron.left")
            }.accessibilityLabel("退出阅读")
            Text(book.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button { toggleDownload() } label: {
                Image(systemName: downloadingThis ? "stop.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(downloadingThis ? DS.highlight : DS.accent)
            }
            .accessibilityLabel(downloadingThis ? "停止下载" : "下载整本")
            Button { showSourceSwitch = true } label: {
                Label("换源", systemImage: "arrow.triangle.swap")
                    .font(.subheadline)
            }.accessibilityIdentifier("reader.changeSource")
            Button { showBookmarks = true } label: {
                Image(systemName: "bookmark")
            }.accessibilityLabel("书签")
            Button { showCatalog = true } label: {
                Image(systemName: "list.bullet")
            }.accessibilityLabel("目录")
            Button { showSettings = true } label: {
                Image(systemName: "textformat.size")
            }.accessibilityLabel("阅读设置")
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(.bar)
    }

    private var bottomBar: some View {
        VStack(spacing: DS.Spacing.sm) {
            HStack {
                Text(chapters[safe: currentIndex]?.title ?? "")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(currentIndex + 1)/\(chapters.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Spacing.md) {
                Button { goTo(currentIndex - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentIndex <= 0)
                .accessibilityLabel("上一章")

                Slider(
                    value: Binding(
                        get: { Double(currentIndex) },
                        set: { goTo(Int($0.rounded())) }
                    ),
                    in: 0...Double(max(0, chapters.count - 1)),
                    step: 1
                )
                .tint(DS.accent)

                Button { goTo(currentIndex + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentIndex >= chapters.count - 1)
                .accessibilityLabel("下一章")
            }
            .tint(DS.accent)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(.bar)
    }

    // MARK: - 设置面板

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("主题") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.md) {
                            ForEach(ReadTheme.all) { item in
                                Button {
                                    themeId = item.id
                                } label: {
                                    VStack(spacing: DS.Spacing.xs) {
                                        RoundedRectangle(cornerRadius: DS.Radius.md)
                                            .fill(item.background)
                                            .frame(width: 52, height: 52)
                                            .overlay(
                                                Text("文")
                                                    .font(.system(size: 20, design: .serif))
                                                    .foregroundStyle(item.text)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: DS.Radius.md)
                                                    .strokeBorder(
                                                        themeId == item.id ? DS.accent : DS.separator,
                                                        lineWidth: themeId == item.id ? 2.5 : 1
                                                    )
                                            )
                                        Text(item.name).font(.caption2)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, DS.Spacing.xs)
                    }
                }

                Section("阅读模式") {
                    Picker("阅读模式", selection: $scrollMode) {
                        Text("翻页").tag(false)
                        Text("上下滚动").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section("排版") {
                    stepperRow(
                        title: "字号", value: $fontSize,
                        range: 14...30, step: 1, unit: ""
                    )
                    stepperRow(
                        title: "行距", value: $lineSpacing,
                        range: 2...20, step: 1, unit: ""
                    )
                    stepperRow(
                        title: "边距", value: $pageMargin,
                        range: 10...44, step: 2, unit: ""
                    )
                    Picker("字体", selection: $fontName) {
                        ForEach(ReaderFont.all) { f in
                            Text(f.name).tag(f.postScript)
                        }
                    }
                }

                Section("亮度") {
                    HStack {
                        Image(systemName: "sun.min")
                            .foregroundStyle(.secondary)
                        Slider(value: $dim, in: 0...0.55)
                            .tint(DS.accent)
                        Image(systemName: "moon")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("阅读时常亮", isOn: $keepScreenOn)
                        .onChange(of: keepScreenOn) { _, newValue in
                            UIApplication.shared.isIdleTimerDisabled = newValue
                        }
                }

                Section("预览") {
                    Text("　　这是一段用于预览当前排版效果的示例文字，可据此调整字号与行距到最舒适的状态。")
                        .font(Font(PageLayout.font(name: fontName, size: fontSize)))
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(theme.text)
                        .padding(.vertical, DS.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(theme.background)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func stepperRow(
        title: String, value: Binding<Double>,
        range: ClosedRange<Double>, step: Double, unit: String
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            Text("\(Int(value.wrappedValue))\(unit)")
                .monospacedDigit()
                .frame(minWidth: 36)
            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - 目录面板

    // MARK: - 书签面板

    private var bookmarksSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        addBookmarkHere()
                    } label: {
                        Label("为当前位置添加书签", systemImage: "bookmark.fill")
                    }
                    .disabled(currentBookmarked)
                }
                if bookmarkList.isEmpty {
                    Text("还没有书签，读到想标记的地方点上面按钮即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Section("已保存 \(bookmarkList.count) 处") {
                        ForEach(bookmarkList) { bm in
                            Button {
                                reader.goToChapter(bm.chapterIndex, offset: bm.position)
                                showBookmarks = false
                            } label: {
                                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                    Text(bm.chapterTitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !bm.excerpt.isEmpty {
                                        Text(bm.excerpt)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                shelf.removeBookmark(bookUrl: book.bookUrl, id: bookmarkList[i].id)
                            }
                            bookmarkList = shelf.bookmarks(for: book.bookUrl)
                        }
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showBookmarks = false }
                }
            }
            .task { bookmarkList = shelf.bookmarks(for: book.bookUrl) }
        }
        .presentationDetents([.medium, .large])
    }

    /// 当前章节+偏移是否已加书签
    private var currentBookmarked: Bool {
        shelf.hasBookmark(bookUrl: book.bookUrl, chapterIndex: currentIndex, position: reader.anchor)
    }

    private func addBookmarkHere() {
        let title = chapters[safe: currentIndex]?.title ?? "第 \(currentIndex + 1) 章"
        let excerpt = reader.pagination?.text(at: reader.pageIndex) ?? ""
        shelf.addBookmark(bookUrl: book.bookUrl, chapterIndex: currentIndex,
                          chapterTitle: title, position: reader.anchor,
                          excerpt: excerpt.trimmingCharacters(in: .whitespacesAndNewlines))
        bookmarkList = shelf.bookmarks(for: book.bookUrl)
        reader.message = "已添加书签"
    }

    private var catalogSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters.indices, id: \.self) { index in
                    Button {
                        goTo(index)
                        showCatalog = false
                    } label: {
                        HStack {
                            Text(chapters[index].title)
                                .font(.subheadline)
                                .foregroundStyle(
                                    index == currentIndex ? DS.accent : .primary
                                )
                                .lineLimit(1)
                            Spacer()
                            if index == currentIndex {
                                Image(systemName: "location.fill")
                                    .font(.caption2)
                                    .foregroundStyle(DS.accent)
                            } else if shelf.hasContent(
                                bookUrl: book.bookUrl, chapterIndex: index
                            ) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .id(index)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
            }
            .navigationTitle("目录 · \(chapters.count) 章")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showCatalog = false }
                }
            }
        }
    }

    // MARK: - 数据

    private func goTo(_ index: Int) {
        reader.goToChapter(index)
    }

    /// 把正文中的 `<img>` 替换为占位符 `\u{FFFC}`，返回清洗后的文本与图片锚点。
    /// - 图片 src 以章节 URL 为基准绝对化
    /// - 锚点 offset 是替换后文本的 UTF-16 偏移，与分页器的字符偏移一致
    private static func parseImages(_ raw: String, baseURL: String) -> (text: String, anchors: [ImageAnchor]) {
        // 先用 TextFormatter 绝对化 src（保留 img 标签）
        let absolutized = TextFormatter.formatKeepImg(raw, redirectUrl: baseURL)
        guard let regex = try? NSRegularExpression(
            pattern: "<img[^>]*>",
            options: [.caseInsensitive]
        ) else { return (raw, []) }

        let ns = absolutized as NSString
        let matches = regex.matches(in: absolutized, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (absolutized, []) }

        var result = ""
        var anchors: [ImageAnchor] = []
        var cursor = 0
        let placeholder = "\u{FFFC}" as NSString
        for match in matches {
            // 匹配之前的文本
            let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += before
            // 提取 src
            let tag = ns.substring(with: match.range)
            let srcRange = (tag as NSString).range(
                of: #"src\s*=\s*"([^"]*)""#,
                options: .regularExpression
            )
            var url = ""
            if srcRange.location != NSNotFound {
                let src = (tag as NSString).substring(with: srcRange)
                url = src.replacingOccurrences(
                    of: #"^src\s*=\s*"|"$"#, with: "", options: .regularExpression
                )
            }
            let offset = (result as NSString).length
            result += placeholder as String
            if !url.isEmpty {
                anchors.append(ImageAnchor(offset: offset, url: url))
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return (result, anchors)
    }

    /// 滚动模式：按图片锚点把正文切成文本/图片块。
    private enum ScrollBlock {
        case text(String)
        case image(String)
    }

    private static func splitByImages(_ text: String, anchors: [ImageAnchor]) -> [ScrollBlock] {
        guard !anchors.isEmpty else { return [.text(text)] }
        let sorted = anchors.sorted { $0.offset < $1.offset }
        let ns = text as NSString
        var blocks: [ScrollBlock] = []
        var cursor = 0
        for anchor in sorted {
            let offset = min(max(0, anchor.offset), ns.length)
            if offset > cursor {
                blocks.append(.text(ns.substring(with: NSRange(location: cursor, length: offset - cursor))))
            }
            if offset < ns.length {
                blocks.append(.image(anchor.url))
            }
            cursor = min(ns.length, offset + 1)
        }
        if cursor < ns.length {
            blocks.append(.text(ns.substring(from: cursor)))
        }
        return blocks
    }

    private func startSession() {
        let repository = shelf
        let sources = sourceRepo
        let currentBook = book
        let catalog = chapters
        reader.start(load: { index in
            let raw: String
            if let cached = repository.loadContent(bookUrl: currentBook.bookUrl, chapterIndex: index) {
                raw = cached
            } else {
                guard let source = sources.source(for: currentBook.origin) else {
                    throw ReaderError.missingSource
                }
                raw = try await WebBook.content(
                    source: source, book: currentBook, chapter: catalog[index],
                    nextChapterUrl: catalog[safe: index + 1]?.url
                )
                try Task.checkCancellation()
                repository.saveContent(raw, bookUrl: currentBook.bookUrl, chapterIndex: index)
            }
            let parsed = Self.parseImages(raw, baseURL: catalog[safe: index]?.url ?? currentBook.bookUrl)
            reader.setImageAnchors(parsed.anchors, forChapter: index)
            imageStore.load(urls: parsed.anchors.map(\.url))
            return parsed.text
        }, onProgress: { index, position in
            repository.updateProgress(
                bookUrl: currentBook.bookUrl, chapterIndex: index,
                chapterTitle: catalog[safe: index]?.title, position: position
            )
            repository.markUpdateSeen(bookUrl: currentBook.bookUrl)
        })
    }

    private enum ReaderError: LocalizedError {
        case missingSource
        var errorDescription: String? { "本章尚未缓存，且找不到对应书源" }
    }

}

extension Array {
    /// 安全下标，越界返回 nil
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 阅读页时钟：阅读时系统状态栏被隐藏，这里显示当前时间。
///
/// 只在跨分钟时刷新，不做每秒轮询；进入前台时立即校正，
/// 避免后台待机后显示停在旧时间。
struct ReaderClock: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // 跟随系统 12/24 小时制
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter
    }()

    var body: some View {
        Text(Self.formatter.string(from: now))
            .accessibilityLabel("当前时间 \(Self.formatter.string(from: now))")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                now = Date()
                // 先对齐到下一个整分钟，之后每分钟刷新一次
                while !Task.isCancelled {
                    let next = Self.nextMinute(after: Date())
                    let gap = next.timeIntervalSinceNow
                    if gap > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                    }
                    guard !Task.isCancelled else { return }
                    now = Date()
                }
            }
    }

    private static func nextMinute(after date: Date) -> Date {
        let calendar = Calendar.current
        guard let next = calendar.nextDate(
            after: date, matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) else {
            return date.addingTimeInterval(60)
        }
        return next
    }
}

/// 阅读页电量标识：状态栏隐藏时补回电量信息。
/// 监听系统电量与充电状态变化；模拟器电量不可用（-1）时显示 "—"。
struct ReaderBattery: View {
    @State private var level: Float = -1
    @State private var charging = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption2)
            Text(level >= 0 ? "\(Int((level * 100).rounded()))%" : "—")
                .font(.caption2).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("电量 \(level >= 0 ? "\(Int((level * 100).rounded()))%" : "未知")")
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryLevelDidChangeNotification
        )) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryStateDidChangeNotification
        )) { _ in refresh() }
    }

    private var iconName: String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 0.75...: return "battery.75"
        case 0.5..<0.75: return "battery.50"
        case 0.25..<0.5: return "battery.25"
        case 0..<0.25: return "battery.0"
        default: return "battery.100"
        }
    }

    private func refresh() {
        let device = UIDevice.current
        charging = device.batteryState == .charging || device.batteryState == .full
        // 模拟器返回 -1：保持未知，显示 "—"
        level = device.batteryLevel
    }
}
