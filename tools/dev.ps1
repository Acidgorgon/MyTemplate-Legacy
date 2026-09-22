# Dev loop: feature watcher (in this window), Blink, sourcemap, wally on change.
# Does not start Rojo serve. Ctrl+C stops everything this script started.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Disconnect-TemplateGit {
  if (Test-Path -LiteralPath (Join-Path $Root ".keep-git")) { return }
  $gitDir = Join-Path $Root ".git"
  if (-not (Test-Path -LiteralPath $gitDir)) { return }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
  $origin = $null
  try {
    $origin = & git -C $Root remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) { return }
  } catch {
    return
  }
  if (-not $origin) { return }
  if ($origin -notmatch '(?i)(?:github\.com[:/])Acidgorgon/MyTemplate-Legacy(?:\.git)?/?$') { return }
  Write-Host "Disconnecting from template git ($origin)"
  # Drop the remote first so a locked .git is no longer the template origin.
  try {
    & git -C $Root remote remove origin 2>$null
  } catch {}
  # Cursor keeps .git/cursor open on Windows; deleting those files can fail.
  Get-ChildItem -LiteralPath $gitDir -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "cursor" } |
    ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
  if (-not (Get-ChildItem -LiteralPath $gitDir -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $gitDir -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath (Join-Path $gitDir "config")) {
    Write-Host "Could not fully remove .git (files in use). Template remote is gone; ./dev will continue."
  } else {
    Write-Host "This folder is no longer a git repo. Run git init and add your own remote when ready."
  }
}

Disconnect-TemplateGit

$RokitBin = Join-Path $env:USERPROFILE ".rokit\bin"
if (Test-Path -LiteralPath $RokitBin) {
  $env:Path = "$RokitBin;$env:Path"
}

function Find-Tool([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Invoke-WallyInstall {
  $wally = Find-Tool "wally"
  if ($null -eq $wally) { throw "Missing wally. Run rokit install (see rokit.toml)." }
  Write-Host "wally install"
  & $wally install
  if ($LASTEXITCODE -ne 0) { throw "wally install failed ($LASTEXITCODE)" }
}

function Stop-Matching([string]$Pattern) {
  Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $Pattern } | ForEach-Object {
    Write-Host "stopping leftover $($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Start-Hidden([string]$File, [string]$ArgLine) {
  return Start-Process -FilePath $File -ArgumentList $ArgLine -WorkingDirectory $Root -PassThru -WindowStyle Hidden
}

$WallyToml = Join-Path $Root "wally.toml"
$WatcherScript = Join-Path $PSScriptRoot "watch-features.ps1"
if (-not (Test-Path -LiteralPath $WatcherScript)) {
  throw "missing $WatcherScript"
}

Write-Host "dev root: $Root"

$needWally = -not (Test-Path -LiteralPath (Join-Path $Root "Packages\Janitor.lua"))
if ($needWally) {
  Invoke-WallyInstall
} else {
  Write-Host "Packages already present (edit wally.toml to reinstall)"
}
$lastWally = (Get-Item -LiteralPath $WallyToml).LastWriteTimeUtc

Stop-Matching "watch-features\.ps1"
Stop-Matching "events\.blink -w"
Stop-Matching "sourcemap default\.project\.json"

$GENTREE_WATCH_LIB = $true
. $WatcherScript

$procs = @{}
$blink = Find-Tool "blink"
if ($null -eq $blink) {
  Write-Host "blink not found, skip"
} else {
  $procs.blink = Start-Hidden $blink "events.blink -w"
}

$rojo = Find-Tool "rojo"
if ($null -eq $rojo) {
  Write-Host "rojo not found, skip sourcemap"
} else {
  $procs.sourcemap = Start-Hidden $rojo "sourcemap default.project.json -o sourcemap.json --watch"
}

Write-Host "running: features + blink -w + sourcemap --watch. Ctrl+C to stop."

$warned = @{}
try {
  while ($true) {
    Invoke-FeatureTick
    Start-Sleep -Seconds 1
    foreach ($name in @($procs.Keys)) {
      $p = $procs[$name]
      if ($p -and $p.HasExited -and -not $warned.ContainsKey($name)) {
        $warned[$name] = $true
        Write-Host "$name exited $($p.ExitCode)"
      }
    }
    $now = (Get-Item -LiteralPath $WallyToml).LastWriteTimeUtc
    if ($now -gt $lastWally) {
      $lastWally = $now
      Invoke-WallyInstall
    }
  }
} finally {
  foreach ($name in @($procs.Keys)) {
    $p = $procs[$name]
    if ($p -and -not $p.HasExited) {
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
  }
}