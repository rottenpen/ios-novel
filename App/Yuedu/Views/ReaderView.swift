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
    @State private var forward = true

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
                        .lineLimit(1)
                        .frame(height: 20)
                        // 与正文左边缘对齐，不再居中
                        .frame(maxWidth: .infinity, alignment: .leading)
                    page(layout: layout)
                        .frame(width: layout.width, height: layout.height)
                    HStack {
                        // 目录位置，不写成"第 N 章"：书源目录含卷末感言等非正文条目，
                        // 位置序号与标题里的作品章号本就不同，并列显示会被误读为错位。
                        Text("\(currentIndex + 1) / \(chapters.count)")
                        Spacer()
                        if let pages = reader.pagination {
                            Text("\(reader.pageIndex + 1) / \(pages.ranges.count) 页")
                        }
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
                if showControls { controlOverlay }
            }
            .task(id: layout) {
                startSession()
                reader.configure(layout)
            }
        }
        .statusBarHidden(true)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            reader.stop()
            shelf.flush()
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active && keepScreenOn
            if phase != .active { shelf.flush() }
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
                renderedPage(pages)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.text)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { location in
            if showControls { withAnimation(DS.Motion.quick) { showControls = false } }
            else if location.x < layout.width * 0.3 { turn(-1) }
            else if location.x > layout.width * 0.7 { turn(1) }
            else { withAnimation(DS.Motion.quick) { showControls = true } }
        }
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height),
                  abs(value.translation.width) > 35 else { return }
            turn(value.translation.width < 0 ? 1 : -1)
        })
    }

    @ViewBuilder
    private func pageContent(_ pages: TextPagination) -> some View {
        if pages.text.isEmpty {
            Text("本章暂无正文").foregroundStyle(theme.text.opacity(0.6))
        } else {
            TextPageView(pagination: pages, page: reader.pageIndex, color: theme.text)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing)
        )
    }

    private func renderedPage(_ pages: TextPagination) -> some View {
        let pageNumber = reader.pageIndex
        let label = pages.text.isEmpty ? "本章暂无正文" : pages.text(at: pageNumber)
        let visual = pageContent(pages)
            .id("\(currentIndex)-\(pageNumber)")
            .transition(pageTransition)
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
            .contextMenu {
                Button {
                    UIPasteboard.general.string = pages.text(at: pageNumber)
                } label: {
                    Label("复制本页正文", systemImage: "doc.on.doc")
                }
            }
    }

    private func turn(_ direction: Int) {
        forward = direction > 0
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { reader.turn(direction) }
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
