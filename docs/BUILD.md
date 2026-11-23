---
date: "2026-11-17"
updated: "2026-11-23"
---

# 星记双端构建与发布

以下命令在 Windows 的 PowerShell 7 中从仓库根目录执行。双端正式入口是 `lib/main.dart`。安装文件和构建号见[产品说明](../README.md)，已有验收记录见[开发交接](AGENT_HANDOFF.md#发布与验收记录)，打包与上传步骤见[发布说明](RELEASING.md)。

## 从空白克隆开始

独立克隆可以使用本机安装的工具。各路径优先采用显式设置的环境变量，其余位置按下表从左到右查找。“同级”指与仓库并列的目录。

| 用途 | 查找顺序 | 覆盖变量 |
| --- | --- | --- |
| 工具链 | 已有的同级 `.tools\`、仓库内 `.tools\`。选定目录中没有 Flutter 时使用 PATH | `XINGJI_TOOLS_ROOT` |
| 发布产物 | 已有的同级 `dist\`、仓库内 `dist\` | `XINGJI_DIST_ROOT` |
| 签名材料 | 已有的同级 `.signing\`、已有的仓库内 `.signing\`、`%LOCALAPPDATA%\XingJi\signing\` | `XINGJI_SIGNING_DIR` |
| Inno Setup | 工具链内 `InnoSetup\ISCC.exe`、Program Files 中安装的 Inno Setup | `XINGJI_ISCC` |

加载 `. .\tool\paths.ps1` 后可查看 `$ToolRoot`、`$DistRoot` 和 `$SigningRoot` 的实际位置。QA 夹具使用的 `.test-data\` 及各自的参数见下文“平台专项”。[路径解析](../tool/paths.ps1)


## 准备环境

| 范围 | 0.5.1 使用的工具 |
| --- | --- |
| 两端共用 | Flutter 3.47.8、Dart 3.13.7、PowerShell 7，Dart 依赖由 `pubspec.lock` 锁定。 |
| Windows | Windows 11 x64、Visual Studio 2022 Build Tools 的 C++ 桌面工具和 MSVC v143、Windows SDK、含简体中文语言文件的 Inno Setup 7.1.0。 |
| Android | JDK 17、Android SDK 36、Build Tools 36.0.0、NDK 28.2.13676358。Windows 下编译 sodium 还需 bash、GNU make 和 diffutils。 |
| 数据库集成测试 | 独立的 PostgreSQL 16 测试实例和有效的测试 CA。 |

`tool/env.ps1` 按上面的优先级加载 SDK、Pub 缓存及临时目录；只有检测到随仓库的 `.tools` 时才会隔离 `PUB_CACHE`、`TEMP` 和用户目录。`tool/android_env.ps1` 再设置 Android SDK、Gradle、JDK 和 shell 工具，缺 SDK 时会提示设置 `XINGJI_ANDROID_SDK` 或 `ANDROID_HOME`。单独检查工具链时，在当前 PowerShell 中加载对应脚本。[公共环境](../tool/env.ps1) · [Android 环境](../tool/android_env.ps1)

## 生成发布包

| 平台 | 命令 | 输出 |
| --- | --- | --- |
| Windows | `.\tool\build.ps1` | `dist\` 下的 x64 安装器、含安装器与安装说明的 ZIP、SHA-256 清单。 |
| Android | `.\tool\build_android.ps1` | `dist\android\` 下的签名 APK、使用说明、第三方声明、许可证和 SHA-256 清单。 |

两个入口默认运行依赖解析、静态分析、测试和 Release 编译。同一份代码已完成回归时，重复打包可加 `-SkipTests`。临时目录按构建任务分配并在结束后回收，SDK 和依赖缓存可复用。[Windows 脚本](../tool/build.ps1) · [Android 脚本](../tool/build_android.ps1)

- **Windows 版本与分发**　应用版本和构建号取自 [pubspec.yaml](../pubspec.yaml)。发布时同步更新[安装器定义](../installer/xingji.iss)的版本、[ZIP 脚本](../tool/package_release.ps1)的默认版本和安装说明。保留现有安装器 AppId、`XingJi.Desktop` 通知身份及 `xingji://` 协议。安装器包含 Flutter 引擎、DLL、运行库和 `data` 目录。
- **Android 覆盖升级**　沿用包名 `app.xingji.memo`、原发布密钥并递增 `--build-number`，同时更新脚本中的 APK 输出名。脚本将签名参数传给 Gradle，随后用 `apksigner` 核对签名。签名材料由发布环境单独保管：默认读取 `.signing\`（或 `XINGJI_SIGNING_DIR`），也可用 `XINGJI_ANDROID_KEYSTORE`、`XINGJI_ANDROID_STORE_PASSWORD`、`XINGJI_ANDROID_KEY_PASSWORD` 直接提供。证书指纹通过 `XINGJI_EXPECTED_CERT` 或签名目录下的 `release-cert.sha256` 固定；两者都不存在时只打印警告，方便其他开发者用本地密钥构建。
- **随包文档**　`docs/USER_GUIDE.md` 是两端使用说明的原稿。Android 脚本复制分发副本，Windows 安装器嵌入打包时的版本。数据库说明和 SQL 随 Windows 安装。两端使用 `collect_notices.ps1` 从依赖许可证生成的 UTF-8 第三方声明。[数据库说明](../database/README.md) · [声明生成脚本](../tool/collect_notices.ps1)

## 运行测试

```powershell
. .\tool\env.ps1
Get-XingJiDependencies
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
```

单独回归编辑器和本机图片，可运行 `flutter test --no-pub test/image_attachment_test.dart test/workflow_test.dart`。原生剪贴板、通知送达和系统时钟交接分别在对应平台核对。

### PostgreSQL 与 TLS

五项数据库用例默认跳过。使用独立测试实例，按[数据库说明](../database/README.md)准备 v2 结构，并按[同步用例](../test/sync_integration_test.dart)和[删除用例](../test/purge_sync_test.dart)配置测试角色。用例连接回环地址上的 55473 端口，TLS 测试证书应在有效期内，DNS SAN 包含 `localhost`。[TLS 用例](../test/transport_test.dart)

```powershell
$env:XINGJI_TEST_CA = (Resolve-Path -LiteralPath (Read-Host '测试 CA 的 PEM 文件路径')).Path
$env:XINGJI_PG_TEST = '1'
try {
    flutter test --no-pub --concurrency=1 --reporter=expanded
} finally {
    Remove-Item Env:XINGJI_PG_TEST, Env:XINGJI_TEST_CA -ErrorAction SilentlyContinue
}
```

### 平台专项

| 验证目标 | 入口与条件 |
| --- | --- |
| Windows 通知 | [QA 入口](../tool/qa_main.dart)用 `XINGJI_QA_PROFILE` 指定独立测试目录，两次运行分别安排通知和检查通知历史。该入口与正式程序共用通知身份，测试后使用正式入口重新构建。 |
| Windows 界面 | [预览生成器](../tool/seed_preview_test.dart)在 `XINGJI_UI_PROFILE` 指定的全新测试目录创建虚构资料，目录需位于仓库的 `.test-data/`（或同级工作区 `.test-data/`）下。启动应用时用 `--data-dir=` 指向该目录。 |
| Android 原生提醒 | 加载 Android 环境，启动一台专用测试模拟器后运行 `.\tool\test_android_reminders.ps1 -Serial (adb -e get-serialno)`。脚本会安装测试 APK 并替换测试提醒。10 秒测试验证前台时钟请求，30 秒测试经过正式排程和 Receiver。[原生测试脚本](../tool/test_android_reminders.ps1) |
| Android 升级与互通 | [升级夹具](../tool/android_upgrade_test.dart)验证同签名升级后的测试资料，[互通测试入口](../tool/android_qa.dart)验证 Keystore、备份、同步与排程。真机听感和厂商权限需在真机上逐项确认。 |

复建旧版 Android 测试环境时，可使用 `system-images;android-26;google_apis;x86_64` 镜像，并在测试 AVD 的 `config.ini` 中将 `hw.mainKeys` 设为 `no`，以启用虚拟导航栏。启动模拟器和执行测试的两个终端均需先加载 `. .\tool\android_env.ps1`。

## 常见构建问题

- **找不到 Visual Studio**　先运行 `flutter doctor -v`，确认已安装 C++ 桌面工具和 Windows SDK。使用工作区的便携 Build Tools 时，Windows 发布脚本会将 `vswhere` 返回的安装目录和版本传给 CMake，空白构建目录也能选中该实例。
- **Flutter 插件链接失败**　在加载 `tool/env.ps1` 后运行 `Get-XingJiDependencies`。Flutter 因 Windows 符号链接失败时，该命令会使用已解析的插件目录创建目录联接，再执行一次依赖解析。两个发布脚本调用同一入口。依赖已缓存时可加 `-Offline`。
- **安装后通知注册失败**　从 ZIP 解压到普通用户的“下载”文件夹后运行安装器。开发目录的低完整性标签可能影响通知注册，安装器会在用户临时目录写入 `Setup Log *.txt`。
