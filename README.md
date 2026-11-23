---
date: "2026-11-17"
updated: "2026-11-23"
---

# 星记 XingJi

星记是一款离线可用的加密备忘录。可以给事项设置提醒、完成后归档，再按日期查看。需要在电脑和手机之间同步时，两端可连接同一个 PostgreSQL 资料库。

仓库包含应用源码、图标、测试、文档和数据库结构脚本。`pubspec.lock` 锁定 Dart 依赖，Gradle Wrapper 按工程指定的版本下载 Gradle。

## 安装 0.5.1

版本发布后，可在本仓库的 Releases（发行版）页下载以下文件。

| 平台 | 系统与构建号 | 发布资源 |
| --- | --- | --- |
| Windows | Windows 11 x64，构建号 9 | `XingJi-0.5.1-Windows-x64.zip`（含安装器、安装说明和许可证） |
| Windows | Windows 11 x64，构建号 9 | `XingJi-0.5.1-Windows-x64-Setup.exe` |
| Android | Android 8.0 或以上，构建号 16 | `XingJi-0.5.1-Android.apk`（v2 签名，ARMv7 / ARM64 / x86_64） |

Windows 任选一种下载。可以直接运行安装器，也可以将 ZIP 解压到“下载”文件夹后运行其中的同一个安装器。Android 可用同一签名的 APK 覆盖升级。用同页的 `SHA256SUMS.txt` 核对下载文件。[安装与升级说明](docs/USER_GUIDE.md#安装与升级)

## 首次使用

- **单机记录**　在欢迎页创建资料库，设置主密码，离线保存首次显示的恢复码。可为事项添加清单、重复规则和提醒。[首次使用与密码](docs/USER_GUIDE.md#首次使用与密码)
- **接入另一台设备**　先在原设备配置同步，新设备在欢迎页选择“连接已有资料库”。[同步步骤](docs/USER_GUIDE.md#postgresql-双端同步) · [数据库部署](database/README.md)
- **添加图片**　Windows 在标题或正文按 `Ctrl+V`，Android 在编辑页选择或粘贴图片。图片仅在添加它的设备上加密保存，换机前请另存原图。[本机图片说明](docs/USER_GUIDE.md#添加本机图片)

## 数据与隐私

- 业务内容以 XChaCha20-Poly1305 加密后写入本机 SQLite，主密码通过 Argon2id 包装资料库密钥。
- 设备密钥由 Windows DPAPI 或 Android Keystore 保护；数据库口令同样保存在受保护的数据块中，不写明文。
- 单机记录可离线使用。测试连接、接入已有资料库或同步时，应用会连接你填写的 PostgreSQL 主机。启用后台同步后，也可由系统调度连接。
- 同步时标题和正文等业务字段以密文传输。服务端还保存数据库角色、资料库和设备标识、同步游标、写入时间等元数据。

## 从源码构建

以下命令在 Windows 的 PowerShell 7 中执行，使用 Flutter 3.47.8（Dart 3.13.7）。Windows 安装器还需要 Visual Studio 2022 C++ 桌面工具、Windows SDK 和 Inno Setup。Android 需要 JDK 17、Android SDK 和 NDK。[构建环境与版本](docs/BUILD.md#准备环境)

```powershell
git clone <仓库地址> xingji
cd xingji
. .\tool\env.ps1
Get-XingJiDependencies
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
```

```powershell
.\tool\build.ps1 -SkipTests          # Windows：安装器、ZIP、SHA-256 清单 → dist\
.\tool\build_android.ps1 -SkipTests  # Android：签名 APK、说明、许可证 → dist\android\
```

独立克隆可直接使用 PATH 中的 Flutter。默认发布目录为仓库内的 `dist\`。已有同级工具、签名或产物目录的工作区可沿用原布局，也可以通过环境变量显式指定各目录。[路径选择顺序](docs/BUILD.md#从空白克隆开始)

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| [lib/](lib/main.dart) | Flutter 共用业务层：存储、加密、同步与界面 |
| [android/](android/app/src/main/kotlin/app/xingji/memo/) · [windows/](windows/runner/) | 两端原生工程与提醒、通知桥接 |
| [database/](database/README.md) | PostgreSQL 结构脚本与部署说明 |
| [tool/](tool/build.ps1) | 构建、打包、签名、QA 夹具脚本 |
| [test/](test/core_test.dart) | 加密、存储、同步与界面的回归测试 |
| [docs/](docs/AGENT_HANDOFF.md) | 开发交接、构建说明、使用说明、发布流程 |

## 参与开发

提 issue 或 PR 前请先运行 `flutter analyze --no-pub` 与 `flutter test --no-pub --concurrency=1`。改动同步协议或数据库结构时，请同时更新 [database/](database/README.md) 与[开发交接](docs/AGENT_HANDOFF.md)中的兼容性说明。发布流程见[发布说明](docs/RELEASING.md)。

## 许可

源码以 [MIT 许可证](LICENSE)发布。第三方组件的许可证与声明见[第三方声明](docs/THIRD_PARTY_NOTICES.txt)。
