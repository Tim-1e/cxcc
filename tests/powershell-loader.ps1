[CmdletBinding()]
param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestProcessEnvironment.ps1")
$previousEnvironment = Save-TestProcessEnvironment
$previousLocation = Get-Location
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("cxcc-loader-" + [guid]::NewGuid().ToString("N"))
$loaderPath = Join-Path $SourceDir "src/powershell/CxCc/CxCc.ps1"
$moduleNames = @("Profiles", "ToolRuntime", "Health", "CodexApp", "Mcp", "Entrypoints")

try {
  $env:AI_ENV_HOME = Join-Path $tmpRoot "home"
  $env:AI_ENV_NONINTERACTIVE = "1"
  Remove-Item Env:AI_CODEX_APP_BRIDGE_PROJECT -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path (Join-Path $env:AI_ENV_HOME ".ai-env"), (Join-Path $tmpRoot "unrelated") | Out-Null
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/profiles.json") -Destination (Join-Path $env:AI_ENV_HOME ".ai-env/profiles.json")
  Set-Location -LiteralPath (Join-Path $tmpRoot "unrelated")

  if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) { throw "Stable PowerShell loader is missing: $loaderPath" }
  foreach ($moduleName in $moduleNames) {
    $modulePath = Join-Path $SourceDir "src/powershell/CxCc/$moduleName.ps1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "PowerShell module is missing: $modulePath" }
  }
  if (Test-Path -LiteralPath (Join-Path $SourceDir "src/legacy/powershell/ai-env.ps1")) {
    throw "Legacy PowerShell implementation still exists"
  }

  $loaderText = Get-Content -Raw -LiteralPath $loaderPath
  $expectedLoads = @($moduleNames | ForEach-Object { '. (Join-Path $PSScriptRoot "' + $_ + '.ps1")' })
  $actualLoads = @(Get-Content -LiteralPath $loaderPath | Where-Object { $_.StartsWith('. ') })
  if (($actualLoads -join "`n") -cne ($expectedLoads -join "`n")) { throw "Loader module order is not explicit and stable" }
  if ($loaderText -match 'legacy[\\/]powershell[\\/]ai-env\.ps1') { throw "Loader still references the legacy implementation" }
  $loaderStatements = @(Get-Content -LiteralPath $loaderPath | Where-Object { $_.Trim() })
  if ($loaderStatements[-1] -cne "Initialize-AiEnvProfiles") {
    throw "Loader must initialize profiles only after loading all modules"
  }
  . $loaderPath

  $expectedRoot = [IO.Path]::GetFullPath($SourceDir)
  $actualRoot = [IO.Path]::GetFullPath($script:CxCcSourceRoot)
  if (-not $actualRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Loader source root mismatch: expected '$expectedRoot', got '$actualRoot'"
  }

  $expectedProject = [IO.Path]::GetFullPath((Join-Path $SourceDir "src/bridge/CodexProviderBridge/CodexProviderBridge.csproj"))
  $actualProject = Get-CodexAppBridgeProjectPath
  if (-not $actualProject.Equals($expectedProject, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Default Bridge project mismatch: expected '$expectedProject', got '$actualProject'"
  }

  Write-Host "PowerShell loader check passed."
} finally {
  Set-Location -LiteralPath $previousLocation
  Restore-TestProcessEnvironment -Snapshot $previousEnvironment
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
