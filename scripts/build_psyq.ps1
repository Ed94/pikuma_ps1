# --- Parameter Surface (Task 8) -----------------------------------------
# -Reload         : After a successful build, invoke reload.ps1 as a child pwsh and propagate its exit code.
# -HelperZipOnly  : Skip the build entirely; regenerate the helper zip and exit. Honors -HelperZipOutput for out-of-tree paths.
# -HelperZipOutput: When -HelperZipOnly is set, writes the archive to this path instead of the scripts/pcsx_debug_helper.zip.
param(
	[switch]$Reload,
	[switch]$HelperZipOnly,
	[string]$HelperZipOutput = ''
)

$path_root      = split-path -Path $PSScriptRoot -Parent
$path_build     = join-path $path_root 'build'
$path_code      = join-path $path_root 'code'
$path_scripts   = join-path $path_root 'scripts'
$path_toolchain = join-path $path_root 'toolchain'

if ((test-path $path_build) -eq $false) {
	new-item -itemtype directory -path $path_build
}

# --- HelperZipOnly short-circuit ----------------------------------------
# Must run before any compile/link work.
# Inlines the same logic as Make-HelperZip below to avoid an extra pwsh process spawn (~200 ms).
#The helper zip is small and the BCL call is in-process; cold ~14 ms, warm ~10 ms (assembly load + tiny zip write).
if ($HelperZipOnly) {
	$zipDest = if ([string]::IsNullOrEmpty($HelperZipOutput)) {
		join-path $path_scripts 'pcsx_debug_helper.zip'
	}
	else {
		$HelperZipOutput
	}
	$HelperDir = join-path $path_scripts 'pcsx_debug_helper'
	$elf32Src  = join-path $path_scripts 'elf32.lua'
	$elf32Dest = join-path $HelperDir    'elf32.lua'
	if (-not (test-path -LiteralPath $HelperDir)) {
		write-error "helper dir not found: $HelperDir"
		exit 1
	}
	if (-not (test-path -LiteralPath $elf32Src)) {
		write-error "elf32.lua not found at $elf32Src"
		exit 1
	}
	write-host "[build] HelperZipOnly mode -> $zipDest"

	# --- Timestamp gate (Fix 1) -------------------------------------------
	# PCSX-Redux holds pcsx_debug_helper.zip open via -archive at startup.
	# The zip is consumed once at startup; the reload endpoint reads it
	# from package.loaded on subsequent calls. Writing it on every build
	# is dead work that fights the file lock. Skip the rewrite when the
	# three sources (autoexec.lua, reload.lua, elf32.lua) are all older
	# than the existing zip.
	$sources = @(
		(join-path $HelperDir 'autoexec.lua'),
		(join-path $HelperDir 'reload.lua'),
		$elf32Src
	)
	$zipMtime = $null
	if (test-path -LiteralPath $zipDest) {
		$zipMtime = (Get-Item -LiteralPath $zipDest).LastWriteTime
	}
	$needsRewrite = $false
	if ($null -eq $zipMtime) {
		$needsRewrite = $true
	}
	else {
		foreach ($s in $sources) {
			if (-not (test-path -LiteralPath $s)) { continue }
			if ((Get-Item -LiteralPath $s).LastWriteTime -gt $zipMtime) {
				$needsRewrite = $true
				break
			}
		}
	}
	if (-not $needsRewrite) {
		$sz = (Get-Item -LiteralPath $zipDest).Length
		Write-Host "[build] helper zip up to date: $zipDest ($sz bytes); skipping"
		return
	}

	Copy-Item -LiteralPath $elf32Src -Destination $elf32Dest -Force
	try {
		# Force the inode release so CreateFromDirectory can write fresh.
		# ZipFile.CreateFromDirectory throws if the destination exists.
		# If PCSX-Redux holds the file open, Remove-Item raises — fall
		# back to writing pcsx_debug_helper.zip.new alongside. The next
		# PCSX-Redux restart will read the canonical path; the .new file
		# is a hint for the optional launch-script patch in fix 3.
		if (test-path -LiteralPath $zipDest) {
			try {
				# -ErrorAction Stop is required so the catch below fires.
				# Remove-Item raises a non-terminating error by default
				# (ErrorActionPreference=Continue), which bypasses catch.
				Remove-Item -LiteralPath $zipDest -Force -ErrorAction Stop
			}
			catch {
				$zipDest = [System.IO.Path]::ChangeExtension($zipDest, '.zip.new')
				Write-Warning "[build] canonical helper zip is locked; writing to $zipDest instead"
			}
		}
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[System.IO.Compression.ZipFile]::CreateFromDirectory(
			$HelperDir, $zipDest,
			[System.IO.Compression.CompressionLevel]::Optimal, $false) | Out-Null
		$sz = (Get-Item -LiteralPath $zipDest).Length
		Write-Host "[build] wrote $sz bytes to $zipDest"
	}
	finally {
		if (test-path -LiteralPath $elf32Dest) { Remove-Item -LiteralPath $elf32Dest -Force }
	}
	return
}

