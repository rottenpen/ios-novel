import Foundation

/// 使用独立的系统 Cookie 存储，按响应所属站点校验域和公共后缀。
public final class CookieStore: @unchecked Sendable {
    public static let shared = CookieStore()
    private let storage: HTTPCookieStorage
    private let lock = NSLock()

    public init() {
        storage = URLSessionConfiguration.ephemeral.httpCookieStorage!
    }

    private func parsedURL(_ address: String) -> URL? {
        URL(string: address.contains("://") ? address : "https://" + address)
    }

    public func get(_ address: String) -> String {
        guard let url = parsedURL(address) else { return "" }
        return lock.withLock {
            let cookies = (storage.cookies(for: url) ?? []).filter {
                (!$0.isSecure || url.scheme?.lowercased() == "https") && ($0.expiresDate.map { $0 > Date() } ?? true)
            }.sorted {
                $0.path.count == $1.path.count ? $0.name < $1.name : $0.path.count > $1.path.count
            }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    /// 手动传入的 Cookie 没有域属性，仅绑定到指定主机。
    public func set(_ address: String, cookie: String) {
        guard let url = parsedURL(address) else { return }
        remove(address)
        for pair in cookie.split(separator: ";") where pair.contains("=") {
            let secure = url.scheme?.lowercased() == "https" ? "; Secure" : ""
            merge(address, setCookie: pair.trimmingCharacters(in: .whitespaces) + "; Path=/" + secure)
        }
    }

    public func merge(_ address: String, setCookie: String) {
        guard let url = parsedURL(address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        lock.withLock {
            for line in setCookie.components(separatedBy: .newlines) where !line.isEmpty {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": line], for: url)
                storage.setCookies(cookies, for: url, mainDocumentURL: url)
            }
        }
    }

    public func remove(_ address: String) {
        guard let url = parsedURL(address) else { return }
        lock.withLock {
            for cookie in storage.cookies(for: url) ?? [] { storage.deleteCookie(cookie) }
        }
    }

    public var all: [String: String] {
        lock.withLock {
            var result: [String: String] = [:]
            for cookie in storage.cookies ?? [] {
                let key = "\(cookie.isSecure ? "https" : "http")://\(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))\(cookie.path)"
                let pair = "\(cookie.name)=\(cookie.value)"
                result[key] = result[key].map { $0 + "; " + pair } ?? pair
            }
            return result
        }
    }

    public func restore(_ map: [String: String]) {
        lock.withLock { for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) } }
        for (address, value) in map { set(address, cookie: value) }
    }
}
