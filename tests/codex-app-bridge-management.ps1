param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestProcessEnvironment.ps1")
$previousProcessEnvironment = Save-TestProcessEnvironment
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-app-bridge-management-" + [guid]::NewGuid().ToString("N"))
$testHome = Join-Path $tmpRoot "home"
$bridgeHome = Join-Path $tmpRoot "bridge"
$previous = @{
  AI_ENV_HOME = $env:AI_ENV_HOME
  AI_CODEX_APP_BRIDGE_HOME = $env:AI_CODEX_APP_BRIDGE_HOME
  AI_CODEX_APP_BRIDGE_PROJECT = $env:AI_CODEX_APP_BRIDGE_PROJECT
  AI_CODEX_APP_BRIDGE_BINARY = $env:AI_CODEX_APP_BRIDGE_BINARY
  AI_CODEX_APP_REAL_CLI = $env:AI_CODEX_APP_REAL_CLI
  AI_CODEX_APP_BRIDGE_ENV_TARGET = $env:AI_CODEX_APP_BRIDGE_ENV_TARGET
  AI_CODEX_CONFIG_PATH = $env:AI_CODEX_CONFIG_PATH
  CODEX_CLI_PATH = $env:CODEX_CLI_PATH
}

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $testHome ".ai-env") | Out-Null
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/profiles.json") -Destination (Join-Path $testHome ".ai-env/profiles.json")
  $env:AI_ENV_HOME = $testHome
  $env:AI_CODEX_APP_BRIDGE_HOME = $bridgeHome
  $env:AI_CODEX_APP_BRIDGE_PROJECT = Join-Path $SourceDir "src/bridge/CodexProviderBridge/CodexProviderBridge.csproj"
  $prebuiltBridge = Join-Path $tmpRoot "codex-provider-bridge.exe"
  [IO.File]::WriteAllText($prebuiltBridge, "prebuilt-bridge-fixture", [Text.UTF8Encoding]::new($false))
  $env:AI_CODEX_APP_BRIDGE_BINARY = $prebuiltBridge
  $trustedBundle = Join-Path $tmpRoot "trusted-bundle-v1"
  $trustedBundleV2 = Join-Path $tmpRoot "trusted-bundle-v2"
  New-Item -ItemType Directory -Force -Path $trustedBundle, $trustedBundleV2 | Out-Null
  $trustedCli = Join-Path $trustedBundle "codex.exe"
  $trustedCliV2 = Join-Path $trustedBundleV2 "codex.exe"
  $bundleNames = @("codex.exe", "codex-command-runner.exe", "codex-code-mode-host.exe", "codex-windows-sandbox-setup.exe")
  foreach ($name in $bundleNames) {
    [IO.File]::WriteAllText((Join-Path $trustedBundle $name), "fixture-v1-$name", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $trustedBundleV2 $name), "fixture-v2-$name", [Text.UTF8Encoding]::new($false))
  }
  $env:AI_CODEX_APP_REAL_CLI = $trustedCli
  $env:AI_CODEX_APP_BRIDGE_ENV_TARGET = "Process"
  $env:AI_CODEX_CONFIG_PATH = Join-Path $testHome ".codex/config.toml"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $env:AI_CODEX_CONFIG_PATH) | Out-Null
  [IO.File]::WriteAllText($env:AI_CODEX_CONFIG_PATH, "model_provider = `"openai`"`n", [Text.UTF8Encoding]::new($false))
  $env:CODEX_CLI_PATH = "C:\before-codex.exe"

  . (Join-Path $SourceDir "src/powershell/CxCc/CxCc.ps1")

  $fakePackageRoot = Join-Path $tmpRoot "OpenAI.Codex_fixture"
  $fakePackageResources = Join-Path $fakePackageRoot "app/resources"
  New-Item -ItemType Directory -Force -Path $fakePackageResources | Out-Null
  $fakePackageCli = Join-Path $fakePackageResources "codex.exe"
  Copy-Item -LiteralPath $trustedCli -Destination $fakePackageCli
  $realCliOverride = $env:AI_CODEX_APP_REAL_CLI
  Remove-Item Env:AI_CODEX_APP_REAL_CLI -ErrorAction SilentlyContinue
  function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    return @()
  }
  function Get-AppxPackage {
    [CmdletBinding()]
    param([string]$Name)
    return [pscustomobject]@{
      Version = [version]"26.715.2305.0"
      InstallLocation = $fakePackageRoot
    }
  }
  try {
    $discoveredCli = Resolve-CodexAppRealCliPath
    if ($discoveredCli -cne $fakePackageCli) { throw "Closed-App discovery did not use Appx package metadata: $discoveredCli" }
  } finally {
    Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-AppxPackage -ErrorAction SilentlyContinue
    $env:AI_CODEX_APP_REAL_CLI = $realCliOverride
  }

  Invoke-CodexAppBridgeCommand -Arguments @("install") | Out-Null

  $bridgePath = Join-Path $bridgeHome "codex-provider-bridge.exe"
  $settingsPath = Join-Path $bridgeHome "codex-provider-bridge.json"
  $activationPath = Join-Path $bridgeHome "activation.json"
  foreach ($path in @($bridgePath, $settingsPath, $activationPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Install did not create $path" }
  }
  if ((Get-FileHash -LiteralPath $bridgePath -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $prebuiltBridge -Algorithm SHA256).Hash) { throw "Install did not use the prebuilt bridge" }
  if ($env:CODEX_CLI_PATH -cne $bridgePath) { throw "Install did not activate CODEX_CLI_PATH" }
  $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -Depth 20
  $securedRealCli = Join-Path $bridgeHome "codex.exe"
  if ($settings.realCodexPath -cne $securedRealCli) { throw "Settings did not select the secured real CLI copy" }
  if ($settings.realCodexSha256 -cne (Get-FileHash -LiteralPath $env:AI_CODEX_APP_REAL_CLI -Algorithm SHA256).Hash) { throw "Settings did not pin the trusted source CLI hash" }
  if ((Get-FileHash -LiteralPath $securedRealCli -Algorithm SHA256).Hash -cne $settings.realCodexSha256) { throw "Secured real CLI copy does not match settings" }
  foreach ($helper in @("codex-command-runner.exe", "codex-code-mode-host.exe", "codex-windows-sandbox-setup.exe")) {
    $sourceHelper = Join-Path $trustedBundle $helper
    $securedHelper = Join-Path $bridgeHome $helper
    if (-not (Test-Path -LiteralPath $securedHelper -PathType Leaf)) { throw "Install omitted required helper $helper" }
    if ((Get-FileHash -LiteralPath $securedHelper -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $sourceHelper -Algorithm SHA256).Hash) { throw "Secured helper differs: $helper" }
  }
  if ((Get-Content -LiteralPath $settingsPath -Raw) -match '(?i)(api[_-]?key|bearer|token)') { throw "Bridge settings contain secret-like fields" }
  $installedStatus = Get-CodexAppBridgeStatus
  if (-not $installedStatus.IsInstalled -or -not $installedStatus.IsConfigured) { throw "Status did not recognize the installed and configured bridge" }
  if (-not $installedStatus.IsCurrentAppCli) { throw "Status did not recognize the pinned CLI as current" }

  $v1Hash = [string]$settings.realCodexSha256
  $env:AI_CODEX_APP_REAL_CLI = $trustedCliV2
  $staleStatus = Get-CodexAppBridgeStatus
  if (-not $staleStatus.IsInstalled -or -not $staleStatus.IsConfigured) { throw "CLI refresh check changed bridge installation state" }
  if ($staleStatus.IsCurrentAppCli) { throw "Status did not detect the changed App CLI bundle" }

  Invoke-CodexAppBridgeCommand -Arguments @("install") | Out-Null
  $refreshedStatus = Get-CodexAppBridgeStatus
  if (-not $refreshedStatus.IsInstalled -or -not $refreshedStatus.IsConfigured) { throw "Reinstall did not leave the bridge installed and configured" }
  if (-not $refreshedStatus.IsCurrentAppCli) { throw "Status did not recognize the refreshed App CLI bundle" }
  $refreshedSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -Depth 20
  $v2Hash = (Get-FileHash -LiteralPath $trustedCliV2 -Algorithm SHA256).Hash
  if ($refreshedSettings.realCodexSha256 -cne $v2Hash) { throw "Reinstall did not pin the v2 CLI hash" }
  if ($refreshedSettings.realCodexSha256 -ceq $v1Hash) { throw "Reinstall retained the v1 CLI hash" }

  $cachedActivationJson = Get-Content -LiteralPath $activationPath -Raw
  $thirdPartyCli = Join-Path $tmpRoot "third-party-codex.exe"
  $env:CODEX_CLI_PATH = $thirdPartyCli
  Invoke-CodexAppBridgeCommand -Arguments @("remove") | Out-Null
  if ($env:CODEX_CLI_PATH -cne $thirdPartyCli) { throw "Remove clobbered a third-party CODEX_CLI_PATH" }
  if (Test-Path -LiteralPath $activationPath) { throw "Remove did not delete activation after ownership changed" }

  [IO.File]::WriteAllText($activationPath, $cachedActivationJson, [Text.UTF8Encoding]::new($false))
  $env:CODEX_CLI_PATH = $bridgePath
  Invoke-CodexAppBridgeCommand -Arguments @("remove") | Out-Null
  if ($env:CODEX_CLI_PATH -cne "C:\before-codex.exe") { throw "Owned remove did not restore the pre-install CODEX_CLI_PATH" }
  if (Test-Path -LiteralPath $activationPath) { throw "Owned remove did not delete activation" }

  if ($IsWindows) {
    $aclFixture = Join-Path $tmpRoot "acl-gate.txt"
    [IO.File]::WriteAllText($aclFixture, "acl-fixture", [Text.UTF8Encoding]::new($false))
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $aclFixture
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($currentSid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $aclFixture -AclObject $acl

    $savedConfigPath = $env:AI_CODEX_CONFIG_PATH
    try {
      Remove-Item Env:AI_CODEX_CONFIG_PATH -ErrorAction SilentlyContinue
      Assert-CodexAppWritablePathsProtected -Paths @($aclFixture)

      $icaclsPath = (Get-Command icacls.exe -CommandType Application -ErrorAction Stop).Source
      & $icaclsPath $aclFixture "/grant" "*S-1-1-0:(WD)" | Out-Null
      $aclExitCode = $LASTEXITCODE
      if ($aclExitCode -ne 0) { throw "icacls failed with exit code $aclExitCode" }
      try {
        Assert-CodexAppWritablePathsProtected -Paths @($aclFixture)
        throw "ACL gate accepted Everyone WriteData"
      } catch {
        if ($_.Exception.Message -notmatch "Unsafe ACL") { throw }
      }
    } finally {
      if ($null -eq $savedConfigPath) { Remove-Item Env:AI_CODEX_CONFIG_PATH -ErrorAction SilentlyContinue } else { $env:AI_CODEX_CONFIG_PATH = $savedConfigPath }
    }
  }

  $status = Get-CodexAppBridgeStatus
  if ($status.IsConfigured) { throw "Bridge still reports configured after remove" }
  Write-Host "Codex App bridge management tests passed"
} finally {
  foreach ($name in $previous.Keys) {
    $value = $previous[$name]
    if ($null -eq $value) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item "Env:$name" $value }
  }
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  Restore-TestProcessEnvironment -Snapshot $previousProcessEnvironment
}
