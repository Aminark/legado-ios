# 第三方许可

小浣熊阅读（项目仓库：<https://github.com/Aminark/legado-ios>）由 Aminark 维护。本项目的新增与修改部分以 GNU GPL v3 提供；第三方材料保留其原版权与适用许可。根目录 [LICENSE](LICENSE) 是完整 GPL v3 文本。

## 阅读 Legado

- 项目：<https://github.com/LegadoTeam/legado>。
- 许可：GNU General Public License v3，完整文本见 [Legado-LICENSE.txt](App/Resources/Legado-LICENSE.txt)。
- 材料：部分业务模块、默认 TXT 目录规则 [txtTocRule.json](App/Resources/txtTocRule.json) 和 HTTP TTS 配置 [httpTTS.json](App/Resources/httpTTS.json)。两份配置对应 `app/src/main/assets/defaultData/` 下的同名文件，原作者署名保留在配置中。
- 版权归 Legado 原作者及其贡献者。Aminark 于 2026-10-13 起修改应用品牌、界面与公开文档；后续修改日期和内容见 [CHANGELOG](CHANGELOG.md) 与 Git 历史。

## SwiftSoup

- 项目：<https://github.com/scinfu/SwiftSoup>。
- 用途：HTML 与 CSS 解析。
- 许可：MIT，完整版权及许可见 [SwiftSoup-LICENSE.txt](App/Resources/SwiftSoup-LICENSE.txt)。

## Kanna

- 项目：<https://github.com/tid-kijyun/Kanna>。
- 用途：XPath 解析。
- 许可：MIT，完整版权及许可见 [Kanna-LICENSE.txt](App/Resources/Kanna-LICENSE.txt)。

## ZIPFoundation

- 项目：<https://github.com/weichsel/ZIPFoundation>，固定版本 `0.9.20`；iOS 工程使用 [Vendor/LegadoZIPFoundation](Vendor/LegadoZIPFoundation/README.md) 中的原版源码，避免与 Readium 的异步 ZIP 分支产生 SwiftPM 包标识冲突。
- 用途：按需读取 EPUB ZIP 容器与校验资源 CRC。
- 许可：MIT，完整版权及许可见 [ZIPFoundation-LICENSE.txt](App/Resources/ZIPFoundation-LICENSE.txt)。

## Readium EPUB 阅读组件

- 项目：<https://github.com/readium/swift-toolkit>，固定版本 `3.8.0`，兼容 iOS 15。
- 用途：渲染 EPUB 的 XHTML/CSS、SVG、内嵌插图、表格、目录与阅读位置。
- 许可：BSD-3-Clause。随 App 使用的 Zip、Readium Fuzi、Readium ZIPFoundation、CryptoSwift、DifferenceKit 的完整版权及许可一并收录在 [Readium-LICENSE.txt](App/Resources/Readium-LICENSE.txt)，可在 App「关于 → 开源许可」中查看。
- 随阅读组件分发的 OpenDyslexic、iA Writer Duospace、AccessibleDfA 字体保留原始资源，版权及许可说明一并收录在上述许可文件中。
- iOS 依赖版本和来源由 Xcode 工程内的 `Package.resolved` 锁定；未使用 Readium LCP 或云端解密服务。

## Google Sign-In 及依赖

- 项目：<https://github.com/google/GoogleSignIn-iOS>。
- 用途：Google 账号登录授权及 Google Drive 应用专用空间备份。
- 许可：Apache License 2.0。Google Sign-In、AppAuth、GTMAppAuth、GTM Session Fetcher、App Check、GoogleUtilities 和相关互操作依赖的版权及许可见 [GoogleSignIn-LICENSES.txt](App/Resources/GoogleSignIn-LICENSES.txt)。
- 依赖版本由 [Package.resolved](Legado.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) 锁定，应用内「开源许可」也提供对应文本。

## 测试数据与演示内容

测试中的规则样本仅用于兼容验证，不打包为 App 默认书源。具体说明见 [测试样本说明](Tests/LegadoCoreTests/Fixtures/README.md)。演示模式使用虚构书籍元数据和项目内演示文本；发布截图不使用个人书架、登录信息或付费章节。

第三方材料继续遵循其各自许可。GPL 覆盖软件的使用和分发，不提供第三方网站、书籍、封面或服务的内容授权。
