function Get-AiProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($property) {
    return $property.Value
  }

  return $Default
}

function Expand-AiPath {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $expanded = [Environment]::ExpandEnvironmentVariables($Path)
  if ($expanded -eq "~") {
    return $script:AiHome
  }

  if ($expanded.StartsWith("~/") -or $expanded.StartsWith("~\")) {
    return (Join-Path $script:AiHome $expanded.Substring(2))
  }

  return $expanded
}

function New-AiDefaultRegistry {
  return [pscustomobject]@{
    schema = 1
    defaults = [pscustomobject]@{
      codex = "sub"
      codex_app = "sub"
      claude = "sub"
    }
    codex = @(
      [pscustomobject]@{
        name = "sub"
        aliases = @("subscription", "chatgpt")
        mode = "sub"
        home = "~/.codex"
        codex_profile = "sub"
        description = "ChatGPT/Codex subscription login cached under CODEX_HOME"
      },
      [pscustomobject]@{
        name = "api"
        aliases = @("router")
        mode = "api"
        home = "~/.codex"
        codex_profile = "api"
        secret_id = "codex.api"
        windows_secret = "~/.ai-secrets/codex-api.ps1"
        linux_secret = "~/.ai-secrets/codex-api.env"
        description = "Default Codex API router"
      }
    )
    claude = @(
      [pscustomobject]@{
        name = "sub"
        aliases = @("subscription", "claude-sub")
        mode = "sub"
        description = "Claude Code subscription/OAuth login"
      },
      [pscustomobject]@{
        name = "api"
        aliases = @("router", "claude-api")
        mode = "api"
        base_url = "https://claude.example.com"
        secret_id = "claude.api"
        windows_secret = "~/.ai-secrets/claude-api.ps1"
        linux_secret = "~/.ai-secrets/claude-api.env"
        description = "Default Claude Code API router"
      }
    )
  }
}

function Get-AiRegistry {
  if (Test-Path -LiteralPath $script:AiRegistryPath) {
    try {
      return (Get-Content -Raw -LiteralPath $script:AiRegistryPath | ConvertFrom-Json)
    } catch {
      Write-Warning "Could not read $script:AiRegistryPath. $($_.Exception.Message)"
    }
  }

  return (New-AiDefaultRegistry)
}

function Get-AiToolProfiles {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  $registry = Get-AiRegistry
  return @(Get-AiProperty -Object $registry -Name $Tool -Default @())
}

function Get-AiDefaultProfileName {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  $registry = Get-AiRegistry
  $defaults = Get-AiProperty -Object $registry -Name "defaults"
  $default = Get-AiProperty -Object $defaults -Name $Tool -Default "sub"
  if ($default) {
    return [string]$default
  }

  return "sub"
}

function Test-AiProfileEnabled {
  param([Parameter(Mandatory = $true)]$Profile)

  $enabled = Get-AiProperty -Object $Profile -Name "enabled" -Default $true
  return ($enabled -ne $false)
}

function Get-AiProfileNames {
  param([Parameter(Mandatory = $true)]$Profile)

  $names = @([string](Get-AiProperty -Object $Profile -Name "name" -Default ""))
  $aliases = @(Get-AiProperty -Object $Profile -Name "aliases" -Default @())
  foreach ($alias in $aliases) {
    if ($alias) {
      $names += [string]$alias
    }
  }

  return ($names | Where-Object { $_ })
}

function Get-AiProfileByName {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $query = $Name.ToLowerInvariant()
  foreach ($profile in Get-AiToolProfiles -Tool $Tool) {
    if (-not (Test-AiProfileEnabled -Profile $profile)) {
      continue
    }

    foreach ($candidate in Get-AiProfileNames -Profile $profile) {
      if ($candidate.ToLowerInvariant() -eq $query) {
        return $profile
      }
    }
  }

  return $null
}

function Get-AiProfileName {
  param([Parameter(Mandatory = $true)]$Profile)

  return [string](Get-AiProperty -Object $Profile -Name "name" -Default "")
}

function Get-AiProfileMode {
  param([Parameter(Mandatory = $true)]$Profile)

  return [string](Get-AiProperty -Object $Profile -Name "mode" -Default "sub")
}

function Get-AiNextProfileName {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  $profiles = @(Get-AiToolProfiles -Tool $Tool | Where-Object { Test-AiProfileEnabled -Profile $_ })
  if ($profiles.Count -eq 0) {
    return "sub"
  }

  $saved = Get-AiSavedProfileName -Tool $Tool
  for ($i = 0; $i -lt $profiles.Count; $i++) {
    if ((Get-AiProfileName -Profile $profiles[$i]).ToLowerInvariant() -eq $saved.ToLowerInvariant()) {
      return (Get-AiProfileName -Profile $profiles[($i + 1) % $profiles.Count])
    }
  }

  return (Get-AiDefaultProfileName -Tool $Tool)
}

function Get-AiLegacyStateName {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  $legacyName = if ($Tool -eq "codex") { "cx.profile" } else { "cc.profile" }
  $legacyPath = Join-Path $script:LegacyAiStateDir $legacyName
  if (Test-Path -LiteralPath $legacyPath) {
    $value = (Get-Content -Raw -LiteralPath $legacyPath).Trim()
    if ($value) {
      return $value
    }
  }

  return $null
}

function Get-AiState {
  $state = [pscustomobject]@{
    codex = $null
    claude = $null
    updated_at = $null
  }

  if (Test-Path -LiteralPath $script:AiStatePath) {
    try {
      $loaded = Get-Content -Raw -LiteralPath $script:AiStatePath | ConvertFrom-Json
      foreach ($name in @("codex", "claude", "updated_at")) {
        $value = Get-AiProperty -Object $loaded -Name $name
        if ($null -ne $value) {
          $state.$name = $value
        }
      }
    } catch {
      Write-Warning "Could not read $script:AiStatePath. $($_.Exception.Message)"
    }
  }

  if (-not $state.codex) {
    $state.codex = Get-AiLegacyStateName -Tool "codex"
  }
  if (-not $state.claude) {
    $state.claude = Get-AiLegacyStateName -Tool "claude"
  }
  if (-not $state.codex) {
    $state.codex = Get-AiDefaultProfileName -Tool "codex"
  }
  if (-not $state.claude) {
    $state.claude = Get-AiDefaultProfileName -Tool "claude"
  }

  return $state
}

function Save-AiSelectedProfile {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $state = Get-AiState
  $state.$Tool = $Name
  $state.updated_at = (Get-Date).ToUniversalTime().ToString("o")
  New-Item -ItemType Directory -Force -Path $script:AiConfigDir | Out-Null
  $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:AiStatePath -Encoding UTF8
}

function Save-AiRegistry {
  param([Parameter(Mandatory = $true)]$Registry)

  New-Item -ItemType Directory -Force -Path $script:AiConfigDir | Out-Null
  $json = (($Registry | ConvertTo-Json -Depth 20) + "`n")
  Write-AiUtf8NoBomAtomic -Path $script:AiRegistryPath -Content $json
}

function Get-AiNameSlug {
  param([Parameter(Mandatory = $true)][string]$Name)

  $slug = $Name.Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '-'
  $slug = $slug.Trim("-_")
  if (-not $slug) {
    throw "Profile name '$Name' does not contain any usable letters or numbers."
  }

  return $slug
}

function Assert-AiProfileName {
  param([Parameter(Mandatory = $true)][string]$Name)

  if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9:_-]*$') {
    throw "Profile name '$Name' is not supported. Use letters, numbers, ':', '_' or '-'."
  }
}

