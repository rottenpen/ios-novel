import Foundation
import Testing
@testable import ReaderCore

/// 引擎层测试：覆盖 TextFormatter / NetworkUtils / BookSource 解码 /
/// AnalyzeUrl 规则处理 / AnalyzeRule 规则调度。
///
/// 这些测试不依赖网络，全部基于内置 HTML / JSON 夹具，保证可重复。

@Suite("TextFormatter 文本处理")
struct TextFormatterTests {

    @Test("去除 HTML 标签并规整缩进")
    func formatStripsTags() {
        let html = "<div>第一段</div><p>第二段</p>"
        let result = TextFormatter.format(html)
        #expect(result.contains("第一段"))
        #expect(result.contains("第二段"))
        #expect(!result.contains("<div>"))
    }

    @Test("nbsp 转空格")
    func formatNbsp() {
        #expect(TextFormatter.format("a&nbsp;&nbsp;b").contains(" "))
        #expect(!TextFormatter.format("a&nbsp;b").contains("&nbsp;"))
    }

    @Test("移除注释")
    func formatRemovesComment() {
        let result = TextFormatter.format("正文<!--广告-->继续")
        #expect(!result.contains("广告"))
    }

    @Test("formatKeepImg 保留 img 并绝对化 src")
    func keepImgAbsolute() {
        let html = "<p>文字</p><img src=\"/pic/1.jpg\">"
        let result = TextFormatter.formatKeepImg(html, redirectUrl: "https://example.com/book/1")
        #expect(result.contains("https://example.com/pic/1.jpg"))
        #expect(result.contains("<img"))
    }

    @Test("formatKeepImg 处理 data-src 懒加载")
    func keepImgDataSrc() {
        let html = "<img data-original=\"https://cdn.test/a.png\" src=\"loading.gif\">"
        let result = TextFormatter.formatKeepImg(html, redirectUrl: "https://example.com/")
        #expect(result.contains("https://cdn.test/a.png"))
    }

    @Test("中文数字转阿拉伯数字")
    func chineseChapterNumber() {
        #expect(TextFormatter.chineseNumbersToArabic("第一百二十三章 测试") == "第123章 测试")
        #expect(TextFormatter.chineseNumbersToArabic("第十章") == "第10章")
        #expect(TextFormatter.chineseNumbersToArabic("第二十一章") == "第21章")
        #expect(TextFormatter.chineseNumbersToArabic("第两千零一章") == "第2001章")
    }

    @Test("中文数字解析边界")
    func chineseToIntBoundary() {
        #expect(TextFormatter.chineseToInt("一千零一") == 1001)
        #expect(TextFormatter.chineseToInt("十") == 10)
        #expect(TextFormatter.chineseToInt("九十九") == 99)
        #expect(TextFormatter.chineseToInt("abc") == nil)
    }

    @Test("HTML 实体反转义")
    func unescape() {
        #expect(TextFormatter.unescapeHTML("a&lt;b&gt;c") == "a<b>c")
        #expect(TextFormatter.unescapeHTML("&#65;&#66;") == "AB")
        #expect(TextFormatter.unescapeHTML("&#x4E2D;") == "中")
        // 无 & 时应原样返回
        #expect(TextFormatter.unescapeHTML("plain") == "plain")
    }

    @Test("字数格式化")
    func wordCount() {
        #expect(TextFormatter.wordCountFormat("500") == "500字")
        #expect(TextFormatter.wordCountFormat("15000") == "1.5万字")
        // 已带单位原样返回
        #expect(TextFormatter.wordCountFormat("100万字") == "100万字")
        #expect(TextFormatter.wordCountFormat("") == "")
    }

    @Test("书名与作者规整")
    func nameAuthorFormat() {
        #expect(TextFormatter.formatBookName("《测试书名》") == "测试书名")
        #expect(TextFormatter.formatBookAuthor("作者：张三") == "张三")
        #expect(TextFormatter.formatBookAuthor("李四 著") == "李四")
    }

