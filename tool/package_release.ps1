param([string]$Version = '0.5.1')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\paths.ps1"
$OutputDirectory = $DistRoot
$InstallerName = "XingJi-$Version-Windows-x64-Setup.exe"
$Installer = Join-Path $OutputDirectory $InstallerName
if (-not (Test-Path -LiteralPath $Installer)) { throw "Installer missing: $Installer" }
$Archive = Join-Path $OutputDirectory "XingJi-$Version-Windows-x64.zip"
$Readme = Join-Path $OutputDirectory '安装说明.txt'
$License = Join-Path $OutputDirectory 'LICENSE.txt'
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENSE') -Destination $License -Force
$ReadmeContent = @(
  "星记 $Version · Windows 11 x64"
  ''
  '1. 将本 ZIP 解压到你的“下载”文件夹。'
  "2. 运行解压后的 $InstallerName，使用默认安装目录。"
  '3. 从桌面或开始菜单的“星记”快捷方式启动。'
  ''
  '复制截图或浏览器中的图片，把光标放在备忘录标题或正文，按 Ctrl+V 添加图片。复制文字时，Ctrl+V 会在光标处粘贴文字。正文下方可预览和移除图片，每条最多 9 张。图片只在本机加密保存，换机前请另行保留原图。'
  ''
  '不要直接在 ZIP 内或开发项目目录中运行安装程序。开发目录可能带有低完整性标签，导致安装程序无法写入通知注册项。无需修改 Windows 安全设置。'
  ''
  '设置提醒时，在日历中选日期，在 24 小时钟面上先点小时，再点分钟，点“确定”保存。点“取消”保留原值。'
  ''
  '首页展示今天全部待办，按紧急程度和时间排序；已过时间的事项自动变灰置后，仍可继续处理。左侧范围菜单采用圆角与图标，当前范围有勾选提示。'
  ''
  '“按日期查看”可回看归档和未来安排。回收站支持二次确认后永久删除。仍使用 PostgreSQL 结构 v1 的资料库，可由管理员执行安装目录中的 database/002_permanent_delete.sql 升级到 v2，详情见同目录的 README.md。'
  ''
  '本发行包按其开源许可证分发，条款见 LICENSE.txt；随包第三方组件声明见安装目录的 docs/THIRD_PARTY_NOTICES.txt。'
)
$ReadmeContent | Set-Content -LiteralPath $Readme -Encoding utf8
# ZIP contains ordinary file bytes, not workspace NTFS security labels.
# Extract it into a normal per-user directory for installation.
Compress-Archive -LiteralPath $Installer,$Readme,$License -DestinationPath $Archive -Force
Get-FileHash -LiteralPath $Installer,$Archive -Algorithm SHA256 |
  ForEach-Object { $_.Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($_.Path) } |
  Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ascii
Get-Item -LiteralPath $Installer,$Archive | Select-Object Name,Length
