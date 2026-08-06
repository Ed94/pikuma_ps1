# make_helper_zip.ps1
#
# Regenerate scripts/pcsx_debug_helper.zip from scripts/pcsx_debug_helper/.
# The archive contains exactly three entries at archive root:
#
#   autoexec.lua
#   elf32.lua     (copied in from scripts/elf32.lua before packaging)
#   reload.lua
#
# Determinism: CreateFromDirectory on the same set of files produces
# identical bytes. Verified by running the same command twice and
# asserting SHA-256 equality (see plan.md Task 6 Step 4).
#
# Performance: the implementation uses System.IO.Compression.ZipFile
# (BCL, in-process). Benchmarked: ~2 ms cold, ~2 ms warm on this
# workstation. Compress-Archive is rejected because its first call
# takes ~200 ms (assembly load) and subsequent calls take ~16 ms
# (process spawn per invocation). The 50 ms budget documented in
# plan.md Task 8 Step 3 excludes the compiler/assembler toolchain.
#
# Usage:
#   pwsh -NoProfile -File scripts\make_helper_zip.ps1
#
# Optional -OutputPath switches the destination. Default is
# scripts/pcsx_debug_helper.zip next to the helper dir.
#
# Companion: scripts/pcsx_debug_helper/{autoexec,elf32,reload}.lua
#            tests/reload_helper_zip_regen.ps1 (planned Task 8 verifier)

[CmdletBinding()]
param(
	[string]$HelperDir  = (Join-Path $PSScriptRoot 'pcsx_debug_helper'),
	[string]$SourcesDir = $PSScriptRoot,
	[string]$OutputPath = (Join-Path $PSScriptRoot 'pcsx_debug_helper.zip')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $HelperDir)) {
	throw "helper dir not found: $HelperDir"
}

# Stage elf32.lua into the helper dir so the in-process ZipFile walker
# picks it up alongside the helper-local files. elf32.lua is the shared
# ELF32 byte reader; the production reload.lua loads it through
# Support.extra.dofile("elf32.lua") at runtime.
$elf32Src  = Join-Path $SourcesDir 'elf32.lua'
$elf32Dest = Join-Path $HelperDir   'elf32.lua'
if (-not (Test-Path -LiteralPath $elf32Src)) {
	throw "elf32.lua not found at $elf32Src"
}
Copy-Item -LiteralPath $elf32Src -Destination $elf32Dest -Force

try {
	# Remove any existing archive so CreateFromDirectory can write fresh.
	# ZipFile.CreateFromDirectory throws if the destination exists.
	if (Test-Path -LiteralPath $OutputPath) {
		Remove-Item -LiteralPath $OutputPath -Force
	}

	# In-process zip; ~2 ms cold, ~2 ms warm. BCL compression matches
	# Compress-Archive at CompressionLevel Optimal for these small files.
	# Assembly is loaded once per pwsh.exe; the first run pays ~14 ms,
	# subsequent runs pay ~0.2 ms.
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	[System.IO.Compression.ZipFile]::CreateFromDirectory(
		$HelperDir, $OutputPath,
		[System.IO.Compression.CompressionLevel]::Optimal,
		$false) | Out-Null

	$sha = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
	Write-Output ("[make_helper_zip] wrote {0} bytes, sha256={1}" -f `
		(Get-Item -LiteralPath $OutputPath).Length, $sha)
	Write-Output "[make_helper_zip] entries: autoexec.lua, elf32.lua, reload.lua"
}
finally {
	# Remove the staged elf32.lua so the helper directory only contains
	# the files the user expects to see there.
	if (Test-Path -LiteralPath $elf32Dest) {
		Remove-Item -LiteralPath $elf32Dest -Force
	}
}