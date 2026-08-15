# Package and install the local VS Code Insiders extensions under .vscode/.
# Usage:
#   .\install_extensions.ps1
#   .\install_extensions.ps1 -SkipPackage

param([switch] $SkipPackage)

$path_vscode   = $PSScriptRoot
$code_insiders = "C:\apps\Microsoft VS Code Insiders\bin\code-insiders.cmd"
if (-not (test-path -literalpath $code_insiders)) {
	$found = get-command code-insiders -erroraction silentlycontinue
	if ($found) { $code_insiders = $found.source }
}

if (-not (test-path -literalpath $code_insiders)) { throw "code-insiders not found. Install VS Code Insiders or add it to PATH." }

$extensions = @(
	(join-path $path_vscode "tape-atom-syntax"),
	(join-path $path_vscode "cozy-and-windy")
)

foreach ($extension in $extensions) {
	$package_json = join-path $extension "package.json"
	if (-not (test-path -literalpath $package_json)) { throw "missing $package_json" }

	$manifest = get-content -literalpath $package_json -raw | convertfrom-json
	$vsix     = join-path $extension ("{0}-{1}.vsix" -f $manifest.name, $manifest.version)

	if (-not $SkipPackage) {
		if (-not $manifest.scripts.package) { throw "$package_json has no scripts.package" }
		write-host "packaging $($manifest.displayName) ($($manifest.name)@$($manifest.version))"
		& npm --prefix $extension run package
		if ($LASTEXITCODE -ne 0) { throw "npm run package failed for $extension" }
	}

	if (-not (test-path -literalpath $vsix)) { throw "missing $vsix" }

	write-host "installing $vsix"
	& $code_insiders --install-extension $vsix --force
	if ($LASTEXITCODE -ne 0) { throw "install failed for $vsix" }
}

write-host "done. reload the Insiders window (Developer: Reload Window)."
