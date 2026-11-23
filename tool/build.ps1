param([switch]$SkipTests)
. "$PSScriptRoot\release_temp.ps1"
# Flutter, MSVC and Inno Setup write progress and notices to stderr. Keep a
# redirected or merged build log from turning those notices into terminating
# errors; every step below still checks its own exit code.
$ErrorActionPreference = 'Continue'

Invoke-XingJiRelease -Build {
  Get-XingJiDependencies
  & $FlutterExe analyze --no-pub
  if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed' }
  if (-not $SkipTests) {
    & $FlutterExe test --no-pub --concurrency=1
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
  }
  $VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $VsInstance = & $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json | Select-Object -First 1
  $VsRoot = $VsInstance.installationPath
  if (-not $VsRoot) { throw 'Visual Studio or Build Tools with the C++ x64 toolchain was not found' }
  $portableVsWhere = Join-Path $ToolRoot 'vswhere-shim\Microsoft Visual Studio\Installer\vswhere.exe'
  if ($VsWhere -eq $portableVsWhere -and -not $env:CMAKE_TOOLCHAIN_FILE) {
    $v = [version]$VsInstance.installationVersion
    $buildVersion = [version]::new($v.Major, $v.Minor, [Math]::Max(0, $v.Build), [Math]::Max(0, $v.Revision))
    $env:XINGJI_PORTABLE_VS_INSTANCE = "$($VsRoot.Replace('\','/')),version=$buildVersion"
    $env:CMAKE_TOOLCHAIN_FILE = Join-Path $PSScriptRoot 'portable_msvc.cmake'
  }
  & $FlutterExe build windows --release --no-pub --target=lib/main.dart
  if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
  $ReleaseDirectory = (Resolve-Path '.\build\windows\x64\runner\Release' -ErrorAction Stop).Path
  $RuntimeDirectory = Get-ChildItem -LiteralPath (Join-Path $VsRoot 'VC\Redist\MSVC') -Directory |
    Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $RuntimeDirectory) { throw 'MSVC redistributable DLLs not found' }
  Get-ChildItem -LiteralPath $RuntimeDirectory -Filter '*.dll' -ErrorAction Stop | Copy-Item -Destination $ReleaseDirectory -ErrorAction Stop
  & "$PSScriptRoot\collect_notices.ps1"
  if (-not $IsccExe) {
    throw 'Inno Setup compiler not found. Install Inno Setup or set XINGJI_ISCC to ISCC.exe.'
  }
  & $IsccExe ".\installer\xingji.iss" "/DDistDir=$DistRoot"
  if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed' }
  & "$PSScriptRoot\package_release.ps1"
}
