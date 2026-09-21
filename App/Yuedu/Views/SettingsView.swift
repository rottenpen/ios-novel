import SwiftUI
import ReaderCore

/// 设置页：聚合缓存管理、阅读默认排版、启动行为与关于信息。
///
/// 阅读排版键与 `ReaderView` 共用同一批 `reader.*`，改动即时反映到阅读器；
/// 缓存大小与清理复用 `BookshelfRepository` 已有能力。
struct SettingsView: View {
    @EnvironmentObject private var shelf: BookshelfRepository
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @EnvironmentObject private var downloader: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("reader.themeId") private var themeId = "paper"
    @AppStorage("reader.fontSize") private var fontSize: Double = 19
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 9
    @AppStorage("reader.pageMargin") private var pageMargin: Double = 20
    @AppStorage("reader.keepScreenOn") private var keepScreenOn = true
    @AppStorage("shelf.autoResume") private var autoResume = true

    /// 缓存占用字节数，进入时异步计算，避免阻塞界面
    @State private var cacheBytes: Int64 = 0
    @State private var isCalculating = false
    @State private var showClearConfirm = false
    @State private var toast: String?

    private var theme: ReadTheme { ReadTheme.theme(for: themeId) }

    var body: some View {
        NavigationStack {
            Form {
                readingSection
                startupSection
                storageSection
                sourceSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await recalcCache() }
            .toast($toast)
            .confirmationDialog(
                "清除全部缓存？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清除全部缓存", role: .destructive) { clearAllCache() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除所有已下载正文和目录缓存，书架和阅读进度会保留。")
            }
        }
    }

    // MARK: - 阅读排版

    private var readingSection: some View {
        Section("阅读") {
            Picker("主题", selection: $themeId) {
                ForEach(ReadTheme.all) { item in
                    Text(item.name).tag(item.id)
                }
            }
            stepperRow(title: "字号", value: $fontSize, range: 14...30, step: 1)
            stepperRow(title: "行距", value: $lineSpacing, range: 2...20, step: 1)
            stepperRow(title: "边距", value: $pageMargin, range: 10...44, step: 2)
            Toggle("阅读时屏幕常亮", isOn: $keepScreenOn)
        }
    }

    // MARK: - 启动

    private var startupSection: some View {
        Section {
            Toggle("启动后自动续看", isOn: $autoResume)
        } header: {
            Text("启动")
        } footer: {
            Text("打开 App 时自动进入上次阅读的书；关闭后停留在书架。")
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            HStack {
                Text("缓存占用")
                Spacer()
                if isCalculating {
                    ProgressView().controlSize(.small)
                } else {
                    Text(Self.formatBytes(cacheBytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Text("清除全部缓存")
            }
            .disabled(cacheBytes == 0 || isCalculating || downloader.isDownloading)
        } header: {
            Text("存储")
        } footer: {
            if downloader.isDownloading {
                Text("下载进行中，暂不能清除缓存。")
            } else {
                Text("清除后离线正文需要重新下载，书架和阅读进度不受影响。")
            }
        }
    }

    // MARK: - 书源

    private var sourceSection: some View {
        Section("书源") {
            HStack {
                Text("已导入书源")
                Spacer()
                Text("\(sourceRepo.sources.count) 个")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Text("已启用")
                Spacer()
                Text("\(sourceRepo.enabledSources.count) 个")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("阅读 · Yuedu")
                Spacer()
                Text(Self.appVersion)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("书架藏书")
                Spacer()
                Text("\(shelf.books.count) 本")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 组件

    private func stepperRow(
        title: String, value: Binding<Double>,
        range: ClosedRange<Double>, step: Double
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
            Text("\(Int(value.wrappedValue))")
                .monospacedDigit()
                .frame(minWidth: 32)
            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - 逻辑

    private func recalcCache() async {
        isCalculating = true
        cacheBytes = await shelf.cacheSizeAsync()
        isCalculating = false
    }

    private func clearAllCache() {
        shelf.clearAllCache()
        shelf.flush()
        cacheBytes = 0
        toast = "已清除全部缓存"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }
}
