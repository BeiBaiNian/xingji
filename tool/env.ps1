$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\paths.ps1"

# A bundled toolchain at <root>\.tools isolates caches from the host profile.
# Without one, the developer's own Flutter, Pub cache and profile are used.
if ($UsingBundledTools) {
  $env:PATH = "$FlutterBin;$env:PATH"
  $env:PUB_CACHE = Join-Path $ToolRoot 'pub-cache'
  $env:TEMP = Join-Path $ToolRoot 'tmp'
  $env:TMP = $env:TEMP
  $env:APPDATA = Join-Path $ToolRoot 'appdata'
  $env:LOCALAPPDATA = Join-Path $ToolRoot 'local-appdata'
  if (-not $env:FLUTTER_STORAGE_BASE_URL) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
  New-Item -ItemType Directory -Force -Path $env:TEMP,$env:APPDATA,$env:LOCALAPPDATA,$env:PUB_CACHE | Out-Null
  # BuildTools under .tools is not registered with the Visual Studio Installer. The sodium native-assets hook looks for vswhere under ProgramFiles(x86); point it at the local shim, which reports the BuildTools instance.
  $VsWhereShimRoot = Join-Path $ToolRoot 'vswhere-shim'
  if (Test-Path -LiteralPath (Join-Path $VsWhereShimRoot 'Microsoft Visual Studio\Installer\vswhere.exe')) { ${env:ProgramFiles(x86)} = $VsWhereShimRoot }
}
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'

function Get-XingJiDependencies([switch]$Offline) {
  $pubArgs = @('pub', 'get')
  if ($Offline) { $pubArgs += '--offline' }
  Push-Location -LiteralPath $ProjectRoot
  try {
    # Flutter writes the plugin list before it tries the Windows symlinks.
    # Retry only that failure. Keep native stderr readable when output is redirected.
    $ErrorActionPreference = 'Continue'
    $linkError = $false
    & $FlutterExe @pubArgs 2>&1 | ForEach-Object {
      $line = $_.ToString()
      if ($line -match 'requires symlink support|trying to create a symlink|Creating symlink .+ ERROR_INVALID_FUNCTION') {
        $linkError = $true
      }
      Write-Host $line
    }
    if ($LASTEXITCODE -eq 0) { return }
    if (-not $linkError) { throw "flutter pub get failed (exit $LASTEXITCODE)." }

    $metadata = Get-Content -LiteralPath '.flutter-plugins-dependencies' -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $metadata.plugins.windows) { throw 'No resolved Windows plugins to link.' }
    $linkRoot = Join-Path $ProjectRoot 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Force -Path $linkRoot -ErrorAction Stop | Out-Null
    foreach ($plugin in $metadata.plugins.windows) {
      $link = Join-Path $linkRoot $plugin.name
      if (-not (Test-Path -LiteralPath $link)) {
        New-Item -ItemType Junction -Path $link -Target $plugin.path -ErrorAction Stop | Out-Null
      }
    }
    Write-Host 'Prepared Windows plugin junctions. Retrying flutter pub get.'
    & $FlutterExe @pubArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed after preparing plugin junctions (exit $LASTEXITCODE)." }
  } finally {
    Pop-Location
  }
}
