# 构建和安装

## 配置签名构建

1. 安装 Xcode，并在 Xcode 的账号设置中登录自己的 Apple 开发者账号。
2. 为辅助程序选择自己的 Bundle ID，按 [Apple 的 MusicKit 配置说明](https://developer.apple.com/help/account/services/musickit/) 配置对应 App ID。
3. 设置团队 ID 和 Bundle ID 后构建。

```sh
export APPLE_MUSIC_TEAM_ID='YOURTEAMID'
export APPLE_MUSIC_BUNDLE_ID='com.yourcompany.mygo-apple-music'
bash scripts/build-xcode.sh --provision
bash scripts/package.sh
```

`--provision` 允许 Xcode 使用已有账号更新签名配置。已有有效配置时可省略。脚本在缺少团队 ID 或 Bundle ID 时直接报错，不会使用维护者的个人配置。

也可打开 `native/MyGoAppleMusic.xcodeproj`，在 Signing & Capabilities 中选择自己的 Team 和 Bundle Identifier。命令行脚本仍需要上面的环境变量。

MusicKit 是 App Service，不要手动添加 `com.apple.developer.musickit` entitlement，见 [Apple DTS 说明](https://developer.apple.com/forums/thread/784114)。签名构建成功不能替代音乐授权和实际播放检查。

## 使用已有签名证书

如果已有可用的 App ID 与本机证书，可以直接使用 Swift 编译脚本。

```sh
export APPLE_MUSIC_SIGN_IDENTITY='Apple Development: Your Name (XXXXXXXXXX)'
export APPLE_MUSIC_BUNDLE_ID='com.yourcompany.mygo-apple-music'
bash scripts/build.sh --signed
bash scripts/package.sh
```

## 选择架构

构建默认使用本机架构。设置 `APPLE_MUSIC_ARCH=arm64` 或 `APPLE_MUSIC_ARCH=x86_64` 可选择目标架构。打包脚本从实际可执行文件读取架构，输出到 `dist/`。

所有构建会写入 `bin/`，切换签名模式后需要重新打包。完整插件 ZIP 的根目录包含 `plugin.json`、`index.js`、`locales/`、`bin/` 和 `LICENSE`。GitHub 自动生成的源码 ZIP 不是可安装的插件 ZIP。

## 构建诊断包

```sh
bash scripts/build.sh --diagnostic
npm run smoke
bash scripts/package.sh
```

诊断包使用 ad-hoc 签名，文件名带有 `-diagnostic`。它只验证编译、进程桥接和协议，不请求音乐权限，也不能播放 Apple Music。

## 发行二进制

完整操作见 [发行指南](RELEASING.md)。

Apple Development 构建用于本机开发。面向其他设备的发行包需要 Developer ID 发行签名、公证和实际安装验收，不使用开发调试证书作为公开安装包。

待发行辅助程序完成签名和公证后，将完整应用放入 `bin/MyGoAppleMusic.app`，运行 `bash scripts/package.sh`。打包脚本会检查签名、可执行权限，以及清单、package.json 和辅助程序的版本是否一致。

将 `dist/plugin-darwin-arm64.zip` 作为 Release 附件上传。附件中的清单和入口位于 ZIP 根目录。源码仓库的根目录也保留清单和入口，但不包含 `bin/`；缺少平台附件时，MyGo 回退下载的源码无法播放。

发行前验证从 GitHub 安装、音乐授权和播放，再给公开仓库添加 `mygo-music-plugin` 话题。GitHub 索引后会出现在官方插件页。当前发行目标为 Apple Silicon，Intel 仍需单独验收。证书私钥、账号凭据和构建日志不得进入公开仓库或 Release。
