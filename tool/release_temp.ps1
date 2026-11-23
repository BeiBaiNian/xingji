. "$PSScriptRoot\paths.ps1"

# Only directories allocated alongside an exclusive build lease belong to this cleaner.
function Remove-XingJiTempEntry([IO.FileSystemInfo]$Entry) {
  if ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    $Entry.Delete()
    return
  }
  if ($Entry -is [IO.DirectoryInfo]) {
    foreach ($child in $Entry.GetFileSystemInfos()) { Remove-XingJiTempEntry $child }
  } elseif ($Entry.IsReadOnly) {
    $Entry.IsReadOnly = $false
  }
  $Entry.Delete()
}

function Close-XingJiReleaseTemp([string]$Root, [IO.FileStream]$Lease) {
  $marker = [IO.FileInfo]::new($Lease.Name)
  $clean = $false
  try {
    if ($marker.DirectoryName -ne $Root -or $marker.Name -notmatch '^[a-f0-9]{32}\.lock$') {
      throw 'Invalid release temp lease path'
    }
    $folder = [IO.DirectoryInfo]::new([IO.Path]::Combine($Root, $marker.BaseName))
    if ($folder.Parent.FullName -ne $Root) { throw 'Invalid release temp directory' }
    if ($folder.Exists) { Remove-XingJiTempEntry $folder }
    $clean = $true
  } catch {
    Write-Warning "Release temporary files will be retried on the next build: $($_.Exception.Message)"
  } finally {
    $Lease.Dispose()
    if ($clean) {
      try { [IO.File]::Delete($marker.FullName) } catch [IO.IOException] { }
    }
  }
}

function Invoke-XingJiRelease([scriptblock]$Build, [switch]$Android) {
  $ErrorActionPreference = 'Stop'
  $saved = @{}
  foreach ($key in 'TEMP','TMP','TMPDIR','GRADLE_OPTS','ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy','MSBUILDDISABLENODEREUSE','CMAKE_TOOLCHAIN_FILE','XINGJI_PORTABLE_VS_INSTANCE') {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key)
  }
  $lease = $null
  Push-Location (Join-Path $PSScriptRoot '..')
  try {
    if ($Android) { . "$PSScriptRoot\android_env.ps1" } else { . "$PSScriptRoot\env.ps1" }
    $root = $ReleaseTempRoot
    foreach ($dir in $env:TEMP,$root) {
      $info = [IO.Directory]::CreateDirectory($dir)
      if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unexpected linked directory: $dir" }
    }
    foreach ($marker in [IO.DirectoryInfo]::new($root).GetFiles('*.lock')) {
      if ($marker.Name -notmatch '^[a-f0-9]{32}\.lock$' -or ($marker.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
      try { $stale = $marker.Open('Open', 'ReadWrite', 'None') } catch [IO.IOException] { continue }
      Close-XingJiReleaseTemp $root $stale
    }
    $id = [Guid]::NewGuid().ToString('N')
    $lease = [IO.File]::Open((Join-Path $root "$id.lock"), 'CreateNew', 'ReadWrite', 'None')
    $env:TEMP = [IO.Directory]::CreateDirectory((Join-Path $root $id)).FullName
    $env:TMP = $env:TEMP
    $env:TMPDIR = $env:TEMP
    $env:MSBUILDDISABLENODEREUSE = '1'
    if ($Android) {
      if ($AndroidBash) { $env:TMPDIR = (& $AndroidBash.Source -c 'cygpath -u "$TEMP"').Trim() }
      $env:GRADLE_OPTS = "$env:GRADLE_OPTS -Dorg.gradle.daemon=false"
      [Environment]::SetEnvironmentVariable('ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy', 'in-process')
    }
    # Toolchain commands (flutter, gradle, MSVC, Inno Setup, apksigner) report
    # progress on stderr. Under 'Stop' a captured or merged stream turns such a
    # notice into a terminating error, so the build block runs with 'Continue'
    # and every step checks $LASTEXITCODE itself.
    $ErrorActionPreference = 'Continue'
    & $Build
  } finally {
    $ErrorActionPreference = 'Stop'
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    if ($lease) { Close-XingJiReleaseTemp $root $lease }
    Pop-Location
  }
}
