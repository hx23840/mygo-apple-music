# 贡献指南

本项目将 Apple Music 作为 MyGo 音源。新功能应继续使用 MyGo 现有界面，收藏、歌单编辑和歌词管理不写回 Apple Music。

## 提交修改

1. Fork 仓库并创建分支。
2. 修改代码，运行相关测试。
3. 提交 Pull Request，说明用户可见的变化、验证方式和仍未验证的部分。

```sh
npm test
npm run test:native
bash scripts/build.sh --diagnostic
```

修改原生读取或播放逻辑时，还需按 [验证说明](docs/VERIFICATION.md) 使用自己的账号实测。CI 不包含音乐授权或真实播放。

签名配置通过环境变量传入。不要提交个人 Team ID、证书、描述文件、日志、用户资料库快照、音频或歌词数据。提交前使用 `git diff --cached` 检查内容。

## 报告问题

Issue 请包含 macOS、MyGo、插件版本，复现步骤，预期和实际结果。涉及播放时，说明该歌曲能否在系统“音乐”应用中播放。删除日志中的本机路径、账号信息和资料库内容后再分享。

## 许可

提交贡献即表示你有权提供这些修改，并同意按本项目的 AGPL-3.0-only 许可发布。