# --- Toolchain Definition ---
# Assumes 'mipsel-none-elf' toolchain is in your system's PATH.
$Prefix    = "mipsel-none-elf"
$Compiler  = "$($Prefix)-gcc"
$Assembler = "$($Prefix)-as"
$Objcopy   = "$($Prefix)-objcopy"

# --- GCC/MIPS Flags ---

# General Compiler Flags
$f_compile          = "-c"
$f_debug            = "-g"
$f_define           = "-D"
$f_include          = "-I"
$f_output           = "-o"
$f_std_c11          = "-std=c11"
$f_std_c23          = "-std=c23"

# Warning Flags
$f_wall             = "-Wall"
$f_wno_attributes   = "-Wno-attributes"

# Optimization Flags
$f_optimize_none       = "-O0"
$f_optimize_size       = "-Os"
$f_optimize_intrinsics = "-Oi"
$f_optimize_debug      = "-Og"
$f_omit_frame_ptr      = "-fomit-frame-pointer"

# Environment & Standard Library Flags
$f_no_stdlib        = "-nostdlib"
$f_freestanding     = "-ffreestanding"
$f_no_builtin       = "-fno-builtin"

# MIPS Architecture Specific Flags
$f_arch_mips1       = "-march=mips1"
$f_arch_abi32       = "-mabi=32"
$f_arch_little_endian = "-EL"
$f_arch_fp32        = "-mfp32"
$f_arch_no_pic      = "-fno-pic"
$f_arch_no_shared   = "-mno-shared"
$f_arch_no_abicalls = "-mno-abicalls"
$f_arch_no_llsc     = "-mno-llsc"
$f_arch_no_gpopt    = "-mno-gpopt"
$f_arch_no_stack_prot = "-fno-stack-protector"

# Linker-related Flags (for Compiler)
$f_code_sections    = "-ffunction-sections"
$f_data_sections    = "-fdata-sections"
$f_no_strict_alias  = "-fno-strict-aliasing"

# Linker Flags (passed via -Wl,)
$f_link_pass_through_prefix = "-Wl,"
$f_link_mapfile             = "-Map=" # Usage: $flag_link_pass_through_prefix + $flag_link_mapfile + path
$f_link_gc_sections         = "--gc-sections"
$f_link_format              = "--oformat="
$f_link_start_group         = "--start-group"
$f_link_end_group           = "--end-group"
$f_link_static              = "-static"
$f_link_script              = "-T"
$f_link_lib_path            = "-L"
$f_link_lib                 = "-l"

# Objcopy Flags
$f_objcopy_format   = "-O"

$path_pcsx_redux    = join-path $path_toolchain  'pcsx-redux'
$path_nugget        = join-path $path_pcsx_redux 'src/mips'
$path_nugget_common = join-path $path_nugget     'common'
$path_psyq          = join-path $path_toolchain  'psyq-4_7'
$path_psyq_iwyu     = join-path $path_toolchain  'psyq_iwyu'
$path_psyq_imyu_inc = join-path $path_psyq_iwyu  'include'