    @Test("isTrue 判定")
    func isTrueJudge() {
        #expect(TextFormatter.isTrue("true"))
        #expect(TextFormatter.isTrue("1"))
        #expect(!TextFormatter.isTrue("false"))
        #expect(!TextFormatter.isTrue("0"))
        #expect(!TextFormatter.isTrue(nil))
        #expect(!TextFormatter.isTrue(""))
    }
}

@Suite("NetworkUtils URL 处理")
struct NetworkUtilsTests {

    @Test("相对路径转绝对路径")
    func absoluteFromRelative() {
        let result = NetworkUtils.absoluteURL(
            base: "https://example.com/book/1.html", relative: "/toc/2.html"
        )
        #expect(result == "https://example.com/toc/2.html")
    }

    @Test("已是绝对地址时原样返回")
    func absoluteKeepsAbsolute() {
        let url = "https://other.com/a"
        #expect(NetworkUtils.absoluteURL(base: "https://example.com", relative: url) == url)
    }

    @Test("协议相对地址继承 scheme")
    func protocolRelative() {
        let result = NetworkUtils.absoluteURL(
            base: "https://example.com/a", relative: "//cdn.test/img.png"
        )
        #expect(result == "https://cdn.test/img.png")
    }

    @Test("relative 为空返回 base")
    func emptyRelative() {
        #expect(NetworkUtils.absoluteURL(base: "https://example.com", relative: "") == "https://example.com")
    }

    @Test("提取 baseUrl")
    func baseUrlExtract() {
        #expect(NetworkUtils.baseURL(of: "https://example.com/a/b?c=1") == "https://example.com")
    }

    @Test("提取主域名")
    func subDomain() {
        #expect(NetworkUtils.subDomain(of: "https://www.example.com/a") == "example.com")
        #expect(NetworkUtils.subDomain(of: "https://a.b.example.com.cn/x") == "b.example.com.cn"
            || NetworkUtils.subDomain(of: "https://a.b.example.com.cn/x") == "example.com.cn")
    }

    @Test("JSON / XML 识别")
    func jsonXmlDetect() {
        #expect(NetworkUtils.isJSON("{\"a\":1}"))
        #expect(NetworkUtils.isJSON("[1,2]"))
        #expect(!NetworkUtils.isJSON("<html></html>"))
        #expect(NetworkUtils.isXML("<?xml version=\"1.0\"?><a/>"))
    }

    @Test("GBK 响应解码")
    func decodeGBK() {
        guard let gbk = JSEngine.encoding(from: "gbk"),
              let data = "中文测试".data(using: gbk) else {
            return
        }
        let text = NetworkUtils.decode(
            data: data, contentType: "text/html; charset=gbk", forcedCharset: nil
        )
        #expect(text == "中文测试")
    }

    @Test("无 charset 时按 meta 嗅探")
    func decodeByMeta() {
        let html = "<html><head><meta charset=\"utf-8\"></head><body>内容</body></html>"
        guard let data = html.data(using: .utf8) else { return }
        let text = NetworkUtils.decode(data: data, contentType: nil, forcedCharset: nil)
        #expect(text?.contains("内容") == true)
    }
}

@Suite("BookSource 书源解码")
struct BookSourceDecodeTests {

    /// 规则采用嵌套对象的书源样本
    static let nestedJSON = """
    {
      "bookSourceName": "测试书源",
      "bookSourceUrl": "https://example.com",
      "bookSourceGroup": "测试,男频",
      "bookSourceType": 0,
      "enabled": true,
      "enabledExplore": true,
      "searchUrl": "https://example.com/search?q={{key}}",
      "ruleSearch": {
        "bookList": "class.result-item",
        "name": "tag.h3@text",
        "author": "class.author@text",
        "bookUrl": "tag.a@href"
      },
      "ruleBookInfo": {
        "init": "class.detail",
        "name": "tag.h1@text",
        "tocUrl": "class.toc-link@href"
      },
      "ruleToc": {
        "chapterList": "class.chapter-list@tag.li",
        "chapterName": "tag.a@text",
        "chapterUrl": "tag.a@href"
      },
      "ruleContent": {
        "content": "id.content@html"
      }
    }
    """

