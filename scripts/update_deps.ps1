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

$path_armips     = join-path $path_toolchain 'armips'
$path_pcsx_redux = join-path $path_toolchain 'pcsx-redux'
$path_psyq_iwyu  = join-path $path_toolchain 'psyq_iwyu'
$path_lpeg       = join-path $path_toolchain 'lpeg'

clone-gitrepo $path_armips     $url_armips
clone-gitrepo $path_lpeg       $url_lpeg
clone-gitrepo $path_pcsx_redux $url_pcsx_redux
clone-gitrepo $path_psyq_iwyu  $url_psyq_iwyu

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
&	$msbuild_exe $path_pcsx_sln /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v143 /m /v:minimal

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
$lua_inc_dir = Get-ChildItem -Path $luajit_include_root -Directory -Filter 'luajit-*' -ErrorAction SilentlyContinue |
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
&	gcc @lpeg_compile_args
pop-location

# ════════════════════════════════════════════════════════════════════════════
# lfs (LuaFileSystem) — compiled from pcsx-redux's vendored luafilesystem source.
# Source: toolchain/pcsx-redux/third_party/luafilesystem/src/lfs.c
# Output: toolchain/lfs/lfs.dll
# ════════════════════════════════════════════════════════════════════════════

$path_lfs = join-path $path_toolchain 'lfs'
verify-path $path_lfs
$lfs_src = join-path $path_pcsx_redux 'third_party\luafilesystem\src\lfs.c'
$lfs_dll = join-path $path_lfs 'lfs.dll'
$lfs_dll_import = join-path $luajit_lib_dir 'libluajit-5.1.dll.a'
& gcc -O2 -shared "-I$lua_inc_dir" -o $lfs_dll $lfs_src $lfs_dll_import

# ════════════════════════════════════════════════════════════════════════════
# OpenBIOS — built from the PCSX-Redux source tree via make + mipsel-none-elf
# Output: toolchain\pcsx-redux\src\mips\openbios\openbios.bin
# ════════════════════════════════════════════════════════════════════════════

$path_openbios = join-path $path_pcsx_redux 'src\mips\openbios'
push-location $path_openbios
&	make clean
&	make
pop-location
