# --- Toolchain Definition ---
# Assumes 'mipsel-none-elf' toolchain is in your system's PATH.
$Prefix   = "mipsel-none-elf"
$Compiler = "$($Prefix)-gcc"
$Objcopy  = "$($Prefix)-objcopy"

# --- Abstracted GCC/MIPS Flags ---

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

# --- Project Configuration ---
$path_root = $PSScriptRoot

$path_build       = join-path $path_root        'build'
$path_third_party = join-path $path_root        'third_party'
$path_nugget      = join-path $path_third_party 'nugget'
$path_psyq        = join-path $path_third_party 'psyq'
$path_psyq_imyu   = join-path $path_third_party 'psyq-iwyu'

if (-not (test-path $path_build)) {
    new-item -ItemType Directory -Path $path_build | Out-Null
}

$path_nugget_common = join-path $path_nugget 'common'

$unit_nugget_crt0 = join-path $path_nugget_common 'crt0/crt0.s'
$unit_main        = join-path $path_root          'main.c'
$units = @(
	$unit_nugget_crt0,
	$unit_main
)

write-host "--- Compiling Source Files ---" -ForegroundColor Cyan

$compile_args_c = @()
$compile_args_c += $f_debug
$compile_args_c += $f_optimize_none
# $compile_args_c += $f_optimize_size

$compile_args_c += $f_code_sections
$compile_args_c += $f_data_sections

$compile_args_c += $f_wno_attributes
$compile_args_c += $f_freestanding
$compile_args_c += $f_omit_frame_ptr
$compile_args_c += $f_no_builtin
$compile_args_c += $f_no_stdlib
$compile_args_c += $f_no_strict_alias
$compile_args_c += @(
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

$path_psyq_imyu_inc = join-path $path_psyq_imyu 'include'
$compile_args_c    += ($f_include + $path_psyq_imyu_inc)
$compile_args_c    += ($f_include + $path_nugget)

$compile_args_asm = @()
$compile_args_asm += $f_debug
$compile_args_asm += @(
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
$compile_args_asm += $f_no_stdlib
$compile_args_asm += $f_freestanding
$compile_args_asm += ($f_include + $path_nugget)

$link_modules = @()
foreach ($unit in $units) {
    $base_name     = [System.IO.Path]::GetFileNameWithoutExtension($unit)
	$extension     = [System.IO.Path]::GetExtension($unit)
    $link_module   = join-path $path_build "$($base_name).o"
    $link_modules += $link_module

	$module_compile_args = @()
    if     ($extension -eq ".c") { $module_compile_args = $compile_args_c   }
    elseif ($extension -eq ".s") { $module_compile_args = $compile_args_asm }
	else                         { write-error "Unsupported file type: $unit"; exit 1 }

	$module_compile_args = @($module_compile_args) + $f_compile, $unit, ($f_output + $link_module)
    
    write-host "Compiling '$($unit)' -> '$($base_name).o'"
    $module_compile_args | ForEach-Object { Write-Host "`t$_" -ForegroundColor Green }
		& $Compiler $module_compile_args
    if ($LASTEXITCODE -ne 0) { write-error "Compilation failed for $unit. Aborting."; exit 1 }
}


write-host "`n--- Linking Modules ---" -ForegroundColor Cyan

$link_args = @()
$link_args += $f_debug
# $link_args += $f_optimize_size

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

$link_args += $link_modules

$map        = join-path $path_build 'SpinningCube.map'
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

$elf = Join-Path $path_build "SpinningCube.elf"
$final_link_args = @($link_args) + ($f_output + $elf)

write-host "Linking modules into 'SpinningCube.elf'"
$final_link_args += ($f_link_pass_through_prefix + $f_link_end_group)
$final_link_args | foreach-object { write-host $_ }
	& $Compiler $final_link_args
if ($LASTEXITCODE -ne 0) { write-error "Linking failed. Aborting."; exit 1 }


Write-Host "`n--- Creating Final Binary ---" -ForegroundColor Cyan
$exe = join-path $path_build "SpinningCube.ps-exe"

write-host "Converting ELF to PS-EXE -> 'SpinningCube.ps-exe'"
$objcopy_args = ($f_objcopy_format + "binary"), $elf, $exe
	& $Objcopy $objcopy_args
if ($LASTEXITCODE -ne 0) { Write-Error "Objcopy failed. Aborting."; exit 1 }

write-host "`nBuild successful!" -ForegroundColor Green
write-host "Output: $exe"