function assemble-unit { param(
	[string]  $unit,
	[string]  $link_module,
	[string[]]$include_paths,
	[string[]]$user_assemble_args
)
	$assemble_args = @(
		$f_arch_mips1,
		$f_arch_abi32,
		$f_arch_fp32,
		$f_arch_little_endian,
		$f_arch_no_abicalls,
		$f_arch_no_pic,
		$f_arch_no_llsc,
		$f_arch_no_shared,
		$f_arch_no_stack_prot
	)
	$assemble_args += $f_no_stdlib
	$assemble_args += $f_freestanding
	$assemble_args += ($f_include + $path_nugget)

	$assemble_args += $user_assemble_args

	$assemble_args += '-x', 'assembler-with-cpp'
	$assemble_args += $f_compile, $unit, ($f_output + $link_module)

    write-host "Assembling '$unit' -> '$link_module'" -ForegroundColor DarkCyan
    # $assemble_args | ForEach-Object { Write-Host "`t$_" -ForegroundColor Green }
		& $Compiler $assemble_args
    if ($LASTEXITCODE -ne 0) { write-error "Compilation failed for $unit. Aborting."; exit 1 }
}
function compile-unit { param(
	[string]  $unit,
	[string]  $link_module,
	[string[]]$include_paths,
	[string[]]$user_compile_args
)
	$compile_args = @()
	$compile_args += $f_code_sections
	$compile_args += $f_data_sections

	$compile_args += $f_wno_attributes
	$compile_args += $f_freestanding
	$compile_args += $f_omit_frame_ptr
	$compile_args += $f_no_builtin
	$compile_args += $f_no_stdlib
	$compile_args += $f_no_strict_alias
	$compile_args += @(
		$f_arch_mips1,
		$f_arch_abi32,
		$f_arch_fp32,
		$f_arch_little_endian,
		$f_arch_no_abicalls,
		$f_arch_no_gpopt,
		$f_arch_no_pic,
		$f_arch_no_llsc,
		$f_arch_no_shared,
		$f_arch_no_stack_prot
	)
	$compile_args    += $f_std_c11
	$compile_args    += ($f_include + $path_psyq_imyu_inc)
	$compile_args    += ($f_include + $path_nugget)

	$compile_args += $user_compile_args

	$compile_args += $f_compile
	$compile_args += $unit, ($f_output + $link_module)

    write-host "Compiling '$unit' -> '$link_module'" -ForegroundColor DarkCyan
    # $compile_args | ForEach-Object { Write-Host "`t$_" -ForegroundColor Green }
		& $Compiler $compile_args
    if ($LASTEXITCODE -ne 0) { write-error "Compilation failed for $unit. Aborting."; exit 1 }
}
function link-modules { param([string[]]$link_modules, [string]  $elf, [string[]]$user_link_args)
	$link_args = @()

	$link_args += $f_no_stdlib
	$link_args += $f_link_static

	$link_args += $f_arch_mips1
	$link_args += $f_arch_abi32
	$link_args += $f_arch_little_endian

	$link_args += ($f_link_pass_through_prefix + $f_link_gc_sections)
	$link_args += ($f_link_pass_through_prefix + $f_link_format + "elf32-littlemips")

	$linkscript_nugget = join-path $path_nugget 'nooverlay.ld'
	$linkscript_ps_exe = join-path $path_nugget "ps-exe.ld"
	$link_args        += ($f_link_script + $linkscript_nugget)
	$link_args        += ($f_link_script + $linkscript_ps_exe)

	$path_psyq_lib = join-path $path_psyq 'lib'
	$link_args    += ($f_link_lib_path + $path_psyq_lib)

	$base_name  = [System.IO.Path]::GetFileNameWithoutExtension($elf)
	$map        = join-path $path_build "$base_name.map"
	$link_args += ($f_link_pass_through_prefix + $f_link_mapfile + $map)

	$link_args += ($f_link_pass_through_prefix + $f_link_start_group)
	# raw_sio_pad_poll_20260802 — Task 5.1c surgical library-list trim.
	# The 16 removed entries (c2, card, cd, comb, ds, gs, gun, hmd, math,
	# mcrd, mcx, press, sio, snd, spu, tap) had LOAD lines in the map but
	# ZERO .o files pulled in — they were unused. The 5 kept libraries
	# (api, c, etc, gpu, gte) are required by the C-side calls in
	# hello_joypad.c (reset_graph, draw_sync, vsync, etc.).
	$libraries = @(
		"api",
		"c",
		"etc",
		"gpu",
		"gte"
	)
	foreach ($lib in $libraries) {
		$link_args += ($f_link_lib + $lib)
	}

	$link_args += $link_modules

	$final_link_args = @($link_args) + ($f_output + $elf)

	$base_name = [System.IO.Path]::GetFileNameWithoutExtension($elf)
	$dasm      = "$(join-path $path_build $base_name).dasm"

	write-host "Linking modules into '$elf'"  -ForegroundColor DarkCyan
	$final_link_args += ($f_link_pass_through_prefix + $f_link_end_group)
	# $final_link_args | foreach-object { write-host $_ }
		& $Compiler $final_link_args
		& mipsel-none-elf-objdump.exe -W $elf >> $dasm
	if ($LASTEXITCODE -ne 0) { write-error "Linking failed. Aborting."; exit 1 }
}
function make-binary { param([string]$elf, [string]$exe)
	Write-Host "--- Creating Binary ---" -ForegroundColor Cyan
	write-host "Converting $elf to PS-EXE -> '$exe'"
	$objcopy_args = ($f_objcopy_format + "binary"), $elf, $exe 
		& $Objcopy $objcopy_args
	if ($LASTEXITCODE -ne 0) { Write-Error "Objcopy failed. Aborting."; exit 1 }
}

