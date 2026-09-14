import SwiftUI
import ReaderCore
import UniformTypeIdentifiers

/// 书源管理页：导入、分组筛选、启停、调试、删除。
struct BookSourceView: View {
    @EnvironmentObject private var repo: BookSourceRepository

    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var showImport = false
    @State private var showFileImporter = false
    @State private var importURL = ""
    @State private var importText = ""
    @State private var importTab = 0
    @State private var isImporting = false
    @State private var toast: String?
    @State private var toastIsError = false
    @State private var debugSource: BookSource?

    private var filtered: [BookSource] {
        var list = repo.search(keyword: searchText)
        if let selectedGroup {
            list = list.filter { $0.groups.contains(selectedGroup) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if repo.sources.isEmpty {
                    EmptyStateView(
                        icon: "square.and.arrow.down",
                        title: "还没有书源",
                        message: "书源决定了能搜到什么书。\n可以从网络地址导入，或粘贴 JSON 内容。",
                        actionTitle: "导入书源",
                        action: { showImport = true }
                    )
                } else {
                    sourceList
                }
            }
            .background(DS.canvas)
            .navigationTitle("书源")
            .searchable(text: $searchText, prompt: "搜索书源名称 / 网址")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showImport = true
                        } label: {
                            Label("导入书源", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("从文件导入", systemImage: "folder")
                        }
                        if !repo.sources.isEmpty {
                            Divider()
                            Button {
                                repo.setEnabledForAll(true, in: filtered)
                                toast = "已启用 \(filtered.count) 个书源"
                            } label: {
                                Label("全部启用", systemImage: "checkmark.circle")
                            }
                            Button {
                                repo.setEnabledForAll(false, in: filtered)
                                toast = "已停用 \(filtered.count) 个书源"
                            } label: {
                                Label("全部停用", systemImage: "xmark.circle")
                            }
                            ShareLink(
                                item: repo.exportJSON(),
                                preview: SharePreview("书源导出.json")
                            ) {
                                Label("导出全部", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if !repo.allGroups.isEmpty {
                    groupBar
                }
            }
            .sheet(isPresented: $showImport) { importSheet }
            .sheet(item: $debugSource) { source in
                SourceDebugView(source: source)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.json, .text, .plainText]
            ) { result in
                handleFileImport(result)
            }
            .toast($toast, isError: toastIsError)
        }
    }

    // MARK: - 分组栏

    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                groupChip(title: "全部 \(repo.sources.count)", isSelected: selectedGroup == nil) {
                    selectedGroup = nil
                }
                ForEach(repo.allGroups, id: \.self) { group in
                    groupChip(title: group, isSelected: selectedGroup == group) {
                        selectedGroup = selectedGroup == group ? nil : group
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
        }
        .background(.bar)
    }

    private func groupChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(isSelected ? DS.accent : DS.accent.opacity(0.1))
                .foregroundStyle(isSelected ? .white : DS.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 列表

    private var sourceList: some View {
        List {
            Section {
                ForEach(filtered) { source in
                    row(source)
                        .listRowBackground(DS.card)
                }
                .onDelete { offsets in
                    repo.delete(at: offsets, in: filtered)
                    toast = "已删除"
                }
            } footer: {
                Text("已启用 \(repo.enabledSources.count) / 共 \(repo.sources.count) 个书源")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ source: BookSource) -> some View {
        HStack(spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(source.bookSourceName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(source.bookSourceUrl)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: DS.Spacing.xs) {
                    if !source.groups.isEmpty {
                        Text(source.groups.prefix(2).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if source.sourceType != .text {
                        Text(typeLabel(source.sourceType)).chipStyle(color: .orange)
                    }
                    if !(source.exploreUrl ?? "").isEmpty {
                        Text("发现").chipStyle()
                    }
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { _ in repo.toggleEnabled(source) }
            ))
            .labelsHidden()
            .tint(DS.accent)
        }
        .padding(.vertical, DS.Spacing.xxs)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                debugSource = source
            } label: {
                Label("调试此书源", systemImage: "ladybug")
            }
            ShareLink(item: repo.exportJSON([source])) {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                repo.delete(source)
                toast = "已删除"
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func typeLabel(_ type: BookSourceType) -> String {
        switch type {
        case .text: return "文本"
        case .audio: return "有声"
        case .image: return "漫画"
        case .file: return "文件"
        }
    }

    // MARK: - 导入面板

    private var importSheet: some View {
        NavigationStack {
            Form {
                Picker("导入方式", selection: $importTab) {
                    Text("网络地址").tag(0)
                    Text("粘贴内容").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if importTab == 0 {
                    Section {
                        TextField("https://.../shuyuan", text: $importURL, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout)
                    } header: {
                        Text("书源订阅地址")
                    } footer: {
                        Text("支持返回 JSON 数组或单个书源对象的地址")
                    }

                    Section("常用书源仓库") {
                        ForEach(PresetSource.all) { preset in
                            Button {
                                importURL = preset.url
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name).font(.subheadline)
                                    Text(preset.note)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Section {
                        Button {
                            importBuiltin()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(DS.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("导入内置书源").font(.subheadline)
                                    Text("已通过真实联网验证，可直接搜索阅读")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        Text("网络书源仓库可能失效，内置书源可作为兜底")
                    }
                } else {
                    Section {
                        TextEditor(text: $importText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 220)
                    } header: {
                        Text("书源 JSON")
                    } footer: {
                        Text("直接粘贴从其他阅读 App 导出的书源 JSON")
                    }
                }
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showImport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("导入") { performImport() }
                            .disabled(importTab == 0 ? importURL.isEmpty : importText.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - 导入动作

    private func performImport() {
        if importTab == 1 {
            let result = repo.importFromText(importText)
            reportImport(result)
            return
        }
        isImporting = true
        Task {
            do {
                let result = try await repo.importFromURL(importURL)
                reportImport(result)
            } catch {
                toastIsError = true
                toast = "导入失败：\(error.localizedDescription)"
            }
            isImporting = false
        }
    }

    private func reportImport(_ result: ImportResult) {
        if result.total > 0 {
            toastIsError = false
            var text = "新增 \(result.added)，更新 \(result.updated)"
            if result.failed > 0 { text += "，失败 \(result.failed)" }
            toast = text
            showImport = false
            importURL = ""
            importText = ""
        } else {
            toastIsError = true
            toast = result.errors.first ?? "没有导入任何书源"
        }
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            // 安全作用域资源，必须成对开关
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                toastIsError = true
                toast = "文件读取失败"
                return
            }
            reportImport(repo.importFromText(text))
        case let .failure(error):
            toastIsError = true
            toast = error.localizedDescription
        }
    }

    /// 导入随 App 打包的内置书源。
    /// 书源可用性取决于站点和规则的当前状态。
    private func importBuiltin() {
        guard let url = Bundle.main.url(forResource: "builtin_sources", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            toastIsError = true
            toast = "内置书源缺失"
            return
        }
        reportImport(repo.importFromText(text))
        showImport = false
    }
}

/// 预置书源仓库（公开可访问的社区维护地址）
struct PresetSource: Identifiable {
    let name: String
    let url: String
    let note: String
    var id: String { url }

    static let all: [PresetSource] = [
        .init(
            name: "XIU2 精品书源",
            url: "https://yuedu.xiu2.xyz/shuyuan",
            note: "社区维护的第三方书源集合"
        ),
        .init(
            name: "社区书源集合",
            url: "https://gitee.com/gekunfei/shuyuan/raw/master/shuyuan",
            note: "第三方维护，导入后可运行自检"
        )
    ]
}
