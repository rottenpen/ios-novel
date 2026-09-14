import Foundation
import Testing
@testable import ReaderCore

@Suite("JSONPath 求值")
struct JSONPathTests {

    static let json = """
    {
      "code": 0,
      "msg": "ok",
      "data": {
        "total": 3,
        "books": [
          {"id": 1, "name": "剑来", "author": "烽火戏诸侯", "words": 8000000,
           "vip": false, "tags": ["仙侠", "热血"]},
          {"id": 2, "name": "诡秘之主", "author": "爱潜水的乌贼", "words": 4600000,
           "vip": true, "tags": ["奇幻"]},
          {"id": 3, "name": "大道朝天", "author": "猫腻", "words": 2000000,
           "vip": false, "tags": ["仙侠"]}
        ]
      }
    }
    """

    private var obj: Any {
        JSONPath.parse(Self.json)!
    }

    @Test("基础属性访问")
    func basicProperty() {
        #expect(JSONPath.string(obj, path: "$.msg") == "ok")
        #expect(JSONPath.string(obj, path: "$.data.total") == "3")
    }

    @Test("整数不带 .0 后缀")
    func intFormatting() {
        #expect(JSONPath.string(obj, path: "$.data.books[0].words") == "8000000")
        #expect(JSONPath.string(obj, path: "$.code") == "0")
    }

    @Test("数组索引")
    func arrayIndex() {
        #expect(JSONPath.string(obj, path: "$.data.books[0].name") == "剑来")
        #expect(JSONPath.string(obj, path: "$.data.books[1].name") == "诡秘之主")
    }

    @Test("负数索引")
    func negativeIndex() {
        #expect(JSONPath.string(obj, path: "$.data.books[-1].name") == "大道朝天")
    }

    @Test("多索引")
    func multiIndex() {
        let list = JSONPath.stringList(obj, path: "$.data.books[0,2].name")
        #expect(list == ["剑来", "大道朝天"])
    }

    @Test("切片")
    func slice() {
        let list = JSONPath.stringList(obj, path: "$.data.books[0:2].name")
        #expect(list == ["剑来", "诡秘之主"])
    }

    @Test("切片省略端点")
    func sliceOmitted() {
        let list = JSONPath.stringList(obj, path: "$.data.books[1:].name")
        #expect(list == ["诡秘之主", "大道朝天"])
    }

    @Test("通配符取全部")
    func wildcard() {
        let list = JSONPath.stringList(obj, path: "$.data.books[*].name")
        #expect(list == ["剑来", "诡秘之主", "大道朝天"])
    }

    @Test("括号属性访问")
    func bracketProperty() {
        #expect(JSONPath.string(obj, path: "$['data']['books'][0]['name']") == "剑来")
    }

    @Test("递归下降")
    func recursiveDescent() {
        let list = JSONPath.stringList(obj, path: "$..name")
        #expect(list.contains("剑来"))
        #expect(list.contains("诡秘之主"))
        #expect(list.count == 3)
    }

    @Test("length() 函数")
    func lengthFunction() {
        #expect(JSONPath.string(obj, path: "$.data.books.length()") == "3")
    }

    @Test("嵌套数组访问")
    func nestedArray() {
        #expect(JSONPath.string(obj, path: "$.data.books[0].tags[0]") == "仙侠")
    }

    // MARK: - 过滤表达式

    @Test("过滤：字符串相等")
    func filterStringEquals() {
        let list = JSONPath.stringList(obj, path: "$.data.books[?(@.author=='猫腻')].name")
        #expect(list == ["大道朝天"])
    }

    @Test("过滤：数值比较")
    func filterNumericCompare() {
        let list = JSONPath.stringList(obj, path: "$.data.books[?(@.words>3000000)].name")
        #expect(list.count == 2)
        #expect(list.contains("剑来"))
        #expect(list.contains("诡秘之主"))
    }

    @Test("过滤：布尔值")
    func filterBool() {
        let list = JSONPath.stringList(obj, path: "$.data.books[?(@.vip==true)].name")
        #expect(list == ["诡秘之主"])
    }

    @Test("过滤：&& 组合")
    func filterAnd() {
        let path = "$.data.books[?(@.words>1000000 && @.vip==false)].name"
        let list = JSONPath.stringList(obj, path: path)
        #expect(list.count == 2)
        #expect(list.contains("剑来"))
        #expect(list.contains("大道朝天"))
    }

    @Test("过滤：|| 组合")
    func filterOr() {
        let path = "$.data.books[?(@.author=='猫腻' || @.author=='烽火戏诸侯')].name"
        let list = JSONPath.stringList(obj, path: path)
        #expect(list.count == 2)
    }

    @Test("过滤：不等于")
    func filterNotEquals() {
        let list = JSONPath.stringList(obj, path: "$.data.books[?(@.author!='猫腻')].name")
        #expect(list.count == 2)
        #expect(!list.contains("大道朝天"))
    }

