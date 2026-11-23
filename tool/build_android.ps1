param([switch]$SkipTests)
. "$PSScriptRoot\release_temp.ps1"
# Gradle and apksigner write progress and notices to stderr. Keep a redirected
# or merged build log from turning those notices into terminating errors; every
# step below still checks its own exit code.
$ErrorActionPreference = 'Continue'
Invoke-XingJiRelease -Android -Build {
  Get-XingJiDependencies
  & $FlutterExe analyze --no-pub
  if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed' }
  if (-not $SkipTests) {
    & $FlutterExe test --no-pub --concurrency=1
    if ($LASTEXITCODE -ne 0) { throw 'Regression tests failed' }
  }
  $signingEnvironment = @{}
  foreach ($name in 'XINGJI_ANDROID_KEYSTORE','XINGJI_ANDROID_STORE_PASSWORD','XINGJI_ANDROID_KEY_PASSWORD') {
    $signingEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
  }
  try {
    & "$PSScriptRoot\android_signing.ps1"
    & $FlutterExe build apk --release --no-pub --target=lib/main.dart --build-number=16
    if ($LASTEXITCODE -ne 0) { throw 'Android APK build failed' }
  } finally {
    foreach ($name in $signingEnvironment.Keys) {
      [Environment]::SetEnvironmentVariable($name, $signingEnvironment[$name])
    }
  }
  $AndroidOutput = Join-Path $DistRoot 'android'
  New-Item -ItemType Directory -Force -Path $AndroidOutput -ErrorAction Stop | Out-Null
  $AndroidApk = Join-Path $AndroidOutput 'XingJi-0.5.1-Android.apk'
  $builtApk = (Resolve-Path 'build\app\outputs\flutter-apk\app-release.apk').Path
  $signature = & (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\apksigner.bat') verify --verbose --print-certs $builtApk
  if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed' }
  $signature
  # Pin the published upgrade chain only when the release certificate is known.
  # A locally generated keystore cannot continue the official upgrade path, so
  # the check stays informational unless XINGJI_EXPECTED_CERT is provided.
  $actual = ($signature | Where-Object { $_ -match '^Signer #1 certificate SHA-256 digest: ' } |
    ForEach-Object { ($_ -split ':', 2)[1].Trim() } | Select-Object -First 1)
  $expected = $env:XINGJI_EXPECTED_CERT
  if (-not $expected -and (Test-Path -LiteralPath (Join-Path $SigningRoot 'release-cert.sha256') -PathType Leaf)) {
    $expected = (Get-Content -LiteralPath (Join-Path $SigningRoot 'release-cert.sha256') -Raw -ErrorAction Stop).Trim()
  }
  if ($expected) {
    if ($actual -ne $expected) { throw "Unexpected Android release certificate: $actual" }
    "Release certificate digest matches the pinned value."
  } else {
    Write-Warning "Release certificate digest is not pinned (actual: $actual). Set XINGJI_EXPECTED_CERT or create release-cert.sha256 in the signing directory to enforce the official upgrade chain."
  }
  Copy-Item -LiteralPath $builtApk -Destination $AndroidApk -Force -ErrorAction Stop
  & "$PSScriptRoot\collect_notices.ps1"
  Copy-Item -LiteralPath 'docs\USER_GUIDE.md' -Destination (Join-Path $AndroidOutput 'USER_GUIDE.md') -Force -ErrorAction Stop
  Copy-Item -LiteralPath 'docs\THIRD_PARTY_NOTICES.txt' -Destination (Join-Path $AndroidOutput 'THIRD_PARTY_NOTICES.txt') -Force -ErrorAction Stop
  Copy-Item -LiteralPath 'LICENSE' -Destination (Join-Path $AndroidOutput 'LICENSE.txt') -Force -ErrorAction Stop
  $apkHash = (Get-FileHash -LiteralPath $AndroidApk -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  ($apkHash + '  ' + [IO.Path]::GetFileName($AndroidApk)) |
    Set-Content -LiteralPath (Join-Path $AndroidOutput 'SHA256SUMS.txt') -Encoding ascii -ErrorAction Stop
  Get-Item -LiteralPath $AndroidApk | Select-Object Name,Length
}
