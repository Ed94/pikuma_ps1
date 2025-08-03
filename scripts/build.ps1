$path_root      = split-path -Path $PSScriptRoot -Parent
$path_build     = join-path $path_root 'build'
$path_code      = join-path $path_root 'code'
$path_scripts   = join-path $path_root 'scripts'
$path_toolchain = join-path $path_root 'toolchain'

if ((test-path $path_build) -eq $false) {
	new-item -itemtype directory -path $path_build
}

$armips      = join-path $path_toolchain 'armips/armips.exe'
$bin2exe_lua = join-path $path_scripts 'bin2exe.lua'
$bin2exe_py  = join-path $path_scripts 'bin2exe.py'

function build-program { param(
	[string]$module,
	[string]$unit
)
	$path_module = join-path $path_code   $module
	$src         = join-path $path_module "$unit.s"
	$bin         = join-path $path_build  "$unit.bin"
	$exe         = join-path $path_build  "$unit.exe"

	push-location $path_build
	write-host "Assembling: $src`n"
	& $armips $src

	write-host 'Generating executable..'
	& lua $bin2exe_lua $bin $exe
	# & py $bin2exe_py $bin $exe

	write-host 'Done!'
	pop-location
}
build-program 'fillmem' 'fillmem'
build-program 'warmup' 'exercise_1'
build-program 'warmup' 'exercise_2'
build-program 'warmup' 'exercise_3'