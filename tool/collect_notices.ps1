$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ConfigurationDirectory = Join-Path $ProjectRoot '.dart_tool'
$Configuration = Get-Content -LiteralPath (Join-Path $ConfigurationDirectory 'package_config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Notices = [Collections.Generic.List[string]]::new()
$Notices.Add("星记第三方组件声明`nGenerated from the resolved dependency licenses. Application source is supplied separately; component licenses apply to their respective components.")
foreach ($Package in ($Configuration.packages | Sort-Object name)) {
    if ($Package.name -eq 'xingji') { continue }
    if ($Package.rootUri.StartsWith('file:')) {
        $PackageDirectory = ([Uri]$Package.rootUri).LocalPath
    } else {
        $PackageDirectory = [IO.Path]::GetFullPath((Join-Path $ConfigurationDirectory ([Uri]::UnescapeDataString($Package.rootUri))))
    }
    foreach ($LicenseName in @('LICENSE', 'LICENSE.txt', 'COPYING')) {
        $LicensePath = Join-Path $PackageDirectory $LicenseName
        if (Test-Path -LiteralPath $LicensePath -PathType Leaf) {
            $Notices.Add("`n========================================`n$($Package.name)`n========================================`n" + (Get-Content -LiteralPath $LicensePath -Raw -Encoding UTF8))
            break
        }
    }
}
$SodiumSource = Join-Path $ConfigurationDirectory 'hooks_runner\shared\sodium'
if (Test-Path -LiteralPath $SodiumSource) {
    $NativeLicense = Get-ChildItem -LiteralPath $SodiumSource -Filter 'LICENSE' -Recurse -File |
        Where-Object { $_.Directory.Name -eq 'libsodium-stable' } | Select-Object -First 1
    if ($NativeLicense) { $Notices.Add("`n========================================`nlibsodium native library`n========================================`n" + (Get-Content -LiteralPath $NativeLicense.FullName -Raw -Encoding UTF8)) }
}
$Notices.Add("`nSQLite native library: https://www.sqlite.org/copyright.html`nMicrosoft Visual C++ runtime components (Windows only): https://visualstudio.microsoft.com/license-terms/`nFlutter engine and bundled component notices are also available in the application's open-source licenses page (Android: Settings > Appearance and information; Windows: Settings > Diagnostics).")
[IO.File]::WriteAllText((Join-Path $ProjectRoot 'docs\THIRD_PARTY_NOTICES.txt'), ($Notices -join "`n"), [Text.UTF8Encoding]::new($false))