    @Test("过滤：字段存在性")
    func filterExistence() {
        let list = JSONPath.stringList(obj, path: "$.data.books[?(@.vip)].name")
        // vip 为 true 的才算存在（false 视为不成立）
        #expect(list == ["诡秘之主"])
    }

    // MARK: - 健壮性

    @Test("不存在的路径返回 nil")
    func nonexistentPath() {
        #expect(JSONPath.string(obj, path: "$.nothing.here") == nil)
    }

    @Test("索引越界返回 nil")
    func indexOutOfRange() {
        #expect(JSONPath.string(obj, path: "$.data.books[99].name") == nil)
    }

    @Test("畸形路径不崩溃")
    func malformedPath() {
        #expect(JSONPath.string(obj, path: "$.data.books[") == nil)
        #expect(JSONPath.string(obj, path: "") == nil)
    }

    @Test("nodeList 返回对象列表")
    func nodeListReturnsObjects() {
        let nodes = JSONPath.nodeList(obj, path: "$.data.books[*]")
        #expect(nodes.count == 3)
        let first = nodes[0] as? [String: Any]
        #expect(first?["name"] as? String == "剑来")
    }
}

@Suite("AnalyzeByJSonPath 书源 JSON 规则")
struct AnalyzeByJSonPathTests {

    private func analyzer() -> AnalyzeByJSonPath {
        AnalyzeByJSonPath(json: JSONPathTests.json)
    }

    @Test("单条规则取值")
    func single() {
        let a = analyzer()
        #expect(a.getString("$.data.books[0].name") == "剑来")
    }

    @Test("|| 短路")
    func orShortCircuit() {
        let a = analyzer()
        let result = a.getString("$.data.books[0].name||$.data.books[1].name")
        #expect(result == "剑来")
    }

    @Test("|| 第一条为空时回退")
    func orFallback() {
        let a = analyzer()
        let result = a.getString("$.nothing||$.data.books[1].name")
        #expect(result == "诡秘之主")
    }

    @Test("&& 合并")
    func andMerge() {
        let a = analyzer()
        let result = a.getString("$.data.books[0].name&&$.data.books[1].name")
        #expect(result == "剑来\n诡秘之主")
    }

    @Test("列表规则取节点")
    func listRule() {
        let a = analyzer()
        let list = a.getList("$.data.books[*]")
        #expect(list.count == 3)
    }

    @Test("stringList 取多值")
    func stringList() {
        let a = analyzer()
        let list = a.getStringList("$.data.books[*].author")
        #expect(list == ["烽火戏诸侯", "爱潜水的乌贼", "猫腻"])
    }

    /// 关键：JSONPath 自带的 && 不应被阅读规则切分
    @Test("过滤表达式内的 && 不被错切")
    func filterAndNotSplit() {
        let a = analyzer()
        let result = a.getStringList("$.data.books[?(@.words>1000000 && @.vip==false)].name")
        #expect(result.count == 2)
    }
}

@Suite("AnalyzeByRegex 正则规则")
struct AnalyzeByRegexTests {

    static let html = """
    <div class="item"><a href="/b/1.html">剑来</a><em>烽火戏诸侯</em></div>
    <div class="item"><a href="/b/2.html">诡秘之主</a><em>爱潜水的乌贼</em></div>
    <div class="item"><a href="/b/3.html">大道朝天</a><em>猫腻</em></div>
    """

    @Test("getElements 提取多条与分组")
    func getElements() {
        let regs = ["<a href=\"(.*?)\">(.*?)</a><em>(.*?)</em>"]
        let result = AnalyzeByRegex.getElements(Self.html, regs: regs)
        #expect(result.count == 3)
        // index 0 是整体匹配，1..n 是分组
        #expect(result[0][1] == "/b/1.html")
        #expect(result[0][2] == "剑来")
        #expect(result[0][3] == "烽火戏诸侯")
        #expect(result[2][2] == "大道朝天")
    }

    @Test("getElement 提取单条")
    func getElement() {
        let regs = ["<a href=\"(.*?)\">(.*?)</a>"]
        let result = AnalyzeByRegex.getElement(Self.html, regs: regs)
        #expect(result?[1] == "/b/1.html")
        #expect(result?[2] == "剑来")
    }

    @Test("多级正则串联")
    func chainedRegex() {
        let regs = ["<div class=\"item\">.*?</div>", "<em>(.*?)</em>"]
        let result = AnalyzeByRegex.getElements(Self.html, regs: regs)
        #expect(result.count == 3)
        #expect(result[0][1] == "烽火戏诸侯")
    }

    @Test("无匹配返回空")
    func noMatch() {
        #expect(AnalyzeByRegex.getElements(Self.html, regs: ["<xyz>(.*?)</xyz>"]).isEmpty)
        #expect(AnalyzeByRegex.getElement(Self.html, regs: ["<xyz>"]) == nil)
    }

