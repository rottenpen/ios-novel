import Foundation
import Testing
@testable import ReaderCore

@Suite("AnalyzeByJSoup HTML 规则解析")
struct AnalyzeByJSoupTests {

    /// 模拟一个典型小说站搜索结果页
    static let searchHTML = """
    <html><body>
      <div class="result">
        <div class="item">
          <h3><a href="/book/1.html">剑来</a></h3>
          <span class="author">烽火戏诸侯</span>
          <img src="/cover/1.jpg" data-src="/lazy/1.jpg">
          <p class="intro">大千世界，无奇不有。</p>
          <span class="last">第100章 归乡</span>
        </div>
        <div class="item">
          <h3><a href="/book/2.html">诡秘之主</a></h3>
          <span class="author">爱潜水的乌贼</span>
          <img src="/cover/2.jpg" data-src="/lazy/2.jpg">
          <p class="intro">蒸汽与机械的世界。</p>
          <span class="last">第200章 愚者</span>
        </div>
        <div class="item">
          <h3><a href="/book/3.html">大道朝天</a></h3>
          <span class="author">猫腻</span>
          <img src="/cover/3.jpg" data-src="/lazy/3.jpg">
          <p class="intro">修行之路。</p>
          <span class="last">第300章 朝天</span>
        </div>
      </div>
      <div class="toc">
        <ul>
          <li><a href="/c/1.html">第一章 序</a></li>
          <li><a href="/c/2.html">第二章 上山</a></li>
          <li><a href="/c/3.html">第三章 下山</a></li>
          <li><a href="/c/4.html">第四章 归来</a></li>
        </ul>
      </div>
      <div id="content">
        正文第一段。
        <script>var ad = 1;</script>
        <p>正文第二段。</p>
        <p>正文第三段。</p>
      </div>
    </body></html>
    """

    private func analyzer() throws -> AnalyzeByJSoup {
        try AnalyzeByJSoup(doc: Self.searchHTML)
    }

    // MARK: - 基础取值

