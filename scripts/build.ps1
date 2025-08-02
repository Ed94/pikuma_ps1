$path_root  = split-path -Path $PSScriptRoot -Parent
$path_build = join-path $path_root 'build'
$path_code  = join-path $path_root 'code'

if ((test-path $path_build) -eq $false) {
	new-item -itemtype directory -path $path_build
}

$armips = 'armips'

$path_fillmem = join-path $path_code 'fillmem'
$src_fillmem  = join-path $path_fillmem 'fillmem.s'

push-location $path_build
& $armips $src_fillmem
pop-location
