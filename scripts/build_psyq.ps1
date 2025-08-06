$path_root      = split-path -Path $PSScriptRoot -Parent
$path_build     = join-path $path_root 'build'
$path_code      = join-path $path_root 'code'
$path_scripts   = join-path $path_root 'scripts'
$path_toolchain = join-path $path_root 'toolchain'

if ((test-path $path_build) -eq $false) {
	new-item -itemtype directory -path $path_build
}

# TODO(Ed): General way to build C runtime sandboxed projects.
# The goal here is to lift w/e is going on in SpinningCube to just utilize the toolchain dir's content
# We also want to strip down the C to just calling the ASM's entry point, from there we'll try to use
# the PS1 SDK from asm and just setup macros for the ABI calling convention

# --- Toolchain Definition ---
# Assumes 'mipsel-none-elf' toolchain is in your system's PATH.
$Prefix    = "mipsel-none-elf"
$Compiler  = "$($Prefix)-gcc"
$Assembler = $Compiler
$Objcopy   = "$($Prefix)-objcopy"

# --- GCC/MIPS Flags ---

# General Compiler Flags
$f_compile          = "-c"
$f_debug            = "-g"
$f_define           = "-D"
$f_include          = "-I"
$f_output           = "-o"
$f_std_c11          = "-std=c11"

# Warning Flags
$f_wall             = "-Wall"
$f_wno_attributes   = "-Wno-attributes"

# Optimization Flags
$f_optimize_none    = "-O0" # For Debug builds
$f_optimize_size    = "-Os" # For Release builds
$f_omit_frame_ptr   = "-fomit-frame-pointer"

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
# $path_nugget_common = join-path $path_nugget     'common'
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

	$assemble_args += $f_compile, $unit, ($f_output + $link_module)

    write-host "Assembling '$unit' -> '$link_module'" -ForegroundColor Cyan
    $assemble_args | ForEach-Object { Write-Host "`t$_" -ForegroundColor Green }
		& $Assembler $assemble_args
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
	$compile_args    += ($f_include + $path_psyq_imyu_inc)
	$compile_args    += ($f_include + $path_nugget)

	$compile_args += $user_compile_args

	$compile_args += $f_compile, $unit, ($f_output + $link_module)

    write-host "Compiling '$unit' -> '$link_module'" -ForegroundColor Cyan
    $compile_args | ForEach-Object { Write-Host "`t$_" -ForegroundColor Green }
		& $Compiler $compile_args
    if ($LASTEXITCODE -ne 0) { write-error "Compilation failed for $unit. Aborting."; exit 1 }
}
function link-modules { param(
	[string[]]$link_modules,
	[string]  $elf,
	[string[]]$user_link_args
)
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
	$libraries = @(
		"api", 
		"c", 
		"c2", 
		"card", 
		"cd", 
		"comb", 
		"ds", 
		"etc", 
		"gpu", 
		"gs", 
		"gte", 
		"gun", 
		"hmd", 
		"math",
		"mcrd",
		"mcx",
		"pad",
		"press",
		"sio",
		"snd",
		"spu",
		"tap"
	)
	foreach ($lib in $libraries) {
		$link_args += ($f_link_lib + $lib)
	}

	$link_args += $link_modules

	$final_link_args = @($link_args) + ($f_output + $elf)

	write-host "Linking modules into '$elf'"  -ForegroundColor Cyan
	$final_link_args += ($f_link_pass_through_prefix + $f_link_end_group)
	$final_link_args | foreach-object { write-host $_ }
		& $Compiler $final_link_args
	if ($LASTEXITCODE -ne 0) { write-error "Linking failed. Aborting."; exit 1 }
}
function make-binary { param(
	[string]$elf,
	[string]$exe
)
	Write-Host "--- Creating Binary ---" -ForegroundColor Cyan
	write-host "Converting $elf to PS-EXE -> '$exe'"
	$objcopy_args = ($f_objcopy_format + "binary"), $elf, $exe
		& $Objcopy $objcopy_args
	if ($LASTEXITCODE -ne 0) { Write-Error "Objcopy failed. Aborting."; exit 1 }
}

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

function build-double_buffer {
	$includes += @()

	$path_module = join-path $path_code 'graphics_hello_psyq'

	$src_asm    = join-path $path_module 'hello_gpu.s'
	$module_asm = join-path $path_build  'hello_gpu.o'

	$assemble_args = @()
	$assemble_args += $f_debug
	$assemble_args += $f_optimize_none
	assemble-unit $src_asm $module_asm $includes $assemble_args

	$src_c    = join-path $path_module 'hello_gpu.c'
	$module_c = join-path $path_build  'hello_gpu_c.o'

	$compile_args = @()
	$compile_args += $f_debug
	$compile_args += $f_optimize_none
	# $compile_args += $f_optimize_size
	compile-unit $src_c $module_c $includes $compile_args

	$elf = join-path $path_build 'hello_gpu.elf'
	$exe = join-path $path_build 'hello_gpu.ps-exe'

	$link_args += $f_debug
	# $link_args += $f_optimize_size
	link-modules @($module_asm, $module_c) $elf $link_args
	make-binary $elf $exe
}
build-double_buffer
