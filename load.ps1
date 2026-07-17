$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Stop"

try {
  $installRoot = [IO.Path]::GetFullPath($PSScriptRoot)
  $currentPath = Join-Path $installRoot "current.json"
  if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
    throw "cxcc is not installed: current.json is missing."
  }

  $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
  $version = [string]$current.version
  if ($version -notmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') {
    throw "cxcc current.json contains an invalid version."
  }

  $versionsRoot = [IO.Path]::GetFullPath((Join-Path $installRoot "versions"))
  $versionRoot = [IO.Path]::GetFullPath((Join-Path $versionsRoot $version))
  $expectedPrefix = $versionsRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if (-not $versionRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "cxcc current version escapes the versions directory."
  }

  $versionFile = Join-Path $versionRoot "VERSION"
  if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf) -or (Get-Content -LiteralPath $versionFile -Raw).Trim() -cne $version) {
    throw "cxcc installed version metadata is invalid: $version"
  }

  $entrypoint = Join-Path $versionRoot "src\powershell\CxCc\CxCc.ps1"
  if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
    throw "cxcc PowerShell entrypoint is missing: $entrypoint"
  }

  . $entrypoint
} finally {
  $ErrorActionPreference = $savedErrorActionPreference
}
