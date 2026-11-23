# Local signing material is kept outside version control and never packaged.
# Supply XINGJI_ANDROID_KEYSTORE plus XINGJI_ANDROID_STORE_PASSWORD and
# XINGJI_ANDROID_KEY_PASSWORD to build with an existing keystore instead.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\paths.ps1"
if ($env:XINGJI_ANDROID_KEYSTORE -or $env:XINGJI_ANDROID_STORE_PASSWORD -or $env:XINGJI_ANDROID_KEY_PASSWORD) {
  if (-not $env:XINGJI_ANDROID_KEYSTORE -or -not $env:XINGJI_ANDROID_STORE_PASSWORD) {
    throw 'Set XINGJI_ANDROID_KEYSTORE and XINGJI_ANDROID_STORE_PASSWORD together.'
  }
  $env:XINGJI_ANDROID_KEYSTORE = (Get-Item -LiteralPath $env:XINGJI_ANDROID_KEYSTORE -ErrorAction Stop).FullName
  if (-not [IO.File]::Exists($env:XINGJI_ANDROID_KEYSTORE)) { throw 'The supplied Android keystore must be a file.' }
  $env:XINGJI_ANDROID_KEY_PASSWORD = if ($env:XINGJI_ANDROID_KEY_PASSWORD) { $env:XINGJI_ANDROID_KEY_PASSWORD } else { $env:XINGJI_ANDROID_STORE_PASSWORD }
  return
}
$AndroidSigningDirectory = $SigningRoot
$AndroidKeystorePath = Join-Path $AndroidSigningDirectory 'xingji-android-release.p12'
$AndroidPasswordPath = Join-Path $AndroidSigningDirectory 'android-password.dpapi'
Add-Type -AssemblyName System.Security
New-Item -ItemType Directory -Force -Path $AndroidSigningDirectory | Out-Null
if (-not (Test-Path -LiteralPath $AndroidKeystorePath)) {
  if (Test-Path -LiteralPath $AndroidPasswordPath) { throw 'Signing password exists without keystore. Restore the matching keystore instead of generating a new identity.' }
  $AndroidPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
  $AndroidPasswordBytes = [Text.Encoding]::UTF8.GetBytes($AndroidPassword)
  [IO.File]::WriteAllBytes($AndroidPasswordPath, [Security.Cryptography.ProtectedData]::Protect($AndroidPasswordBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
  [Array]::Clear($AndroidPasswordBytes, 0, $AndroidPasswordBytes.Length)
  $env:XINGJI_ANDROID_STORE_PASSWORD = $AndroidPassword
  & (Join-Path $env:JAVA_HOME 'bin\keytool.exe') -genkeypair -keystore $AndroidKeystorePath -storetype PKCS12 -storepass:env XINGJI_ANDROID_STORE_PASSWORD -keypass:env XINGJI_ANDROID_STORE_PASSWORD -alias xingji-release -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=XingJi Personal, OU=Development, O=XingJi, C=CN'
  if ($LASTEXITCODE -ne 0) { throw 'Android release certificate generation failed' }
  Write-Warning "Generated a new local signing identity in $AndroidKeystorePath. It cannot upgrade an installed official release; use the project's own keystore for distribution builds."
} else {
  $AndroidPasswordBytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($AndroidPasswordPath), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  $AndroidPassword = [Text.Encoding]::UTF8.GetString($AndroidPasswordBytes)
  [Array]::Clear($AndroidPasswordBytes, 0, $AndroidPasswordBytes.Length)
  $env:XINGJI_ANDROID_STORE_PASSWORD = $AndroidPassword
}
$env:XINGJI_ANDROID_KEYSTORE = $AndroidKeystorePath
$env:XINGJI_ANDROID_KEY_PASSWORD = $AndroidPassword
$AndroidPassword = $null