    /// 旧版导出格式（规则被转义成字符串）
    static let stringifiedJSON = """
    {
      "bookSourceName": "旧格式书源",
      "bookSourceUrl": "https://old.example.com",
      "enabled": "true",
      "bookSourceType": "0",
      "customOrder": "5",
      "ruleSearch": "{\\"bookList\\":\\"class.item\\",\\"name\\":\\"tag.h3@text\\"}"
    }
    """

    @Test("解码嵌套对象格式")
    func decodeNested() throws {
        let data = Self.nestedJSON.data(using: .utf8)!
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        #expect(source.bookSourceName == "测试书源")
        #expect(source.sourceType == .text)
        #expect(source.isEnabled)
        #expect(source.ruleSearch?.bookList == "class.result-item")
        #expect(source.ruleBookInfo?.initRule == "class.detail")
        #expect(source.ruleToc?.chapterList == "class.chapter-list@tag.li")
        #expect(source.ruleContent?.content == "id.content@html")
    }

    @Test("解码字符串化规则格式")
    func decodeStringified() throws {
        let data = Self.stringifiedJSON.data(using: .utf8)!
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        #expect(source.bookSourceName == "旧格式书源")
        // "true" 字符串应被识别为 true
        #expect(source.isEnabled)
        #expect(source.customOrder == 5)
        // 转义 JSON 字符串应被还原成规则对象
        #expect(source.ruleSearch?.bookList == "class.item")
        #expect(source.ruleSearch?.name == "tag.h3@text")
    }

    @Test("分组拆分")
    func groupSplit() throws {
        let data = Self.nestedJSON.data(using: .utf8)!
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        #expect(source.groups.contains("测试"))
        #expect(source.groups.contains("男频"))
    }

    @Test("编码后可回环解码")
    func roundTrip() throws {
        let data = Self.nestedJSON.data(using: .utf8)!
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(BookSource.self, from: encoded)
        #expect(decoded.bookSourceUrl == source.bookSourceUrl)
        #expect(decoded.ruleSearch?.bookList == source.ruleSearch?.bookList)
        #expect(decoded.ruleToc?.chapterName == source.ruleToc?.chapterName)
    }

    @Test("并发限流配置解析")
    func concurrentRate() throws {
        var source = BookSource()
        source.concurrentRate = "5/1000"
        #expect(source.concurrentLimit?.count == 5)
        #expect(source.concurrentLimit?.intervalMillis == 1000)

        source.concurrentRate = "800"
        #expect(source.concurrentLimit?.count == 1)
        #expect(source.concurrentLimit?.intervalMillis == 800)

        source.concurrentRate = "0"
        #expect(source.concurrentLimit == nil)
    }

    @Test("请求头解析包含默认 UA")
    func headerMap() throws {
        var source = BookSource()
        source.header = "{\"Referer\":\"https://example.com\"}"
        let map = source.headerMap()
        #expect(map["Referer"] == "https://example.com")
        #expect(map["User-Agent"] != nil)
    }

    @Test("请求头支持单引号 JSON（真实书源常见）")
    func headerSingleQuoted() throws {
        var source = BookSource()
        // 真实书源大量使用这种写法，严格 JSON 解析会失败
        source.header = "{'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 8.0.0)', 'Referer': 'http://a.com'}"
        let map = source.headerMap()
        #expect(map["User-Agent"] == "Dalvik/2.1.0 (Linux; U; Android 8.0.0)")
        #expect(map["Referer"] == "http://a.com")
    }

    @Test("请求头支持多行带缩进的 JSON")
    func headerMultiline() throws {
        var source = BookSource()
        source.header = "{\n\t\"Accept\": \"*/*\",\n\t\"Connection\": \"Close\"\n}"
        let map = source.headerMap()
        #expect(map["Accept"] == "*/*")
        #expect(map["Connection"] == "Close")
    }
}

