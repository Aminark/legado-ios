# 备份与同步

入口：我的 → 文件与存储 → 备份与同步。

## 文件备份

导出 `.legadobackup` 单文件，可保存到“文件”或已安装网盘提供的位置。可选包含本地 TXT / EPUB 与已缓存正文。恢复先预览，再显式合并；同网址书籍保留较新阅读进度，不清空现有书架。自定义字体和背景图片请另行保存。

## WebDAV

填写最终 HTTPS 地址、账号及网盘生成的应用专用密码（如坚果云 `https://dav.jianguoyun.com/dav/`）。测试连接会使用服务器下的 `Legado/backups` 文件夹。凭据仅保存在设备钥匙串，不写入应用备份。

- 自动同步需单独确认启用，在启动、前台及尽力后台时执行。只同时启用一种自动同步后端。
- 自动同步使用 `Legado/library-v1.json`。服务器需支持强 ETag、If-Match 和 If-None-Match；不支持版本校验时可继续使用独立备份。
- “备份到 WebDAV”每次创建独立文件；“查看云端备份”可以下载、预览并合并恢复。
- 解除连接只移除本机凭据、停止同步，不删除两端数据。

## Google Drive

使用 Google 官方 Sign-In SDK（10.1.0），仅申请 `drive.appdata` 备份空间权限。Google 密码由 Google 登录页面处理，令牌由官方 SDK 管理。每次备份单独保存，可从列表恢复；支持手动备份/恢复，绑定区域的“自动备份”默认开启；不做自动进度同步。解除绑定会移除本机登录状态，保留云端备份。

开发配置：在自己的 Google Cloud 项目启用 Drive API、配置 Google Auth Platform，并创建与安装包 Bundle ID 完全一致的 iOS OAuth 客户端。将客户端 ID 与反向客户端 URL scheme 通过以下构建设置传入：

```
GOOGLE_CLIENT_ID=<iOS client ID ending in .apps.googleusercontent.com>
GOOGLE_REVERSED_CLIENT_ID=<reversed client ID>
GOOGLE_CLIENT_BUNDLE_ID=<registered bundle ID>
```

默认构建不包含已注册的 Google 客户端。请使用自己的项目和客户端，将三个构建设置与实际安装包标识对应；无需修改或更换上游默认 Bundle ID。

这三个值是公开的应用标识，不是密码；不要把 OAuth client secret、登录密码或 token 放进工程。Google 登录配置缺失或 Bundle ID 不符时，绑定入口会说明不可用。测试模式需把实际试用账号加入测试用户；以控制台显示的受众与发布状态为准。

Google 的应用专用空间不在普通网盘文件列表显示，只能在本 App 中查看；需要普通文件副本时使用“导出备份”。

## 自动备份

Google Drive 和 WebDAV 绑定区域各有独立的“自动备份”开关，默认开启；已有绑定升级到此版本也会自动启用。绑定完成或手动开启时尝试立即备份，备份间隔默认 6 小时，可选常用间隔或自定义 1～10080 分钟，按账号保存。之后在启动、回到前台和离开 App 时检查；前台使用期间每分钟检查一次，仅在达到所选间隔且数据有变化时上传。无变化或失败后的重复检查退避五分钟，所选间隔更短时随之缩短；下次打开会继续尝试。页面显示最近成功自动备份时间及最近的失败原因，手动备份不受这个间隔限制。

开关和记录与当前云端账号对应，解除绑定后停止执行；新账号默认开启，手动关闭的选择按账号记住，同一账号重新绑定仍保持关闭。自动备份只保存云端元数据副本，不恢复或合并远程数据，不删除已有备份。iOS 后台任务可能被暂停，应用关闭时不保证按时备份；离开应用前的任务仅在系统允许的时间内尽力完成。

## 数据范围与限制

文件备份、WebDAV 同步和两种云备份均包含阅读记录与统计原始数据（累计时长、每日时长、最后阅读时间），以及书架、目录、阅读进度、书签、分组、搜索历史、订阅源、订阅阅读记录、订阅收藏、书源、规则和设置。今日时长、阅读书数、连续天数和近 7 天统计根据恢复后的记录重新计算。

恢复合并时，同一设备和书籍的累计时长、每日时长保留较大值，不把两份累计记录相加；不同设备的记录分别保留。重复恢复同一份备份不会重复累计，旧备份不会让现有统计回退。旧版备份缺少搜索历史或订阅阅读记录时保留本机对应记录。

云端不上传本地 TXT / EPUB 或缓存正文文件，完整文件迁移使用文件导出。网页登录 Cookie、日志、云绑定凭据、设备标识和临时搜索结果不进入备份；统计记录中的设备归属用于合并去重，会随记录保留，恢复不会覆盖本机设备标识。书源中用户自行填写的自定义请求头属于书源配置，会随书源导出。

云端元数据文件上限 32 MiB，云端列表最多 10,000 项。HTTPS 使用系统证书校验，禁止携带云端凭据跟随重定向；不要把阅读规则中的“不校验证书”设置应用到云存储。网络中断或恢复校验失败时保留本机数据。

## 可选 iCloud 构建

默认构建不申请 CloudKit 权限，WebDAV、Google Drive 和文件备份不依赖 iCloud 容器。保留 iCloud 的可选构建：

```
LEGADO_ENTITLEMENTS_FILE=App/Legado-iCloud.entitlements
LEGADO_ICLOUD_ENABLED=YES
```

该版本需要团队管理员预先创建并绑定 `iCloud.<Bundle ID>`，并使用包含 CloudKit 权限的描述文件。

参考：[Google iOS API 授权](https://developers.google.com/identity/sign-in/ios/api-access)、[Google 应用数据空间](https://developers.google.com/workspace/drive/api/guides/appdata)、[坚果云应用密码](https://help.jianguoyun.com/?p=2064)。
