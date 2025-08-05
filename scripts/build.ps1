$path_root      = split-path -Path $PSScriptRoot -Parent
$path_build     = join-path $path_root 'build'
$path_code      = join-path $path_root 'code'
$path_scripts   = join-path $path_root 'scripts'
$path_toolchain = join-path $path_root 'toolchain'

if ((test-path $path_build) -eq $false) {
	new-item -itemtype directory -path $path_build
}

$armips      = join-path $path_toolchain 'armips/build/Debug/armips.exe'
$bin2exe_lua = join-path $path_scripts 'bin2exe.lua'
$bin2exe_py  = join-path $path_scripts 'bin2exe.py'


