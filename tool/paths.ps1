# Path resolution shared by every build and release script.
#
# A standalone clone can use machine-installed tools. Outputs default to dist
# in the clone and signing material can live in the user's application data.
#
# A personal workspace that keeps .tools, .signing and dist next to
# the clone keeps working unchanged: those sibling directories win when present.
# Every root can also be pinned explicitly:
#   XINGJI_TOOLS_ROOT   toolchain root (flutter, pub-cache, Inno Setup, ...)
#   XINGJI_DIST_ROOT    release output directory
#   XINGJI_SIGNING_DIR  keystore and DPAPI-wrapped password
#   XINGJI_RELEASE_TEMP temp lease root for release runs
#   XINGJI_ISCC         full path to Inno Setup's ISCC.exe
#
# This file only assigns variables and has no side effects, so it is safe to
# dot-source from more than one script in the same session.

$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$WorkspaceRoot = Split-Path -Parent $ProjectRoot

function Test-XingJiPath([string]$LiteralPath) {
  if (-not $LiteralPath) { return $false }
  return (Test-Path -LiteralPath $LiteralPath -PathType Container)
}

function Resolve-XingJiRoot([string]$Override, [string]$First, [string]$Last) {
  if ($Override) { return [IO.Path]::GetFullPath($Override) }
  if (Test-XingJiPath $First) { return [IO.Path]::GetFullPath($First) }
  return [IO.Path]::GetFullPath($Last)
}

$ToolRoot = Resolve-XingJiRoot $env:XINGJI_TOOLS_ROOT `
  (Join-Path $WorkspaceRoot '.tools') `
  (Join-Path $ProjectRoot '.tools')
$UsingBundledTools = Test-XingJiPath $ToolRoot

$FlutterBin = Join-Path $ToolRoot 'flutter\bin'
if (Test-Path -LiteralPath (Join-Path $FlutterBin 'flutter.bat') -PathType Leaf) {
  $FlutterExe = Join-Path $FlutterBin 'flutter.bat'
} else {
  # No bundled SDK: fall back to the flutter command on PATH.
  $FlutterExe = 'flutter'
}

$DistRoot = Resolve-XingJiRoot $env:XINGJI_DIST_ROOT `
  (Join-Path $WorkspaceRoot 'dist') `
  (Join-Path $ProjectRoot 'dist')

$DefaultSigningRoot = Join-Path $ProjectRoot '.signing'
if (-not (Test-XingJiPath $DefaultSigningRoot)) {
  $DefaultSigningRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'XingJi\signing'
}
$SigningRoot = Resolve-XingJiRoot $env:XINGJI_SIGNING_DIR `
  (Join-Path $WorkspaceRoot '.signing') `
  $DefaultSigningRoot

if ($env:XINGJI_RELEASE_TEMP) {
  $ReleaseTempRoot = [IO.Path]::GetFullPath($env:XINGJI_RELEASE_TEMP)
} elseif (Test-XingJiPath $ToolRoot) {
  $ReleaseTempRoot = Join-Path $ToolRoot 'tmp\release-runs'
} else {
  $ReleaseTempRoot = Join-Path $ProjectRoot 'build\release-runs'
}

$IsccExe = $env:XINGJI_ISCC
if (-not $IsccExe) {
  $IsccCandidates = @(Join-Path $ToolRoot 'InnoSetup\ISCC.exe')
  foreach ($Root in @("${env:ProgramFiles(x86)}", $env:ProgramFiles)) {
    if (-not $Root) { continue }
    $IsccCandidates += Get-ChildItem -Path (Join-Path $Root 'Inno Setup*\ISCC.exe') -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.FullName }
  }
  $IsccExe = $IsccCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
}
