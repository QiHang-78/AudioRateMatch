# 上传与发布

本项目目录可作为一个独立 Git 仓库。源码发布包包含文档、源码、测试和隐藏的 Git 配置文件，不携带本机 Git 历史、用户身份、构建缓存、私人诊断或音乐文件。

## 首次上传到 GitHub / Gitee

在平台上创建一个空仓库，建议名称 `AudioRateMatch`。不要让平台额外生成 README 或许可证，以便直接上传这份项目。准备使用 MIT 许可证发布时保留根目录 `LICENSE`；其中版权署名目前为 `AudioRateMatch contributors`。

解压源码包，在包含 `README.md` 的项目根目录打开终端。使用自己的 Git 作者身份，然后执行：

```sh
git init -b main
git add .
git diff --cached --check
git status --short
git commit -m "Initial open-source release of AudioRateMatch 1.0"
git remote add origin YOUR_REPOSITORY_URL
git push -u origin main
```

先将 `YOUR_REPOSITORY_URL` 替换为平台给出的 SSH 或 HTTPS 仓库地址。仓库已有提交时，应在现有克隆中合并项目文件，不使用强制推送。源码压缩包不携带 Git 历史或远程配置；从平台克隆的仓库则已经包含这些信息，无需重新初始化。

`.gitignore` 排除 `.build/`、`dist/`、应用包、压缩包、日志和常见本地配置。如果使用网页上传，请上传解压后的文件并包含 `.github/`、`.gitignore`、`.gitattributes` 和 `.editorconfig`；直接把源码 ZIP 作为唯一文件上传不会形成可浏览的代码仓库。CLI 上传可完整保留这些文件和脚本执行权限。

建议仓库描述：

> A native macOS menu-bar utility that matches output sample rates to verified playback streams.

可选 Topics：`macos`、`swift`、`coreaudio`、`audio`、`sample-rate`、`menu-bar`。

## 本地构建与打包

```sh
bash test.sh
bash package.sh --arch universal
```

也可将架构换成 `native`、`arm64` 或 `x86_64`。产物示例：

```text
dist/AudioRateMatch.app
dist/AudioRateMatch-1.0-macOS-universal.zip
dist/AudioRateMatch-1.0-macOS-universal.zip.sha256
```

构建脚本从 `VERSION` 读取版本并写入应用 Bundle 的两个版本字段，支持 `1.0` 或 `1.0.1` 这样的格式。`Resources/Info.plist` 中的 `0.0` 是模板占位值。所有路径相对项目本身解析，可以从其他工作目录调用脚本。

ZIP 使用系统 `ditto` 保存应用结构和执行权限。可以在 `dist/` 中执行以下命令验证下载文件：

```sh
shasum -a 256 -c AudioRateMatch-1.0-macOS-universal.zip.sha256
```

## GitHub Actions

`.github/workflows/ci.yml` 在 push、pull request 和手动触发时运行。Apple Silicon 与 Intel runner 分别进行合成测试、原生应用构建、CLI 版本检查、签名验证及 ZIP 打包，并保存构建产物。

工作流仅申请读取仓库内容的权限，不需要自定义密钥，不推送提交，不创建 Release。上传仓库后查看 Actions 结果；本地构建通过不等于已完成远程 CI。Gitee 需要另行配置其 CI。

配置所用 runner 和 Action 来自 GitHub 官方资料：[runner 列表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[checkout](https://github.com/actions/checkout)、[upload-artifact](https://github.com/actions/upload-artifact)。维护时可以按官方说明更新版本。

## 创建 Release

更新 `VERSION`、README、`CHANGELOG.md` 和实际验证记录，通过测试及构建后提交更改。修改图标绘制代码后先运行 `bash scripts/generate-icons.sh`，并提交 `Resources/AppIcon.icns` 和 `Resources/AppIcon.png`。再创建对应标签，例如：

```sh
git tag v1.0
git push origin v1.0
```

在平台发布页选择该标签，附上应用 ZIP 和对应 `.sha256` 文件，并说明 macOS 要求、构建架构、签名 / 公证状态和格式识别限制。二进制作为 Release 附件，源码由 Git 保存。

当前脚本使用 ad-hoc 签名，只校验包的完整性；它不代表 Apple Developer ID 身份或 Apple 公证。需要面向公众分发已公证二进制时，应在有权使用的 Apple Developer 账号下另行完成 Developer ID 签名、公证及 stapling，并对最终签名产物重新打包生成校验值。证书和账号凭据不应写入源码仓库。