@Suite("AnalyzeUrl URL 规则")
struct AnalyzeUrlTests {

    @Test("关键词与分页替换")
    func keyAndPage() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://example.com"
        let analyze = try AnalyzeUrl(
            mUrl: "https://example.com/s?q={{key}}&p={{page}}",
            key: "剑来",
            page: 2,
            baseUrl: "https://example.com",
            source: source
        )
        #expect(analyze.url.contains("剑来"))
        #expect(analyze.url.contains("p=2"))
    }

    @Test("分页 <a,b> 语法按页取值")
    func pagePattern() throws {
        let analyze = try AnalyzeUrl(
            mUrl: "https://example.com/<list_1.html,list_2.html,list_3.html>",
            page: 2,
            baseUrl: "https://example.com"
        )
        #expect(analyze.url.contains("list_2.html"))
    }

    @Test("分页超出范围取最后一项")
    func pageOverflow() throws {
        let analyze = try AnalyzeUrl(
            mUrl: "https://example.com/<p1,p2>",
            page: 9,
            baseUrl: "https://example.com"
        )
        #expect(analyze.url.contains("p2"))
    }

    @Test("解析 POST 选项")
    func postOption() throws {
        let rule = "https://example.com/api,{\"method\":\"POST\",\"body\":\"key=test\"}"
        let analyze = try AnalyzeUrl(mUrl: rule, baseUrl: "https://example.com")
        #expect(analyze.method == "POST")
        #expect(analyze.body == "key=test")
        #expect(analyze.url == "https://example.com/api")
    }

    @Test("解析 headers 与 charset 选项")
    func headerOption() throws {
        let rule = """
        https://example.com/s,{"headers":{"Referer":"https://ref.com"},"charset":"gbk"}
        """
        let analyze = try AnalyzeUrl(mUrl: rule, baseUrl: "https://example.com")
        #expect(analyze.headerMap["Referer"] == "https://ref.com")
        #expect(analyze.charset == "gbk")
    }

    @Test("body 为 JSON 对象时序列化为字符串")
    func jsonBodyOption() throws {
        let rule = "https://example.com/api,{\"method\":\"POST\",\"body\":{\"k\":\"v\"}}"
        let analyze = try AnalyzeUrl(mUrl: rule, baseUrl: "https://example.com")
        #expect(analyze.method == "POST")
        #expect(analyze.body?.contains("\"k\"") == true)
    }

    @Test("相对 URL 依据 baseUrl 绝对化")
    func relativeUrl() throws {
        let analyze = try AnalyzeUrl(
            mUrl: "/book/123.html", baseUrl: "https://example.com/list"
        )
        #expect(analyze.url == "https://example.com/book/123.html")
    }

    @Test("{{js}} 内嵌脚本求值")
    func innerJS() throws {
        let analyze = try AnalyzeUrl(
            mUrl: "https://example.com/p{{1+2}}.html",
            baseUrl: "https://example.com"
        )
        #expect(analyze.url.contains("p3.html"))
    }

    @Test("非法选项 JSON 不影响主体 URL")
    func malformedOption() throws {
        let analyze = try AnalyzeUrl(
            mUrl: "https://example.com/a,{not-json}", baseUrl: "https://example.com"
        )
        #expect(analyze.url == "https://example.com/a")
    }

    @Test("选项支持单引号 JSON（真实书源常见）")
    func singleQuotedOption() throws {
        let rule = "https://example.com/s,{'method':'POST','body':'k=v'}"
        let analyze = try AnalyzeUrl(mUrl: rule, baseUrl: "https://example.com")
        #expect(analyze.method == "POST")
        #expect(analyze.body == "k=v")
    }

    @Test("选项单引号 headers 生效")
    func singleQuotedHeaders() throws {
        let rule = "https://example.com/s,{'headers':{'Referer':'https://ref.com'}}"
        let analyze = try AnalyzeUrl(mUrl: rule, baseUrl: "https://example.com")
        #expect(analyze.headerMap["Referer"] == "https://ref.com")
    }
}

