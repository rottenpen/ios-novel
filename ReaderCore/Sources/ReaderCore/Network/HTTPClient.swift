// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// HTTP 响应。
public struct StrResponse: Sendable {
    /// 最终 URL（跟随重定向后）
    public var url: String
    public var body: String?
    public var statusCode: Int
    public var headers: [String: String]
    /// 原始字节，图片 / 需要自行解码的场景使用
    public var data: Data?

    public init(
        url: String,
        body: String?,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        data: Data? = nil
    ) {
        self.url = url
        self.body = body
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

public enum HTTPError: LocalizedError {
    case invalidURL(String)
    case emptyBody(String)
    case decodeFailed(String)
    case statusCode(Int, String)
    case concurrentLimited(String)
    case insecureRedirect

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url): return "URL 格式错误：\(URL(string: url)?.host ?? "未知站点")"
        case let .emptyBody(url): return "未获取到网页内容：\(URL(string: url)?.host ?? "未知站点")"
        case let .decodeFailed(url): return "网页内容解码失败：\(URL(string: url)?.host ?? "未知站点")"
        case let .statusCode(code, url): return "请求失败（HTTP \(code)）：\(URL(string: url)?.host ?? "未知站点")"
        case .insecureRedirect: return "已阻止从 HTTPS 跳转到不安全的 HTTP 地址"
        case let .concurrentLimited(name): return "书源「\(name)」触发并发限制，请稍后重试"
        }
    }
}

/// 书源并发限流器。
///
/// concurrentRate 两种语义：
/// - `"1000"`：单线程串行，每次请求间隔至少 1000ms
/// - `"5/1000"`：1000ms 窗口内最多 5 次请求
actor ConcurrentLimiter {
    static let shared = ConcurrentLimiter()

    private struct Record {
        var windowStart: Date
        var count: Int
    }

    private var records: [String: Record] = [:]

    /// 请求前等待，返回需要休眠的秒数（调用方负责 sleep）
    func waitTime(forKey key: String, limit: (count: Int, intervalMillis: Int)) -> TimeInterval {
        let now = Date()
        let interval = TimeInterval(limit.intervalMillis) / 1000

        guard var record = records[key] else {
            records[key] = Record(windowStart: now, count: 1)
            return 0
        }

        let elapsed = now.timeIntervalSince(record.windowStart)
        if elapsed >= interval {
            // 窗口已过期，重开窗口
            records[key] = Record(windowStart: now, count: 1)
            return 0
        }

        if record.count < limit.count {
            record.count += 1
            records[key] = record
            return 0
        }

        // 窗口内配额用尽，等到下个窗口
        let wait = interval - elapsed
        records[key] = Record(windowStart: now.addingTimeInterval(wait), count: 1)
        return wait
    }
}

