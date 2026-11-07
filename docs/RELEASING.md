# 发布可安装版本

发行需要 Xcode 中已登录的开发者账号、适用的 Developer ID 签名权限，以及已配置的团队和 App ID。按 [构建指南](BUILDING.md) 设置 `APPLE_MUSIC_TEAM_ID` 和 `APPLE_MUSIC_BUNDLE_ID`。签名、公证在本机完成，凭据不上传到 GitHub。

## 验证并归档

同步修改 `plugin.json`、`package.json`、Xcode 工程、直接构建脚本和请求 User-Agent 的版本，并更新构建号与 CHANGELOG。

```sh
npm test
npm run test:native
xcodebuild -project native/MyGoAppleMusic.xcodeproj \
  -scheme MyGoAppleMusic -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/distribution-derived \
  -archivePath build/MyGoAppleMusic.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$APPLE_MUSIC_TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$APPLE_MUSIC_BUNDLE_ID" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES archive
```

## 提交公证

在 `build/DistributionExport.plist` 中配置以下导出参数。`teamID` 使用自己的团队 ID。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>YOURTEAMID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
```

```sh
xcodebuild -exportArchive \
  -archivePath build/MyGoAppleMusic.xcarchive \
  -exportOptionsPlist build/DistributionExport.plist \
  -exportPath build/distribution-export \
  -allowProvisioningUpdates
xcodebuild -exportNotarizedApp \
  -archivePath build/MyGoAppleMusic.xcarchive \
  -exportPath build/notarized
```

上传成功不等于公证通过。公证尚未完成时，等待 Apple 处理后再导出。也可通过 Xcode Organizer 查看状态和导出公证后的应用。

## 校验与打包

将导出的完整应用复制到 `bin/MyGoAppleMusic.app`，保留签名和公证票据。核对版本后执行：

```sh
codesign --verify --deep --strict bin/MyGoAppleMusic.app
codesign -dv --verbose=4 bin/MyGoAppleMusic.app
xcrun stapler validate bin/MyGoAppleMusic.app
spctl --assess --type execute --verbose=4 bin/MyGoAppleMusic.app
npm run smoke
npm run verify:live
bash scripts/package.sh
shasum -a 256 dist/plugin-darwin-arm64.zip
```

确认签名为 Developer ID Application、启用 hardened runtime，并且 Gatekeeper 返回 `Notarized Developer ID`。真实播放检查会播放音频并可能请求系统音乐授权。测试条件见 [验证说明](VERIFICATION.md)。

普通 `package.sh` 也支持本机开发包，因此公开发布必须另外通过上面的发行签名和公证检查。解压最终 ZIP 后再次验证签名、票据、可执行权限和版本，避免打包破坏发行产物。

## 发布到 GitHub

1. 提交并推送源码，等待 CI 通过。
2. 为该提交创建版本 Release，附上 `plugin-darwin-arm64.zip`、SHA-256 校验文件和发行说明。
3. 从 MyGo 的 GitHub 安装入口测试该 Release。核对安装后的文件与附件一致，验证专辑浏览、设置入口和播放。
4. 验收通过后，给仓库添加 `mygo-music-plugin` 话题，等待 GitHub 索引。

只上传安装包、校验文件和发行说明。日志、归档、证书私钥、描述文件及账号凭据保留在本机。发行包包含公开签名证书信息，用于验证发布者。
