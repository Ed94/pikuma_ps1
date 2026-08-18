$path_root      = split-path -Path $PSScriptRoot -Parent
$path_build     = join-path $path_root 'build'
$path_code      = join-path $path_root 'code'
$path_scripts   = join-path $path_root 'scripts'
$path_toolchain = join-path $path_root 'toolchain'

# Halt on any error (instead of PowerShell's default `Continue`).
$ErrorActionPreference = 'Stop'

$misc = join-path $PSScriptRoot 'helpers/misc.ps1'
. $misc

$url_armips     = 'https://github.com/Kingcom/armips.git'
$url_pcsx_redux = 'https://github.com/grumpycoders/pcsx-redux.git'
$url_psyq_iwyu  = 'https://github.com/johnbaumann/psyq_include_what_you_use.git'
$url_lpeg       = 'https://github.com/roberto-ieru/LPeg.git'
# $url_mkpsxiso   = 'https://github.com/Lameguy64/mkpsxiso.git'

$url_mkpsxiso_win64 = 'https://github.com/Lameguy64/mkpsxiso/releases/download/v2.30/mkpsxiso-2.30-win64.zip'

$path_armips     = join-path $path_toolchain 'armips'
$path_pcsx_redux = join-path $path_toolchain 'pcsx-redux'
$path_psyq_iwyu  = join-path $path_toolchain 'psyq_iwyu'
$path_lpeg       = join-path $path_toolchain 'lpeg'
$path_mkpsxiso   = join-path $path_toolchain 'mkpsxiso'

clone-gitrepo $path_armips     $url_armips
clone-gitrepo $path_lpeg       $url_lpeg
clone-gitrepo $path_pcsx_redux $url_pcsx_redux
clone-gitrepo $path_psyq_iwyu  $url_psyq_iwyu
# clone-gitrepo $path_mkpsxiso   $url_mkpsxiso

$path_armips_build = join-path $path_armips 'build'
verify-path $path_armips_build
push-location $path_armips_build
&	cmake ..
&	cmake --build . --config Debug
pop-location

# $path_pcsx_redux_vsprojects = join-path $path_pcsx_redux            'vscprojects'
# $path_pcsx_redux_binaries   = join-path $path_pcsx_redux_vsprojects 'x64/Release'

# $psyq_obj_parser = join-path $path_pcsx_redux_binaries 'psyq-obj-parser.exe'

# ════════════════════════════════════════════════════════════════════════════
# PCSX-Redux — built via MSBuild (VS2022)
# Requires: Visual Studio 2022 with the C++ desktop workload.
# Output: toolchain\pcsx-redux\vsprojects\x64\Debug\pcsx-redux.exe
# ════════════════════════════════════════════════════════════════════════════

# Locate MSBuild from the VS2022 install (no hardcoded path — uses vswhere).
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
	write-error "vswhere not found at '$vswhere'. Install Visual Studio 2022 with the C++ desktop workload."
	exit 1
}
$msbuild_exe = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" 2>$null | Select-Object -First 1
if (-not $msbuild_exe) {
	write-error "MSBuild not found via vswhere. Install Visual Studio 2022 with the C++ desktop workload."
	exit 1
}

$path_pcsx_sln = join-path $path_pcsx_redux 'vsprojects\pcsx-redux.sln'

# ════════════════════════════════════════════════════════════════════════════
# NuGet restore — required before MSBuild.
# pcsx-redux's .vcxproj files use the legacy packages.config style with
# hardcoded `<Import Project="..\packages\{id}.{ver}\...">` directives.
# MSBuild's `/t:Restore` won't fetch missing packages here (the local
# packages\ dir is checked but no package-source lookup happens), and
# `dotnet restore` errors on packages.config projects, so we walk every
# packages.config, parse out the <package id version/> entries, and pull
# any missing .nupkg directly from api.nuget.org's flat container.
# ════════════════════════════════════════════════════════════════════════════
$path_pcsx_packages = join-path $path_pcsx_redux 'vsprojects\packages'
$nuget_flat_container = 'https://api.nuget.org/v3-flatcontainer'