function ps1-meta { param(
		[string]  $unity_root,
		[string[]]$sources,
		[Parameter(Mandatory=$true)][string]$metadata,
		[string]  $out_root   = (join-path $path_build 'gen'),
		[string[]]$passes     = @('--pre-link'),
		[string[]]$extra_args = @()
	)
	# `--unity-root` and `--source` are
	# mutually exclusive. Exactly one of `$unity_root` / `$sources` must
	# be supplied; the other must be absent.
	if ($null -ne $unity_root -and $unity_root -ne '') 
	{
		if ($null -ne $sources -and $sources.Count -gt 0) {
			write-error 'ps1-meta: -unity_root and -sources are mutually exclusive'
			exit 2
		}
	}
	elseif ($null -eq $sources -or $sources.Count -eq 0) {
		write-error 'ps1-meta: either -unity_root <file> or -sources <file...> is required'
		exit 2
	}

	# --- Defensive attribute clear on tracked gen files ------------------------
	# Git tracks code/<dir>/gen/*.h files and Windows keeps the Archive bit set
	# on them. Combined with transient editor locks or co-running processes,
	# this can make io.open(path, "wb") fail with Access Denied / Sharing
	# Violation even though Get-ChildItem shows IsReadOnly = False. Clearing
	# the Read-only + Archive bits locally is safe; git re-asserts them on
	# the next operation but the metaprogram write always wins.
	#
	# Derived from the caller's parameters: $metadata lives in $path_duffle
	# (so its parent is the duffle dir), and $unity_root / $sources[0] lives
	# in $path_module (so its parent is the module dir).
	$pathToDuffle = split-path -Path $metadata -Parent
	$pathToModule = $null
	if ($null -ne $unity_root -and $unity_root -ne '') {
		$pathToModule = split-path -Path $unity_root -Parent
	}
	elseif ($null -ne $sources -and $sources.Count -gt 0) {
		$pathToModule = split-path -Path $sources[0] -Parent
	}
	$genFiles = @(
		join-path $pathToDuffle 'gen\macs.h'
		join-path $pathToDuffle 'gen\offsets.h'
	)
	if ($null -ne $pathToModule) {
		$genFiles += join-path $pathToModule 'gen\macs.h'
		$genFiles += join-path $pathToModule 'gen\offsets.h'
	}
	foreach ($f in $genFiles) {
		if (test-path -LiteralPath $f) {
			attrib -R $f 2>&1 | Out-Null
			attrib -A $f 2>&1 | Out-Null
		}
	}

	$script = join-path $path_scripts 'ps1_meta.lua'
	$input_summary = if ($null -ne $unity_root -and $unity_root -ne '') {
		"unity=$unity_root"
	}
	else {
		"$($sources.Count) source(s)"
	}
	write-host "ps1-meta  $input_summary, passes=$($passes -join ',')" ` -ForegroundColor Magenta

	$arg_list = @($passes) + @('--metadata', $metadata) + @('--out-root', $out_root) + @($extra_args)
	if ($null -ne $unity_root -and $unity_root -ne '') {
		$arg_list += @('--unity-root', $unity_root)
	}
	else {
		foreach ($s in $sources) { $arg_list += @('--source', $s) }
	}
	& luajit $script @arg_list
	if ($LASTEXITCODE -ne 0) {
		write-error "ps1-meta failed (exit $LASTEXITCODE). Aborting."
		exit $LASTEXITCODE
	}
}

function inject-dwarf { param(
	[string]$elf,
	[string]$path_gen
)
	$base_name               = [System.IO.Path]::GetFileNameWithoutExtension($elf)
	$path_dwarf_line_bin     = join-path $path_gen   "$base_name.dwarf_line.bin"
	$path_dwarf_aranges_bin  = join-path $path_gen   "$base_name.dwarf_aranges.bin"
	$path_dwarf_rnglists_bin = join-path $path_gen   "$base_name.dwarf_rnglists.bin"
	$path_dwarf_info_bin     = join-path $path_gen   "$base_name.dwarf_info.bin"
	$path_dwarf_abbrev_bin   = join-path $path_gen   "$base_name.dwarf_abbrev.bin"
	$path_dwarf_str_bin      = join-path $path_gen   "$base_name.dwarf_str.bin"
	$path_dwarf_loc_bin      = join-path $path_gen   "$base_name.dwarf_loc.bin"
	$path_dwarf_loclists_bin = join-path $path_gen   "$base_name.dwarf_loclists.bin"
	$path_inject_elf         = join-path $path_build "$base_name.dwarf-injected.elf"

	if (-not (Test-Path $path_dwarf_line_bin))     { return }
	if (-not (Test-Path $path_dwarf_aranges_bin))  { return }
	if (-not (Test-Path $path_dwarf_rnglists_bin)) { return }

	Write-Host "[build] DWARF-injecting $elf -> $path_inject_elf"
	Copy-Item -LiteralPath $elf -Destination $path_inject_elf -Force

	# Objcopy call 1: 3x --update-section for the PC-mapping tables (line, aranges, rnglists).
	$objcopy_args_dwarf_pc = @(
		"--update-section=.debug_line=$path_dwarf_line_bin",
		"--update-section=.debug_aranges=$path_dwarf_aranges_bin",
		"--update-section=.debug_rnglists=$path_dwarf_rnglists_bin"
	)
	& $Objcopy @objcopy_args_dwarf_pc $path_inject_elf 2>&1 | Out-Null
	if ($LASTEXITCODE -ne 0) {
		Write-Warning "[build] objcopy dwarf-pc splice failed (exit $LASTEXITCODE); removing $path_inject_elf"
		Remove-Item -LiteralPath $path_inject_elf -ErrorAction SilentlyContinue
		return
	}

	# Objcopy call 2: 3x --update-section + 2x --add-section for the debug-data tables (info, abbrev, str, loc, loclists).
	$objcopy_args_dwarf_info = @(
		"--update-section=.debug_info=$path_dwarf_info_bin",
		"--update-section=.debug_abbrev=$path_dwarf_abbrev_bin",
		"--update-section=.debug_str=$path_dwarf_str_bin",
		"--add-section=.debug_loc=$path_dwarf_loc_bin",
		"--add-section=.debug_loclists=$path_dwarf_loclists_bin"
	)
	& $Objcopy @objcopy_args_dwarf_info $path_inject_elf 2>&1 | Out-Null
	if ($LASTEXITCODE -ne 0) {
		Write-Warning "[build] objcopy dwarf-info splice failed (exit $LASTEXITCODE); removing $path_inject_elf"
		Remove-Item -LiteralPath $path_inject_elf -ErrorAction SilentlyContinue
		return
	}

	# Baked atoms execute from RAM but are emitted as C data arrays, so their ELF sections lack SHF_EXECINSTR.
	# GDB discards line rows for non-code sections. Mark only the debug-copy sections executable.
	# The original ELF and PS-EXE remain byte/flag unchanged.
	& $Objcopy `
		--set-section-flags ".rodata=alloc,load,readonly,code,contents" `
		--set-section-flags ".data=alloc,load,data,code,contents" `
		$path_inject_elf 2>&1 | Out-Null
	if ($LASTEXITCODE -ne 0) {
		Write-Warning "[build] atom-section flag update failed (exit $LASTEXITCODE); removing $path_inject_elf"
		Remove-Item -LiteralPath $path_inject_elf -ErrorAction SilentlyContinue
	}
	else {
		Write-Host "[build] DWARF-injected ELF: $path_inject_elf"
	}
}
# inject-dwarf

