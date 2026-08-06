# scripts/reload.ps1
#
# PCSX-Redux Lua helper reload client.
#
# Modes:
#   elf   - Request a full ELF reload. Requires -ElfPath.
#   patch - Request a single-word RAM patch. Requires -Address and -Word.
#
# -RequestOnly prints the URI and exits before any network I/O.
# -Quiet suppresses the compact-JSON printout on the real path.

[CmdletBinding()]
param(
	[ValidateSet('elf', 'patch')][string]$Mode = 'elf',
	[string]$Target = 'hello_camera',
	[string]$ElfPath = '',
	[string]$Address = '',
	[string]$Word = '',
	[int]$Port = 8080,
	[switch]$RequestOnly,
	[switch]$Quiet
)

# mode-specific argument guards
switch ($Mode) {
	'patch' {
		if ([string]::IsNullOrEmpty($Address) -or [string]::IsNullOrEmpty($Word)) {
			Write-Error "patch mode requires both -Address and -Word"
			exit 1
		}
	}
	'elf' {
		if ([string]::IsNullOrEmpty($ElfPath)) {
			Write-Error "elf mode requires -ElfPath"
			exit 1
		}
	}
}

# Build the URL-encoded query string.
$queryParts = New-Object System.Collections.Generic.List[string]
[void]$queryParts.Add("mode=$([uri]::EscapeDataString($Mode))")
[void]$queryParts.Add("target=$([uri]::EscapeDataString($Target))")

switch ($Mode) {
	'elf' {
		[void]$queryParts.Add("path=$([uri]::EscapeDataString($ElfPath))")
	}
	'patch' {
		[void]$queryParts.Add("addr=$([uri]::EscapeDataString($Address))")
		[void]$queryParts.Add("hex=$([uri]::EscapeDataString($Word))")
	}
}

$uri = "http://localhost:$Port/api/v1/lua/reload?$($queryParts -join '&')"

# RequestOnly path: emit URI and return before any network I/O.
if ($RequestOnly) {
	Write-Output $uri
	return
}

# Real request path: POST, decode body if it is a byte array, parse JSON.
$response = Invoke-WebRequest -Method Post -Uri $uri

if ($response.Content -is [byte[]]) {
	$text = [System.Text.Encoding]::UTF8.GetString([byte[]]$response.Content)
}
else {
	$text = [string]$response.Content
}

$obj = $text | ConvertFrom-Json

if (-not $Quiet) {
	$obj | ConvertTo-Json -Compress | Write-Output
}

if (-not $obj.ok) {
	$errCode = if ($obj.error) { [string]$obj.error } else { 'unknown' }
	throw "Reload failed: $errCode"
}