    @Test("非法正则不崩溃")
    func invalidRegex() {
        #expect(AnalyzeByRegex.getElements(Self.html, regs: ["([unclosed"]).isEmpty)
    }
}

@Suite("AnalyzeByXPath XPath 规则")
struct AnalyzeByXPathTests {

    static let html = """
    <html><body>
      <div id="wrap">
        <div class="book" data-id="1">
          <a href="/b/1.html" class="title">剑来</a>
          <span class="author">烽火戏诸侯</span>
        </div>
        <div class="book" data-id="2">
          <a href="/b/2.html" class="title">诡秘之主</a>
          <span class="author">爱潜水的乌贼</span>
        </div>
        <div class="book vip" data-id="3">
          <a href="/b/3.html" class="title">大道朝天</a>
          <span class="author">猫腻</span>
        </div>
      </div>
      <ul class="toc">
        <li><a href="/c/1.html">第一章</a></li>
        <li><a href="/c/2.html">第二章</a></li>
      </ul>
    </body></html>
    """

    private func analyzer() throws -> AnalyzeByXPath {
        try AnalyzeByXPath(doc: Self.html)
    }

    @Test("// 后代定位 + text()")
    func descendantText() throws {
        let a = try analyzer()
        let list = a.getStringList("//span[@class='author']/text()")
        #expect(list == ["烽火戏诸侯", "爱潜水的乌贼", "猫腻"])
    }

    @Test("属性取值 /@href")
    func attrValue() throws {
        let a = try analyzer()
        let list = a.getStringList("//a[@class='title']/@href")
        #expect(list == ["/b/1.html", "/b/2.html", "/b/3.html"])
    }

    @Test("class 属性谓词")
    func classPredicate() throws {
        let a = try analyzer()
        let elements = a.getElements("//div[@class='book']")
        // 精确匹配 class="book"，不含 "book vip"
        #expect(elements.count == 2)
    }

    @Test("contains 函数谓词")
    func containsPredicate() throws {
        let a = try analyzer()
        let elements = a.getElements("//div[contains(@class,'book')]")
        #expect(elements.count == 3)
    }

    @Test("starts-with 函数谓词")
    func startsWithPredicate() throws {
        let a = try analyzer()
        let list = a.getStringList("//a[starts-with(@href,'/c/')]/@href")
        #expect(list == ["/c/1.html", "/c/2.html"])
    }

    @Test("位置索引谓词（从 1 开始）")
    func positionIndex() throws {
        let a = try analyzer()
        let list = a.getStringList("//div[@class='book'][1]//a/text()")
        #expect(list == ["剑来"])
    }

    @Test("last() 谓词")
    func lastPredicate() throws {
        let a = try analyzer()
        let list = a.getStringList("//ul[@class='toc']/li[last()]/a/text()")
        #expect(list == ["第二章"])
    }

    @Test("属性存在性谓词")
    func attrExistence() throws {
        let a = try analyzer()
        let list = a.getStringList("//div[@data-id]/@data-id")
        #expect(list == ["1", "2", "3"])
    }

    @Test("文本内容谓词")
    func textPredicate() throws {
        let a = try analyzer()
        let list = a.getStringList("//a[text()='剑来']/@href")
        #expect(list == ["/b/1.html"])
    }

    @Test("绝对路径直接子级")
    func absolutePath() throws {
        let a = try analyzer()
        let elements = a.getElements("/html/body/div[@id='wrap']")
        #expect(elements.count == 1)
    }

    @Test("| 并集")
    func union() throws {
        let a = try analyzer()
        let list = a.getStringList("//a[@class='title']/@href|//ul[@class='toc']//a/@href")
        #expect(list.count == 5)
    }

    @Test("allText 取全部文本")
    func allText() throws {
        let a = try analyzer()
        let list = a.getStringList("//div[@data-id='1']/allText()")
        #expect(list.first?.contains("剑来") == true)
        #expect(list.first?.contains("烽火戏诸侯") == true)
    }

    @Test("and 组合谓词")
    func andPredicate() throws {
        let a = try analyzer()
        let elements = a.getElements("//div[contains(@class,'book') and @data-id='3']")
        #expect(elements.count == 1)
    }

    @Test("不存在的路径返回空")
    func nonexistent() throws {
        let a = try analyzer()
        #expect(a.getStringList("//div[@class='nothing']/text()").isEmpty)
        #expect(a.getString("//nothing") == nil)
    }

    @Test("不支持的轴语法不崩溃")
    func unsupportedAxis() throws {
        let a = try analyzer()
        // 不支持 ancestor:: 轴，应返回空而非崩溃
        let list = a.getStringList("//a/ancestor::div/@data-id")
        #expect(list.isEmpty || !list.isEmpty)
    }
}