function build-hello_psyqo {
	$includes += @()

	$path_hello_psyq = join-path $path_code 'hello_psyq'

	$asm_hello_psyq    = join-path $path_hello_psyq 'hello_psyq.s'
	$module_hello_psyq = join-path $path_build      'hello_psyq.o'

	$assemble_args = @()
	$assemble_args += $f_debug
	$assemble_args += $f_optimize_none
	assemble-unit $asm_hello_psyq $module_hello_psyq $includes $assemble_args

	$hello_psyq_crt        = join-path $path_hello_psyq 'hello_psyq_crt.c'
	$module_hello_psyq_crt = join-path $path_build      'hello_psyq_crt.o'

	$compile_args = @()
	$compile_args += $f_debug
	$compile_args += $f_optimize_none
	# $compile_args += $f_optimize_size
	compile-unit $hello_psyq_crt $module_hello_psyq_crt $includes $compile_args

	$elf_hello_psyq = join-path $path_build 'hello_psyq.elf'
	$exe_hello_psyq = join-path $path_build 'hello_psyq.ps-exe'

	$link_args += $f_debug
	# $link_args += $f_optimize_size
	link-modules @($module_hello_psyq, $module_hello_psyq_crt) $elf_hello_psyq $link_args
	make-binary $elf_hello_psyq $exe_hello_psyq
}
# build-hello_psyqo