# Collect required (id, version) pairs from every packages.config.
$required_packages = @{}
Get-ChildItem -Path (join-path $path_pcsx_redux 'vsprojects') -Filter 'packages.config' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        [xml]$xml = Get-Content -LiteralPath $_.FullName -Raw
        foreach ($pkg in $xml.packages.package) {
            $key = '{0}|{1}' -f $pkg.id, $pkg.version
            $required_packages[$key] = @{ id = $pkg.id; version = $pkg.version }
        }
    }

# Ensure the packages root exists.
if (-not (Test-Path -LiteralPath $path_pcsx_packages)) {
    New-Item -ItemType Directory -Path $path_pcsx_packages -Force | Out-Null
}

# Download anything missing.
# Skip the package entirely if its dir already has any contents (the legacy packages.config style means the targets file location varies per package 
# — `luajit.native` puts it at build/native/, `glfw` puts it elsewhere — so we can't probe a specific path; just check whether the dir is non-empty).
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($pkg in $required_packages.Values) {
    $pkgDir = Join-Path $path_pcsx_packages ('{0}.{1}' -f $pkg.id, $pkg.version)
    if ((Test-Path -LiteralPath $pkgDir) -and `
        (@(Get-ChildItem -LiteralPath $pkgDir -Recurse -ErrorAction SilentlyContinue).Count -gt 0)) {
        continue
    }
    $url = '{0}/{1}/{2}/{1}.{2}.nupkg' -f $nuget_flat_container, $pkg.id, $pkg.version
    $nupkg = Join-Path $pkgDir ('{0}.{1}.nupkg' -f $pkg.id, $pkg.version)
    New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
    Write-Host "Fetching NuGet package: $($pkg.id) $($pkg.version)"
    try {
        Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $pkgDir)
        Remove-Item -LiteralPath $nupkg -Force
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '404') {
            Write-Host "  Not on nuget.org (vendored?) — skipping $url"
        } else {
            Write-Warning "Failed to fetch $url — $msg"
        }
        if (Test-Path -LiteralPath $nupkg) { Remove-Item -LiteralPath $nupkg -Force }
    }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# isoffi.lua size guard — `core.vcxproj` #includes src/core/isoffi.lua into luaiso.cc via the `-- lualoader, R"EOF(...)EOF"` trick.
# The raw string literal between R"EOF(-- and -- )EOF" must stay under ~16,379 bytes or MSVC (19.44) fails with C2026 (its actual raw-string limit is 16,384, minus 5 bytes for the `-- lualoader, ` prefix).
# If the upstream file grows past that, trim it: remove license header, trailing whitespace, blank separators, inline comments, and shrink 4-space indent to 2-space.
# Idempotent — only writes when the raw string exceeds the limit.
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
$path_isoffi = join-path $path_pcsx_redux 'src\core\isoffi.lua'
if (Test-Path -LiteralPath $path_isoffi) {
    $content = Get-Content -LiteralPath $path_isoffi -Raw -Encoding utf8
    $startMarker = $content.IndexOf('R"EOF(--')
    $endMarker   = $content.IndexOf('-- )EOF"')
    $literalLen  = if ($startMarker -ge 0 -and $endMarker -gt $startMarker) { $endMarker - ($startMarker + 8) } else { -1 }
    # Effective MSVC raw-string limit for the lualoader prefix is 16379 bytes.
    if ($literalLen -gt 16379) {
        Write-Host "isoffi.lua raw string is $literalLen bytes (>16379); trimming for MSVC C2026 limit."
        $lines     = $content -split "`n"
        $markerIdx = -1
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -match '^-- \)EOF"') { $markerIdx = $i; break }
        }
        $newLines = @()
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $lineNum = $i + 1
            $line    = $lines[$i]
            # Keep the first line and the EOF-marker line untouched.
            if ($i -eq 0 -or $i -eq $markerIdx) { $newLines += $line; continue }
            # Drop the GPL license header (lines 2-17).
            if ($lineNum -ge 2 -and $lineNum -le 17) { continue }
            # Drop blank separator lines.
            if ($line -match '^\s*$') { continue }
            # Drop trailing whitespace.
            $line = $line -replace '\s+$', ''
            # Drop inline comments (anything from `--` to end of line).
            $line = $line -replace '\s*--.*$', ''
            # Shrink 4-space indent to 2-space.
            $line = $line -replace '^(    )', '  '
            if ($line -match '^\s*$') { continue }
            $newLines += $line
        }
        ($newLines -join "`n") | Out-File -LiteralPath $path_isoffi -Encoding utf8 -NoNewline
        $newLen = ((Get-Content -LiteralPath $path_isoffi -Raw -Encoding utf8) -replace '.*R"EOF\(--', '' -replace '-- \)EOF".*', '').Length
        Write-Host "isoffi.lua trimmed: $literalLen -> $newLen bytes of raw string content."
    }
}

