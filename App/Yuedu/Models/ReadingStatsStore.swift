import Foundation
import Observation

/// 单日阅读统计
struct DayStat: Codable, Equatable {
    var seconds: Int = 0
    var chapters: Int = 0
}

/// 阅读统计存储文件结构（Documents/stats.json）
struct StatsFile: Codable, Equatable {
    var days: [String: DayStat] = [:]
    /// 最后有阅读记录的一天（yyyy-MM-dd），用于连续天数计算
    var lastActiveDay: String?
}

/// 阅读统计：每日阅读时长 + 章节数，纯本地 JSON 存储。
///
/// 采集点：ReaderView 会话计时（进入阅读页开始，离开/切后台结算）。
@Observable
@MainActor
final class ReadingStatsStore {
    static let shared = ReadingStatsStore()

    private var file = StatsFile()
    private let fileURL: URL

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let calendar = Calendar.current

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    private static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("stats.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        file = (try? JSONDecoder().decode(StatsFile.self, from: data)) ?? StatsFile()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 记录一次阅读会话：时长（秒）+ 去重章节数。
    func recordReading(seconds: Int, chapters: Int) {
        guard seconds > 0 else { return }
        let day = Self.dayFormatter.string(from: Date())
        var stat = file.days[day] ?? DayStat()
        stat.seconds += seconds
        stat.chapters += max(0, chapters)
        file.days[day] = stat
        file.lastActiveDay = day
        save()
    }

    /// 今日阅读时长（秒）
    var todaySeconds: Int {
        file.days[Self.dayFormatter.string(from: Date())]?.seconds ?? 0
    }

    /// 今日阅读章节数
    var todayChapters: Int {
        file.days[Self.dayFormatter.string(from: Date())]?.chapters ?? 0
    }

    /// 连续阅读天数：从最后活跃日往回数，中间断档即停。
    var streakDays: Int {
        guard let last = file.lastActiveDay,
              let lastDate = Self.dayFormatter.date(from: last) else { return 0 }
        var cursor = lastDate
        var count = 0
        while true {
            let key = Self.dayFormatter.string(from: cursor)
            if file.days[key] != nil {
                count += 1
            } else {
                break
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    /// 累计阅读时长（秒）
    var totalSeconds: Int {
        file.days.values.reduce(0) { $0 + $1.seconds }
    }

    /// 累计阅读章节数
    var totalChapters: Int {
        file.days.values.reduce(0) { $0 + $1.chapters }
    }

    /// 秒数格式化为中文时长：55秒 / 32分钟 / 3小时25分
    static func formatDuration(_ seconds: Int) -> String {
        guard seconds >= 0 else { return "0秒" }
        if seconds < 60 { return "\(seconds)秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)小时" : "\(hours)小时\(mins)分"
    }
}
