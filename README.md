# MyGo Apple Music

将自己的 Apple Music 资料库和歌单接入 [MyGo Music](https://github.com/egoist/mygo-music)。Apple Music 提供音乐数据和完整歌曲播放，专辑、音乐人、搜索、收藏、歌单、歌词与播放队列沿用 MyGo 现有界面。

收藏和歌单编辑保存在 MyGo 本地，不写回 Apple Music。左下角使用 MyGo 原生“设置”，没有额外的账号界面。

## 功能

- 浏览资料库中的专辑、音乐人、歌曲和歌单，支持资料库内搜索。
- 使用 MusicKit 播放完整歌曲，支持暂停、继续、进度跳转及 MyGo 队列切歌。
- 本地收藏，以及本地歌单的创建、重命名、删除、曲目增删和排序。
- 将 Apple Music 歌单导入为本地副本。首次打开或编辑时读取曲目，之后的本地编辑独立保存。
- 通过 [LRCLIB](https://lrclib.net) 匹配同步歌词，在 MyGo 原有歌词界面中展示和跳转。

## 安装

发行包面向 Apple Silicon Mac，需要 macOS 14 或更新版本、MyGo Music 0.1.20 或更新版本和 Apple Music 订阅。在系统“音乐”应用中登录订阅账号，确认资料库中的歌曲可播放。Intel Mac 尚未完成实机验收。

### 从 GitHub 安装

最新 [Release](https://github.com/hx23840/mygo-apple-music/releases/latest) 提供 `plugin-darwin-arm64.zip`，辅助程序使用 Developer ID 签名并通过 Apple 公证。

在 MyGo 的 **设置 > 插件 > 安装插件 > 从 GitHub** 填入 `hx23840/mygo-apple-music`，也可以使用 [在 MyGo 中安装](mygo-music://install-plugin?repo=hx23840/mygo-apple-music)。MyGo 会下载对应平台的发行包并显示权限确认。

如果之前通过本地文件安装过同 ID 插件，先在插件的“更多操作”中移除旧包，再从 GitHub 安装。MyGo 会将旧文件夹移至废纸篓并保留插件数据；本项目已验证迁移后收藏和歌单保持不变。

也可以从 Release 下载 `plugin-darwin-arm64.zip`，通过 **从 Zip 文件** 安装。只有这个附件包含原生辅助程序；GitHub 自动生成的 Source code 压缩包和仓库源码均不能直接用于播放。

1. 允许插件启动包内辅助程序。
2. 切换到 **Apple Music** 音源。首次使用时，在 macOS 的音乐访问弹窗中允许访问，再重试资料库页面。
3. 从 MyGo 侧栏进入专辑、音乐人、歌曲或歌单。

已授权时不需要额外登录。拒绝过访问时，在 **系统设置 > 隐私与安全性 > 媒体与 Apple Music** 中检查权限。

### 自行构建

自行构建需要 Xcode 和自己的 Apple 开发者签名配置。

```sh
git clone https://github.com/hx23840/mygo-apple-music.git
cd mygo-apple-music
export APPLE_MUSIC_TEAM_ID='YOURTEAMID'
export APPLE_MUSIC_BUNDLE_ID='com.yourcompany.mygo-apple-music'
bash scripts/build-xcode.sh --provision
bash scripts/package.sh
```

将示例值替换为自己的开发团队和 App ID，再安装 `dist/plugin-darwin-arm64.zip`。签名、MusicKit 配置和诊断构建见 [构建指南](docs/BUILDING.md)。

## 使用边界

- 内容范围是你的资料库和歌单，不包含 Apple Music 全曲库搜索。专辑页展示已保存到资料库的曲目。
- 导入后的歌单是本地快照，不会持续同步 Apple 端的编辑。删除本地副本后，刷新不会自动重新导入。
- 播放依赖 Apple Music 原歌曲；部分歌单曲目还依赖原歌单引用。源端不可用时，本地收藏不会让它重新可播。
- MusicKit 未提供可播放参数的项目及音乐视频会显示为不可用。灰色条目不一定是插件故障。
- 部分源数据没有有效专辑或音乐人关联。插件保留名称和封面，不生成失效的详情链接。
- 不提供音频导出、离线下载、独立播放器音量或 Windows/Linux 播放。音量使用 macOS 系统控制。
- MyGo 管理队列、随机和循环，必须保持运行。暂停期间从外部恢复播放可能不能立即同步到 MyGo。
- 同步歌词可能没有匹配结果。插件不会把普通歌词伪造成带时间轴的歌词。

## 开发

Node.js 20 或更新版本用于测试。项目没有 npm 运行时依赖，无需 `npm install`。

```sh
npm test
npm run test:native
bash scripts/build.sh --diagnostic
npm run smoke
```

原生测试和构建需要 macOS 与 Xcode。诊断包只用于协议验证，不能连接 Apple Music。完整播放检查需要自行签名和音乐授权，详见 [测试记录与复现](docs/VERIFICATION.md)。

| 目录 | 内容 |
| --- | --- |
| `plugin.json`、`index.js`、`locales/` | 位于仓库根目录的插件清单、入口和中文翻译 |
| `bin/` | 构建生成的原生辅助程序，不进入源码仓库 |
| `native/` | Swift MusicKit 辅助程序与 Xcode 工程 |
| `scripts/` | 构建、打包和验证脚本 |
| `tests/` | JS 行为测试及 Swift 协议测试 |
| `docs/` | 构建指南、架构与验证说明 |

[架构说明](docs/ARCHITECTURE.md) · [贡献指南](CONTRIBUTING.md) · [更新记录](CHANGELOG.md)

## 数据与权限

Apple 音乐授权和受保护音频播放由本机 MusicKit 处理。插件不要求填写 Apple ID 密码、私钥或开发者令牌。收藏、歌单快照和歌词缓存保存在 MyGo 插件本地存储中，封面保存在辅助程序的本机缓存中。

歌词匹配会向 LRCLIB 发送歌曲名、音乐人、专辑和时长，不发送 Apple 账号令牌或音频。插件清单声明封面域名 `*.mzstatic.com` 和歌词域名 `lrclib.net`，并允许启动包内的原生辅助程序。该原生程序通过系统 MusicKit 访问音乐服务。

## 许可与致谢

本项目采用 [AGPL-3.0-only](LICENSE)。Copyright © 2026 mygo-apple-music contributors。

MyGo Music 是 [egoist/mygo-music](https://github.com/egoist/mygo-music) 项目。本插件独立维护，不属于 MyGo 或 Apple 官方产品。插件接口以 MyGo v0.1.21 的 [API 文档](https://github.com/egoist/mygo-music/blob/0c8e5574f9a9c7d397f222727fb852fdb0e7e0ad/README.md#plugins) 为对接依据。歌词服务由 LRCLIB 提供。