function Test-AiProfileNameExists {
  param(
    [Parameter(Mandatory = $true)]$Registry,
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $query = $Name.ToLowerInvariant()
  foreach ($profile in @(Get-AiProperty -Object $Registry -Name $Tool -Default @())) {
    foreach ($candidate in Get-AiProfileNames -Profile $profile) {
      if ($candidate.ToLowerInvariant() -eq $query) {
        return $true
      }
    }
  }

  return $false
}

function Add-AiProfileRegistration {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile
  )

  $name = Get-AiProfileName -Profile $Profile
  Assert-AiProfileName -Name $name
  $registry = Get-AiRegistry
  if (Test-AiProfileNameExists -Registry $registry -Tool $Tool -Name $name) {
    throw "$Tool profile '$name' already exists. Remove it first, or choose another name."
  }

  $profiles = @(Get-AiProperty -Object $registry -Name $Tool -Default @())
  $registry.$Tool = @($profiles + $Profile)
  Save-AiRegistry -Registry $registry
  return $Profile
}

function Remove-AiProfileRegistration {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $registry = Get-AiRegistry
  $query = $Name.ToLowerInvariant()
  $removed = $null
  $kept = @()
  foreach ($profile in @(Get-AiProperty -Object $registry -Name $Tool -Default @())) {
    $matches = $false
    foreach ($candidate in Get-AiProfileNames -Profile $profile) {
      if ($candidate.ToLowerInvariant() -eq $query) {
        $matches = $true
        break
      }
    }

    if ($matches) {
      $removed = $profile
    } else {
      $kept += $profile
    }
  }

  if (-not $removed) {
    throw "$Tool profile '$Name' does not exist."
  }

  $removedName = Get-AiProfileName -Profile $removed
  $registry.$Tool = @($kept)
  Save-AiRegistry -Registry $registry

  if ((Get-AiSavedProfileName -Tool $Tool).ToLowerInvariant() -eq $removedName.ToLowerInvariant()) {
    Save-AiSelectedProfile -Tool $Tool -Name (Get-AiDefaultProfileName -Tool $Tool)
  }

  return $removedName
}