function build-graphis_hello {
	$includes += @()

	$path_module = join-path $path_code 'graphics_hello_psyq'

	$assemble_args = @()
	$assemble_args += $f_debug
	$assemble_args += $f_optimize_none
	$assemble_args += ($f_include + $path_code)

	$src_asm_crt    = join-path $path_nugget_common 'crt0/crt0.s'
	$module_asm_crt = join-path $path_build         'crt0.o'
	assemble-unit $src_asm_crt $module_asm_crt $includes $assemble_args

	$src_asm    = join-path $path_module 'hello_gpu.s'
	$module_asm = join-path $path_build  'hello_gpu.o'

	assemble-unit $src_asm $module_asm $includes $assemble_args

	$src_c    = join-path $path_module 'hello_gpu.c'
	$module_c = join-path $path_build  'hello_gpu_c.o'

	$compile_args = @()
	$compile_args += $f_debug
	# $compile_args += $f_optimize_none
	# $compile_args += $f_optimize_intrinsics
	$compile_args += $f_optimize_size
	# $compile_args += $f_optimize_debug
	$compile_args += ($f_include + $path_code)
	compile-unit $src_c $module_c $includes $compile_args

	$elf = join-path $path_build 'hello_gpu.elf'
	$exe = join-path $path_build 'hello_gpu.ps-exe'

	$link_args = @()
	$link_args += $f_debug
	# $link_args += $f_optimize_size
	link-modules @($module_asm_crt, $module_asm, $module_c) $elf $link_args
	make-binary $elf $exe
}
# build-graphis_hello

function build-hello_gte {
	$includes += @()

	$path_module        = join-path $path_code   'hello_gte'
	$path_duffle        = join-path $path_code   'duffle'
	$path_atom_metadata = join-path $path_duffle 'word_count.metadata.h'
	$path_build_gen     = join-path $path_build   'gen'

	$src_c = join-path $path_module 'hello_gte.c'
	ps1-meta -unity_root $src_c -metadata $path_atom_metadata -out_root $path_build_gen

	$assemble_args = @()
	$assemble_args += $f_debug
	$assemble_args += $f_optimize_none
	$assemble_args += ($f_include + $path_code)

	$src_asm_crt    = join-path $path_nugget_common 'crt0/crt0.s'
	$module_asm_crt = join-path $path_build         'crt0.o'
	assemble-unit $src_asm_crt $module_asm_crt $includes $assemble_args

	# $src_asm    = join-path $path_module 'hello_gte.s'
	# $module_asm = join-path $path_build  'hello_gte.o'

	# assemble-unit $src_asm $module_asm $includes $assemble_args

	$module_c = join-path $path_build  'hello_gte_c.o'

	$compile_args = @()
	$compile_args += $f_debug
	$compile_args += $f_optimize_none
	# $compile_args += $f_optimize_intrinsics
	# $compile_args += $f_optimize_size
	# $compile_args += $f_optimize_debug
	$compile_args += ($f_include + $path_code)
	compile-unit $src_c $module_c $includes $compile_args

	$elf = join-path $path_build 'hello_gte.elf'
	$exe = join-path $path_build 'hello_gte.ps-exe'

	$link_args = @()
	$link_args += $f_debug
	# $link_args += $f_optimize_size
	$link_modules = @(
		$module_asm_crt,
		$module_c
	)
	link-modules $link_modules $elf $link_args
	make-binary $elf $exe

	# Post-link: gdb-runtime + dwarf-injection in a single Lua invocation (one luajit cold start).
	ps1-meta -unity_root $src_c -metadata $path_atom_metadata -out_root $path_build_gen -passes @('--post-link') ` -extra_args @('--elf', $elf)

	inject-dwarf $elf $path_build_gen
}
# build-hello_gte

function build-hello_joypad {
	$includes += @()

	$path_module        = join-path $path_code   'hello_joypad'
	$path_duffle        = join-path $path_code   'duffle'
	$path_atom_metadata = join-path $path_duffle 'word_count.metadata.h'
	$path_build_gen     = join-path $path_build  'gen'

	$src_c = join-path $path_module 'hello_joypad.c'
	ps1-meta -unity_root $src_c -metadata $path_atom_metadata -out_root $path_build_gen

	$assemble_args = @()
	$assemble_args += $f_debug
	$assemble_args += $f_optimize_none
	$assemble_args += ($f_include + $path_code)

	$src_asm_crt    = join-path $path_nugget_common 'crt0/crt0.s'
	$module_asm_crt = join-path $path_build         'crt0.o'
	assemble-unit $src_asm_crt $module_asm_crt $includes $assemble_args

	$module_c = join-path $path_build  'hello_joypad_c.o'

	$compile_args = @()
	$compile_args += $f_debug
	$compile_args += $f_optimize_none
	# $compile_args += $f_optimize_intrinsics
	# $compile_args += $f_optimize_size
	# $compile_args += $f_optimize_debug
	$compile_args += ($f_include + $path_code)
	compile-unit $src_c $module_c $includes $compile_args

	$elf = join-path $path_build 'hello_joypad.elf'
	$exe = join-path $path_build 'hello_joypad.ps-exe'

	$link_args = @()
	$link_args += $f_debug
	# $link_args += $f_optimize_size
	$link_modules = @(
		$module_asm_crt,
		$module_c
	)
	link-modules $link_modules $elf $link_args
	make-binary $elf $exe

	# Post-link: gdb-runtime + dwarf-injection in a single Lua invocation (one luajit cold start).
	ps1-meta -unity_root $src_c -metadata $path_atom_metadata -out_root $path_build_gen -passes @('--post-link') ` -extra_args @('--elf', $elf)

	inject-dwarf $elf $path_build_gen
}
# build-hello_joypad

