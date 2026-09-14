# 第三方来源与许可

Yuedu 以 [GNU GPL v3](LICENSE) 发布。以下声明随源码一同分发，第三方文件中的版权、许可及作者声明仍然有效。

## 规则解析与书源兼容

`ReaderCore/Sources/ReaderCore/` 中的 `Engine/`、`Rules/`、`Models/`、`JS/` 以及网络与存储接口，参考并改写自 [Legado](https://github.com/violetnight/legado) 的规则解析、数据模型、书源抓取和宿主接口。原项目作者为 gedoor 及其贡献者；所参考仓库版本为 `9c27c3b44d3fcfa246ba0c3d8847553f9bb39d70`，适用 [GPL v3](https://github.com/violetnight/legado/blob/9c27c3b44d3fcfa246ba0c3d8847553f9bb39d70/LICENSE)。

Yuedu 项目于 2026-09-14 整理并修改这些实现：使用 Swift、JavaScriptCore 与 SwiftSoup 提供规则执行，采用 Swift Concurrency、iOS 网络请求和 JSON 持久化，并修正重定向、Cookie、脚本桥及搜索状态处理。各相关源文件标有修改说明。原项目的名称和书源格式名称仅用于说明来源及兼容关系。

## SwiftSoup

`Vendor/SwiftSoup/` 来自 [scinfu/SwiftSoup](https://github.com/scinfu/SwiftSoup)，版本为 `35f7e1b0049236edcc351c0f10e7beddd0d4e76c`，按 [MIT 许可证](Vendor/SwiftSoup/LICENSE) 分发。源码保留原始许可与声明。

- Copyright © 2009–2025 Jonathan Hedley
- Copyright © 2016–2025 Nabil Chatbi

## 书源样本

`ReaderCore/Tests/ReaderCoreTests/Fixtures/real_sources.json` 来自 [XIU2/Yuedu](https://github.com/XIU2/Yuedu)，适用该项目的 [GPL v3 许可证](https://github.com/XIU2/Yuedu/blob/master/LICENSE)。JSON 中保留了原始书源说明；当前快照未记录上游提交号。

`ReaderCore/Tests/ReaderCoreTests/Fixtures/adapted_source.json` 与 `App/Yuedu/builtin_sources.json` 是基于该集合整理的速读谷规则样本，修改内容包括适配本项目已支持的解析规则。修改整理日期为 2026-09-14。测试数据用于格式兼容验证；网站内容的权利归相应权利人，站点和书源的持续可用性由其维护者决定。
