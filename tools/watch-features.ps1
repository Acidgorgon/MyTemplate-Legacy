# New PascalCase folder in shared/Features OR server/Features -> full trio (no overwrite).
# Delete shared folder -> remove server Feature + Controller.
# Server folders that already existed when the watcher started are left alone (server-only).
# Names starting with _ or . are ignored.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $PSScriptRoot) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Shared = Join-Path $Root "src\shared\Features"
$Server = Join-Path $Root "src\server\Features"
$Controllers = Join-Path $Root "src\client\Client\Controllers"
if (-not $KnownShared) {
  $KnownShared = New-Object "System.Collections.Generic.HashSet[string]"
}
if (-not $KnownServer) {
  $KnownServer = New-Object "System.Collections.Generic.HashSet[string]"
}

function Test-FeatureName([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  if ($Name.StartsWith(".") -or $Name.StartsWith("_")) { return $false }
  return ($Name -match "^[A-Za-z][A-Za-z0-9]*$")
}

function Get-FeatureNames([string]$Dir) {
  $set = New-Object "System.Collections.Generic.HashSet[string]"
  Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if (Test-FeatureName $_.Name) { [void]$set.Add($_.Name) }
  }
  return $set
}

function Write-IfMissing([string]$Path, [string]$Contents) {
  if (Test-Path -LiteralPath $Path) { return }
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $out = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText($Path, $Contents, $out)
  Write-Host ("add  " + $Path.Substring($Root.Length + 1))
}

function Sync-Feature([string]$Name) {
  if (-not (Test-FeatureName $Name)) { return }
  $sharedFeat = Join-Path $Shared $Name
  $serverFeat = Join-Path $Server $Name
  $controller = Join-Path $Controllers ($Name + "Controller")
  New-Item -ItemType Directory -Force -Path $sharedFeat | Out-Null
  New-Item -ItemType Directory -Force -Path $serverFeat | Out-Null
  New-Item -ItemType Directory -Force -Path $controller | Out-Null
  Write-IfMissing (Join-Path $sharedFeat "init.luau") ("-- Config/data for " + $Name + ". Numbers must be unique to THIS game.`r`nlocal " + $Name + " = {}`r`n`r`nreturn " + $Name + "`r`n")
  Write-IfMissing (Join-Path $serverFeat ($Name + "Service.luau")) ("local " + $Name + "Service = {}`r`n`r`nfunction " + $Name + "Service:Init()`r`nend`r`n`r`nfunction " + $Name + "Service:Start()`r`nend`r`n`r`nreturn " + $Name + "Service`r`n")
  Write-IfMissing (Join-Path $serverFeat "init.server.luau") ("local " + $Name + "Service = require(script." + $Name + "Service)`r`n`r`n" + $Name + "Service:Init()`r`n" + $Name + "Service:Start()`r`n")
  Write-IfMissing (Join-Path $controller "init.luau") ("local " + $Name + "Controller = {}`r`n`r`nfunction " + $Name + "Controller:Init(_janitor)`r`nend`r`n`r`nfunction " + $Name + "Controller:Start()`r`nend`r`n`r`nreturn " + $Name + "Controller`r`n")
}

function Remove-FeatureCopies([string]$Name) {
  if (-not (Test-FeatureName $Name)) { return }
  $serverFeat = Join-Path $Server $Name
  $controller = Join-Path $Controllers ($Name + "Controller")
  if (Test-Path -LiteralPath $serverFeat) {
    Remove-Item -LiteralPath $serverFeat -Recurse -Force
    Write-Host ("del  src\server\Features\" + $Name)
  }
  if (Test-Path -LiteralPath $controller) {
    Remove-Item -LiteralPath $controller -Recurse -Force
    Write-Host ("del  src\client\Client\Controllers\" + $Name + "Controller")
  }
}

function Invoke-FeatureTick {
  $sharedNow = Get-FeatureNames $Shared
  $serverNow = Get-FeatureNames $Server

  $gone = @()
  foreach ($name in @($KnownShared)) {
    if (-not $sharedNow.Contains($name)) { $gone += $name }
  }
  foreach ($name in $gone) {
    Remove-FeatureCopies $name
    [void]$KnownShared.Remove($name)
    [void]$KnownServer.Remove($name)
  }

  # Re-scan after deletes so a just-removed server folder is not treated as a new feature.
  $serverNow = Get-FeatureNames $Server
  $sharedNow = Get-FeatureNames $Shared

  foreach ($name in @($KnownServer)) {
    if (-not $serverNow.Contains($name) -and -not $sharedNow.Contains($name)) {
      [void]$KnownServer.Remove($name)
    }
  }

  foreach ($name in $sharedNow) {
    Sync-Feature $name
    [void]$KnownShared.Add($name)
    [void]$KnownServer.Add($name)
  }

  foreach ($name in $serverNow) {
    $isNew = -not $KnownServer.Contains($name) -and -not $KnownShared.Contains($name)
    if ($isNew) {
      Sync-Feature $name
      [void]$KnownShared.Add($name)
    }
    [void]$KnownServer.Add($name)
  }
}

Get-ChildItem -LiteralPath $Shared -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  if (Test-FeatureName $_.Name) { [void]$KnownShared.Add($_.Name) }
}
Get-ChildItem -LiteralPath $Server -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  if (Test-FeatureName $_.Name) { [void]$KnownServer.Add($_.Name) }
}

if ($GENTREE_WATCH_LIB) {
  Write-Host ("watching " + $Shared + " and " + $Server)
  return
}

Write-Host ("watching " + $Shared + " and " + $Server + "  (Ctrl+C to stop)")
while ($true) {
  Invoke-FeatureTick
  Start-Sleep -Seconds 1
}