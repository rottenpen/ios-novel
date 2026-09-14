// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// 书源导入结果
public struct ImportResult: Sendable {
    public var added: Int
    public var updated: Int
    public var failed: Int
    /// 失败原因样本，用于给用户可读反馈
    public var errors: [String]

    public init(added: Int = 0, updated: Int = 0, failed: Int = 0, errors: [String] = []) {
        self.added = added
        self.updated = updated
        self.failed = failed
        self.errors = errors
    }

    public var total: Int { added + updated }
}

/// 书源仓库：负责书源的持久化、导入、增删改查。
///
/// 存储选型：书源是「整体读入 + 偶发写入」的中等规模数据（数千条），
/// 用单个 JSON 文件 + 内存索引即可，无需引入 SQLite/SwiftData 依赖。
/// 写入采用原子替换，避免中途崩溃导致文件损坏。
@MainActor
public final class BookSourceRepository: ObservableObject {
    public static let shared = BookSourceRepository()

    @Published public private(set) var sources: [BookSource] = []
    @Published public private(set) var isLoading = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.yuedu.source-repo", qos: .utility)

    public init(fileName: String = "book_sources.json") {
        let dir = AppPaths.documents
        self.fileURL = dir.appendingPathComponent(fileName)
        load()
    }

    // MARK: - 读写

    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            sources = []
            return
        }
        do {
            sources = try JSONDecoder().decode([BookSource].self, from: data)
        } catch {
            // 单条损坏不应导致整体丢失：退化为逐条解析
            sources = Self.decodeLenient(data)
        }
        sortSources()
    }

    /// 宽松解析：跳过无法解析的条目，尽量保住其余书源
    private static func decodeLenient(_ data: Data) -> [BookSource] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        var result: [BookSource] = []
        let decoder = JSONDecoder()
        for item in array {
            guard let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let source = try? decoder.decode(BookSource.self, from: itemData) else {
                continue
            }
            result.append(source)
        }
        return result
    }

    public func save() {
        let snapshot = sources
        let url = fileURL
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            // 原子写入：先写临时文件再替换
            let tmp = url.appendingPathExtension("tmp")
            do {
                try data.write(to: tmp, options: .atomic)
                _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } catch {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func sortSources() {
        // 按 customOrder 升序，其次按名称
        sources.sort {
            let lhs = $0.customOrder ?? 0
            let rhs = $1.customOrder ?? 0
            if lhs != rhs { return lhs < rhs }
            return $0.bookSourceName.localizedCompare($1.bookSourceName) == .orderedAscending
        }
    }

    // MARK: - 查询

    public var enabledSources: [BookSource] {
        sources.filter { $0.isEnabled }
    }

    public var exploreSources: [BookSource] {
        sources.filter { $0.isEnabled && $0.isExploreEnabled && !($0.exploreUrl ?? "").isEmpty }
    }

    /// 所有分组，去重后排序
    public var allGroups: [String] {
        var set = Set<String>()
        for source in sources {
            for group in source.groups { set.insert(group) }
        }
        return set.sorted()
    }

    public func source(for url: String) -> BookSource? {
        sources.first { $0.bookSourceUrl == url }
    }

    public func search(keyword: String) -> [BookSource] {
        guard !keyword.isEmpty else { return sources }
        let lower = keyword.lowercased()
        return sources.filter {
            $0.bookSourceName.lowercased().contains(lower)
                || $0.bookSourceUrl.lowercased().contains(lower)
                || ($0.bookSourceGroup ?? "").lowercased().contains(lower)
        }
    }

    // MARK: - 增删改

    public func upsert(_ source: BookSource) {
        if let index = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        sortSources()
        save()
    }

    public func delete(_ source: BookSource) {
        sources.removeAll { $0.bookSourceUrl == source.bookSourceUrl }
        save()
    }

    public func delete(at offsets: IndexSet, in list: [BookSource]) {
        let urls = offsets.map { list[$0].bookSourceUrl }
        sources.removeAll { urls.contains($0.bookSourceUrl) }
        save()
    }

    public func setEnabled(_ enabled: Bool, for source: BookSource) {
        guard let index = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl })
        else { return }
        sources[index].enabled = enabled
        save()
    }

    public func toggleEnabled(_ source: BookSource) {
        setEnabled(!source.isEnabled, for: source)
    }

    public func setEnabledForAll(_ enabled: Bool, in list: [BookSource]) {
        let urls = Set(list.map { $0.bookSourceUrl })
        for index in sources.indices where urls.contains(sources[index].bookSourceUrl) {
            sources[index].enabled = enabled
        }
        save()
    }

    // MARK: - 导入

    /// 从 URL 导入书源（支持单对象与数组）
    public func importFromURL(_ urlString: String) async throws -> ImportResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HTTPError.invalidURL(urlString)
        }
        isLoading = true
        defer { isLoading = false }

        let response = try await HTTPClient.shared.request(url: trimmed)
        guard let body = response.body, !body.isEmpty else {
            throw HTTPError.emptyBody(trimmed)
        }
        return importFromText(body)
    }

    /// 从 JSON 文本导入
    @discardableResult
    public func importFromText(_ text: String) -> ImportResult {
        var result = ImportResult()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            result.failed = 1
            result.errors.append("文本编码错误")
            return result
        }

        // 顶层可能是数组，也可能是单个书源对象
        var items: [Any] = []
        if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            items = array
        } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            items = [object]
        } else {
            result.failed = 1
            result.errors.append("不是合法的 JSON 书源格式")
            return result
        }

        let decoder = JSONDecoder()
        for item in items {
            guard let itemData = try? JSONSerialization.data(withJSONObject: item) else {
                result.failed += 1
                continue
            }
            do {
                let source = try decoder.decode(BookSource.self, from: itemData)
                // 缺少必要字段的书源无法工作，直接判失败
                guard !source.bookSourceUrl.isEmpty else {
                    result.failed += 1
                    if result.errors.count < 5 {
                        result.errors.append("书源缺少 bookSourceUrl")
                    }
                    continue
                }
                var normalized = source
                if normalized.bookSourceName.isEmpty {
                    normalized.bookSourceName = normalized.bookSourceUrl
                }
                if let index = sources.firstIndex(where: {
                    $0.bookSourceUrl == normalized.bookSourceUrl
                }) {
                    sources[index] = normalized
                    result.updated += 1
                } else {
                    sources.append(normalized)
                    result.added += 1
                }
            } catch {
                result.failed += 1
                if result.errors.count < 5 {
                    result.errors.append(error.localizedDescription)
                }
            }
        }
        sortSources()
        save()
        return result
    }

    /// 导出为 JSON 文本
    public func exportJSON(_ list: [BookSource]? = nil) -> String {
        let target = list ?? sources
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(target) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

/// 应用目录，集中管理，便于测试替换
public enum AppPaths {
    public static var documents: URL {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let dir = urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 正文缓存目录
    public static var contentCache: URL {
        let dir = documents.appendingPathComponent("content", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