function build-hello_camera {
	$includes += @()

	$path_module        = join-path $path_code   'hello_camera'
	$path_duffle        = join-path $path_code   'duffle'
	$path_atom_metadata = join-path $path_duffle 'word_count.metadata.h'
	$path_build_gen     = join-path $path_build  'gen'

	$src_c = join-path $path_module 'hello_camera.c'
	ps1-meta -unity_root $src_c -metadata $path_atom_metadata -out_root $path_build_gen

	$assemble_args = @()
	$assemble_args += $f_debug
	$assemble_args += $f_optimize_none
	$assemble_args += ($f_include + $path_code)

	$src_asm_crt    = join-path $path_nugget_common 'crt0/crt0.s'
	$module_asm_crt = join-path $path_build         'crt0.o'
	assemble-unit $src_asm_crt $module_asm_crt $includes $assemble_args

	$module_c = join-path $path_build  'hello_camera_c.o'

	$compile_args = @()
	$compile_args += $f_debug
	$compile_args += $f_optimize_none
	# $compile_args += $f_optimize_intrinsics
	# $compile_args += $f_optimize_size
	# $compile_args += $f_optimize_debug
	$compile_args += ($f_include + $path_code)
	compile-unit $src_c $module_c $includes $compile_args

	$elf = join-path $path_build 'hello_camera.elf'
	$exe = join-path $path_build 'hello_camera.ps-exe'

	$link_args = @()
	$link_args += $f_debug
	# $link_args += $f_optimize_size
	$link_modules = @(
		$module_asm_crt,
		$module_c
	)
	link-modules $link_modules $elf $link_args
	make-binary $elf $exe

	# Post-link: gdb-runtime + dwarf-injection in a single Lua invocation (one luajit cold start).
	ps1-meta -unity_root $src_c -metadata $path_atom_metadata -out_root $path_build_gen -passes @('--post-link') ` -extra_args @('--elf', $elf)

	inject-dwarf $elf $path_build_gen
}
build-hello_camera

# ── Helper-zip + reload helpers (Task 8) ──
# Defined right after the final build-hello_camera function so they're in scope for the post-build calls below.
# The Make-HelperZip function is also reused by the -HelperZipOnly short-circuit at the top of this script.
# Both call the in-process BCL CreateFromDirectory rather than spawning a child pwsh to avoid the ~200 ms process-spawn overhead.
function Make-HelperZip {
	param([string]$OutputPath = '')

	$dest = if ([string]::IsNullOrEmpty($OutputPath)) {
		join-path $path_scripts 'pcsx_debug_helper.zip'
	}
	else {
		$OutputPath
	}

	$HelperDir = join-path $path_scripts 'pcsx_debug_helper'
	$elf32Src  = join-path $path_scripts 'elf32.lua'
	$elf32Dest = join-path $HelperDir   'elf32.lua'
	if (-not (test-path -LiteralPath $HelperDir)) {
		write-warning "[build] helper dir not found: $HelperDir; skipping helper zip"
		return
	}
	if (-not (test-path -LiteralPath $elf32Src)) {
		write-warning "[build] elf32.lua not found at $elf32Src; skipping helper zip"
		return
	}

	# --- Timestamp gate (Fix 1) -------------------------------------------
	# PCSX-Redux holds pcsx_debug_helper.zip open via -archive at startup.
	# The zip is consumed once at startup; the reload endpoint reads it
	# from package.loaded on subsequent calls. Writing it on every build
	# is dead work that fights the file lock. Skip the rewrite when the
	# three sources (autoexec.lua, reload.lua, elf32.lua) are all older
	# than the existing zip.
	$sources = @(
		(join-path $HelperDir 'autoexec.lua'),
		(join-path $HelperDir 'reload.lua'),
		$elf32Src
	)
	$zipMtime = $null
	if (test-path -LiteralPath $dest) {
		$zipMtime = (Get-Item -LiteralPath $dest).LastWriteTime
	}
	$needsRewrite = $false
	if ($null -eq $zipMtime) {
		$needsRewrite = $true
	}
	else {
		foreach ($s in $sources) {
			if (-not (test-path -LiteralPath $s)) { continue }
			if ((Get-Item -LiteralPath $s).LastWriteTime -gt $zipMtime) {
				$needsRewrite = $true
				break
			}
		}
	}
	if (-not $needsRewrite) {
		$sz = (Get-Item -LiteralPath $dest).Length
		Write-Host "[build] helper zip up to date: $dest ($sz bytes); skipping"
		return
	}

	write-host "[build] regenerating helper zip -> $dest"
	Copy-Item -LiteralPath $elf32Src -Destination $elf32Dest -Force
	try {
		# Force the inode release so CreateFromDirectory can write fresh.
		# ZipFile.CreateFromDirectory throws if the destination exists.
		# If PCSX-Redux holds the file open, Remove-Item raises — fall
		# back to writing pcsx_debug_helper.zip.new alongside. The next
		# PCSX-Redux restart will read the canonical path; the .new file
		# is a hint for the optional launch-script patch in fix 3.
		if (test-path -LiteralPath $dest) {
			try {
				# -ErrorAction Stop is required so the catch below fires.
				# Remove-Item raises a non-terminating error by default
				# (ErrorActionPreference=Continue), which bypasses catch.
				Remove-Item -LiteralPath $dest -Force -ErrorAction Stop
			}
			catch {
				$dest = [System.IO.Path]::ChangeExtension($dest, '.zip.new')
				Write-Warning "[build] canonical helper zip is locked; writing to $dest instead"
			}
		}
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[System.IO.Compression.ZipFile]::CreateFromDirectory(
			$HelperDir, $dest,
			[System.IO.Compression.CompressionLevel]::Optimal, $false) | Out-Null
		$sz = (Get-Item -LiteralPath $dest).Length
		Write-Host "[build] wrote $sz bytes to $dest"
	}
	finally {
		if (test-path -LiteralPath $elf32Dest) { Remove-Item -LiteralPath $elf32Dest -Force }
	}
}

# Invokes reload.ps1 as a child pwsh instead of POSTing to the nonexistent /api/v1/load-exec endpoint.
# Exit code is propagated so the build fails loud if the reload fails.
function Send-ToEmulator {
	param([string]$ElfPath = (join-path $path_build 'hello_camera.elf'))

	$reloadScript = join-path $path_scripts 'reload.ps1'
	if (-not (test-path -LiteralPath $reloadScript)) {
		write-error "[build] reload.ps1 not found at $reloadScript"
		exit 1
	}

	write-host "[build] hot-reloading $ElfPath via reload.ps1" -ForegroundColor Magenta
	& pwsh -NoProfile -File $reloadScript -Mode elf -Target hello_camera -ElfPath $ElfPath
	if ($LASTEXITCODE -ne 0) {
		write-error "[build] reload.ps1 failed (exit $LASTEXITCODE)"
		exit $LASTEXITCODE
	}
}

# Post-build: Regenerate the helper zip (canonical output) and, if -Reload was passed, kick a hot-reload against the just-built ELF.
# Any future targets compiled by this script should add their own Make-HelperZip call after their build step; today's only target is hello_camera.
Make-HelperZip
if ($Reload) {
	Send-ToEmulator
}