@Suite("AnalyzeRule 规则调度")
struct AnalyzeRuleTests {

    static let listHTML = """
    <html><body>
      <div class="result-item">
        <h3><a href="/book/1.html">剑来</a></h3>
        <span class="author">作者：烽火戏诸侯</span>
        <span class="words">3500000</span>
        <p class="intro">背剑少年下山</p>
        <img class="cover" src="/cover/1.jpg">
      </div>
      <div class="result-item">
        <h3><a href="/book/2.html">遮天</a></h3>
        <span class="author">作者：辰东</span>
        <span class="words">4200000</span>
        <p class="intro">九龙拉棺</p>
        <img class="cover" src="/cover/2.jpg">
      </div>
    </body></html>
    """

    @Test("getElements 取列表并逐项取字段")
    func listFields() {
        let rule = AnalyzeRule()
        rule.setContent(Self.listHTML, baseUrl: "https://example.com")
        rule.setRedirectUrl("https://example.com")

        let items = rule.getElements("class.result-item")
        #expect(items.count == 2)

        rule.setContent(items[0])
        #expect(rule.getString("tag.h3@text") == "剑来")
        #expect(rule.getString("class.author@text") == "作者：烽火戏诸侯")
        // isUrl 时应绝对化
        #expect(rule.getString("tag.a@href", isUrl: true) == "https://example.com/book/1.html")
    }

    @Test("## 正则替换后处理")
    func replaceRegex() {
        let rule = AnalyzeRule()
        rule.setContent(Self.listHTML, baseUrl: "https://example.com")
        let items = rule.getElements("class.result-item")
        rule.setContent(items[0])
        // 去掉「作者：」前缀
        let author = rule.getString("class.author@text##作者：##")
        #expect(author == "烽火戏诸侯")
    }

    @Test("## 替换支持分组引用")
    func replaceWithGroup() {
        let rule = AnalyzeRule()
        rule.setContent("<p id=\"t\">第123章 测试</p>")
        let result = rule.getString("id.t@text##第(\\d+)章##章节$1")
        #expect(result.contains("123"))
    }

    @Test("getStringList 返回多项")
    func stringList() {
        let rule = AnalyzeRule()
        rule.setContent(Self.listHTML, baseUrl: "https://example.com")
        let names = rule.getStringList("class.result-item@tag.h3@text")
        #expect(names?.count == 2)
        #expect(names?.first == "剑来")
    }

    @Test("getStringList isUrl 去重并绝对化")
    func stringListUrls() {
        let rule = AnalyzeRule()
        rule.setContent(Self.listHTML, baseUrl: "https://example.com")
        rule.setRedirectUrl("https://example.com")
        let urls = rule.getStringList("class.result-item@tag.a@href", isUrl: true)
        #expect(urls?.count == 2)
        #expect(urls?.allSatisfy { $0.hasPrefix("https://example.com/book/") } == true)
    }

    @Test("@put / @get 变量传递")
    func putGetVariable() {
        let data = RuleData()
        let rule = AnalyzeRule(ruleData: data)
        rule.setContent(Self.listHTML, baseUrl: "https://example.com")
        let items = rule.getElements("class.result-item")
        rule.setContent(items[0])

        // 先 put 再在另一条规则中 get
        _ = rule.getString("@put:{bookName:tag.h3@text}tag.h3@text")
        #expect(data.getVariable("bookName") == "剑来")
        #expect(rule.get("bookName") == "剑来")
    }

    @Test("@put 宽松 JSON 解析（真实书源常见写法）")
    func putLenientJSON() {
        // 无引号写法
        let a = AnalyzeRule.parsePutJSON("{bookName:tag.h3@text}")
        #expect(a["bookName"] == "tag.h3@text")

        // 标准带引号写法
        let b = AnalyzeRule.parsePutJSON("{\"key\":\"class.a@text\"}")
        #expect(b["key"] == "class.a@text")

        // 多键
        let c = AnalyzeRule.parsePutJSON("{k1:rule1,k2:rule2}")
        #expect(c["k1"] == "rule1")
        #expect(c["k2"] == "rule2")

        // 值中含冒号（XPath 规则）不应被截断
        let d = AnalyzeRule.parsePutJSON("{t:@XPath://div/text()}")
        #expect(d["t"] == "@XPath://div/text()")
    }

