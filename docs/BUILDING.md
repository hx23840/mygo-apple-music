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

所有构建会写入 `plugin/bin/`，切换签名模式后需要重新打包。完整插件 ZIP 的根目录包含 `plugin.json`、`index.js`、`locales/` 和 `bin/`。GitHub 自动生成的源码 ZIP 不是可安装的插件 ZIP。

## 构建诊断包

```sh
bash scripts/build.sh --diagnostic
npm run smoke
bash scripts/package.sh
```

诊断包使用 ad-hoc 签名，文件名带有 `-diagnostic`。它只验证编译、进程桥接和协议，不请求音乐权限，也不能播放 Apple Music。

## 发行二进制

本仓库当前只发布源码。Apple Development 构建用于本机开发，仓库不会上传开发者证书、描述文件或个人签名安装包。面向其他设备的二进制发行需要另行配置适用的签名、公证和实机验收。
