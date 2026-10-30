<div align="center">

<img src="App/Assets.xcassets/BrandIcon.imageset/BrandIcon.png" width="128" height="128" alt="小浣熊阅读" />

# 小浣熊阅读

**搜书快一点，读书舒服一点。**

一款优先兼容阅读书源的 iOS 阅读器

![iOS 15+](https://img.shields.io/badge/iOS-15%2B-315C50)
![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)
[![GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue)](LICENSE)
[![TestFlight 公测](https://img.shields.io/badge/TestFlight-Beta-0D96F6?logo=apple&logoColor=white)](https://testflight.apple.com/join/RSmhQ9Xn)

[下载安装](#下载安装) · [主要功能](#主要功能) · [应用截图](#应用截图) · [书源说明](#书源说明) · [问题反馈](https://github.com/Aminark/legado-ios/issues)

</div>

小浣熊阅读是一款 iOS 阅读器，由 [Aminark](https://github.com/Aminark) 维护，优先兼容阅读书源。希望从导入书源、搜索书籍到打开阅读，都能方便、顺手一些。

项目仍在边用边改，书源兼容和阅读体验会继续完善。

**小浣熊阅读不提供书源或在线书库。** 书源需由用户自行从网络公开分享获取，或自行编写后导入；也可以直接阅读本地 TXT / EPUB。

## 下载安装

支持 **iOS / iPadOS 15.0 及以上**。

### TestFlight 公测（推荐）

**[点击加入小浣熊阅读 TestFlight 公测](https://testflight.apple.com/join/RSmhQ9Xn)**

1. 在 iPhone 或 iPad 上安装 Apple 官方的 [TestFlight](https://apps.apple.com/app/testflight/id899247664)。
2. 使用同一台设备打开上方公测链接，按页面提示接受邀请并安装「小浣熊阅读」。
3. 后续可在 TestFlight 中获取测试版更新，也欢迎通过 TestFlight 或 [GitHub Issues](https://github.com/Aminark/legado-ios/issues) 反馈问题。

通过 TestFlight 安装无需自行签名。

### IPA 与源码安装

**IPA 下载见 [GitHub Releases](https://github.com/Aminark/legado-ios/releases)，需要自行签名安装。** 请下载附件中的 `.ipa` 文件；`Source code` 是源码压缩包。

- **自行签名安装**：使用自己的签名工具安装 IPA。免费 Apple 账号自签的描述文件有效期通常为 7 天，到期需要重新签名安装，见 [Apple 说明](https://developer.apple.com/help/account/basics/about-your-developer-account#enable-a-personal-team-in-xcode)。
- **巨魔安装**：已支持 [TrollStore](https://github.com/opa334/TrollStore) 的设备可自行尝试安装，具体系统兼容范围以 TrollStore 项目说明为准。
- **源码构建**：有 macOS 和 Xcode 的朋友也可以自行编译，见 [开发指南](docs/DEVELOPMENT.md)。

这个项目主要是自己使用和分享，没有盈利计划。

## 主要功能

| 功能 | 说明 |
| --- | --- |
| 阅读书源 | 支持 JSON、文件、URL 和二维码导入，以及书源分组、编辑和调试 |
| 快速搜书 | 多书源并发搜索，结果陆续展示；重复搜索可先显示有效缓存，同书多源合并 |
| 书架管理 | 列表、网格、分组、章节更新、换源和本机阅读进度 |
| 阅读排版 | 字号、间距、边距、日夜主题、滚动与分页阅读、目录和书签 |
| 本地 TXT / EPUB | TXT 自定义目录规则；EPUB 2/3 原书排版、封面、内嵌图表、目录与续读 |
| 语音朗读 | 系统朗读与 HTTP TTS 配置 |
| 阅读工具 | 替换净化、阅读记录、时长统计和缓存管理 |
| RSS 订阅 | 订阅源管理与内容阅读 |

搜书速度是我比较在意的部分，目前做了并发调度、有效书源优先和结果缓存等优化。实际体验仍会受到网络和书源网站响应的影响。

兼容阅读书源不代表所有书源都能直接使用。复杂 JavaScript、登录、验证码和 WebView 规则仍可能存在平台差异，遇到问题欢迎反馈。

## 应用截图

<table>
  <tr>
    <td align="center"><strong>书架</strong><br /><a href="docs/images/bookshelf.png"><img src="docs/images/bookshelf.png" width="230" alt="小浣熊阅读书架" /></a></td>
    <td align="center"><strong>搜书</strong><br /><a href="docs/images/search.png"><img src="docs/images/search.png" width="230" alt="小浣熊阅读搜索结果与缓存展示" /></a></td>
    <td align="center"><strong>书源管理</strong><br /><a href="docs/images/sources.png"><img src="docs/images/sources.png" width="230" alt="小浣熊阅读书源管理" /></a></td>
  </tr>
  <tr>
    <td align="center"><strong>日间阅读</strong><br /><a href="docs/images/reader.png"><img src="docs/images/reader.png" width="230" alt="小浣熊阅读纸色主题" /></a></td>
    <td align="center"><strong>夜间阅读</strong><br /><a href="docs/images/reader-dark.png"><img src="docs/images/reader-dark.png" width="230" alt="小浣熊阅读夜间主题" /></a></td>
    <td align="center"><strong>我的</strong><br /><a href="docs/images/profile.png"><img src="docs/images/profile.png" width="230" alt="小浣熊阅读个人中心" /></a></td>
  </tr>
</table>

<details>
<summary>查看更多截图：发现、阅读统计、关于</summary>

<table>
  <tr>
    <td align="center"><strong>发现</strong><br /><a href="docs/images/explore.png"><img src="docs/images/explore.png" width="230" alt="小浣熊阅读发现页面" /></a></td>
    <td align="center"><strong>阅读统计</strong><br /><a href="docs/images/statistics.png"><img src="docs/images/statistics.png" width="230" alt="小浣熊阅读统计页面" /></a></td>
    <td align="center"><strong>关于</strong><br /><a href="docs/images/about.png"><img src="docs/images/about.png" width="230" alt="小浣熊阅读关于页面" /></a></td>
  </tr>
</table>

</details>

截图使用演示书籍、书源和正文，点击可查看大图。

## 开始使用

1. 自行准备你有权使用的阅读书源，安装后进入「我的 → 书源管理」导入。
2. 在书架点击搜索，输入书名或作者，打开书籍详情后开始阅读。
3. 将书籍加入书架，方便下次继续阅读；也可以从书架直接导入本地 TXT 或 EPUB。

4. 点击正文唤出阅读工具栏，通过「设置 → 默认排版」一键使用大号加粗标题、自然字距、两字缩进和更清晰的段落间距。设置顶部可调亮度、字号和常用背景；「更多外观」提供完整样式选项，返回后仍停留在设置页。工具栏可直接切换日夜间。

EPUB 导入入口：书架 → 更多 → 本地书，或「我的 → 文件管理 → 导入 TXT / EPUB」。自 v0.1.13 起使用 Readium 显示无 DRM EPUB 2/3，保留原书 XHTML、CSS、SVG 封面、内嵌插图和表格，支持目录、书签、翻页／滚动、主题与字号设置，并保存原排版阅读位置。已导入但缺封面的书会自动尝试补回封面；原有朗读和文字工具可从 EPUB 阅读菜单「文字阅读与朗读」进入。

应用支持 `legado://` 规则导入链接。来源网站改版或停止服务时，书源规则可能需要更新。

### 换源时的正文对照

打开换源列表后，应用自动读取候选书源的对应章节，并尝试获取起点或 QQ 阅读的公开可见正文作为参照。列表分别显示「可见片段相似度」和「正文是否多于参照」，便于排除明显错文；没有可读取的参照时，将相同正文汇总为「同文组 · 未验证」。

**目录标题匹配、开头相似、多个源正文相同，都不能保证整章正确。** 相似度只覆盖已取得的公开可见片段，正文更多也不代表后续内容已经核实；正文过短或章节未匹配时会说明原因。

换源候选、参照与已获取的正文会保存在本地缓存中，关闭页面或重启应用后可复用，默认有效期为 24 小时。切换章节或修改书源规则后使用新的缓存；需要重新检查时点击换源页右上角刷新。预览不会切换当前书源。

在线书源入口位于「书源管理 → 更多 → 在线书源」，包含语雀、喵公子和开源阅读分享页；网页导入前可预览并选择书源。

### 备份与同步

| 方式 | 数据与用途 |
| --- | --- |
| 文件导出 | 生成 `.legadobackup` 单文件，可选包含本地 TXT / EPUB 和已缓存正文，适合完整迁移 |
| WebDAV | 保存独立历史备份；也可单独开启自动同步，用于合并书架、阅读进度等数据 |
| Google Drive | 通过官方登录绑定账号，在应用专用空间保存独立备份，可选择旧备份恢复 |

备份包含书架、目录、进度、书签、分组、阅读记录与时长统计、搜索历史、订阅及阅读记录、书源、规则和设置。恢复会合并现有数据并保留较新的阅读进度；重复恢复不会重复累计阅读时长。自定义字体和背景图片需另行保存。

WebDAV 与 Google Drive 绑定后的**自动备份默认开启，间隔默认 6 小时**，可选择常用间隔或自定义 1～10080 分钟。应用在启动、前后台切换及前台使用期间检查，只在达到间隔且数据有变化时上传。iOS 后台执行时间由系统决定，关闭应用后不保证定时上传。

云端备份与同步不包含本地 TXT / EPUB 和正文缓存文件，Google Drive 也不做自动进度合并；完整文件迁移请用导出备份。默认构建未启用 iCloud，具备相应容器及签名权限时可单独构建启用。配置、数据范围和恢复规则见 [备份与同步说明](docs/BACKUP_SYNC.md)。

### 章节缓存

点击正文打开「目录 → 缓存」，可缓存接下来 10 章或剩余章节、停止任务及打开缓存管理。已缓存章节用正常字色、未缓存用灰色，当前章保持高亮；本地书均视为已在本机。下载时显示成功和失败数，超出容量上限后会清理较早缓存；上限和预加载数量可在缓存管理中配置。「我的 → 文件与存储」也可打开缓存管理。

文字分页支持跟手横划和跨章动画，后续章节按配置持续预加载；点击中央区域打开菜单，左右点击不翻页。EPUB 默认继续使用上游的原书排版阅读器。

## 书源说明

小浣熊阅读仅提供书源解析、书籍管理和阅读功能，**不提供、内置或分发网络书源**。用户使用的书源来自网络公开分享，或由用户自行编写、导入。

在线书籍正文、封面、简介及订阅内容由书源对应的第三方网站提供，版权归原作者或合法权利人所有。网络公开分享、书源可导入或内容可访问，不代表已获得内容授权。

请自行核实书源和内容的来源，在获得授权或法律允许的范围内使用，遵守来源网站的使用规则，支持正版阅读。第三方网站或书源失效时，需要更新规则或更换来源。

## 为什么做这个

我之前一直用香色闺阁看书，也用得挺习惯。不过在自己的使用过程中，搜书等待时间一直让我比较难受。后来能用的书源越来越少，就想着干脆自己折腾一个。

最开始只是打算自己用：搜书快一点，导入书源方便一点，找到书以后能舒舒服服地看下去。

后来就这样边写边用、缺什么补什么，慢慢成了现在的小浣熊阅读。既然可能还有朋友有同样的需求，就把它开源出来，欢迎一起折腾。

## 反馈与贡献

遇到问题或有功能建议，欢迎提交 [Issue](https://github.com/Aminark/legado-ios/issues)。反馈时请附上应用版本、系统版本、设备和复现步骤；书源问题尽量提供最小规则。

请先去掉日志和规则中的账号、Cookie、Token 等个人信息。欢迎提交代码、兼容用例和文档改进，具体见 [贡献指南](CONTRIBUTING.md)。

## 开源许可

本项目采用 **GNU GPL v3**，详见 [LICENSE](LICENSE)。

第三方材料的版权与许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。

请遵守书源网站的使用规则和内容授权，支持正版阅读。

## 🔗 友情链接

[LINUX DO](https://linux.do/) —— 真诚分享、友好讨论的技术社区，本项目的交流与反馈也发布于此
