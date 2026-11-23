---
date: "2026-11-22"
updated: "2026-11-23"
---

# 星记发布流程

同一版本的 Windows 和 Android 构建共用一个 Git 标签和一个 Release。用户在 Release 页按平台下载，开发者从对应标签取得源码。

首次在 Windows 上准备源码提交时，暂存文件后执行 `git update-index --chmod=+x -- android/gradlew`。这样在 Unix 系统检出时，Gradle 启动脚本具有执行权限。

## 1. 同步版本号

一次发布要改完下面四处，漏一处会导致安装器或 APK 版本不一致。

| 位置 | 字段 |
| --- | --- |
| [pubspec.yaml](../pubspec.yaml) | `version: 0.5.1+9`（语义版本 + 构建号） |
| [installer/xingji.iss](../installer/xingji.iss) | `AppVersion`、`VersionInfoVersion` |
| [tool/package_release.ps1](../tool/package_release.ps1) | `param([string]$Version = '0.5.1')` |
| [tool/build_android.ps1](../tool/build_android.ps1) | 递增 `--build-number`，更新 APK 输出名 |

改完更新 [README.md](../README.md) 的安装表、[docs/USER_GUIDE.md](USER_GUIDE.md) 中的文件名，并在[开发交接](AGENT_HANDOFF.md#发布与验收记录)追加一条验收记录。

## 2. 构建两个发行包

```powershell
.\tool\build.ps1            # Windows：安装器 + ZIP + SHA-256 清单
.\tool\build_android.ps1    # Android：签名 APK + 说明 + 许可证 + SHA-256 清单
```

两个脚本默认跑依赖解析、静态分析、回归测试和 Release 编译；同一份代码已回归时可加 `-SkipTests`。产物写到 `dist\`（可用 `XINGJI_DIST_ROOT` 改到别处），该目录已被 `.gitignore` 排除。

正式发布沿用上个版本的 Android 签名。可将 `XINGJI_SIGNING_DIR` 指向存有 `xingji-android-release.p12` 和 `android-password.dpapi` 的私有目录，也可提供 `XINGJI_ANDROID_KEYSTORE` 和 `XINGJI_ANDROID_STORE_PASSWORD`。密钥别名为 `xingji-release`，密钥口令默认取库口令，可用 `XINGJI_ANDROID_KEY_PASSWORD` 覆盖。将上版已验证的签名证书 SHA-256 写入签名目录的 `release-cert.sha256`，或设置 `XINGJI_EXPECTED_CERT`。构建时会核对该指纹。首次本地试构建可以生成自己的测试密钥。

编译器可能将源码、工具链和调试符号的绝对路径写入二进制。正式附件宜在使用中性目录名的独立构建目录中生成。发布包中的应用许可证随 Windows 安装器、ZIP 和 APK 分发。

## 3. Release 资源清单

一个 tag 对应一个 Release，附以下文件：

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `XingJi-0.5.1-Windows-x64-Setup.exe` | `dist\` | 安装器，用户可直接运行 |
| `XingJi-0.5.1-Windows-x64.zip` | `dist\` | 含安装器、安装说明与 `LICENSE.txt` |
| `XingJi-0.5.1-Android.apk` | `dist\android\` | v2 签名，含 ARMv7 / ARM64 / x86_64 |
| `SHA256SUMS.txt` | 构建完成后按下方命令生成 | 本次三个下载文件各一条 SHA-256 |

两端都构建完成后，从这次要上传的三个文件重新计算清单。重新构建任一端后再执行一次。

```powershell
. .\tool\paths.ps1
$version = '0.5.1'
$assets = @(
    (Join-Path $DistRoot "XingJi-$version-Windows-x64-Setup.exe")
    (Join-Path $DistRoot "XingJi-$version-Windows-x64.zip")
    (Join-Path $DistRoot "android\XingJi-$version-Android.apk")
)
$hashes = Get-FileHash -LiteralPath $assets -Algorithm SHA256 -ErrorAction Stop
$hashes | ForEach-Object { $_.Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($_.Path) } |
    Set-Content -LiteralPath (Join-Path $DistRoot 'SHA256SUMS.txt') -Encoding ascii -ErrorAction Stop
```

上传时逐个选择表中四个文件。个人资料库的迁移导出可能包含记录密文、设备标识和账号授权，需留在私有工作区。开发者初始化或升级数据库时使用源码中的[结构脚本](../database/README.md)。

## 4. 打标签并上传

```powershell
git tag -a v0.5.1 -m "星记 0.5.1"
git push origin main
git push origin v0.5.1
```

在托管平台创建 `v0.5.1` 的 Release，标题写 `星记 0.5.1`，正文至少包含：

```markdown
## 星记 0.5.1

- Windows 11 x64（构建号 9）：`XingJi-0.5.1-Windows-x64.zip` 或 `...-Setup.exe`
- Android 8.0+（构建号 16）：`XingJi-0.5.1-Android.apk`，同一签名可覆盖升级

升级前请保留一份备份。校验值见 `SHA256SUMS.txt`。

### 本次改动
- <逐条列出用户可感知的变化>
```

上传后下载一次资源，用清单核对哈希：

```powershell
Get-FileHash .\XingJi-0.5.1-Windows-x64-Setup.exe -Algorithm SHA256
Get-FileHash .\XingJi-0.5.1-Windows-x64.zip -Algorithm SHA256
Get-FileHash .\XingJi-0.5.1-Android.apk -Algorithm SHA256
```

## 5. 发布前检查

- `git status --porcelain` 为空，标签指向的提交与构建出的源码一致。
- 首次公开提交前，运行 `git rev-parse --show-toplevel` 核对仓库根目录，运行 `git var GIT_AUTHOR_IDENT` 和 `git var GIT_COMMITTER_IDENT` 核对将公开的姓名和邮箱。带注释的标签也会保存署名。
- 提交里没有 `dist\`、`build\`、`.dart_tool\`、`.tools\`、`.signing\`、`.test-data\`、`*.apk`、`*.exe`。
- Release 资源与 `SHA256SUMS.txt` 全部对应，没有旧版本残留文件。
- 升级路径验证过：Windows 覆盖安装、Android 用同一签名的 APK 覆盖安装。