function ConvertFrom-AiManagementArgs {
  param([string[]]$Arguments)

  $options = @{}
  $positionals = @()
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $arg = [string]$Arguments[$i]
    if ($arg.StartsWith("--")) {
      $key = $arg.Substring(2)
      if (-not $key) {
        continue
      }
      if (($i + 1) -lt $Arguments.Count -and -not ([string]$Arguments[$i + 1]).StartsWith("--")) {
        $options[$key] = [string]$Arguments[$i + 1]
        $i++
      } else {
        $options[$key] = "true"
      }
    } else {
      $positionals += $arg
    }
  }

  return [pscustomobject]@{
    Positionals = $positionals
    Options = $options
  }
}

function Get-AiOption {
  param(
    [Parameter(Mandatory = $true)]$Options,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][string]$Default = $null
  )

  if ($Options.ContainsKey($Name) -and $Options[$Name]) {
    return [string]$Options[$Name]
  }

  return $Default
}

function Get-AiSavedProfileName {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  $state = Get-AiState
  $saved = [string](Get-AiProperty -Object $state -Name $Tool -Default "")
  if ($saved) {
    return $saved
  }

  return (Get-AiDefaultProfileName -Tool $Tool)
}

function Get-AiSecretPath {
  param([Parameter(Mandatory = $true)]$Profile)

  $path = Get-AiProperty -Object $Profile -Name "windows_secret"
  if (-not $path) {
    $path = Get-AiProperty -Object $Profile -Name "secret"
  }

  return (Expand-AiPath $path)
}

function Get-AiSecretId {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile
  )

  $secretId = Get-AiProperty -Object $Profile -Name "secret_id"
  if ($secretId) {
    return [string]$secretId
  }

  return "$Tool.$(Get-AiProfileName -Profile $Profile)"
}

function Format-AiSecretPreview {
  param([AllowNull()][string]$Value)

  if (-not $Value) {
    return "<unset>"
  }

  if ($Value.Length -le 12) {
    return ($Value.Substring(0, [Math]::Min(4, $Value.Length)) + "...")
  }

  return ($Value.Substring(0, [Math]::Min(8, $Value.Length)) + "..." + $Value.Substring($Value.Length - 4))
}

function ConvertFrom-AiTomlValue {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $trimmed = $Value.Trim()
  if ($trimmed -match '^"((?:\\.|[^"])*)"') {
    try {
      return ($Matches[0] | ConvertFrom-Json)
    } catch {
      return $Matches[1]
    }
  }
  if ($trimmed -match "^'([^']*)'") {
    return $Matches[1]
  }
  if ($trimmed -match '^(true|false)\b') {
    return $Matches[1].ToLowerInvariant()
  }

  return (($trimmed -split '\s+#', 2)[0]).Trim()
}

function Get-AiTomlSecretSection {
  param([Parameter(Mandatory = $true)][string]$SecretId)

  $values = @{}
  if (-not (Test-Path -LiteralPath $script:AiSecretsPath)) {
    return $values
  }

  $current = ""
  foreach ($line in Get-Content -LiteralPath $script:AiSecretsPath) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#")) {
      continue
    }
    if ($trimmed -match '^\[([^\]]+)\]\s*$') {
      $current = $Matches[1].Trim()
      continue
    }
    if ($current -ne $SecretId) {
      continue
    }
    if ($trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') {
      $values[$Matches[1]] = ConvertFrom-AiTomlValue $Matches[2]
    }
  }

  return $values
}

