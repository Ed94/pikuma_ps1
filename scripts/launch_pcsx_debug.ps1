# scripts/launch_pcsx_debug.ps1
#
# One-shot launcher for debug sessions: starts pcsx-redux with the .ps-exe
# loaded, the gdb stub enabled, the web server enabled, AND the
# pcsx_debug_helper Lua plugin loaded so external CLI tools can drive
# reloads via http://localhost:8080/api/v1/lua/reload.
#
# After launch:
#   - gdb: target remote localhost:3333
#   - web: POST http://localhost:8080/api/v1/lua/reload?mode=prime&...
#
# usage:
#   .\scripts\launch_pcsx_debug.ps1
#   .\scripts\launch_pcsx_debug.ps1 -ExePath build\hello_camera.ps-exe
#   .\scripts\launch_pcsx_debug.ps1 -Cpu dynarec
#   .\scripts\launch_pcsx_debug.ps1 -ElfPath build\hello_camera.elf
#
# Companion: scripts/debug_psyq.ps1 (bare launch — no .ps-exe, no helper).

[CmdletBinding()]
param(
    [string]$PcsxPath = (Join-Path $PSScriptRoot '..\toolchain\pcsx-redux\vsprojects\x64\Release\pcsx-redux.exe'),
    [string]$ExePath  = (Join-Path $PSScriptRoot '..\build\hello_camera.ps-exe'),
    [string]$ElfPath  = '',
    [string]$HelperZip = (Join-Path $PSScriptRoot 'pcsx_debug_helper.zip'),
    [int]   $GdbPort  = 3333,
    [int]   $WebPort  = 8080,
    [ValidateSet('interpreter', 'dynarec')][string]$Cpu = 'interpreter'
)

$ErrorActionPreference = 'Stop'

# ── Derive -ElfPath when absent ──
# Convention: the .elf sits beside the .ps-exe with the same stem.
if ([string]::IsNullOrEmpty($ElfPath)) {
    $exeFull  = [System.IO.Path]::GetFullPath($ExePath)
    $stem     = [System.IO.Path]::GetFileNameWithoutExtension($exeFull)
    $exeDir   = [System.IO.Path]::GetDirectoryName($exeFull)
    $ElfPath  = Join-Path $exeDir "$stem.elf"
}

# ── Pre-checks ──
foreach ($p in @($PcsxPath, $ExePath, $ElfPath, $HelperZip)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Error "Missing: $p"
        exit 1
    }
}

# ── Reject a stale helper zip (Task 8) ──
# The helper zip must be newer than every .lua source that contributes
# to it. A stale zip means the running plugin does not match the on-disk
# source, which makes the reload contract meaningless.
$helperDir  = Join-Path $PSScriptRoot 'pcsx_debug_helper'
$elf32Src   = Join-Path $PSScriptRoot 'elf32.lua'
$sourceLuas = @(
    (Join-Path $helperDir 'autoexec.lua'),
    (Join-Path $helperDir 'reload.lua'),
    $elf32Src
) | Where-Object { Test-Path -LiteralPath $_ }

$zipTime = (Get-Item -LiteralPath $HelperZip).LastWriteTime
$stale = $false
foreach ($src in $sourceLuas) {
    $srcTime = (Get-Item -LiteralPath $src).LastWriteTime
    if ($srcTime -gt $zipTime) {
        Write-Error "helper zip is older than source: $src (zip=$($zipTime.ToString('o')) src=$($srcTime.ToString('o')); rerun build_psyq.ps1 to regenerate."
        $stale = $true
    }
}
if ($stale) {
    exit 1
}

# Kill any existing pcsx-redux so the archive file isn't locked.
Get-Process pcsx-redux -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# ── Launch ──
$absExe  = [System.IO.Path]::GetFullPath($ExePath)
$absZip  = [System.IO.Path]::GetFullPath($HelperZip)

$cpuFlag = if ($Cpu -eq 'dynarec') { '-dynarec' } else { '-interpreter' }

$args = @(
    '-gdb', '-run'
    '-loadexe', "`"$absExe`""
    '-archive', "`"$absZip`""
    '-webserver'
    $cpuFlag
)

Write-Host "Launching pcsx-redux..." -ForegroundColor Cyan
Write-Host "  ps-exe    : $absExe"
Write-Host "  elf       : $ElfPath"
Write-Host "  helper zip: $absZip"
Write-Host "  gdb       : localhost:$GdbPort"
Write-Host "  web       : localhost:$WebPort/api/v1/lua/reload"
Write-Host "  cpu       : $Cpu ($cpuFlag)"
Write-Host ""

Start-Process -FilePath $PcsxPath -ArgumentList $args | Out-Null

# ── Wait for both endpoints to come up ──
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    $gdbUp = $false
    $webUp = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.BeginConnect('localhost', $GdbPort, $null, $null) | Out-Null
        Start-Sleep -Milliseconds 100
        $gdbUp = $tcp.Connected
        $tcp.Close()
    } catch { $gdbUp = $false }
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$WebPort/" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
        $webUp = $r.StatusCode -ne 0
    } catch { $webUp = $false }
    if ($gdbUp -and $webUp) { break }
    Start-Sleep -Milliseconds 500
}

# ── Smoke-test the gte handler ──
try {
    $r = Invoke-WebRequest -Uri "http://localhost:$WebPort/api/v1/lua/gte" -UseBasicParsing -TimeoutSec 5
    $firstLine = ([System.Text.Encoding]::UTF8.GetString($r.Content) -split "`n")[0]
    Write-Host "GTE handler OK: $firstLine" -ForegroundColor Green
} catch {
    Write-Warning "GTE handler NOT responding: $_"
    Write-Host "Check the pcsx-redux Lua Console for debug cli messages." -ForegroundColor Yellow
}

# ── Prime the reload handler (Task 8) ──
# The reload handler keeps an internal ACTIVE manifest of the running
# ELF; reload requests fail with reload_not_primed until prime succeeds.
# We retry until the response carries ok=true or the launch deadline
# expires — the helper may not have finished registering handlers in the
# first web-poll cycle after the gte handler comes up.
$absElf = [System.IO.Path]::GetFullPath($ElfPath)
$encodedPath = [uri]::EscapeDataString($absElf)
$primeUri = "http://localhost:${WebPort}/api/v1/lua/reload?mode=prime&target=hello_camera&path=${encodedPath}"

Write-Host "Priming reload handler: $primeUri" -ForegroundColor Cyan
$primeDeadline = (Get-Date).AddSeconds(15)
$primeOk = $false
while ((Get-Date) -lt $primeDeadline) {
    try {
        $resp = Invoke-WebRequest -Method Post -Uri $primeUri -UseBasicParsing -TimeoutSec 5
        $body = if ($resp.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString([byte[]]$resp.Content)
        } else {
            [string]$resp.Content
        }
        $obj = $body | ConvertFrom-Json
        if ($obj.ok) {
            Write-Host "Prime OK: $(($obj | ConvertTo-Json -Compress))" -ForegroundColor Green
            $primeOk = $true
            break
        } else {
            Write-Host "Prime not yet ready: error=$($obj.error)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Prime request failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Start-Sleep -Milliseconds 500
}
if (-not $primeOk) {
    Write-Warning "Prime did not return ok=true before the launch deadline. Reload requests will fail until the user primes manually."
}

Write-Host ""
Write-Host "pcsx-redux running. PIDs:" -ForegroundColor Cyan
Get-Process pcsx-redux | Select-Object Id, ProcessName | Format-Table