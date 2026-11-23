param([string]$Serial = 'emulator-5554')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\android_env.ps1"
Set-Location (Join-Path $PSScriptRoot '..')
if (-not $Serial.StartsWith('emulator-')) { throw 'Only an isolated emulator is allowed' }
$Hardware = (& adb -s $Serial shell getprop ro.hardware).Trim()
if ($Hardware -notin @('ranchu', 'goldfish')) { throw 'Isolated emulator required' }
# Native instrumentation uses fictional schedules; never install this onto a real phone.
flutter build apk --debug --no-pub --target=lib/main.dart --target-platform=android-x64
if ($LASTEXITCODE -ne 0) { throw 'Debug build failed' }
Push-Location android
try {
  $InstalledNdk = (Get-ChildItem -LiteralPath "$env:ANDROID_HOME\ndk" -Directory).Name -join ','
  & .\gradlew.bat :app:assembleDebugAndroidTest -Ptarget-platform=android-x64 "-Pflutter.androidSdkRoot=$env:ANDROID_HOME" "-Pflutter.installedNdkVersions=$InstalledNdk" --offline --console=plain
  if ($LASTEXITCODE -ne 0) { throw 'Instrumentation build failed' }
} finally { Pop-Location }
& adb -s $Serial install -r 'build\app\outputs\flutter-apk\app-debug.apk'
if ($LASTEXITCODE -ne 0) { throw 'Fixture app install failed; use a clean isolated emulator' }
& adb -s $Serial install -r 'build\app\outputs\apk\androidTest\debug\app-debug-androidTest.apk'
if ($LASTEXITCODE -ne 0) { throw 'Instrumentation install failed' }
$Result = & adb -s $Serial shell am instrument -w -e isolated true 'app.xingji.memo.test/app.xingji.memo.ReminderInstrumentation'
$Result
if ($LASTEXITCODE -ne 0 -or ($Result -join "`n") -notmatch 'INSTRUMENTATION_CODE: -1' -or ($Result -join "`n") -match 'failure=') {
  throw 'Native reminder checks failed'
}
