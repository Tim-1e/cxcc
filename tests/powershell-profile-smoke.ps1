[CmdletBinding()]
param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestProcessEnvironment.ps1")
$previousEnvironment = Save-TestProcessEnvironment
$previousLocation = Get-Location
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("cxcc-profile-smoke-" + [guid]::NewGuid().ToString("N"))
$loaderPath = Join-Path $SourceDir "src/powershell/CxCc/CxCc.ps1"

try {
  $env:AI_ENV_HOME = Join-Path $tmpRoot "home"
  $env:AI_ENV_NONINTERACTIVE = "1"
  New-Item -ItemType Directory -Force -Path (Join-Path $env:AI_ENV_HOME ".ai-env"), (Join-Path $tmpRoot "unrelated") | Out-Null
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/profiles.json") -Destination (Join-Path $env:AI_ENV_HOME ".ai-env/profiles.json")
  Set-Location -LiteralPath (Join-Path $tmpRoot "unrelated")

  if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) { throw "Stable PowerShell loader is missing: $loaderPath" }
  . $loaderPath

  $expectedOwners = @{
    cx = Join-Path $SourceDir "src/powershell/CxCc/Entrypoints.ps1"
    cc = Join-Path $SourceDir "src/powershell/CxCc/Entrypoints.ps1"
    mcp = Join-Path $SourceDir "src/powershell/CxCc/Mcp.ps1"
    codex = Join-Path $SourceDir "src/powershell/CxCc/Entrypoints.ps1"
  }
  foreach ($name in $expectedOwners.Keys) {
    $command = Get-Command $name -CommandType Function -ErrorAction Stop
    $actualOwner = [IO.Path]::GetFullPath($command.ScriptBlock.File)
    $expectedOwner = [IO.Path]::GetFullPath($expectedOwners[$name])
    if (-not $actualOwner.Equals($expectedOwner, [StringComparison]::OrdinalIgnoreCase)) {
      throw "$name loaded from '$actualOwner', expected '$expectedOwner'"
    }
  }

  Write-Host "PowerShell profile smoke check passed."
} finally {
  Set-Location -LiteralPath $previousLocation
  Restore-TestProcessEnvironment -Snapshot $previousEnvironment
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