    @Test("JSON 规则模式")
    func jsonMode() {
        let json = """
        {"data":{"list":[{"name":"书名A","url":"/a"},{"name":"书名B","url":"/b"}]}}
        """
        let rule = AnalyzeRule()
        rule.setContent(json, baseUrl: "https://example.com")
        let names = rule.getStringList("$.data.list[*].name")
        #expect(names?.count == 2)
        #expect(names?.first == "书名A")
    }

    @Test("@js: 规则执行")
    func jsRule() {
        let rule = AnalyzeRule()
        rule.setContent("<p id=\"t\">hello</p>")
        let result = rule.getString("id.t@text@js:result.toUpperCase()")
        #expect(result == "HELLO")
    }

    @Test("{{js}} 内嵌规则回填")
    func innerJSRule() {
        let rule = AnalyzeRule()
        rule.setContent("<p id=\"t\">世界</p>")
        let result = rule.getString("你好{{@@id.t@text}}")
        #expect(result.contains("世界"))
    }

    @Test("@XPath: 前缀走 XPath 模式")
    func xpathMode() {
        let rule = AnalyzeRule()
        rule.setContent("<html><body><h1>标题</h1></body></html>")
        let result = rule.getString("@XPath://h1/text()")
        #expect(result == "标题")
    }

    @Test("@CSS: 前缀走 CSS 选择器")
    func cssMode() {
        let rule = AnalyzeRule()
        rule.setContent(Self.listHTML)
        let result = rule.getString("@CSS:.result-item h3 a@text")
        #expect(result.contains("剑来"))
    }

    @Test("规则为空返回空字符串")
    func emptyRule() {
        let rule = AnalyzeRule()
        rule.setContent(Self.listHTML)
        #expect(rule.getString(nil) == "")
        #expect(rule.getString("") == "")
    }

    @Test("isUrl 且结果为空时回落 baseUrl")
    func urlFallback() {
        let rule = AnalyzeRule()
        rule.setContent(Self.listHTML, baseUrl: "https://example.com/list")
        let result = rule.getString("class.not-exist@href", isUrl: true)
        #expect(result == "https://example.com/list")
    }

    @Test("规则缓存复用不影响结果")
    func ruleCacheStability() {
        let rule = AnalyzeRule()
        rule.setContent(Self.listHTML)
        let items = rule.getElements("class.result-item")

        rule.setContent(items[0])
        let first = rule.getString("tag.h3@text")
        rule.setContent(items[1])
        let second = rule.getString("tag.h3@text")

        #expect(first == "剑来")
        #expect(second == "遮天")
    }
}

@Suite("JSEngine 书源 JS")
struct JSEngineTests {

    @Test("基础表达式求值")
    func basicEval() {
        let result = JSEngine.shared.evaluate("1 + 2")
        #expect(result as? Int == 3)
    }

    @Test("result 绑定可用")
    func resultBinding() {
        let result = JSEngine.shared.evaluate("result + '!'", result: "hi")
        #expect(result as? String == "hi!")
    }

    @Test("base64 编解码")
    func base64() {
        let encoded = JSEngine.shared.evaluate("java.base64Encode('abc')")
        #expect(encoded as? String == "YWJj")
        let decoded = JSEngine.shared.evaluate("java.base64Decode('YWJj')")
        #expect(decoded as? String == "abc")
    }

