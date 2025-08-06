$path_root      = split-path -Path $PSScriptRoot -Parent
$path_build     = join-path $path_root 'build'
$path_code      = join-path $path_root 'code'
$path_scripts   = join-path $path_root 'scripts'
$path_toolchain = join-path $path_root 'toolchain'

$path_pcsx_redux            = join-path $path_toolchain             'pcsx-redux'
$path_pcsx_redux_vsprojects = join-path $path_pcsx_redux            'vsprojects'
$path_pcsx_redux_binaries   = join-path $path_pcsx_redux_vsprojects 'x64/Release'

$pcsx_redux = join-path $path_pcsx_redux_binaries 'pcsx-redux.exe'
& $pcsx_redux