& $msbuild_exe $path_pcsx_sln /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v143 /m /v:minimal

# Locate luajit via scoop. `luajit.exe` is on PATH via scoop's shim;
# we use `scoop prefix` to find the install root for the include dir (needed to compile lpeg against luajit's headers).
# If scoop or luajit is missing, fail fast with an actionable message.
$luajit_prefix = & scoop prefix luajit 2>$null
if (-not $luajit_prefix -or -not (Test-Path (Join-Path $luajit_prefix 'bin/luajit.exe'))) {
	write-error "luajit not found via 'scoop prefix luajit'. Install via: scoop install luajit"
	exit 1
}

# Discover the luajit include dir by globbing `include/luajit-*`.
# This avoids hardcoding a specific version (e.g. `luajit-2.1`).
$luajit_include_root = Join-Path $luajit_prefix 'include'
$lua_inc_dir         = Get-ChildItem -Path $luajit_include_root -Directory -Filter 'luajit-*' -ErrorAction SilentlyContinue |
Select-Object -First 1 -ExpandProperty FullName
if (-not $lua_inc_dir) {
	write-error "No 'luajit-*' include dir found under '$luajit_include_root'. The scoop luajit install may be broken."
	exit 1
}

# Generate lpeg.dll by compiling the 6 source files directly.
# `gcc` is on PATH (scoop's shim puts it there).
# The source files: lpcap.c lpcode.c lpcset.c lpprint.c lptree.c lpvm.c
# Link against luajit's import library (`libluajit-5.1.a`) for the Lua C API symbols (lua_*, luaL_*).
$luajit_lib_dir = Join-Path $luajit_prefix 'lib'
$lpeg_sources = @('lpcap.c', 'lpcode.c', 'lpcset.c', 'lpprint.c', 'lptree.c', 'lpvm.c')
$lpeg_compile_args = @(
	'-O2', '-shared',
	"-I$lua_inc_dir",
	"-L$luajit_lib_dir",
	'-o', 'lpeg.dll'
) + $lpeg_sources + @('-lluajit-5.1')
push-location $path_lpeg
& gcc @lpeg_compile_args
pop-location

# ════════════════════════════════════════════════════════════════════════════
# lfs (LuaFileSystem) — compiled from pcsx-redux's vendored luafilesystem source.
# Source: toolchain/pcsx-redux/third_party/luafilesystem/src/lfs.c
# Output: toolchain/lfs/lfs.dll
# ════════════════════════════════════════════════════════════════════════════

$path_lfs = join-path $path_toolchain 'lfs'
verify-path $path_lfs
$lfs_src        = join-path $path_pcsx_redux 'third_party\luafilesystem\src\lfs.c'
$lfs_dll        = join-path $path_lfs 'lfs.dll'
$lfs_dll_import = join-path $luajit_lib_dir 'libluajit-5.1.dll.a'
& gcc -O2 -shared "-I$lua_inc_dir" -o $lfs_dll $lfs_src $lfs_dll_import

# ════════════════════════════════════════════════════════════════════════════
# OpenBIOS — built from the PCSX-Redux source tree via make + mipsel-none-elf
# Output: toolchain\pcsx-redux\src\mips\openbios\openbios.bin
# ════════════════════════════════════════════════════════════════════════════

$path_openbios = join-path $path_pcsx_redux 'src\mips\openbios'

# Wipe stale *.dep files across src\mips.
# These cache absolute paths to the GCC headers directory; if the toolchain was upgraded (e.g. v14.2.0 → v16.1.0)
# Make reads the stale paths and aborts with "no rule to make target .../stddef.h".
# `make clean` in openbios only clears its own dir — subdirs like common/crt0/, modplayer/, and shell/ keep their stale .dep files.
# Easier to just delete the lot before each build than to teach every Makefile about deepclean recursion.
Get-ChildItem -Path (join-path $path_pcsx_redux 'src\mips') -Recurse -Filter '*.dep' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

push-location $path_openbios
&	make clean
&	make
pop-location