    @Test("md5 摘要")
    func md5() {
        let result = JSEngine.shared.evaluate("java.digestHex('abc','MD5')")
        #expect(result as? String == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test("htmlFormat 去标签")
    func htmlFormat() {
        let result = JSEngine.shared.evaluate("java.htmlFormat('<p>abc</p>')")
        #expect((result as? String)?.contains("abc") == true)
    }

    @Test("不支持的能力返回 null 而不崩溃")
    func unsupportedReturnsNull() {
        let result = JSEngine.shared.evaluate("java.queryTTF('x')")
        #expect(result == nil)
    }

    @Test("语法错误不崩溃")
    func syntaxErrorSafe() {
        let result = JSEngine.shared.evaluate("this is not valid js !!!")
        #expect(result == nil)
    }

    @Test("变量 put/get 走 VariableStore")
    func variableStore() {
        let store = VariableStore()
        _ = JSEngine.shared.evaluate("java.put('k','v')", variableStore: store)
        #expect(store.get("k") == "v")
        let got = JSEngine.shared.evaluate("java.get('k')", variableStore: store)
        #expect(got as? String == "v")
    }

    @Test("每次求值使用独立 context 互不污染")
    func contextIsolation() {
        _ = JSEngine.shared.evaluate("var leaked = 42;")
        let result = JSEngine.shared.evaluate("typeof leaked")
        #expect(result as? String == "undefined")
    }
}

@Suite("BookSourceRepository 导入")
struct RepositoryImportTests {

    @Test("导入书源数组")
    @MainActor
    func importArray() {
        // 用临时文件，避免污染真实数据
        let repo = BookSourceRepository(fileName: "test_sources_\(UUID().uuidString).json")
        let json = """
        [
          {"bookSourceName":"源A","bookSourceUrl":"https://a.com"},
          {"bookSourceName":"源B","bookSourceUrl":"https://b.com"}
        ]
        """
        let result = repo.importFromText(json)
        #expect(result.added == 2)
        #expect(repo.sources.count == 2)
    }

    @Test("导入单个书源对象")
    @MainActor
    func importSingle() {
        let repo = BookSourceRepository(fileName: "test_single_\(UUID().uuidString).json")
        let json = "{\"bookSourceName\":\"源C\",\"bookSourceUrl\":\"https://c.com\"}"
        let result = repo.importFromText(json)
        #expect(result.added == 1)
    }

    @Test("重复 URL 视为更新而非新增")
    @MainActor
    func importDuplicate() {
        let repo = BookSourceRepository(fileName: "test_dup_\(UUID().uuidString).json")
        _ = repo.importFromText("[{\"bookSourceName\":\"旧\",\"bookSourceUrl\":\"https://x.com\"}]")
        let result = repo.importFromText(
            "[{\"bookSourceName\":\"新\",\"bookSourceUrl\":\"https://x.com\"}]"
        )
        #expect(result.updated == 1)
        #expect(repo.sources.count == 1)
        #expect(repo.sources.first?.bookSourceName == "新")
    }

    @Test("缺少 URL 的书源计入失败")
    @MainActor
    func importInvalid() {
        let repo = BookSourceRepository(fileName: "test_invalid_\(UUID().uuidString).json")
        let result = repo.importFromText("[{\"bookSourceName\":\"无URL\"}]")
        #expect(result.failed == 1)
        #expect(repo.sources.isEmpty)
    }

    @Test("非法 JSON 返回失败而不抛异常")
    @MainActor
    func importMalformed() {
        let repo = BookSourceRepository(fileName: "test_bad_\(UUID().uuidString).json")
        let result = repo.importFromText("this is not json")
        #expect(result.failed == 1)
    }

    @Test("导出可被重新导入")
    @MainActor
    func exportRoundTrip() {
        let repo = BookSourceRepository(fileName: "test_export_\(UUID().uuidString).json")
        _ = repo.importFromText("[{\"bookSourceName\":\"源E\",\"bookSourceUrl\":\"https://e.com\"}]")
        let exported = repo.exportJSON()

        let repo2 = BookSourceRepository(fileName: "test_export2_\(UUID().uuidString).json")
        let result = repo2.importFromText(exported)
        #expect(result.added == 1)
        #expect(repo2.sources.first?.bookSourceName == "源E")
    }
}
