# 阅读 · Yuedu

<img src="App/Yuedu/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" alt="阅读 App 图标">

一个使用 SwiftUI 构建的 iOS 小说阅读器。支持导入 JSON 书源、多书源搜索、书架管理和横向逐页阅读。

## 阅读体验

- 左右滑动翻页，点击左侧上一页、右侧下一页，中间打开阅读菜单。
- 章末进入下一章，章首可返回上一章末页；阅读进度保存到章内文字位置。
- 支持主题、字号、行距、边距和常亮设置；调整排版或旋转屏幕后继续定位原文。
- 长按正文可复制本页内容；支持辅助功能朗读和翻页操作。
- 自动缓存已读正文，相邻章节预加载；已有缓存可在离线或书源缺失时阅读。
- 阅读菜单中点“换源”，可在其他已启用书源中查找同名书，预览对应章节后切换。优先按标题匹配章节，切换后从章首继续，书架和缓存同步更新。

## 构建

需要 macOS、Xcode 16 或更新版本、Swift 6 工具链和 Python 3；应用最低支持 iOS 17。已在 Xcode 26.6 工具链下验证构建。SwiftSoup 源码随仓库提供，无需额外下载包依赖。

```bash
python3 generate_project.py
open Yuedu.xcodeproj
```

在 Xcode 中选择 `Yuedu` Scheme 和模拟器运行。也可使用命令行：

```bash
xcodebuild -project Yuedu.xcodeproj -scheme Yuedu \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build build
```

真机需要自己的 Apple 开发团队、唯一的 bundle ID，并在设备上开启开发者模式。可在 Xcode 的 Signing & Capabilities 配置，或传入构建参数：

```bash
xcodebuild -project Yuedu.xcodeproj -scheme Yuedu \
  -destination 'platform=iOS,id=<设备UDID>' \
  -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<你的TeamID> \
  PRODUCT_BUNDLE_IDENTIFIER=<你的唯一BundleID> build
```

工程生成器也支持 `YUEDU_DEV_TEAM`、`YUEDU_BUNDLE_ID` 环境变量。公开工程默认不绑定个人团队；提交前使用无这些变量的环境重新生成。已有安装请沿用原 bundle ID，以保留应用数据。

## 书源

首次运行会导入随包提供的一个书源样本；也可在“书源”页从网址、JSON 文本或文件导入。支持常用的 Legado 3.0 书源字段和规则子集。书源来源与许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。

内置样本和社区集合均为第三方规则，能否搜索和阅读取决于站点当前状态。导入后可在书源调试界面检查搜索、目录和正文结果。

解析能力包括 CSS/JSoup 风格选择器、常用 XPath/JSONPath、正则、JavaScript、变量传递和分页抓取。依赖浏览器执行或验证码、字体解码、压缩包、本地脚本文件、远程脚本导入等能力的书源尚不支持。正文图片以文字标记显示。

## 开发与验证

```bash
swift test --package-path ReaderCore
swift run --package-path ReaderCore LiveCheck 剑来 10
```

单元与集成测试覆盖规则解析、结构化脚本输入、本地 HTTP 重定向与 Cookie、搜索取消、文字分页及进度持久化。`LiveCheck` 会请求书源网站，结果取决于网络和站点状态。应用可用 `-selfcheck <关键词>` 启动参数打开抓取自检界面。

```text
App/Yuedu/                 SwiftUI 应用与资源
ReaderCore/Sources/        解析、网络、存储和分页核心
ReaderCore/Tests/          自动化测试与书源样本
Vendor/SwiftSoup/          HTML 解析依赖源码
Yuedu.xcodeproj/           可直接打开的 Xcode 工程
generate_project.py       可复现的工程生成器
```

功能要求见 [SPEC](SPEC.md)，验证结果和能力边界见 [代码审查](CODE_REVIEW.md)，数据处理方式见 [隐私说明](PRIVACY.md)。

## 许可

本项目按 [GNU GPL v3](LICENSE) 分发。相关代码、依赖与数据来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，其中 SwiftSoup 保留 MIT 许可证。
