$path_root      = split-path -Path $PSScriptRoot -Parent
$path_build     = join-path $path_root 'build'
$path_code      = join-path $path_root 'code'
$path_scripts   = join-path $path_root 'scripts'
$path_toolchain = join-path $path_root 'toolchain'

$misc = join-path $PSScriptRoot 'helpers/misc.ps1'
. $misc

$url_armips     = 'https://github.com/Kingcom/armips.git'
$url_pcsx_redux = 'https://github.com/grumpycoders/pcsx-redux.git'

$path_armips     = join-path $path_toolchain 'armips'
$path_pcsx_redux = join-path $path_toolchain 'pcsx_redux'

clone-gitrepo $path_armips     $url_armips
clone-gitrepo $path_pcsx_redux $url_pcsx_redux

$path_armips_build = join-path $path_armips 'build'
verify-path $path_armips_build
push-location $path_armips_build
&	cmake ..
&	cmake --build . --config Debug
pop-location
