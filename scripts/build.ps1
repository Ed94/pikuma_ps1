$path_root    = split-path -Path $PSScriptRoot -Parent
$path_build   = join-path $path_root 'build'
$path_code    = join-path $path_root 'code'
$path_scripts = join-path $path_root 'scripts'

if ((test-path $path_build) -eq $false) {
	new-item -itemtype directory -path $path_build
}

$armips      = 'armips'
$bin2exe_lua = join-path $path_scripts 'bin2exe.lua'

$path_fillmem = join-path $path_code    'fillmem'
$src_fillmem  = join-path $path_fillmem 'fillmem.s'
$bin_fillmem  = join-path $path_build   'fillmem.bin'
$exe_fillmem  = join-path $path_build   'fillmem.exe'

push-location $path_build
write-host "Assembling: $src_fillmem`n"
& $armips $src_fillmem

write-host 'Generating executable..'
& lua $bin2exe_lua $bin_fillmem $exe_fillmem

write-host 'Done!'
pop-location