function Test-AiTomlSecretValues {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  $section = Get-AiTomlSecretSection -SecretId (Get-AiSecretId -Tool $Tool -Profile $Profile)
  foreach ($name in $Names) {
    if ($section.ContainsKey($name) -and $section[$name]) {
      return $true
    }
  }

  return $false
}

function Set-AiEnvironmentFromTomlSecret {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  $secretId = Get-AiSecretId -Tool $Tool -Profile $Profile
  $section = Get-AiTomlSecretSection -SecretId $secretId
  $loaded = $false
  foreach ($name in $Names) {
    if ($section.ContainsKey($name) -and $section[$name]) {
      Set-Item -Path "Env:$name" -Value ([string]$section[$name])
      $loaded = $true
    }
  }

  if ($loaded) {
    return "$script:AiSecretsPath#$secretId"
  }

  return $null
}

function Get-AiSecretDisplay {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  if (Test-AiTomlSecretValues -Tool $Tool -Profile $Profile -Names $Names) {
    return "$script:AiSecretsPath#$(Get-AiSecretId -Tool $Tool -Profile $Profile)"
  }

  $legacy = Get-AiSecretPath -Profile $Profile
  if ($legacy) {
    if (Test-Path -LiteralPath $legacy) {
      return $legacy
    }
    return "<missing> $legacy"
  }

  return "<missing> $script:AiSecretsPath#$(Get-AiSecretId -Tool $Tool -Profile $Profile)"
}

function Get-TomlStringValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $pattern = "^\s*" + [regex]::Escape($Key) + "\s*=\s*(.+)$"
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match $pattern) {
      return [string](ConvertFrom-AiTomlValue $Matches[1])
    }
  }

  return $null
}

function Get-AiTomlTopLevelStringValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $pattern = "^\s*" + [regex]::Escape($Key) + "\s*=\s*(.+)$"
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line.Trim() -match '^\[') { break }
    if ($line -match $pattern) { return [string](ConvertFrom-AiTomlValue $Matches[1]) }
  }
  return $null
}

function Get-AiTomlSectionStringValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Section,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $currentSection = ""
  $pattern = "^\s*" + [regex]::Escape($Key) + "\s*=\s*(.+)$"
  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\[\[') {
      $currentSection = ""
      continue
    }
    if ($trimmed -match '^\[([^\[\]]+)\]\s*(?:#.*)?$') {
      $currentSection = $Matches[1].Trim()
      continue
    }
    if ($currentSection -eq $Section -and $line -match $pattern) {
      return [string](ConvertFrom-AiTomlValue $Matches[1])
    }
  }
  return $null
}

