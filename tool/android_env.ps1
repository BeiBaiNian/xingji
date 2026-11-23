. "$PSScriptRoot\env.ps1"

# Android SDK: explicit override, bundled copy, then the machine's own install.
$AndroidSdkCandidates = @(
  $env:XINGJI_ANDROID_SDK,
  (Join-Path $ToolRoot 'android-sdk'),
  $env:ANDROID_HOME,
  $env:ANDROID_SDK_ROOT,
  (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Android\Sdk')
)
$AndroidSdk = $null
foreach ($Candidate in $AndroidSdkCandidates) {
  if ($Candidate -and (Test-Path -LiteralPath (Join-Path $Candidate 'platform-tools') -PathType Container)) {
    $AndroidSdk = [IO.Path]::GetFullPath($Candidate)
    break
  }
}
if (-not $AndroidSdk) {
  throw 'Android SDK not found. Set XINGJI_ANDROID_SDK or ANDROID_HOME to a directory containing platform-tools.'
}
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk

# Gradle and emulator state stay inside a bundled toolchain; otherwise the
# machine defaults (%USERPROFILE%\.gradle, %USERPROFILE%\.android) apply.
if (Test-Path -LiteralPath (Join-Path $ToolRoot 'gradle') -PathType Container) {
  $env:GRADLE_USER_HOME = Join-Path $ToolRoot 'gradle'
}
if (Test-Path -LiteralPath (Join-Path $ToolRoot 'android-user') -PathType Container) {
  $env:ANDROID_USER_HOME = Join-Path $ToolRoot 'android-user'
  $env:ANDROID_EMULATOR_HOME = $env:ANDROID_USER_HOME
}
if (-not $env:JAVA_HOME -or -not (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
  $AndroidJava = (Get-Command javac.exe -ErrorAction Stop).Source
  $env:JAVA_HOME = Split-Path (Split-Path $AndroidJava -Parent) -Parent
}
$env:PATH = "$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:PATH"
$AndroidBash = Get-Command bash.exe -ErrorAction SilentlyContinue
if ($AndroidBash) {
  $AndroidShellBin = Split-Path $AndroidBash.Source -Parent
  $env:PATH = "$AndroidShellBin;$env:PATH"
  $env:TMPDIR = (& $AndroidBash.Source -c 'cygpath -u "$TEMP"').Trim()
}
if ($env:GRADLE_USER_HOME) { New-Item -ItemType Directory -Force -Path $env:GRADLE_USER_HOME | Out-Null }
if ($env:ANDROID_USER_HOME) { New-Item -ItemType Directory -Force -Path $env:ANDROID_USER_HOME | Out-Null }
