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

/// 按屏幕逐页阅读，保留章内文字位置并支持跨章翻页。
struct ReaderView: View {
    let book: Book
    let chapters: [BookChapter]
    let onSourceChange: (Book, [BookChapter], Int) -> Void

    @EnvironmentObject private var shelf: BookshelfRepository
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("reader.themeId") private var themeId = "paper"
    @AppStorage("reader.fontSize") private var fontSize: Double = 19
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 9
    @AppStorage("reader.pageMargin") private var pageMargin: Double = 20
    @AppStorage("reader.keepScreenOn") private var keepScreenOn = true

    @StateObject private var reader: ReadingSession
    @State private var showControls = false
    @State private var showSettings = false
    @State private var showCatalog = false
    @State private var showSourceSwitch = false
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var settlingOffset: Double?
    @State private var settlingID = UUID()
    @State private var showCopyActions = false
    @State private var copyText = ""

    private var currentIndex: Int { reader.chapterIndex }
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
                fontSize: min(30, max(14, fontSize)), lineSpacing: min(20, max(2, lineSpacing))
            )
            ZStack {
                theme.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(chapters[safe: currentIndex]?.title ?? "正文")
                        .font(.caption).foregroundStyle(theme.text.opacity(0.6))
                        .lineLimit(1).frame(height: 20)
                    page(layout: layout)
                        .frame(width: layout.width, height: layout.height)
                    HStack {
                        Text("第 \(currentIndex + 1) / \(chapters.count) 章")
                        Spacer()
                        if let pages = reader.pagination {
                            Text("\(reader.pageIndex + 1) / \(pages.ranges.count) 页")
                        }
                    }
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(theme.text.opacity(0.6)).frame(height: 16)
                }
                .padding(.horizontal, margin).padding(.vertical, 12)
                if showControls { controlOverlay }
            }
            .task(id: layout) {
                resetDrag()
                startSession()
                reader.configure(layout)
            }
        }
        .statusBarHidden(true)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
        .onDisappear {
            resetDrag()
            UIApplication.shared.isIdleTimerDisabled = false
            reader.stop()
            shelf.flush()
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active && keepScreenOn
            if phase != .active { resetDrag(); shelf.flush() }
        }
        .onChange(of: reader.pagination.map(ObjectIdentifier.init)) { _, _ in resetDrag() }
        .confirmationDialog("正文操作", isPresented: $showCopyActions, titleVisibility: .hidden) {
            Button("复制本页正文") { UIPasteboard.general.string = copyText }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showCatalog) { catalogSheet }
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

    @ViewBuilder
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
            TextPageView(pagination: pages, page: page, color: theme.text)
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
        VStack {
            // 顶栏
            HStack(spacing: DS.Spacing.lg) {
                Button { shelf.flush(); dismiss() } label: {
                    Image(systemName: "chevron.left")
                }.accessibilityLabel("退出阅读")
                Text(book.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Button { showSourceSwitch = true } label: {
                    Label("换源", systemImage: "arrow.triangle.swap")
                        .font(.subheadline)
                }.accessibilityIdentifier("reader.changeSource")
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

            Spacer()

            // 底栏：章节进度
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
                Slider(
                    value: Binding(
                        get: { Double(currentIndex) },
                        set: { goTo(Int($0.rounded())) }
                    ),
                    in: 0...Double(max(0, chapters.count - 1)),
                    step: 1
                )
                .tint(DS.accent)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
            .background(.bar)
        }
        .transition(.opacity)
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
                }

                Section {
                    Toggle("阅读时常亮", isOn: $keepScreenOn)
                        .onChange(of: keepScreenOn) { _, newValue in
                            UIApplication.shared.isIdleTimerDisabled = newValue
                        }
                }

                Section("预览") {
                    Text("　　这是一段用于预览当前排版效果的示例文字，可据此调整字号与行距到最舒适的状态。")
                        .font(.system(size: fontSize, design: .serif))
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
            return raw.replacingOccurrences(of: "<img[^>]*>", with: "［图片］", options: .regularExpression)
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