function Get-PowerShellEnvAssignment {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $pattern = "^\s*\`$env:" + [regex]::Escape($Name) + "\s*=\s*['`"]([^'`"]+)['`"]"
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match $pattern) {
      return $Matches[1]
    }
  }

  return $null
}

function Split-AiEnvArguments {
  param([string[]]$Arguments)

  $envMap = [ordered]@{}
  $rest = @()
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $arg = [string]$Arguments[$i]
    if (($arg -eq "--env" -or $arg -eq "--set-env") -and ($i + 1) -lt $Arguments.Count) {
      $pair = [string]$Arguments[$i + 1]
      $i++
      $idx = $pair.IndexOf("=")
      if ($idx -lt 1) {
        throw "Invalid --env value '$pair'. Expected KEY=VALUE."
      }
      $envMap[$pair.Substring(0, $idx)] = $pair.Substring($idx + 1)
    } else {
      $rest += $arg
    }
  }

  return [pscustomobject]@{ Env = $envMap; Rest = @($rest) }
}

function Test-AiInteractive {
  if ($env:AI_ENV_NONINTERACTIVE) {
    return $false
  }
  try {
    if ([Console]::IsInputRedirected) {
      return $false
    }
  } catch {
    return $false
  }
  return $true
}

function Read-AiInput {
  param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$Default = ""
  )

  $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
  $answer = Read-Host -Prompt $label
  if ([string]::IsNullOrWhiteSpace($answer)) {
    return $Default
  }
  return $answer.Trim()
}

function Read-AiSecretInput {
  param([Parameter(Mandatory = $true)][string]$Prompt)

  $secure = Read-Host -Prompt $Prompt -AsSecureString
  if (-not $secure -or $secure.Length -eq 0) {
    return ""
  }
  $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  } finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
  }
}

function Add-AiTomlSecretValue {
  param(
    [Parameter(Mandatory = $true)][string]$SecretId,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Value
  )

  $sectionExists = $false
  if (Test-Path -LiteralPath $script:AiSecretsPath) {
    foreach ($line in Get-Content -LiteralPath $script:AiSecretsPath) {
      if ($line.Trim() -eq "[$SecretId]") {
        $sectionExists = $true
        break
      }
    }
  }
  if ($sectionExists) {
    return $false
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:AiSecretsPath) | Out-Null
  $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
  $block = @()
  if (Test-Path -LiteralPath $script:AiSecretsPath) {
    $block += ""
  }
  $block += "[$SecretId]"
  $block += "$Key = `"$escaped`""
  Add-Content -LiteralPath $script:AiSecretsPath -Value (($block -join "`n") + "`n") -Encoding UTF8
  return $true
}

function Resolve-AiSecretScaffold {
  param(
    [Parameter(Mandatory = $true)][string]$SecretId,
    [Parameter(Mandatory = $true)][string]$Key,
    [bool]$Interactive = $false
  )

  $existing = Get-AiTomlSecretSection -SecretId $SecretId
  if ($existing.ContainsKey($Key) -and $existing[$Key]) {
    return "$script:AiSecretsPath [$SecretId] $Key (already set)"
  }

  if ($Interactive) {
    $value = Read-AiSecretInput -Prompt "Enter $Key for [$SecretId] (blank to skip)"
    if ($value) {
      if (Add-AiTomlSecretValue -SecretId $SecretId -Key $Key -Value $value) {
        return "wrote $script:AiSecretsPath [$SecretId] $Key"
      }
      return "$script:AiSecretsPath [$SecretId] already present; left unchanged"
    }
  }

  return "add $Key to $script:AiSecretsPath [$SecretId]"
}

function New-CodexProfileConfig {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [AllowNull()][string]$BaseUrl,
    [AllowNull()][string]$Model,
    [AllowNull()][string]$EnvKey,
    [AllowNull()][string]$ProviderName
  )

  $mode = Get-AiProfileMode -Profile $Profile
  $profilePath = Get-CodexProfilePath -Profile $Profile
  if (Test-Path -LiteralPath $profilePath) {
    return $profilePath
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $profilePath) | Out-Null
  $providerId = "api-router"
  $displayName = if ($ProviderName) { $ProviderName } else { (Get-AiProfileName -Profile $Profile).Replace(":", " ") }
  $keyName = if ($EnvKey) { $EnvKey } else { "OPENAI_API_KEY" }

  if ($mode -eq "api") {
    $url = if ($BaseUrl) { $BaseUrl } else { "https://your-router.example/v1" }
    $lines = @("model_provider = `"$providerId`"")
    if ($Model) {
      $lines += "model = `"$Model`""
    }
    $lines += @(
      "disable_response_storage = true"
      ""
      "[model_providers.$providerId]"
      "name = `"$displayName`""
      "base_url = `"$url`""
      "env_key = `"$keyName`""
    )
    (($lines -join "`n") + "`n") | Set-Content -LiteralPath $profilePath -Encoding UTF8
  } else {
    $lines = @("model_provider = `"openai`"")
    if ($Model) {
      $lines += "model = `"$Model`""
    }
    (($lines -join "`n") + "`n") | Set-Content -LiteralPath $profilePath -Encoding UTF8
  }

  return $profilePath
}

function Add-CodexApiProfile {
  param([string[]]$Arguments)

  $split = Split-AiEnvArguments -Arguments $Arguments
  $parsed = ConvertFrom-AiManagementArgs -Arguments $split.Rest
  if ($parsed.Positionals.Count -lt 1) {
    throw "Usage: cx add-api <name> [--base-url URL] [--env-key NAME] [--provider-name NAME] [--model MODEL] [--home PATH] [--env KEY=VALUE ...]"
  }

  $name = [string]$parsed.Positionals[0]
  Assert-AiProfileName -Name $name
  $slug = Get-AiNameSlug -Name $name
  $interactive = Test-AiInteractive
  $profileHome = Get-AiOption -Options $parsed.Options -Name "home" -Default "~/.codex"
  $runtimeProfile = Get-AiOption -Options $parsed.Options -Name "profile" -Default "api-$($slug.Replace(':', '-'))"
  $secretId = Get-AiOption -Options $parsed.Options -Name "secret-id" -Default "codex.$name"
  $model = Get-AiOption -Options $parsed.Options -Name "model"

  $baseUrl = Get-AiOption -Options $parsed.Options -Name "base-url"
  if (-not $baseUrl) {
    $baseUrl = if ($interactive) { Read-AiInput -Prompt "Codex base_url" -Default "https://your-router.example/v1" } else { "https://your-router.example/v1" }
  }
  $envKey = Get-AiOption -Options $parsed.Options -Name "env-key"
  if (-not $envKey) {
    $envKey = if ($interactive) { Read-AiInput -Prompt "Codex env_key (secret variable name)" -Default "OPENAI_API_KEY" } else { "OPENAI_API_KEY" }
  }
  $providerName = Get-AiOption -Options $parsed.Options -Name "provider-name"
  if (-not $providerName) {
    $providerName = if ($interactive) { Read-AiInput -Prompt "Codex provider display name" -Default $name } else { $name }
  }

  $profile = [pscustomobject]@{
    name = $name
    aliases = @()
    mode = "api"
    home = $profileHome
    codex_profile = $runtimeProfile
    secret_id = $secretId
    windows_secret = "~/.ai-secrets/codex-$slug.ps1"
    linux_secret = "~/.ai-secrets/codex-$slug.env"
    description = "Codex API profile"
  }
  if ($split.Env.Count -gt 0) {
    $profile | Add-Member -NotePropertyName "env" -NotePropertyValue ([pscustomobject]$split.Env)
  }
  Add-AiProfileRegistration -Tool "codex" -Profile $profile | Out-Null
  $profilePath = New-CodexProfileConfig -Profile $profile -BaseUrl $baseUrl -Model $model -EnvKey $envKey -ProviderName $providerName
  $secretState = Resolve-AiSecretScaffold -SecretId $secretId -Key $envKey -Interactive $interactive

  Write-Host "Added Codex API profile '$name'."
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  CODEX_HOME: $(Expand-AiPath $profileHome)"
  Write-Host "  Config: $profilePath"
  Write-Host "  Secret: $secretState"
  if ($split.Env.Count -gt 0) {
    Write-Host "  Env: $(@($split.Env.Keys) -join ', ')"
  }
}

function Add-CodexSubProfile {
  param([string[]]$Arguments)

  $parsed = ConvertFrom-AiManagementArgs -Arguments $Arguments
  if ($parsed.Positionals.Count -lt 1) {
    throw "Usage: cx add-sub <name> [--home PATH] [--model MODEL]"
  }

  $name = [string]$parsed.Positionals[0]
  Assert-AiProfileName -Name $name
  $slug = Get-AiNameSlug -Name $name
  $interactive = Test-AiInteractive
  $profileHome = Get-AiOption -Options $parsed.Options -Name "home"
  if (-not $profileHome) {
    $profileHome = if ($interactive) { Read-AiInput -Prompt "Codex CODEX_HOME for this subscription" -Default "~/.codex-$slug" } else { "~/.codex-$slug" }
  }
  $runtimeProfile = Get-AiOption -Options $parsed.Options -Name "profile" -Default "sub"
  $model = Get-AiOption -Options $parsed.Options -Name "model"

  $profile = [pscustomobject]@{
    name = $name
    aliases = @()
    mode = "sub"
    home = $profileHome
    codex_profile = $runtimeProfile
    description = "Codex subscription profile"
  }
  Add-AiProfileRegistration -Tool "codex" -Profile $profile | Out-Null
  $profilePath = New-CodexProfileConfig -Profile $profile -Model $model
  Write-Host "Added Codex subscription profile '$name'."
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  CODEX_HOME: $(Expand-AiPath $profileHome)"
  Write-Host "  Config: $profilePath"
  Write-Host "  Login: CODEX_HOME=`"$(Expand-AiPath $profileHome)`" codex login"
}

function Remove-CodexProfile {
  param([string[]]$Arguments)

  $parsed = ConvertFrom-AiManagementArgs -Arguments $Arguments
  if ($parsed.Positionals.Count -lt 1) {
    throw "Usage: cx remove <name> [--delete-config]"
  }

  $existing = Get-AiProfileByName -Tool "codex" -Name ([string]$parsed.Positionals[0])
  if (-not $existing) {
    throw "codex profile '$($parsed.Positionals[0])' does not exist."
  }
  $existingName = Get-AiProfileName -Profile $existing
  if ((Get-CodexAppDefaultProfileName) -eq $existingName) {
    throw "Cannot remove Codex profile '$existingName' while it is the Codex App default. Run 'cx app-default sub' first."
  }
  $profilePath = Get-CodexProfilePath -Profile $existing
  $removed = Remove-AiProfileRegistration -Tool "codex" -Name ([string]$parsed.Positionals[0])
  if ((Get-AiOption -Options $parsed.Options -Name "delete-config") -eq "true") {
    Remove-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
  }

  Write-Host "Removed Codex profile '$removed'."
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  Config: $(if (Test-Path -LiteralPath $profilePath) { $profilePath } else { '<removed or absent>' })"
}

function Add-ClaudeApiProfile {
  param([string[]]$Arguments)

  $split = Split-AiEnvArguments -Arguments $Arguments
  $parsed = ConvertFrom-AiManagementArgs -Arguments $split.Rest
  if ($parsed.Positionals.Count -lt 1) {
    throw "Usage: cc add-api <name> [--base-url URL] [--env-key NAME] [--env KEY=VALUE ...]"
  }

  $name = [string]$parsed.Positionals[0]
  Assert-AiProfileName -Name $name
  $slug = Get-AiNameSlug -Name $name
  $interactive = Test-AiInteractive
  $secretId = Get-AiOption -Options $parsed.Options -Name "secret-id" -Default "claude.$name"

  $baseUrl = Get-AiOption -Options $parsed.Options -Name "base-url"
  if (-not $baseUrl) {
    $baseUrl = if ($interactive) { Read-AiInput -Prompt "Claude base_url" -Default $script:ClaudeRouterBaseUrl } else { $script:ClaudeRouterBaseUrl }
  }
  $envKey = Get-AiOption -Options $parsed.Options -Name "env-key"
  if (-not $envKey) {
    $envKey = if ($interactive) { Read-AiInput -Prompt "Claude secret variable (ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY)" -Default "ANTHROPIC_AUTH_TOKEN" } else { "ANTHROPIC_AUTH_TOKEN" }
  }

  $profile = [pscustomobject]@{
    name = $name
    aliases = @()
    mode = "api"
    base_url = $baseUrl
    secret_id = $secretId
    windows_secret = "~/.ai-secrets/claude-$slug.ps1"
    linux_secret = "~/.ai-secrets/claude-$slug.env"
    description = "Claude Code API profile"
  }
  if ($split.Env.Count -gt 0) {
    $profile | Add-Member -NotePropertyName "env" -NotePropertyValue ([pscustomobject]$split.Env)
  }
  Add-AiProfileRegistration -Tool "claude" -Profile $profile | Out-Null
  $secretState = Resolve-AiSecretScaffold -SecretId $secretId -Key $envKey -Interactive $interactive

  Write-Host "Added Claude Code API profile '$name'."
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  Base URL: $baseUrl"
  Write-Host "  Secret: $secretState"
  if ($split.Env.Count -gt 0) {
    Write-Host "  Env: $(@($split.Env.Keys) -join ', ')"
  }
}

function Add-ClaudeSubProfile {
  param([string[]]$Arguments)

  $parsed = ConvertFrom-AiManagementArgs -Arguments $Arguments
  if ($parsed.Positionals.Count -lt 1) {
    throw "Usage: cc add-sub <name>"
  }

  $name = [string]$parsed.Positionals[0]
  Assert-AiProfileName -Name $name
  $profile = [pscustomobject]@{
    name = $name
    aliases = @()
    mode = "sub"
    description = "Claude Code subscription profile"
  }
  Add-AiProfileRegistration -Tool "claude" -Profile $profile | Out-Null
  Write-Host "Added Claude Code subscription profile '$name'."
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  Login: claude /login"
}

function Remove-ClaudeProfile {
  param([string[]]$Arguments)

  $parsed = ConvertFrom-AiManagementArgs -Arguments $Arguments
  if ($parsed.Positionals.Count -lt 1) {
    throw "Usage: cc remove <name>"
  }

  $removed = Remove-AiProfileRegistration -Tool "claude" -Name ([string]$parsed.Positionals[0])
  Write-Host "Removed Claude Code profile '$removed'."
  Write-Host "  Registry: $script:AiRegistryPath"
}

function Set-AiProfileProbeModel {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [string[]]$Arguments
  )

  $parsed = ConvertFrom-AiManagementArgs -Arguments $Arguments
  if ($parsed.Positionals.Count -lt 1) {
    throw "Usage: probe-model <name> [model]  (omit model to clear -> automatic probe model)"
  }
  $query = ([string]$parsed.Positionals[0]).ToLowerInvariant()
  $model = if ($parsed.Positionals.Count -ge 2) { [string]$parsed.Positionals[1] } else { "" }

  $registry = Get-AiRegistry
  $found = $false
  foreach ($profile in @(Get-AiProperty -Object $registry -Name $Tool -Default @())) {
    $matched = $false
    foreach ($cand in Get-AiProfileNames -Profile $profile) {
      if ($cand.ToLowerInvariant() -eq $query) { $matched = $true; break }
    }
    if (-not $matched) { continue }
    $found = $true
    $pname = Get-AiProfileName -Profile $profile
    if ($model) {
      if ($profile.PSObject.Properties.Name -contains 'probe_model') {
        $profile.probe_model = $model
      } else {
        $profile | Add-Member -NotePropertyName probe_model -NotePropertyValue $model
      }
      Write-Host "Set $Tool '$pname' probe_model = $model"
    } else {
      if ($profile.PSObject.Properties.Name -contains 'probe_model') {
        $profile.PSObject.Properties.Remove('probe_model')
        Write-Host "Cleared $Tool '$pname' probe_model (using automatic probe model)"
      } else {
        Write-Host "$Tool '$pname' has no probe_model set (already automatic)"
      }
    }
    break
  }
  if (-not $found) { throw "$Tool profile '$($parsed.Positionals[0])' not found." }
  Save-AiRegistry -Registry $registry
}

function Set-AiDefaultProfile {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [string[]]$Arguments
  )

  $parsed = ConvertFrom-AiManagementArgs -Arguments $Arguments
  $current = Get-AiDefaultProfileName -Tool $Tool
  if ($parsed.Positionals.Count -lt 1) {
    Write-Host "$Tool default = $current"
    return
  }
  $name = [string]$parsed.Positionals[0]
  if (-not (Get-AiProfileByName -Tool $Tool -Name $name)) {
    throw "Unknown $Tool profile '$name'."
  }
  $registry = Get-AiRegistry
  $defaults = Get-AiProperty -Object $registry -Name "defaults"
  if (-not $defaults) {
    $defaults = [pscustomobject]@{}
    $registry | Add-Member -NotePropertyName defaults -NotePropertyValue $defaults
  }
  if ($defaults.PSObject.Properties.Name -contains $Tool) {
    $defaults.$Tool = $name
  } else {
    $defaults | Add-Member -NotePropertyName $Tool -NotePropertyValue $name
  }
  Save-AiRegistry -Registry $registry
  Write-Host "Set $Tool default = $name"
}

function Write-AiUtf8NoBomAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
  )

  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $tempPath = Join-Path $directory ((Split-Path -Leaf $Path) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    [IO.File]::WriteAllText($tempPath, $Content, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}

function Edit-AiRegistry {
  $path = $script:AiRegistryPath
  if (-not (Test-Path -LiteralPath $path)) {
    Write-Host "Registry not found: $path"
    return
  }
  $editor = if ($env:EDITOR) { $env:EDITOR } elseif ($env:VISUAL) { $env:VISUAL } elseif ($IsWindows) { 'notepad' } else { 'vi' }
  $parts = @($editor -split '\s+' | Where-Object { $_ -and $_ -notin @('--wait', '-w') })
  if ($parts.Count -eq 0) { $parts = @('notepad') }
  $rest = @(); if ($parts.Count -gt 1) { $rest = @($parts[1..($parts.Count - 1)]) }; $rest += $path
  Write-Host "Opening $path with $($parts[0]) ..."
  & $parts[0] @rest
}
