# 漫画阅读

正文包含图片时，阅读页自动使用纵向图片列表，不受文字翻页模式影响。图片按源规则顺序显示，保持宽高比；支持上下章、目录、书签和阅读位置恢复。只为当前可见区域解码图片，复用离屏视图，并限制内存图片缓存。

支持的正文格式：

- `<img src="…">`、`mip-img`，以及 `data-src`、`data-original`、`data-echo`、`data-url`、`srcset` 等懒加载属性。
- 每行一个图片 URL。漫画类型 `bookSourceType=2` 或 `ruleContent.imageStyle=FULL` 也支持没有图片扩展名的地址。
- 旧文本类型漫画源、图文混排、分页正文中的相对图片地址。
- URL 后附加 `,{"headers":{"Referer":"…"}}` 的阅读请求选项，包括旧规则直接把未转义 JSON 拼进 `src` 的格式。

图片请求沿用书源请求头、Cookie、并发限制和 URL 请求选项；没有指定 Referer 时使用章节地址。失败图片提供单独重试按钮。缓存的旧章节也会在打开时识别图片。

当前图片以静态图显示，使用系统 ImageIO 解码；`imageDecode` 自定义解码脚本尚未实现，会明确提示不支持。漫画模式暂不提供文字分页、朗读或自动滚动，也不把章节文字缓存视为离线图片下载。

## 兼容依据与测试

参考公开的[阅读 3 漫画源样例](https://gist.github.com/cxfksword/486d85e7e0c1e28eb78ae0fbcfa55d1f)中的 CSS、JSONPath、JS 生成 img 和 Referer 拼接规则。回归测试使用合成地址和自绘测试图片，不内置第三方书源，不依赖这些旧网站仍然在线。

- `ChapterImageTests`：导入代表性规则，正文解析、分页相对地址、懒加载、混合正文位置、请求头和 Cookie。
- `ComicReaderTests`：旧缓存图片识别、阅读位置及漫画/文字阅读器选择。
- `ReaderComicGeometryTests`：图片宽高比、初始位置和宽度变化后的恢复。
- `ReaderScrollGestureTests/testComicImagesLoadInOrderAndFailedImageCanRetry`：实际 HTTP 图片加载、503 后重试、长图和上下章。

运行 UI 用例前启动 `python3 scripts/fixtures/comic-flow-server.py`；其默认地址为 `http://127.0.0.1:18089`。测试源仅在 Debug 的 `-uiComicRegression` 启动参数下启用。

## 不兼容书源反馈

如果仍有无法正常显示的漫画源，欢迎在 issue 中提供书源 JSON 或导入链接、具体漫画与章节、应用版本，以及错误提示或截图，方便复现并继续适配。
