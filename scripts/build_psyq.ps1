$path_root      = split-path -Path $PSScriptRoot -Parent
$path_build     = join-path $path_root 'build'
$path_code      = join-path $path_root 'code'
$path_scripts   = join-path $path_root 'scripts'
$path_toolchain = join-path $path_root 'toolchain'

if ((test-path $path_build) -eq $false) {
	new-item -itemtype directory -path $path_build
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
	# 16 removed entries (c2, card, cd, comb, ds, gs, gun, hmd, math, mcrd, mcx, press, sio, snd, spu, tap)
	# had LOAD lines in the map but ZERO .o files pulled in — they were unused.
	# 5 kept libraries (api, c, etc, gpu, gte) are required by the C-side calls in hello_joypad.c (reset_graph, draw_sync, vsync, etc.).
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
		[string]$unity_root,
		[string[]]$sources,
		[Parameter(Mandatory=$true)][string]$metadata,
		[string]$out_root = (join-path $path_build 'gen'),
		[string[]]$passes = @('--pre-link'),
		[string[]]$extra_args = @()
	)
	# `--unity-root` and `--source` are mutually exclusive. Exactly one of `$unity_root` / `$sources` must be supplied; the other must be absent.
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
	$path_dwarf_line_bin     = join-path $path_gen  "$base_name.dwarf_line.bin"
	$path_dwarf_aranges_bin  = join-path $path_gen  "$base_name.dwarf_aranges.bin"
	$path_dwarf_rnglists_bin = join-path $path_gen  "$base_name.dwarf_rnglists.bin"
	$path_dwarf_info_bin     = join-path $path_gen  "$base_name.dwarf_info.bin"
	$path_dwarf_abbrev_bin   = join-path $path_gen  "$base_name.dwarf_abbrev.bin"
	$path_dwarf_str_bin      = join-path $path_gen  "$base_name.dwarf_str.bin"
	$path_dwarf_loc_bin      = join-path $path_gen  "$base_name.dwarf_loc.bin"
	$path_dwarf_loclists_bin = join-path $path_gen  "$base_name.dwarf_loclists.bin"
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
	ps1-meta -unity_root $src_c -metadata $path_atom_metadata -out_root $path_build_gen -passes @('--pre-link')

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

	ps1-meta -unity_root $src_c -metadata $path_atom_metadata -out_root $path_build_gen -passes @('--post-link') ` -extra_args @('--elf', $elf)

	inject-dwarf $elf $path_build_gen
}
build-hello_camera

# NO idea if this works yet...
function Send-ToEmulator { param( [string]$exePath )
    $uri = "http://localhost:8080/api/v1/load-exec"

    # Absolute path is safest for the emulator web server
    $absolutePath = [System.IO.Path]::GetFullPath($exePath)

    # Create JSON payload pointing to your compiled .ps-exe
    $body = @{ filename = $absolutePath } | ConvertTo-Json

    Write-Host "Pushing hot-reload to PCSX-Redux..." -ForegroundColor Magenta
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json"
        Write-Host "Hot-reload successful!" -ForegroundColor Green
    } catch {
        Write-Warning "Could not connect to PCSX-Redux web server. Ensure the emulator is running and Web Server is enabled."
    }
}

# # Automatically hot-reloads it into the running emulator
# Send-ToEmulator (join-path $path_build 'hello_gte.ps-exe')

# --- Hot Reload via PCSX-Redux Web Server ---
# $exe_path = join-path $path_build 'hello_gte.ps-exe'
# $absolute_path = [System.IO.Path]::GetFullPath($exe_path)

# PCSX-Redux expects the file location in the URL query string?
# We URL-encode the path to ensure backslashes and spaces don't break the HTTP request?
# $encoded_path = [uri]::EscapeDataString($absolute_path)
# $uri = "http://localhost:8080/api/v1/load-exec?path=$encoded_path"

# Write-Host "Pushing hot-reload to PCSX-Redux..." -ForegroundColor Magenta
# try {
#     # Send the request with the query string included
#     Invoke-RestMethod -Uri $uri -Method Post 
#     Write-Host "Hot-reload successful!" -ForegroundColor Green
# } catch {
#     Write-Host "Failed to hot-reload." -ForegroundColor Red
#     # This will print the *actual* HTTP error instead of our generic warning
#     Write-Host $_.Exception.Message -ForegroundColor Yellow
# }