/// 每个请求独立跟踪重定向，避免多次跳转重新带回最初的认证信息。
final class RedirectHandler: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var current: URLRequest
    private var rejected = false
    private let cookieStore: CookieStore
    private let usesCookies: Bool

    init(request: URLRequest, cookieStore: CookieStore, usesCookies: Bool) {
        current = request
        self.cookieStore = cookieStore
        self.usesCookies = usesCookies
    }

    var rejectedDowngrade: Bool { lock.withLock { rejected } }

    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    static func redirect(current: URLRequest, response: HTTPURLResponse, proposed: URLRequest) -> URLRequest? {
        guard let target = proposed.url else { return nil }
        // 禁止 HTTPS 降级，避免正文或凭据转为明文传输。
        guard !(response.url?.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http") else { return nil }
        let same = sameOrigin(response.url, target)
        var next = proposed
        let method = current.httpMethod?.uppercased() ?? "GET"
        let keepBody = [307, 308].contains(response.statusCode) || (same && [301, 302].contains(response.statusCode))
        if keepBody {
            next.httpMethod = method
            next.httpBody = current.httpBody
        } else if response.statusCode == 303 && method != "HEAD" {
            next.httpMethod = "GET"
            next.httpBody = nil
        }
        if same {
            for (key, value) in current.allHTTPHeaderFields ?? [:] where next.value(forHTTPHeaderField: key) == nil {
                next.setValue(value, forHTTPHeaderField: key)
            }
        } else {
            // 自定义请求头也可能含令牌，跨站仅保留内容协商和编码所需的头。
            let allowed: Set<String> = ["accept", "accept-language", "accept-encoding", "user-agent", "content-type", "content-length"]
            for key in (next.allHTTPHeaderFields ?? [:]).keys where !allowed.contains(key.lowercased()) {
                next.setValue(nil, forHTTPHeaderField: key)
            }
        }
        if next.httpBody == nil {
            next.setValue(nil, forHTTPHeaderField: "Content-Length")
            next.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        return next
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let next: URLRequest? = lock.withLock {
            if usesCookies, let address = response.url?.absoluteString,
               let cookies = response.value(forHTTPHeaderField: "Set-Cookie") {
                cookieStore.merge(address, setCookie: cookies)
            }
            guard var next = Self.redirect(current: current, response: response, proposed: request) else {
                rejected = true
                return nil
            }
            if usesCookies, let target = next.url {
                let cookie = cookieStore.get(target.absoluteString)
                next.setValue(cookie.isEmpty ? nil : cookie, forHTTPHeaderField: "Cookie")
            }
            current = next
            return next
        }
        completionHandler(next)
    }
}

/// HTTP 客户端。
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession
    private let cookieStore: CookieStore

    public init(timeout: TimeInterval = 30, cookieStore: CookieStore = .shared) {
        self.cookieStore = cookieStore
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpShouldSetCookies = false  // Cookie 由 CookieStore 自行管理
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config)
    }

    /// 发起请求。charset 为书源指定的强制字符集（可空则自动探测）。
    public func request(
        url: String,
        method: String = "GET",
        body: String? = nil,
        headers: [String: String] = [:],
        charset: String? = nil,
        retry: Int = 0,
        source: BookSource? = nil
    ) async throws -> StrResponse {
        // 并发限流
        if let source, let limit = source.concurrentLimit {
            let wait = await ConcurrentLimiter.shared.waitTime(
                forKey: source.bookSourceUrl, limit: limit
            )
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }

        guard let requestURL = URL(string: url) else {
            throw HTTPError.invalidURL(url)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method.uppercased()
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(AppConstants.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        // 附加已保存的 Cookie
        if source?.enabledCookieJar ?? false {
            let cookie = cookieStore.get(url)
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }
        if let body, !body.isEmpty, request.httpMethod != "GET" {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(
                    "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
                )
            }
            // POST body 需按目标站点字符集编码，否则中文关键词会乱码
            let encoding = JSEngine.encoding(from: charset) ?? .utf8
            request.httpBody = body.data(using: encoding) ?? body.data(using: .utf8)
        }

        var lastError: Error?
        // retry 语义总尝试次数 = retry + 1
        for attempt in 0...max(0, retry) {
            try Task.checkCancellation()
            let redirect = RedirectHandler(request: request, cookieStore: cookieStore, usesCookies: source?.enabledCookieJar ?? false)
            do {
                let (data, response) = try await session.data(for: request, delegate: redirect)
                if redirect.rejectedDowngrade { throw HTTPError.insecureRedirect }
                let http = response as? HTTPURLResponse
                let statusCode = http?.statusCode ?? 200
                let finalURL = http?.url?.absoluteString ?? url

                var headerMap: [String: String] = [:]
                if let fields = http?.allHeaderFields {
                    for (key, value) in fields {
                        headerMap[String(describing: key)] = String(describing: value)
                    }
                }
                // 保存 Cookie
                if source?.enabledCookieJar ?? false,
                   let setCookie = http?.value(forHTTPHeaderField: "Set-Cookie") {
                    cookieStore.merge(finalURL, setCookie: setCookie)
                }

                guard (200..<400).contains(statusCode) else {
                    throw HTTPError.statusCode(statusCode, url)
                }

                let contentType = http?.value(forHTTPHeaderField: "Content-Type")
                let text = NetworkUtils.decode(
                    data: data, contentType: contentType, forcedCharset: charset
                )
                return StrResponse(
                    url: finalURL,
                    body: text,
                    statusCode: statusCode,
                    headers: headerMap,
                    data: data
                )
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if case HTTPError.insecureRedirect = error { throw error }
                lastError = error
                if attempt < max(0, retry) {
                    // 退避重试，避免瞬时失败直接放弃
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
            }
        }
        throw lastError ?? HTTPError.emptyBody(url)
    }

    /// 下载二进制（封面图等）
    public func data(url: String, headers: [String: String] = [:]) async throws -> Data {
        guard let requestURL = URL(string: url) else { throw HTTPError.invalidURL(url) }
        var request = URLRequest(url: requestURL)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(AppConstants.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let redirect = RedirectHandler(request: request, cookieStore: cookieStore, usesCookies: false)
        let (data, response) = try await session.data(for: request, delegate: redirect)
        if redirect.rejectedDowngrade { throw HTTPError.insecureRedirect }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.statusCode(http.statusCode, url)
        }
        return data
    }
}

/// 供书源 JS 同步调用的 HTTP 桥。
///
/// 书源 JS（`java.ajax` / `java.get` / `java.post`）按书源接口约定同步返回，
/// JS 侧写法依赖这一点。这里用信号量把异步请求转成同步。
///
/// 注意：调用方必须保证不在承载该异步任务的线程上阻塞。本项目所有规则解析都在
/// 专用后台线程执行（见 `RuleExecutor`），因此不会死锁；不要在主线程直接调用。
public final class SyncHTTP: @unchecked Sendable {
    public static let shared = SyncHTTP()

    private let timeout: TimeInterval = 30

    /// 执行带规则的请求（url 可能带 `,{...}` 选项）
    public func requestString(rule: String, source: BookSource?) -> String? {
        let analyzed = try? AnalyzeUrl(mUrl: rule, source: source)
        guard let analyzed else { return nil }
        return blocking { [analyzed] in
            let response = try await analyzed.getStrResponse()
            return response.body
        }
    }

    /// 执行简单请求，返回 JS 侧可读的 { body, url, statusCode } 结构
    public func request(
        url: String,
        method: String,
        body: String?,
        headers: [String: String]?,
        source: BookSource?
    ) -> [String: Any]? {
        var mutableHeaders = source?.headerMap() ?? ["User-Agent": AppConstants.defaultUserAgent]
        if let headers {
            mutableHeaders.merge(headers) { _, new in new }
        }
        // 定型为常量后再进入并发闭包
        let headerMap = mutableHeaders
        return blocking {
            let response = try await HTTPClient.shared.request(
                url: url, method: method, body: body,
                headers: headerMap, source: source
            )
            return [
                "body": response.body ?? "",
                "url": response.url,
                "statusCode": response.statusCode
            ]
        }
    }

    /// 异步转同步。超时返回 nil，避免书源 JS 卡死整个解析流程。
    private func blocking<T>(_ operation: @escaping @Sendable () async throws -> T?) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            do {
                box.value = try await operation()
            } catch {
                JSLog.shared.append("同步请求失败：\(error.localizedDescription)")
            }
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            JSLog.shared.append("同步请求超时")
            return nil
        }
        return box.value
    }
}

/// 跨线程传值容器。写入发生在 semaphore.signal() 之前，读取在 wait() 之后，
/// 由信号量建立 happens-before 关系，故无需额外加锁。
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