    @Test("class 规则取 text")
    func classText() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.author@text")
        #expect(list == ["烽火戏诸侯", "爱潜水的乌贼", "猫腻"])
    }

    @Test("tag 规则取属性")
    func tagAttr() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item@tag.a@href")
        #expect(list == ["/book/1.html", "/book/2.html", "/book/3.html"])
    }

    @Test("取 img 的自定义属性")
    func customAttr() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item@tag.img@data-src")
        #expect(list == ["/lazy/1.jpg", "/lazy/2.jpg", "/lazy/3.jpg"])
    }

    @Test("id 规则")
    func idRule() throws {
        let a = try analyzer()
        let text = try a.getString("id.content@text")
        #expect(text?.contains("正文第一段") == true)
    }

    // MARK: - 索引语义（阅读原生写法）

    @Test("正索引选择首项")
    func positiveIndex() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item.0@class.author@text")
        #expect(list == ["烽火戏诸侯"])
    }

    @Test("负索引选择末项")
    func negativeIndex() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item.-1@class.author@text")
        #expect(list == ["猫腻"])
    }

    @Test("! 排除索引")
    func excludeIndex() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item!0@class.author@text")
        #expect(list == ["爱潜水的乌贼", "猫腻"])
    }

    @Test("多个索引 . 选择")
    func multiIndexSelect() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item.0:2@class.author@text")
        #expect(list.contains("烽火戏诸侯"))
        #expect(list.contains("猫腻"))
    }

    // MARK: - 索引语义（[] 写法）

    @Test("[] 单索引")
    func bracketSingleIndex() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item[0]@class.author@text")
        #expect(list == ["烽火戏诸侯"])
    }

    @Test("[] 负索引")
    func bracketNegativeIndex() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item[-1]@class.author@text")
        #expect(list == ["猫腻"])
    }

    @Test("[] 多索引逗号分隔")
    func bracketMultiIndex() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item[0,2]@class.author@text")
        #expect(list == ["烽火戏诸侯", "猫腻"])
    }

    @Test("[!] 排除索引")
    func bracketExclude() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item[!0]@class.author@text")
        #expect(list == ["爱潜水的乌贼", "猫腻"])
    }

    // MARK: - 组合规则

    @Test("|| 短路：第一条命中即停止")
    func orShortCircuit() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.author@text||class.intro@text")
        #expect(list == ["烽火戏诸侯", "爱潜水的乌贼", "猫腻"])
    }

    @Test("|| 第一条为空时取第二条")
    func orFallback() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.nonexistent@text||class.author@text")
        #expect(list == ["烽火戏诸侯", "爱潜水的乌贼", "猫腻"])
    }

    @Test("&& 合并两条规则结果")
    func andMerge() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item.0@class.author@text&&class.item.0@class.last@text")
        #expect(list == ["烽火戏诸侯", "第100章 归乡"])
    }

    @Test("%% 交叉合并")
    func crossMerge() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.author@text%%class.last@text")
        // 交叉：author[0], last[0], author[1], last[1], ...
        #expect(list.count == 6)
        #expect(list[0] == "烽火戏诸侯")
        #expect(list[1] == "第100章 归乡")
        #expect(list[2] == "爱潜水的乌贼")
    }

    // MARK: - 末段取值方式

    @Test("textNodes 只取直属文本节点")
    func textNodes() throws {
        let a = try analyzer()
        let text = try a.getString("id.content@textNodes")
        #expect(text?.contains("正文第一段") == true)
        // textNodes 不含子元素 <p> 的文本
        #expect(text?.contains("正文第二段") == false)
    }

    @Test("ownText 排除子元素文本")
    func ownText() throws {
        let a = try analyzer()
        let text = try a.getString("id.content@ownText")
        #expect(text?.contains("正文第一段") == true)
        #expect(text?.contains("正文第二段") == false)
    }

    @Test("html 取值时移除 script 与 style")
    func htmlRemovesScript() throws {
        let a = try analyzer()
        let html = try a.getString("id.content@html")
        #expect(html?.contains("正文第二段") == true)
        #expect(html?.contains("var ad") == false)
    }

    // MARK: - @CSS: 前缀

    @Test("@CSS: 标准选择器")
    func cssPrefix() throws {
        let a = try analyzer()
        let list = try a.getStringList("@CSS:.item .author@text")
        #expect(list == ["烽火戏诸侯", "爱潜水的乌贼", "猫腻"])
    }

    @Test("@CSS: 取属性")
    func cssPrefixAttr() throws {
        let a = try analyzer()
        let list = try a.getStringList("@CSS:.item h3 a@href")
        #expect(list == ["/book/1.html", "/book/2.html", "/book/3.html"])
    }

    // MARK: - getElements（列表规则）

    @Test("getElements 返回书籍列表元素")
    func getElementsList() throws {
        let a = try analyzer()
        let elements = try a.getElements("class.item")
        #expect(elements.size() == 3)
    }

    @Test("getElements 目录列表")
    func getElementsToc() throws {
        let a = try analyzer()
        let elements = try a.getElements("class.toc@tag.li")
        #expect(elements.size() == 4)
    }

    /// 子元素上下文：从列表元素内继续解析字段（书源搜索的核心流程）
    @Test("列表元素内逐项解析字段")
    func perItemFields() throws {
        let a = try analyzer()
        let elements = try a.getElements("class.item")
        var names: [String] = []
        var urls: [String] = []
        for el in elements.array() {
            let sub = try AnalyzeByJSoup(doc: el)
            names.append(try sub.getString0("tag.h3@tag.a@text"))
            urls.append(try sub.getString0("tag.h3@tag.a@href"))
        }
        #expect(names == ["剑来", "诡秘之主", "大道朝天"])
        #expect(urls == ["/book/1.html", "/book/2.html", "/book/3.html"])
    }

    // MARK: - 健壮性

    @Test("空规则返回空")
    func emptyRule() throws {
        let a = try analyzer()
        #expect(try a.getStringList("").isEmpty)
        #expect(try a.getString("") == nil)
    }

    @Test("不存在的规则返回空而不抛错")
    func nonexistentRule() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.nothing-here@text")
        #expect(list.isEmpty)
    }

    @Test("索引越界不崩溃")
    func indexOutOfBounds() throws {
        let a = try analyzer()
        let list = try a.getStringList("class.item.99@class.author@text")
        #expect(list.isEmpty)
    }

    @Test("畸形 HTML 仍可解析")
    func malformedHTML() throws {
        let a = try AnalyzeByJSoup(doc: "<div class='x'><p>未闭合<span>文本</div>")
        let text = try a.getString("class.x@text")
        #expect(text?.contains("未闭合") == true)
    }
}
