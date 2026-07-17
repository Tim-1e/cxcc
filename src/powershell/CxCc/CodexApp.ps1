function ConvertTo-AiTomlString {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

  return ($Value | ConvertTo-Json -Compress)
}

function Get-CodexAppDefaultProfileName {
  $registry = Get-AiRegistry
  $defaults = Get-AiProperty -Object $registry -Name "defaults"
  $name = Get-AiProperty -Object $defaults -Name "codex_app" -Default "sub"
  if ($name) { return [string]$name }
  return "sub"
}

function Get-CodexAppBaselineConfigPath {
  $configPath = Get-AiCodexConfigPath
  $backupPath = "$configPath.aienv-app.bak"
  if (Test-Path -LiteralPath $backupPath -PathType Leaf) { return $backupPath }
  return $configPath
}

function Test-AiIsolatedTestHome {
  if (-not $env:AI_ENV_HOME -or -not $env:AI_CODEX_CONFIG_PATH) { return $false }
  try {
    $homePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:AI_ENV_HOME)).TrimEnd('\', '/')
    $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if (-not $homePath.StartsWith($tempPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($path in @($script:AiConfigDir, $script:AiSecretsPath, (Get-AiCodexConfigPath))) {
      $fullPath = [IO.Path]::GetFullPath($path)
      if (-not $fullPath.StartsWith($homePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
  } catch {
    return $false
  }
}

function Assert-CodexAppWritablePathsProtected {
  param([Parameter(Mandatory = $true)][string[]]$Paths)

  if (-not $IsWindows -or (Test-AiIsolatedTestHome)) { return }

  $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $allowedSids = @($currentSid, "S-1-5-18", "S-1-5-32-544")
  try {
    $allowedSids += ([System.Security.Principal.NTAccount]"NT SERVICE\TrustedInstaller").Translate([System.Security.Principal.SecurityIdentifier]).Value
  } catch { }
  $writeRights = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
    [System.Security.AccessControl.FileSystemRights]::AppendData -bor
    [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
    [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [System.Security.AccessControl.FileSystemRights]::Delete -bor
    [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [System.Security.AccessControl.FileSystemRights]::TakeOwnership
  $privateRights = $writeRights -bor
    [System.Security.AccessControl.FileSystemRights]::ReadData -bor
    [System.Security.AccessControl.FileSystemRights]::ReadExtendedAttributes -bor
    [System.Security.AccessControl.FileSystemRights]::ReadAttributes -bor
    [System.Security.AccessControl.FileSystemRights]::ReadPermissions -bor
    [System.Security.AccessControl.FileSystemRights]::ExecuteFile
  $privatePaths = @(
    [IO.Path]::GetFullPath((Split-Path -Parent $script:AiSecretsPath)).TrimEnd('\', '/'),
    [IO.Path]::GetFullPath($script:AiSecretsPath).TrimEnd('\', '/')
  )

  foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Codex App credential path is missing: $path"
    }
    $item = Get-Item -Force -LiteralPath $path
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Codex App credential path must not be a reparse point: $path"
    }
    $acl = Get-Acl -LiteralPath $item.FullName
    try {
      $ownerSid = ([System.Security.Principal.NTAccount]$acl.Owner).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
      try { $ownerSid = ([System.Security.Principal.SecurityIdentifier]$acl.Owner).Value } catch { $ownerSid = [string]$acl.Owner }
    }
    if ($ownerSid -notin $allowedSids) {
      throw "Unsafe owner on ${path}: $($acl.Owner)."
    }
    foreach ($rule in $acl.Access) {
      if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
      try {
        $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
      } catch {
        $sid = [string]$rule.IdentityReference
      }
      $fullPath = [IO.Path]::GetFullPath($item.FullName).TrimEnd('\', '/')
      $forbiddenRights = if ($fullPath -in $privatePaths) { $privateRights } else { $writeRights }
      if ($sid -notin $allowedSids -and (($rule.FileSystemRights -band $forbiddenRights) -ne 0)) {
        throw "Unsafe ACL on ${path}: $($rule.IdentityReference) can access protected App credential inputs. Repair the ACL before selecting an API profile."
      }
    }
  }
}

function Get-CodexAppTokenCommandPath {
  if ((Test-AiIsolatedTestHome) -and $env:AI_CODEX_APP_TOKEN_COMMAND) {
    $path = [Environment]::ExpandEnvironmentVariables($env:AI_CODEX_APP_TOKEN_COMMAND)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Codex App token command is missing: $path"
    }
    return $path
  }

  $appAuthDir = Join-Path (Split-Path -Parent (Get-AiCodexConfigPath)) "app-auth"
  $targetPath = Join-Path $appAuthDir "codex-app-token.ps1"
  if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "Codex App token command is missing: $targetPath. Apply the dotfiles first."
  }
  return $targetPath
}

function Assert-CodexAppProfilePath {
  param([Parameter(Mandatory = $true)]$Profile)

  $appConfigPath = Get-AiCodexConfigPath
  $appHome = Split-Path -Parent $appConfigPath
  $profileHome = Get-CodexHome -Profile $Profile
  if (-not (Test-Path -LiteralPath $appHome -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $appHome | Out-Null
  }
  if (-not (Test-Path -LiteralPath $profileHome -PathType Container)) {
    throw "Codex profile home is missing: $profileHome"
  }

  foreach ($path in @($appHome, $profileHome)) {
    $item = Get-Item -Force -LiteralPath $path
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Codex App profile paths must not be reparse points: $path"
    }
  }

  $resolvedAppHome = (Resolve-Path -LiteralPath $appHome).Path.TrimEnd('\', '/')
  $resolvedProfileHome = (Resolve-Path -LiteralPath $profileHome).Path.TrimEnd('\', '/')
  if (-not $resolvedAppHome.Equals($resolvedProfileHome, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Codex App can only select profiles that share its CODEX_HOME ($resolvedAppHome). '$((Get-AiProfileName -Profile $Profile))' uses $resolvedProfileHome."
  }

  $profilePath = Get-CodexProfilePath -Profile $Profile
  if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw "Codex profile config is missing: $profilePath"
  }
  if (((Get-Item -Force -LiteralPath $profilePath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Codex profile config must not be a reparse point: $profilePath"
  }
  $resolvedProfilePath = (Resolve-Path -LiteralPath $profilePath).Path
  $resolvedParent = (Split-Path -Parent $resolvedProfilePath).TrimEnd('\', '/')
  if (-not $resolvedParent.Equals($resolvedProfileHome, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Codex profile config escapes its CODEX_HOME: $resolvedProfilePath"
  }
  return $resolvedProfilePath
}

function Set-CodexAppConfig {
  param(
    [Parameter(Mandatory = $true)][System.Collections.IDictionary]$TopLevelValues,
    [AllowNull()][string]$ProviderBlock
  )

  $path = Get-AiCodexConfigPath
  $original = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -Raw -LiteralPath $path } else { "" }
  $lines = if ($original) { @($original -split '\r?\n') } else { @() }
  if ($lines.Count -gt 0 -and $lines[-1] -eq "") { $lines = @($lines[0..($lines.Count - 2)]) }

  $output = [System.Collections.Generic.List[string]]::new()
  $seen = @{}
  $isTopLevel = $true
  $skipManagedProvider = $false
  foreach ($line in $lines) {
    $trimmed = "$line".Trim()
    if ($trimmed -match '^\[([^\[\]]+)\]\s*(?:#.*)?$') {
      $isTopLevel = $false
      $header = $Matches[1].Trim()
      $skipManagedProvider = [bool]($ProviderBlock -and $header -in @("model_providers.ai-env-app", "model_providers.ai-env-app.auth"))
      if ($skipManagedProvider) { continue }
    } elseif ($trimmed -match '^\[\[') {
      $isTopLevel = $false
      $skipManagedProvider = $false
    } elseif ($skipManagedProvider) {
      continue
    }

    if ($isTopLevel -and $trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=') {
      $key = $Matches[1]
      if ($TopLevelValues.Contains($key)) {
        if (-not $seen.ContainsKey($key) -and $null -ne $TopLevelValues[$key]) {
          $output.Add("$key = $($TopLevelValues[$key])")
        }
        $seen[$key] = $true
        continue
      }
    }
    $output.Add([string]$line)
  }

  $prefix = [System.Collections.Generic.List[string]]::new()
  foreach ($key in $TopLevelValues.Keys) {
    if (-not $seen.ContainsKey([string]$key) -and $null -ne $TopLevelValues[$key]) {
      $prefix.Add("$key = $($TopLevelValues[$key])")
    }
  }
  if ($prefix.Count -gt 0 -and $output.Count -gt 0 -and $output[0].Trim()) { $prefix.Add("") }
  $finalLines = @($prefix) + @($output)
  while ($finalLines.Count -gt 0 -and -not "$($finalLines[-1])".Trim()) {
    if ($finalLines.Count -eq 1) { $finalLines = @(); break }
    $finalLines = @($finalLines[0..($finalLines.Count - 2)])
  }
  if ($ProviderBlock) {
    if ($finalLines.Count -gt 0) { $finalLines += "" }
    $finalLines += @($ProviderBlock.Trim() -split '\r?\n')
  }
  $updated = (($finalLines -join "`n").TrimEnd() + "`n")

  if ($updated -cne $original) {
    $backupPath = "$path.aienv-app.bak"
    if ($original -and -not (Test-Path -LiteralPath $backupPath)) {
      Copy-Item -LiteralPath $path -Destination $backupPath -Force
    }
    Write-AiUtf8NoBomAtomic -Path $path -Content $updated
  }
  return $original
}

function Set-CodexAppDefaultProfile {
  param([string[]]$Arguments)

  $parsed = ConvertFrom-AiManagementArgs -Arguments $Arguments
  if ($parsed.Positionals.Count -lt 1) {
    Write-Host "Codex App default = $(Get-CodexAppDefaultProfileName)"
    return
  }
  if ($parsed.Positionals.Count -gt 1 -or $parsed.Options.Count -gt 0) {
    throw "Usage: cx app-default [NAME]"
  }

  $requestedName = [string]$parsed.Positionals[0]
  $profile = Get-AiProfileByName -Tool "codex" -Name $requestedName
  if (-not $profile) { throw "Unknown Codex profile '$requestedName'." }
  $name = Get-AiProfileName -Profile $profile
  $mode = Get-AiProfileMode -Profile $profile
  $profilePath = Assert-CodexAppProfilePath -Profile $profile
  $topLevel = [ordered]@{ model_provider = ConvertTo-AiTomlString $(if ($mode -eq "api") { "ai-env-app" } else { "openai" }) }

  $model = Get-AiTomlTopLevelStringValue -Path $profilePath -Key "model"
  $reasoning = Get-AiTomlTopLevelStringValue -Path $profilePath -Key "model_reasoning_effort"
  $baselinePath = Get-CodexAppBaselineConfigPath
  if (-not $model) { $model = Get-AiTomlTopLevelStringValue -Path $baselinePath -Key "model" }
  if (-not $reasoning) { $reasoning = Get-AiTomlTopLevelStringValue -Path $baselinePath -Key "model_reasoning_effort" }
  $topLevel["model"] = if ($model) { ConvertTo-AiTomlString $model } else { $null }
  $topLevel["model_reasoning_effort"] = if ($reasoning) { ConvertTo-AiTomlString $reasoning } else { $null }
  $topLevel["disable_response_storage"] = $null

  $providerBlock = $null
  if ($mode -eq "api") {
    $profileProvider = Get-AiTomlTopLevelStringValue -Path $profilePath -Key "model_provider"
    if (-not $profileProvider -or $profileProvider -notmatch '^[A-Za-z0-9_-]+$') {
      throw "Codex App API profile '$name' has an invalid model_provider."
    }
    $providerSection = "model_providers.$profileProvider"
    $baseUrl = Get-AiTomlSectionStringValue -Path $profilePath -Section $providerSection -Key "base_url"
    $providerName = Get-AiTomlSectionStringValue -Path $profilePath -Section $providerSection -Key "name"
    $wireApi = Get-AiTomlSectionStringValue -Path $profilePath -Section $providerSection -Key "wire_api"
    $envKey = Get-AiTomlSectionStringValue -Path $profilePath -Section $providerSection -Key "env_key"
    if (-not $providerName) { $providerName = $name }
    if (-not $wireApi) { $wireApi = "responses" }
    if (-not $envKey) { $envKey = "OPENAI_API_KEY" }
    $uri = $null
    if (-not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne "https" -or $uri.UserInfo) {
      throw "Codex App API profile '$name' must use an absolute HTTPS base_url without user info."
    }
    if ($wireApi -ne "responses") { throw "Codex App only supports wire_api = responses for managed API profiles." }
    if (-not (Test-AiTomlSecretValues -Tool "codex" -Profile $profile -Names @($envKey))) {
      throw "Codex App API profile '$name' is missing $envKey in $script:AiSecretsPath#$(Get-AiSecretId -Tool 'codex' -Profile $profile)."
    }

    $tokenCommand = Get-CodexAppTokenCommandPath
    $pwshCommand = (Get-Process -Id $PID -ErrorAction Stop).Path
    Assert-CodexAppWritablePathsProtected -Paths @(
      $script:AiConfigDir,
      $script:AiRegistryPath,
      (Split-Path -Parent $script:AiSecretsPath),
      $script:AiSecretsPath,
      (Split-Path -Parent (Get-AiCodexConfigPath)),
      (Get-AiCodexConfigPath),
      $profilePath,
      (Split-Path -Parent $tokenCommand),
      $tokenCommand,
      (Split-Path -Parent $pwshCommand),
      $pwshCommand
    )
    $secretId = Get-AiSecretId -Tool "codex" -Profile $profile
    $args = @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $tokenCommand, "-SecretId", $secretId, "-Key", $envKey, "-SecretsPath", $script:AiSecretsPath)
    $tomlArgs = (@($args | ForEach-Object { ConvertTo-AiTomlString ([string]$_) }) -join ", ")
    $providerBlock = @(
      "[model_providers.ai-env-app]"
      "name = $(ConvertTo-AiTomlString $providerName)"
      "base_url = $(ConvertTo-AiTomlString $baseUrl)"
      "wire_api = `"responses`""
      ""
      "[model_providers.ai-env-app.auth]"
      "command = $(ConvertTo-AiTomlString $pwshCommand)"
      "args = [$tomlArgs]"
      "timeout_ms = 5000"
      "refresh_interval_ms = 0"
    ) -join "`n"
  }

  $configPath = Get-AiCodexConfigPath
  $configExisted = Test-Path -LiteralPath $configPath -PathType Leaf
  $originalConfig = Set-CodexAppConfig -TopLevelValues $topLevel -ProviderBlock $providerBlock
  try {
    $registry = Get-AiRegistry
    $defaults = Get-AiProperty -Object $registry -Name "defaults"
    if (-not $defaults) {
      $defaults = [pscustomobject]@{}
      $registry | Add-Member -NotePropertyName defaults -NotePropertyValue $defaults
    }
    $defaults | Add-Member -NotePropertyName "codex_app" -NotePropertyValue $name -Force
    Save-AiRegistry -Registry $registry
  } catch {
    if ($configExisted) {
      Write-AiUtf8NoBomAtomic -Path $configPath -Content $originalConfig
    } else {
      Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    }
    throw
  }

  Write-Host "Codex App default = $name"
  Write-Host "  Config: $configPath"
  Write-Host "  Provider: $($topLevel['model_provider'].Trim('`"'))"
  Write-Host "  Reload: close and reopen Codex App"
}

function Get-CodexAppBridgeRoot {
  $path = if ($env:AI_CODEX_APP_BRIDGE_HOME) {
    [Environment]::ExpandEnvironmentVariables($env:AI_CODEX_APP_BRIDGE_HOME)
  } else {
    Join-Path $script:AiHome ".codex\app-bridge"
  }
  return [IO.Path]::GetFullPath($path)
}

function Get-CodexAppBridgeEnvironmentTarget {
  param([string]$Name)

  $name = if ($Name) { $Name } elseif ($env:AI_CODEX_APP_BRIDGE_ENV_TARGET) { $env:AI_CODEX_APP_BRIDGE_ENV_TARGET } else { "User" }
  if ($name -ieq "Process") { return [EnvironmentVariableTarget]::Process }
  if ($name -ieq "User") { return [EnvironmentVariableTarget]::User }
  throw "AI_CODEX_APP_BRIDGE_ENV_TARGET must be User or Process."
}

function Get-CodexAppBridgeProjectPath {
  $candidates = [System.Collections.Generic.List[string]]::new()
  if ($env:AI_CODEX_APP_BRIDGE_PROJECT) { $candidates.Add([Environment]::ExpandEnvironmentVariables($env:AI_CODEX_APP_BRIDGE_PROJECT)) }
  $cxccSourceRoot = Get-Variable -Name CxCcSourceRoot -Scope Script -ValueOnly -ErrorAction SilentlyContinue
  if ($cxccSourceRoot) { $candidates.Add((Join-Path $cxccSourceRoot "src\bridge\CodexProviderBridge\CodexProviderBridge.csproj")) }
  if ($script:AiEnvScriptRoot) { $candidates.Add((Join-Path $script:AiEnvScriptRoot "..\..\..\tools\codex-provider-bridge\CodexProviderBridge.csproj")) }
  $chezmoi = Get-Command chezmoi -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($chezmoi) {
    try {
      $sourcePath = (& $chezmoi.Source source-path 2>$null | Select-Object -First 1)
      if ($sourcePath) { $candidates.Add((Join-Path ([string]$sourcePath).Trim() "tools\codex-provider-bridge\CodexProviderBridge.csproj")) }
    } catch { }
  }
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return (Resolve-Path -LiteralPath $candidate).Path }
  }
  throw "Codex App bridge project was not found. Set AI_CODEX_APP_BRIDGE_PROJECT to CodexProviderBridge.csproj."
}

function Get-CodexAppPackageInstallLocations {
  if (-not $IsWindows) { return @() }

  $locations = [System.Collections.Generic.List[string]]::new()
  try {
    foreach ($package in @(Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction Stop | Sort-Object Version -Descending)) {
      if ($package.InstallLocation) { $locations.Add([string]$package.InstallLocation) }
    }
  } catch { }

  if ($locations.Count -eq 0) {
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
      try {
        $query = "Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -ExpandProperty InstallLocation"
        $output = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $query 2>$null
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
          foreach ($line in @($output)) {
            $location = ([string]$line).Trim()
            if ($location) { $locations.Add($location) }
          }
        }
      } catch { }
    }
  }

  return $locations.ToArray()
}

function Resolve-CodexAppRealCliPath {
  if ($env:AI_CODEX_APP_REAL_CLI) {
    $overridePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:AI_CODEX_APP_REAL_CLI))
    if (-not (Test-Path -LiteralPath $overridePath -PathType Leaf)) { throw "AI_CODEX_APP_REAL_CLI does not exist: $overridePath" }
    if (-not (Test-AiIsolatedTestHome)) { Assert-CodexAppWritablePathsProtected -Paths @($overridePath) }
    return (Resolve-Path -LiteralPath $overridePath).Path
  }

  $bundledCli = $null
  if ($IsWindows) {
    try {
      $mainApp = Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction Stop |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -match '\\WindowsApps\\OpenAI\.Codex_' } |
        Sort-Object CreationDate |
        Select-Object -First 1
      if ($mainApp) {
        $candidate = Join-Path (Split-Path -Parent $mainApp.ExecutablePath) "resources\codex.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $bundledCli = (Resolve-Path -LiteralPath $candidate).Path }
      }
    } catch { }
  }

  if (-not $bundledCli -and $IsWindows) {
    foreach ($packageRoot in @(Get-CodexAppPackageInstallLocations)) {
      $candidate = Join-Path $packageRoot "app\resources\codex.exe"
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $bundledCli = (Resolve-Path -LiteralPath $candidate).Path
        break
      }
    }
  }

  if (-not $bundledCli) {
    $bundledCli = Get-Command codex.exe -CommandType Application -All -ErrorAction SilentlyContinue |
      Where-Object { $_.Source -match '\\WindowsApps\\OpenAI\.Codex_' } |
      ForEach-Object { Get-Item -Force -LiteralPath $_.Source } |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First 1 -ExpandProperty FullName
  }
  if (-not $bundledCli) { throw "Could not find the protected Codex App executable under WindowsApps. Open or reinstall Codex App, then retry." }
  Assert-CodexAppWritablePathsProtected -Paths @($bundledCli)
  return $bundledCli
}

function Test-CodexAppBridgeProcessRunning {
  param([Parameter(Mandatory = $true)][string]$BridgePath)

  if (-not $IsWindows) { return $false }
  foreach ($process in Get-Process -Name "codex-provider-bridge" -ErrorAction SilentlyContinue) {
    try {
      if ($process.Path -and [IO.Path]::GetFullPath($process.Path).Equals([IO.Path]::GetFullPath($BridgePath), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    } catch { }
  }
  return $false
}

function Assert-CodexAppBridgeInstallPathsProtected {
  param(
    [Parameter(Mandatory = $true)][string]$BridgeRoot,
    [string[]]$Files = @()
  )

  if (Test-AiIsolatedTestHome) { return }
  $expectedRoot = [IO.Path]::GetFullPath((Join-Path $script:AiHome ".codex\app-bridge")).TrimEnd('\', '/')
  $resolvedRoot = [IO.Path]::GetFullPath($BridgeRoot).TrimEnd('\', '/')
  if (-not $resolvedRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Codex App bridge must be installed at the protected default path: $expectedRoot"
  }
  $codexHome = Split-Path -Parent $resolvedRoot
  Assert-CodexAppWritablePathsProtected -Paths (@($script:AiHome, $codexHome, $resolvedRoot) + @($Files))
}

function Copy-CodexAppBridgeFileAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  $tempPath = "$Destination.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    Copy-Item -LiteralPath $Source -Destination $tempPath
    Move-Item -LiteralPath $tempPath -Destination $Destination -Force
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-CodexAppBundleExecutableNames {
  return @("codex.exe", "codex-command-runner.exe", "codex-code-mode-host.exe", "codex-windows-sandbox-setup.exe")
}

function Send-CodexAppBridgeEnvironmentChanged {
  if (-not $IsWindows) { return }
  try {
    if (-not ("AiEnv.NativeEnvironment" -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AiEnv {
  public static class NativeEnvironment {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
  }
}
'@
    }
    $result = [IntPtr]::Zero
    [void][AiEnv.NativeEnvironment]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, "Environment", 2, 2000, [ref]$result)
  } catch {
    Write-Warning "CODEX_CLI_PATH was saved, but the environment-change broadcast failed: $($_.Exception.Message)"
  }
}

function Install-CodexAppBridge {
  $bridgeRoot = Get-CodexAppBridgeRoot
  $bridgePath = Join-Path $bridgeRoot "codex-provider-bridge.exe"
  $securedRealCliPath = Join-Path $bridgeRoot "codex.exe"
  $settingsPath = Join-Path $bridgeRoot "codex-provider-bridge.json"
  $activationPath = Join-Path $bridgeRoot "activation.json"
  if (Test-CodexAppBridgeProcessRunning -BridgePath $bridgePath) {
    throw "Codex App is using this bridge. Close Codex App before reinstalling the bridge."
  }
  $projectPath = Get-CodexAppBridgeProjectPath
  $trustedSourceCliPath = Resolve-CodexAppRealCliPath
  $target = Get-CodexAppBridgeEnvironmentTarget
  $existingActivation = if (Test-Path -LiteralPath $activationPath -PathType Leaf) {
    Get-Content -LiteralPath $activationPath -Raw | ConvertFrom-Json -Depth 10
  } else { $null }
  if ($existingActivation -and [string]$existingActivation.environmentTarget -cne $target.ToString()) {
    throw "The bridge is activated for $($existingActivation.environmentTarget), not $target. Remove it before changing environment target."
  }
  $stagingPath = Join-Path $bridgeRoot (".staging-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $bridgeRoot | Out-Null
  Assert-CodexAppBridgeInstallPathsProtected -BridgeRoot $bridgeRoot
  New-Item -ItemType Directory -Force -Path $stagingPath | Out-Null
  try {
    & dotnet publish $projectPath -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o $stagingPath --nologo | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }
    $publishedPath = Join-Path $stagingPath "codex-provider-bridge.exe"
    if (-not (Test-Path -LiteralPath $publishedPath -PathType Leaf)) { throw "Bridge publish did not create $publishedPath" }

    $trustedSourceRoot = Split-Path -Parent $trustedSourceCliPath
    $trustedSourcePaths = @((Get-CodexAppBundleExecutableNames) | ForEach-Object { Join-Path $trustedSourceRoot $_ })
    foreach ($sourcePath in $trustedSourcePaths) {
      if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Protected Codex App bundle is missing $(Split-Path -Leaf $sourcePath)." }
    }
    if (-not (Test-AiIsolatedTestHome)) { Assert-CodexAppWritablePathsProtected -Paths (@($trustedSourceRoot) + $trustedSourcePaths) }
    $bundleHashes = [ordered]@{}
    $securedBundlePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($name in (Get-CodexAppBundleExecutableNames)) {
      $sourcePath = Join-Path $trustedSourceRoot $name
      $stagedPath = Join-Path $stagingPath $name
      Copy-Item -LiteralPath $sourcePath -Destination $stagedPath
      $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
      if ((Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash -cne $sourceHash) { throw "Secured copy differs from protected source: $name" }
      $destinationPath = Join-Path $bridgeRoot $name
      Copy-CodexAppBridgeFileAtomic -Source $stagedPath -Destination $destinationPath
      $bundleHashes[$name] = $sourceHash
      $securedBundlePaths.Add($destinationPath)
    }
    Copy-CodexAppBridgeFileAtomic -Source $publishedPath -Destination $bridgePath
    Assert-CodexAppBridgeInstallPathsProtected -BridgeRoot $bridgeRoot -Files (@($securedBundlePaths) + @($bridgePath))

    $settings = [ordered]@{ realCodexPath = $securedRealCliPath; realCodexSha256 = $bundleHashes["codex.exe"]; realCodexPrefixArgs = @(); realCodexBundleSha256 = $bundleHashes }
    Write-AiUtf8NoBomAtomic -Path $settingsPath -Content (($settings | ConvertTo-Json -Depth 5) + "`n")
    Assert-CodexAppBridgeInstallPathsProtected -BridgeRoot $bridgeRoot -Files (@($securedBundlePaths) + @($bridgePath, $settingsPath))

    $activation = if ($existingActivation) { $existingActivation } else {
      $previousValue = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", $target)
      [pscustomobject]@{ schema = 1; hadPrevious = ($null -ne $previousValue); previousValue = $previousValue; environmentTarget = $target.ToString() }
    }
    $activationRecord = [ordered]@{
      schema = 1
      hadPrevious = [bool]$activation.hadPrevious
      previousValue = $activation.previousValue
      environmentTarget = $target.ToString()
      bridgePath = $bridgePath
      installedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    Write-AiUtf8NoBomAtomic -Path $activationPath -Content (($activationRecord | ConvertTo-Json -Depth 5) + "`n")
    Assert-CodexAppBridgeInstallPathsProtected -BridgeRoot $bridgeRoot -Files (@($securedBundlePaths) + @($bridgePath, $settingsPath, $activationPath))
    [Environment]::SetEnvironmentVariable("CODEX_CLI_PATH", $bridgePath, $target)
    $env:CODEX_CLI_PATH = $bridgePath
    if ($target -eq [EnvironmentVariableTarget]::User) { Send-CodexAppBridgeEnvironmentChanged }
  } finally {
    Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Codex App all-provider bridge installed."
  Write-Host "  Bridge: $bridgePath"
  Write-Host "  Real CLI: $securedRealCliPath"
  Write-Host "  Reload: close and reopen Codex App"
}

function Get-CodexAppBridgeStatus {
  $bridgeRoot = Get-CodexAppBridgeRoot
  $bridgePath = Join-Path $bridgeRoot "codex-provider-bridge.exe"
  $securedRealCliPath = Join-Path $bridgeRoot "codex.exe"
  $settingsPath = Join-Path $bridgeRoot "codex-provider-bridge.json"
  $activationPath = Join-Path $bridgeRoot "activation.json"
  $activation = if (Test-Path -LiteralPath $activationPath -PathType Leaf) {
    try { Get-Content -LiteralPath $activationPath -Raw | ConvertFrom-Json -Depth 10 } catch { $null }
  } else { $null }
  $target = Get-CodexAppBridgeEnvironmentTarget -Name $(if ($activation) { [string]$activation.environmentTarget } else { $null })
  $configuredPath = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", $target)
  $isConfigured = $false
  if ($configuredPath) {
    try { $isConfigured = [IO.Path]::GetFullPath($configuredPath).Equals([IO.Path]::GetFullPath($bridgePath), [StringComparison]::OrdinalIgnoreCase) } catch { }
  }
  $isRunning = Test-CodexAppBridgeProcessRunning -BridgePath $bridgePath
  $isCurrentAppCli = $false
  if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    try {
      $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -Depth 10
      $currentSourceCli = Resolve-CodexAppRealCliPath
      $currentSourceRoot = Split-Path -Parent $currentSourceCli
      $configuredRealPath = [IO.Path]::GetFullPath([string]$settings.realCodexPath)
      $isCurrentAppCli = $configuredRealPath.Equals([IO.Path]::GetFullPath($securedRealCliPath), [StringComparison]::OrdinalIgnoreCase)
      foreach ($name in (Get-CodexAppBundleExecutableNames)) {
        $sourcePath = Join-Path $currentSourceRoot $name
        $securedPath = Join-Path $bridgeRoot $name
        $expectedHash = [string](Get-AiProperty -Object $settings.realCodexBundleSha256 -Name $name)
        if (-not $expectedHash -or
            -not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $securedPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -cne $expectedHash -or
            (Get-FileHash -LiteralPath $securedPath -Algorithm SHA256).Hash -cne $expectedHash) {
          $isCurrentAppCli = $false
          break
        }
      }
    } catch { }
  }
  $missingBundleFiles = @((Get-CodexAppBundleExecutableNames) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bridgeRoot $_) -PathType Leaf) })
  return [pscustomobject]@{
    IsInstalled = [bool]((Test-Path -LiteralPath $bridgePath -PathType Leaf) -and (Test-Path -LiteralPath $settingsPath -PathType Leaf) -and $missingBundleFiles.Count -eq 0)
    IsConfigured = $isConfigured
    IsRunning = $isRunning
    IsCurrentAppCli = $isCurrentAppCli
    EnvironmentTarget = $target.ToString()
    ConfiguredPath = $configuredPath
    BridgePath = $bridgePath
  }
}

function Show-CodexAppBridgeStatus {
  $status = Get-CodexAppBridgeStatus
  Write-Host "Codex App all-provider bridge:"
  Write-Host "  Installed: $($status.IsInstalled)"
  Write-Host "  Configured: $($status.IsConfigured) ($($status.EnvironmentTarget))"
  Write-Host "  Running in App: $($status.IsRunning)"
  Write-Host "  App CLI match: $($status.IsCurrentAppCli)"
  Write-Host "  Bridge: $($status.BridgePath)"
  if ($status.IsConfigured -and -not $status.IsRunning) { Write-Host "  Reload required: close and reopen Codex App" }
  if ($status.IsConfigured -and -not $status.IsCurrentAppCli) { Write-Host "  Refresh required: close Codex App, then run cx app-bridge install" }
}

function Remove-CodexAppBridge {
  $bridgeRoot = Get-CodexAppBridgeRoot
  $activationPath = Join-Path $bridgeRoot "activation.json"
  if (-not (Test-Path -LiteralPath $activationPath -PathType Leaf)) {
    Write-Host "Codex App all-provider bridge is already disabled."
    return
  }
  $activation = Get-Content -LiteralPath $activationPath -Raw | ConvertFrom-Json -Depth 10
  $target = Get-CodexAppBridgeEnvironmentTarget -Name ([string]$activation.environmentTarget)
  $hadPrevious = [bool]$activation.hadPrevious
  $previousValue = if ($hadPrevious) { [string]$activation.previousValue } else { $null }
  $configuredValue = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", $target)
  $ownsConfiguredValue = $false
  try {
    $ownsConfiguredValue = [bool]($configuredValue -and [IO.Path]::GetFullPath($configuredValue).Equals([IO.Path]::GetFullPath([string]$activation.bridgePath), [StringComparison]::OrdinalIgnoreCase))
  } catch { }
  if ($ownsConfiguredValue) {
    [Environment]::SetEnvironmentVariable("CODEX_CLI_PATH", $previousValue, $target)
    if ($hadPrevious) { $env:CODEX_CLI_PATH = $previousValue } else { Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue }
    if ($target -eq [EnvironmentVariableTarget]::User) { Send-CodexAppBridgeEnvironmentChanged }
  } else {
    Write-Warning "CODEX_CLI_PATH no longer points to this bridge; leaving the current value unchanged."
  }
  Remove-Item -LiteralPath $activationPath -Force -ErrorAction SilentlyContinue
  Write-Host "Codex App all-provider bridge disabled."
  Write-Host "  Reload: close and reopen Codex App"
}

function Invoke-CodexAppBridgeCommand {
  param([string[]]$Arguments)

  if ($Arguments.Count -eq 0 -or $Arguments[0] -ieq "status") {
    if ($Arguments.Count -gt 1) { throw "Usage: cx app-bridge install|status|remove" }
    Show-CodexAppBridgeStatus
    return
  }
  if ($Arguments.Count -ne 1) { throw "Usage: cx app-bridge install|status|remove" }
  switch ($Arguments[0].ToLowerInvariant()) {
    "install" { Install-CodexAppBridge; return }
    "remove" { Remove-CodexAppBridge; return }
    default { throw "Usage: cx app-bridge install|status|remove" }
  }
}
