import Foundation
import Testing
@testable import ReaderCore

@Suite("网络与搜索行为", .serialized)
struct NetworkRegressionTests {
    @Test("跨站重定向不传递认证信息", arguments: [301, 302, 303, 307, 308])
    func crossOriginRedirect(status: Int) async throws {
        let target = try TestHTTPServer { request in
            let payload = ["method": request.method, "body": request.body,
                           "authorization": request.headers["authorization"] ?? "",
                           "cookie": request.headers["cookie"] ?? "",
                           "apiKey": request.headers["x-api-key"] ?? ""]
            let data = try! JSONEncoder().encode(payload)
            return .init(body: String(decoding: data, as: UTF8.self))
        }
        let url = target.baseURL + "/capture"
        let origin = try TestHTTPServer { _ in .init(status: status, headers: ["Location": url]) }
        let response = try await HTTPClient(timeout: 5).request(
            url: origin.baseURL, method: "POST", body: "review=dummy",
            headers: ["Authorization": "Bearer test-only", "Cookie": "session=test-only", "X-API-Key": "test-only"]
        )
        let body = try JSONDecoder().decode([String: String].self, from: Data(try #require(response.body).utf8))
        #expect(body["authorization"] == "")
        #expect(body["cookie"] == "")
        #expect(body["apiKey"] == "")
        #expect(body["method"] == ([307, 308].contains(status) ? "POST" : "GET"))
        #expect(body["body"] == ([307, 308].contains(status) ? "review=dummy" : ""))
    }

    @Test("同站重定向保留兼容请求并正确处理303", arguments: [301, 302, 303, 307, 308])
    func sameOriginRedirect(status: Int) async throws {
        let server = try TestHTTPServer { request in
            if request.target == "/start" { return .init(status: status, headers: ["Location": "/end"]) }
            return .init(body: "\(request.method)|\(request.body)|\(request.headers["authorization"] ?? "")")
        }
        let response = try await HTTPClient(timeout: 5).request(
            url: server.baseURL + "/start", method: "POST", body: "q=test",
            headers: ["Authorization": "Bearer test-only"]
        )
        #expect(response.body == (status == 303 ? "GET||Bearer test-only" : "POST|q=test|Bearer test-only"))
    }

    @Test("Cookie隔离站点、路径和安全属性")
    func cookieScope() {
        let jar = CookieStore()
        jar.set("https://alice.github.io", cookie: "session=alice")
        #expect(jar.get("https://bob.github.io").isEmpty)
        jar.merge("https://www.example.com/account/login", setCookie: "sid=secret; Path=/account; Secure; HttpOnly")
        #expect(jar.get("https://www.example.com/account/page").contains("sid=secret"))
        #expect(!jar.get("https://www.example.com/other").contains("sid="))
        #expect(!jar.get("http://www.example.com/account").contains("sid="))
        #expect(!jar.get("https://sub.www.example.com/account").contains("sid="))
        jar.merge("https://www.example.com/", setCookie: "shared=ok; Domain=example.com; Path=/")
        #expect(jar.get("https://api.example.com/").contains("shared=ok"))
        jar.merge("https://www.example.com/", setCookie: "shared=gone; Domain=example.com; Path=/; Max-Age=0")
        #expect(!jar.get("https://api.example.com/").contains("shared="))
        jar.merge("https://alice.github.io", setCookie: "bad=1; Domain=github.io; Path=/")
        #expect(!jar.get("https://bob.github.io").contains("bad="))
    }

    @Test("JavaScript网络GET与变量读取共存")
    func javaGet() async throws {
        let server = try TestHTTPServer { request in .init(body: request.headers["x-test"] ?? "missing") }
        let url = server.baseURL
        let result = await Task.detached {
            let variables = VariableStore()
            variables.put("k", "saved")
            return JSEngine.shared.evaluate(
                "java.get('k') + ':' + java.get('\(url)', {'X-Test':'ok'}).body",
                variableStore: variables
            ) as? String
        }.value
        #expect(result == "saved:ok")
    }

    @Test("JavaScript结构化输入和独立宿主对象")
    func javaObjects() throws {
        #expect(JSEngine.shared.evaluate("Array.isArray(result) && result[1].n === 3 && result[0] === null", result: [NSNull(), ["n": 3]]) as? Bool == true)
        #expect(JSEngine.shared.evaluate("result.book.name", result: ["book": ["name": "阅读"]]) as? String == "阅读")
        let key = "test-" + UUID().uuidString
        #expect(JSEngine.shared.evaluate("cache.put('\(key)','value'); cache.get('\(key)')") as? String == "value")
        #expect(JSEngine.shared.evaluate("cache !== java && cookie !== java && cache !== cookie") as? Bool == true)
        #expect(JSEngine.shared.evaluate("cookie.setCookie('https://\(key).invalid', 'a=b'); cookie.getCookie('https://\(key).invalid')") as? String == "a=b")
    }

    @Test("缓存有效期到达后不可读取")
    func cacheExpiry() async throws {
        let key = "expiry-" + UUID().uuidString
        _ = JSEngine.shared.evaluate("cache.put('\(key)','value',1)")
        #expect(JSEngine.shared.evaluate("cache.get('\(key)')") as? String == "value")
        try await Task.sleep(for: .milliseconds(1100))
        #expect(JSEngine.shared.evaluate("cache.get('\(key)')") == nil)
    }

    @Test("旧搜索结束不覆盖新搜索状态")
    @MainActor func searchReplacement() async throws {
        let server = try TestHTTPServer { request in
            let keyword = URLComponents(string: request.target)?.queryItems?.first?.value ?? ""
            return .init(body: "<div class='book'><h2>\(keyword)</h2><a href='/book'>书</a></div>", delay: keyword == "B" ? 1 : 0.2)
        }
        let json: [String: Any] = ["bookSourceUrl": server.baseURL, "bookSourceName": "本地测试",
                                  "searchUrl": "/search?key={{key}}",
                                  "ruleSearch": ["bookList": "class.book", "name": "tag.h2@text", "bookUrl": "tag.a@href"]]
        let source = try JSONDecoder().decode(BookSource.self, from: JSONSerialization.data(withJSONObject: json))
        let model = SearchModel()
        model.search(keyword: "A", sources: [source])
        try await Task.sleep(for: .milliseconds(100))
        model.search(keyword: "B", sources: [source])
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.isSearching)
        #expect(model.searchedCount == 0)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(!model.isSearching)
        #expect(model.results.map(\.name) == ["B"])
        model.search(keyword: " ", sources: [source])
        #expect(model.results.isEmpty)
        #expect(model.totalCount == 0)
        model.search(keyword: "C", sources: [source], maxConcurrent: 0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.results.map(\.name) == ["C"])
        model.cancel()
    }
    @Test("拒绝HTTPS降级，多跳后不恢复认证头")
    func redirectChain() throws {
        let firstURL = URL(string: "https://first.example/start")!
        var current = URLRequest(url: firstURL)
        current.setValue("secret", forHTTPHeaderField: "Authorization")
        current.setValue("key", forHTTPHeaderField: "X-API-Key")
        let response = HTTPURLResponse(url: firstURL, statusCode: 302, httpVersion: nil, headerFields: nil)!
        #expect(RedirectHandler.redirect(current: current, response: response, proposed: URLRequest(url: URL(string: "http://first.example/end")!)) == nil)
        var proposed = current
        proposed.url = URL(string: "https://second.example/start")!
        let next = try #require(RedirectHandler.redirect(current: current, response: response, proposed: proposed))
        let secondResponse = HTTPURLResponse(url: proposed.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let last = try #require(RedirectHandler.redirect(current: next, response: secondResponse, proposed: URLRequest(url: URL(string: "https://second.example/end")!)))
        #expect(last.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(last.value(forHTTPHeaderField: "X-API-Key") == nil)
    }

    @Test("重定向响应Cookie按目标路径重新选择")
    func redirectCookies() async throws {
        let jar = CookieStore()
        let server = try TestHTTPServer { request in
            if request.target == "/start" {
                return .init(status: 302, headers: ["Location": "/account/end", "Set-Cookie": "sid=local; Path=/account"])
            }
            return .init(body: request.headers["cookie"] ?? "")
        }
        var source = BookSource()
        source.enabledCookieJar = true
        let response = try await HTTPClient(timeout: 5, cookieStore: jar).request(url: server.baseURL + "/start", source: source)
        #expect(response.body == "sid=local")
        #expect(jar.get(server.baseURL + "/other").isEmpty)
    }

}
