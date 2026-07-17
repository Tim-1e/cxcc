function Get-CodexHome {
  param([Parameter(Mandatory = $true)]$Profile)

  return (Expand-AiPath (Get-AiProperty -Object $Profile -Name "home" -Default "~/.codex"))
}

function Get-CodexRuntimeProfileName {
  param([Parameter(Mandatory = $true)]$Profile)

  $runtimeProfile = Get-AiProperty -Object $Profile -Name "codex_profile"
  if (-not $runtimeProfile) {
    $runtimeProfile = Get-AiProperty -Object $Profile -Name "profile"
  }
  if (-not $runtimeProfile) {
    $runtimeProfile = (Get-AiProfileName -Profile $Profile).Replace(":", "-")
  }

  return [string]$runtimeProfile
}

function Get-CodexProfilePath {
  param([Parameter(Mandatory = $true)]$Profile)

  return (Join-Path (Get-CodexHome -Profile $Profile) "$(Get-CodexRuntimeProfileName -Profile $Profile).config.toml")
}

function Get-CodexExternalCommand {
  $cmd = Get-Command codex -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    throw "Could not find the real codex executable/script in PATH."
  }

  return $cmd.Source
}

function Get-CodexCurrentProfile {
  $saved = Get-AiSavedProfileName -Tool "codex"
  $profile = Get-AiProfileByName -Tool "codex" -Name ($env:AI_CODEX_LABEL ?? $saved)
  if (-not $profile) {
    $profile = Get-AiProfileByName -Tool "codex" -Name (Get-AiDefaultProfileName -Tool "codex")
  }
  if (-not $profile) { throw "No Codex profile is available." }
  return $profile
}

function New-CodexProcessStartInfo {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$Command
  )

  if (-not $Command) { $Command = Get-CodexExternalCommand }
  $extension = [IO.Path]::GetExtension($Command).ToLowerInvariant()
  $startInfo = if ($extension -eq ".ps1") {
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID -ErrorAction Stop).Path)
    foreach ($argument in @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $Command)) { [void]$info.ArgumentList.Add($argument) }
    $info
  } elseif ($extension -in @(".cmd", ".bat")) {
    $info = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    foreach ($argument in @("/d", "/s", "/c", $Command)) { [void]$info.ArgumentList.Add($argument) }
    $info
  } else {
    [Diagnostics.ProcessStartInfo]::new($Command)
  }
  foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  return $startInfo
}

function Get-CodexAppServerExternalCommand {
  if ($env:AI_CODEX_APP_SERVER_CLI) {
    $path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:AI_CODEX_APP_SERVER_CLI))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "AI_CODEX_APP_SERVER_CLI does not exist: $path" }
    return (Resolve-Path -LiteralPath $path).Path
  }
  if ($IsWindows -and (Get-Command Get-CodexAppBridgeRoot -CommandType Function -ErrorAction SilentlyContinue)) {
    try {
      $bridgeRoot = Get-CodexAppBridgeRoot
      $settingsPath = Join-Path $bridgeRoot "codex-provider-bridge.json"
      $securedCliPath = Join-Path $bridgeRoot "codex.exe"
      if ((Test-Path -LiteralPath $settingsPath -PathType Leaf) -and (Test-Path -LiteralPath $securedCliPath -PathType Leaf)) {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -Depth 10
        $configuredPath = [IO.Path]::GetFullPath([string]$settings.realCodexPath)
        if ($configuredPath.Equals([IO.Path]::GetFullPath($securedCliPath), [StringComparison]::OrdinalIgnoreCase) -and
            (Get-FileHash -LiteralPath $securedCliPath -Algorithm SHA256).Hash -ceq [string]$settings.realCodexSha256) {
          return $securedCliPath
        }
      }
    } catch { }
  }
  return (Get-CodexExternalCommand)
}

function Write-CodexAppServerMessage {
  param(
    [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)]$Message
  )

  $Process.StandardInput.WriteLine(($Message | ConvertTo-Json -Depth 30 -Compress))
  $Process.StandardInput.Flush()
}

function Read-CodexAppServerResponse {
  param(
    [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][string]$RequestId,
    [int]$TimeoutSeconds = 15
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $remaining = $deadline - [DateTime]::UtcNow
    try {
      $line = $Process.StandardOutput.ReadLineAsync().WaitAsync($remaining).GetAwaiter().GetResult()
    } catch [TimeoutException] {
      throw "Timed out waiting for Codex app-server response '$RequestId'."
    }
    if ($null -eq $line) { throw "Codex app-server closed before response '$RequestId'." }
    try { $message = $line | ConvertFrom-Json -Depth 100 -DateKind String } catch { continue }
    if ([string]$message.id -eq $RequestId) { return $message }
  }
  throw "Timed out waiting for Codex app-server response '$RequestId'."
}

function Get-CodexAllProviderSessions {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [switch]$Archived
  )

  $arguments = @("app-server")
  $appServerCommand = Get-CodexAppServerExternalCommand
  $startInfo = New-CodexProcessStartInfo -Arguments $arguments -Command $appServerCommand
  $startInfo.Environment["CODEX_HOME"] = Get-CodexHome -Profile $Profile
  $secretEnvironmentNames = @("OPENAI_API_KEY", "CODEX_API_KEY")
  $profilePath = Get-CodexProfilePath -Profile $Profile
  if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    $providerId = Get-AiTomlTopLevelStringValue -Path $profilePath -Key "model_provider"
    if ($providerId) {
      $envKey = Get-AiTomlSectionStringValue -Path $profilePath -Section "model_providers.$providerId" -Key "env_key"
      if ($envKey) { $secretEnvironmentNames += $envKey }
    }
  }
  foreach ($name in @($secretEnvironmentNames | Where-Object { $_ } | Sort-Object -Unique)) { [void]$startInfo.Environment.Remove($name) }
  $process = [Diagnostics.Process]::Start($startInfo)
  if (-not $process) { throw "Could not start Codex app-server." }
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $sessions = [System.Collections.Generic.List[object]]::new()
  try {
    Write-CodexAppServerMessage -Process $process -Message ([ordered]@{ id = "cx-init"; method = "initialize"; params = [ordered]@{ clientInfo = [ordered]@{ name = "cx"; title = "cx"; version = "1" }; capabilities = $null } })
    $initialize = Read-CodexAppServerResponse -Process $process -RequestId "cx-init"
    if ($initialize.error) { throw "Codex app-server initialization failed." }
    Write-CodexAppServerMessage -Process $process -Message ([ordered]@{ method = "initialized"; params = [ordered]@{} })

    $cursor = $null
    $reachedEnd = $false
    for ($page = 0; $page -lt 100; $page++) {
      $requestId = "cx-list-$page"
      $params = [ordered]@{ cursor = $cursor; limit = 100; sortKey = "updated_at"; modelProviders = @(); archived = [bool]$Archived; useStateDbOnly = $false }
      Write-CodexAppServerMessage -Process $process -Message ([ordered]@{ id = $requestId; method = "thread/list"; params = $params })
      $response = Read-CodexAppServerResponse -Process $process -RequestId $requestId
      if ($response.error) {
        $message = [string]$response.error.message
        throw "Codex app-server thread/list failed on page $page$(if ($message) { ": $message" })."
      }
      foreach ($session in @($response.result.data)) { $sessions.Add($session) }
      $nextCursor = [string]$response.result.nextCursor
      if (-not $nextCursor -or $nextCursor -eq $cursor) { $reachedEnd = $true; break }
      $cursor = $nextCursor
    }
    if (-not $reachedEnd) { throw "Codex app-server thread/list exceeded the 100-page safety limit." }
    return @($sessions)
  } finally {
    try { $process.StandardInput.Close() } catch { }
    if (-not $process.WaitForExit(2000)) { try { $process.Kill($true) } catch { } }
    try { [void]$stderrTask.GetAwaiter().GetResult() } catch { }
    $process.Dispose()
  }
}

function Get-CodexResumeArguments {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][string]$SessionId
  )

  if ([string]::IsNullOrWhiteSpace($SessionId) -or $SessionId -match '[\r\n]') {
    throw "Codex session id is invalid."
  }
  return @("--profile", (Get-CodexRuntimeProfileName -Profile $Profile), "resume", $SessionId)
}

function ConvertTo-CodexSessionView {
  param([Parameter(Mandatory = $true)]$Session)

  $title = if ($Session.name) { [string]$Session.name } elseif ($Session.preview) { [string]$Session.preview } else { [string]$Session.id }
  $title = ($title -replace '\s+', ' ').Trim()
  if ($title.Length -gt 100) { $title = $title.Substring(0, 99) + "…" }
  $updated = if ($Session.updatedAt -is [ValueType]) {
    [DateTimeOffset]::FromUnixTimeSeconds([long]$Session.updatedAt).LocalDateTime
  } else { [string]$Session.updatedAt }
  return [pscustomobject]@{ Updated = $updated; Provider = [string]$Session.modelProvider; Title = $title; Cwd = [string]$Session.cwd; Id = [string]$Session.id }
}

function Select-CodexAllProviderSession {
  param([Parameter(Mandatory = $true)][object[]]$Sessions)

  $views = @($Sessions | ForEach-Object { ConvertTo-CodexSessionView -Session $_ })
  if ($views.Count -eq 0) { throw "No Codex sessions were found." }
  if (-not $env:AI_ENV_NONINTERACTIVE -and (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
    return ($views | Out-GridView -Title "Codex sessions - all providers" -PassThru | Select-Object -First 1)
  }
  if ($env:AI_ENV_NONINTERACTIVE) { throw "A session id is required in non-interactive mode." }

  $pageSize = 25
  $page = 0
  while ($true) {
    $first = $page * $pageSize
    $last = [Math]::Min($first + $pageSize, $views.Count) - 1
    for ($index = $first; $index -le $last; $index++) {
      Write-Host ("[{0}] {1} [{2}] {3}" -f ($index + 1), $views[$index].Updated, $views[$index].Provider, $views[$index].Title)
    }
    $answer = (Read-Host "Select 1-$($views.Count), N(ext), P(revious), or Q(uit)").Trim()
    $selection = 0
    if ([int]::TryParse($answer, [ref]$selection) -and $selection -ge 1 -and $selection -le $views.Count) { return $views[$selection - 1] }
    if ($answer -match '^n') { $page = [Math]::Min($page + 1, [Math]::Floor(($views.Count - 1) / $pageSize)); continue }
    if ($answer -match '^p') { $page = [Math]::Max(0, $page - 1); continue }
    if ($answer -match '^q') { return $null }
  }
}

function Show-CodexAllProviderSessions {
  param([string[]]$Arguments)

  $json = $Arguments -contains "--json"
  $archived = $Arguments -contains "--archived"
  if (@($Arguments | Where-Object { $_ -notin @("--json", "--archived") }).Count -gt 0) { throw "Usage: cx sessions [--archived] [--json]" }
  $sessions = @(Get-CodexAllProviderSessions -Profile (Get-CodexCurrentProfile) -Archived:$archived)
  if ($json) { ConvertTo-Json -InputObject ([object[]]$sessions) -Depth 20; return }
  $sessions | ForEach-Object { ConvertTo-CodexSessionView -Session $_ } | Format-Table -AutoSize
}

function Resume-CodexAllProviderSession {
  param([string[]]$Arguments)

  if ($Arguments.Count -gt 1 -or ($Arguments.Count -eq 1 -and $Arguments[0].StartsWith("-"))) { throw "Usage: cx resume [SESSION_ID]" }
  $profile = Get-CodexCurrentProfile
  $sessionId = if ($Arguments.Count -eq 1) { [string]$Arguments[0] } else { $null }
  if (-not $sessionId) {
    $selection = Select-CodexAllProviderSession -Sessions @(Get-CodexAllProviderSessions -Profile $profile)
    if (-not $selection) { return }
    $sessionId = [string]$selection.Id
  }
  Set-CodexProfileEnvironment -Profile $profile | Out-Null
  $resumeArguments = @(Get-CodexResumeArguments -Profile $profile -SessionId $sessionId)
  & (Get-CodexExternalCommand) @resumeArguments
}

function Get-CodexLoginStatusText {
  try {
    $codexCommand = Get-CodexExternalCommand
    return ((& $codexCommand login status 2>&1 | Out-String).Trim())
  } catch {
    return "unavailable: $($_.Exception.Message)"
  }
}

function Get-CodexProviderConfigArgs {
  param([Parameter(Mandatory = $true)]$Profile)

  $configArgs = @()
  $profilePath = Get-CodexProfilePath -Profile $Profile
  $model = Get-TomlStringValue -Path $profilePath -Key "model"
  $provider = Get-TomlStringValue -Path $profilePath -Key "model_provider"
  $reasoning = Get-TomlStringValue -Path $profilePath -Key "model_reasoning_effort"

  if ($model) {
    $configArgs += @("-c", "model=`"$model`"")
  }
  if ($provider) {
    $configArgs += @("-c", "model_provider=`"$provider`"")
  }
  if ($reasoning) {
    $configArgs += @("-c", "model_reasoning_effort=`"$reasoning`"")
  }

  if ($provider) {
    $baseUrl = Get-TomlStringValue -Path $profilePath -Key "base_url"
    $wireApi = Get-TomlStringValue -Path $profilePath -Key "wire_api"
    $envKey = Get-TomlStringValue -Path $profilePath -Key "env_key"
    $requiresOpenAiAuth = Get-TomlStringValue -Path $profilePath -Key "requires_openai_auth"
    $providerName = Get-TomlStringValue -Path $profilePath -Key "name"
    $hasProviderConfig = [bool]($baseUrl -or $wireApi -or $envKey -or $requiresOpenAiAuth -or $providerName)

    if (($provider -notin @("openai", "ollama", "lmstudio", "amazon-bedrock")) -or $hasProviderConfig) {
      if (-not $providerName) {
        $providerName = $provider
      }
      if (-not $wireApi) {
        $wireApi = "responses"
      }

      $configArgs += @("-c", "model_providers.$provider.name=`"$providerName`"")
      if ($baseUrl) {
        $configArgs += @("-c", "model_providers.$provider.base_url=`"$baseUrl`"")
      }
      if ($wireApi) {
        $configArgs += @("-c", "model_providers.$provider.wire_api=`"$wireApi`"")
      }
      if ($envKey) {
        $configArgs += @("-c", "model_providers.$provider.env_key=`"$envKey`"")
      }
      if ($requiresOpenAiAuth) {
        $configArgs += @("-c", "model_providers.$provider.requires_openai_auth=$requiresOpenAiAuth")
      }
    }
  }

  return $configArgs
}

function Get-CodexDoctorArgs {
  param([Parameter(Mandatory = $true)]$Profile)

  return @("doctor", "--json") + (Get-CodexProviderConfigArgs -Profile $Profile)
}

function Get-CodexDoctorReport {
  param([Parameter(Mandatory = $true)]$Profile)

  try {
    $codexCommand = Get-CodexExternalCommand
    $doctorArgs = Get-CodexDoctorArgs -Profile $Profile
    $json = & $codexCommand @doctorArgs 2>$null
    if (-not $json) {
      return $null
    }
    return ($json | ConvertFrom-Json)
  } catch {
    Write-Verbose "Codex doctor failed: $($_.Exception.Message)"
    return $null
  }
}

function Get-CodexCheck {
  param(
    [Parameter(Mandatory = $true)]$Report,
    [Parameter(Mandatory = $true)][string]$Name
  )

  return $Report.checks.PSObject.Properties[$Name].Value
}

function Write-CodexDoctorSummary {
  param([Parameter(Mandatory = $true)]$Profile)

  $report = Get-CodexDoctorReport -Profile $Profile
  if (-not $report) {
    Write-Host "  Doctor: unavailable"
    return
  }

  $auth = Get-CodexCheck -Report $report -Name "auth.credentials"
  $config = Get-CodexCheck -Report $report -Name "config.load"
  $reach = Get-CodexCheck -Report $report -Name "network.provider_reachability"
  $ws = Get-CodexCheck -Report $report -Name "network.websocket_reachability"
  $sandbox = Get-CodexCheck -Report $report -Name "sandbox.helpers"
  $threads = Get-CodexCheck -Report $report -Name "state.rollout_db_parity"
  $updates = Get-CodexCheck -Report $report -Name "updates.status"

  Write-Host "  Doctor: $($report.overallStatus), Codex $($report.codexVersion)"
  if ($config) {
    Write-Host "  Runtime: model=$($config.details.model); provider=$($config.details.'model provider'); mcp=$($config.details.'mcp servers')"
  }
  if ($auth) {
    Write-Host "  Auth: $($auth.status) - $($auth.summary)"
    if ($auth.details.'stored auth mode') {
      Write-Host "  Auth cache: $($auth.details.'stored auth mode'); api_key=$($auth.details.'stored API key'); chatgpt_tokens=$($auth.details.'stored ChatGPT tokens')"
    }
  }
  if ($reach) {
    Write-Host "  Network: $($reach.status) - $($reach.summary)"
  }
  if ($ws) {
    Write-Host "  WebSocket: $($ws.status) - $($ws.summary)"
  }
  if ($sandbox) {
    Write-Host "  Sandbox: approval=$($sandbox.details.'approval policy'); fs=$($sandbox.details.'filesystem sandbox'); net=$($sandbox.details.'network sandbox')"
  }
  if ($threads) {
    Write-Host "  Threads: active=$($threads.details.'rollout DB active rows'); archived=$($threads.details.'rollout DB archived rows'); providers=$($threads.details.'rollout DB model providers')"
  }
  if ($updates) {
    Write-Host "  Updates: $($updates.details.'latest version status')"
  }
}

function Get-ClaudeAuthStatusReport {
  try {
    $json = & claude auth status --json 2>$null
    if (-not $json) {
      return $null
    }
    return ($json | ConvertFrom-Json)
  } catch {
    Write-Verbose "Claude auth status failed: $($_.Exception.Message)"
    return $null
  }
}

function Write-ClaudeExternalStatus {
  $auth = Get-ClaudeAuthStatusReport
  if ($auth) {
    Write-Host "  Auth status: loggedIn=$($auth.loggedIn); method=$($auth.authMethod); provider=$($auth.apiProvider); source=$($auth.apiKeySource ?? '<none>')"
  } else {
    Write-Host "  Auth status: unavailable"
  }

  $statsPath = Join-Path $HOME ".claude\stats-cache.json"
  if (Test-Path -LiteralPath $statsPath) {
    try {
      $stats = Get-Content -Raw -LiteralPath $statsPath | ConvertFrom-Json
      Write-Host "  Local usage cache: sessions=$($stats.totalSessions); messages=$($stats.totalMessages); lastComputed=$($stats.lastComputedDate)"
    } catch {
      Write-Verbose "Could not read Claude stats cache: $($_.Exception.Message)"
    }
  }
}

function Get-LegacyCodexApiKey {
  $legacyAuthFiles = @(
    (Join-Path $HOME ".codex.API\auth.json"),
    (Join-Path $HOME ".codex-api\auth.json")
  )

  foreach ($authFile in $legacyAuthFiles) {
    if (-not (Test-Path -LiteralPath $authFile)) {
      continue
    }

    try {
      $auth = Get-Content -Raw -LiteralPath $authFile | ConvertFrom-Json
      if ($auth.OPENAI_API_KEY) {
        return [string]$auth.OPENAI_API_KEY
      }
    } catch {
      Write-Warning "Could not read legacy Codex API key from $authFile. $($_.Exception.Message)"
    }
  }

  return $null
}

function Get-AiToolEnvKeys {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  $keys = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($profile in Get-AiToolProfiles -Tool $Tool) {
    $envObj = Get-AiProperty -Object $profile -Name "env"
    if ($envObj) {
      foreach ($prop in $envObj.PSObject.Properties) {
        [void]$keys.Add($prop.Name)
      }
    }
  }

  return $keys
}

function Clear-AiToolExtraEnv {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  foreach ($key in (Get-AiToolEnvKeys -Tool $Tool)) {
    Remove-Item -Path "Env:$key" -ErrorAction SilentlyContinue
  }
}

function Set-AiProfileExtraEnv {
  param([Parameter(Mandatory = $true)]$Profile)

  $envObj = Get-AiProperty -Object $Profile -Name "env"
  if (-not $envObj) {
    return
  }

  foreach ($prop in $envObj.PSObject.Properties) {
    Set-Item -Path "Env:$($prop.Name)" -Value ([string]$prop.Value)
  }
}

function Get-AiProfileEnvSummary {
  param([Parameter(Mandatory = $true)]$Profile)

  $envObj = Get-AiProperty -Object $Profile -Name "env"
  if (-not $envObj) {
    return "<none>"
  }

  return [string]@($envObj.PSObject.Properties).Count
}

function Get-AiProfileEnvValue {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $envObj = Get-AiProperty -Object $Profile -Name "env"
  if (-not $envObj) {
    return $null
  }

  $prop = $envObj.PSObject.Properties[$Name]
  if ($prop -and $prop.Value) {
    return [string]$prop.Value
  }

  return $null
}

function Set-CodexProfileEnvironment {
  param([Parameter(Mandatory = $true)]$Profile)

  $mode = Get-AiProfileMode -Profile $Profile
  $name = Get-AiProfileName -Profile $Profile
  $env:CODEX_HOME = Get-CodexHome -Profile $Profile
  $env:AI_CODEX_PROFILE = Get-CodexRuntimeProfileName -Profile $Profile
  $env:AI_CODEX_LABEL = $name
  New-Item -ItemType Directory -Force -Path $env:CODEX_HOME | Out-Null
  Remove-Item Env:CODEX_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
  Clear-AiToolExtraEnv -Tool "codex"

  $secretSource = "<none>"
  if ($mode -eq "api") {
    $secret = Get-AiSecretPath -Profile $Profile
    $tomlSource = Set-AiEnvironmentFromTomlSecret -Tool "codex" -Profile $Profile -Names @("OPENAI_API_KEY", "CODEX_API_KEY")
    if ($tomlSource) {
      $secretSource = $tomlSource
    } elseif ($secret -and (Test-Path -LiteralPath $secret)) {
      . $secret
      $secretSource = $secret
    }

    if (-not $env:OPENAI_API_KEY -and $env:CODEX_API_KEY) {
      $env:OPENAI_API_KEY = $env:CODEX_API_KEY
    }

    if (-not $env:OPENAI_API_KEY -and $name -eq "api") {
      $legacyKey = Get-LegacyCodexApiKey
      if ($legacyKey) {
        $env:OPENAI_API_KEY = $legacyKey
        $secretSource = "legacy .codex.API auth.json"
      }
    }

    if (-not $env:OPENAI_API_KEY) {
      throw "cx $name needs OPENAI_API_KEY. Put it in $script:AiSecretsPath section [$(Get-AiSecretId -Tool 'codex' -Profile $Profile)] or $secret."
    }
  }

  Set-AiProfileExtraEnv -Profile $Profile
  return $secretSource
}

function Set-ClaudeProfileEnvironment {
  param([Parameter(Mandatory = $true)]$Profile)

  $mode = Get-AiProfileMode -Profile $Profile
  $name = Get-AiProfileName -Profile $Profile
  $env:AI_CLAUDE_LABEL = $name
  foreach ($envName in @("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL")) {
    Remove-Item "Env:$envName" -ErrorAction SilentlyContinue
  }
  Clear-AiToolExtraEnv -Tool "claude"

  $secretSource = "<none>"
  if ($mode -eq "api") {
    $secret = Get-AiSecretPath -Profile $Profile
    $tomlSource = Set-AiEnvironmentFromTomlSecret -Tool "claude" -Profile $Profile -Names @("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL")
    if ($tomlSource) {
      $secretSource = $tomlSource
    } elseif ($secret -and (Test-Path -LiteralPath $secret)) {
      . $secret
      $secretSource = $secret
    }

    if (-not $env:ANTHROPIC_API_KEY -and -not $env:ANTHROPIC_AUTH_TOKEN -and $name -eq "api") {
      $userApiKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")
      $userAuthToken = [Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User")
      if ($userApiKey) {
        $env:ANTHROPIC_API_KEY = $userApiKey
        $secretSource = "user environment variable"
      }
      if ($userAuthToken) {
        $env:ANTHROPIC_AUTH_TOKEN = $userAuthToken
        $secretSource = "user environment variable"
      }
    }

    if (-not $env:ANTHROPIC_BASE_URL) {
      $env:ANTHROPIC_BASE_URL = [string](Get-AiProperty -Object $Profile -Name "base_url" -Default $script:ClaudeRouterBaseUrl)
    }

    if (-not $env:ANTHROPIC_API_KEY -and -not $env:ANTHROPIC_AUTH_TOKEN) {
      throw "cc $name needs ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN in $script:AiSecretsPath section [$(Get-AiSecretId -Tool 'claude' -Profile $Profile)] or $secret."
    }
  }

  Set-AiProfileExtraEnv -Profile $Profile
  return $secretSource
}

function Get-CodexRolloutTokenStats {
  param(
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [int]$Days = 30
  )

  $sessionsDir = Join-Path $CodexHome "sessions"
  $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * $Days)
  $stats = [ordered]@{
    Sessions = 0
    Samples = 0
    Input = 0L
    CachedInput = 0L
    Output = 0L
    ReasoningOutput = 0L
    Total = 0L
    Since = $cutoff
  }

  if (-not (Test-Path -LiteralPath $sessionsDir)) {
    return [pscustomobject]$stats
  }

  foreach ($file in Get-ChildItem -LiteralPath $sessionsDir -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue) {
    if ($file.LastWriteTimeUtc -lt $cutoff) {
      continue
    }

    $latest = $null
    $samples = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue) {
      if ($line -notlike '*"token_count"*') {
        continue
      }
      try {
        $json = $line | ConvertFrom-Json
        if ($json.type -ne "event_msg" -or $json.payload.type -ne "token_count") {
          continue
        }
        $usage = $json.payload.info.total_token_usage
        if ($usage) {
          $latest = $usage
          $samples++
        }
      } catch {
      }
    }

    if ($latest) {
      $stats.Sessions++
      $stats.Samples += $samples
      $stats.Input += [int64](Get-AiProperty -Object $latest -Name "input_tokens" -Default 0)
      $stats.CachedInput += [int64](Get-AiProperty -Object $latest -Name "cached_input_tokens" -Default (Get-AiProperty -Object $latest -Name "cache_read_input_tokens" -Default 0))
      $stats.Output += [int64](Get-AiProperty -Object $latest -Name "output_tokens" -Default 0)
      $stats.ReasoningOutput += [int64](Get-AiProperty -Object $latest -Name "reasoning_output_tokens" -Default 0)
      $total = [int64](Get-AiProperty -Object $latest -Name "total_tokens" -Default 0)
      if ($total -le 0) {
        $total = [int64](Get-AiProperty -Object $latest -Name "input_tokens" -Default 0) + [int64](Get-AiProperty -Object $latest -Name "output_tokens" -Default 0)
      }
      $stats.Total += $total
    }
  }

  return [pscustomobject]$stats
}

function Format-AiTokenCount {
  param([int64]$Value)

  if ($Value -ge 1000000) {
    return ("{0:N2}M" -f ($Value / 1000000.0))
  }
  if ($Value -ge 1000) {
    return ("{0:N1}K" -f ($Value / 1000.0))
  }
  return [string]$Value
}

function Format-AiTokenBar {
  param(
    [int64]$Value,
    [int64]$Total
  )

  if ($Total -le 0 -or $Value -le 0) {
    return ""
  }

  $width = [Math]::Max(1, [Math]::Round(($Value / [double]$Total) * 24))
  return ("#" * $width)
}

function Show-CodexStats {
  param([string[]]$Arguments)

  $parsed = ConvertFrom-AiManagementArgs -Arguments $Arguments
  $daysText = Get-AiOption -Options $parsed.Options -Name "days" -Default "30"
  $days = 30
  if (-not [int]::TryParse($daysText, [ref]$days) -or $days -lt 1) {
    throw "cx stats --days must be a positive integer."
  }

  $saved = Get-AiSavedProfileName -Tool "codex"
  $profile = Get-AiProfileByName -Tool "codex" -Name ($env:AI_CODEX_LABEL ?? $saved)
  if (-not $profile) {
    $profile = Get-AiProfileByName -Tool "codex" -Name (Get-AiDefaultProfileName -Tool "codex")
  }
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } elseif ($profile) { Get-CodexHome -Profile $profile } else { Join-Path $script:AiHome ".codex" }
  $stats = Get-CodexRolloutTokenStats -CodexHome $codexHome -Days $days

  Write-Host "Codex local token stats:"
  Write-Host "  CODEX_HOME: $codexHome"
  Write-Host "  Window: last $days days"
  Write-Host "  Sessions with usage: $($stats.Sessions)"
  Write-Host "  Token samples: $($stats.Samples)"
  Write-Host "  Total: $(Format-AiTokenCount $stats.Total) ($($stats.Total))"
  foreach ($row in @(
    @("input", $stats.Input),
    @("cached", $stats.CachedInput),
    @("output", $stats.Output),
    @("reasoning", $stats.ReasoningOutput)
  )) {
    $label = $row[0]
    $value = [int64]$row[1]
    Write-Host ("  {0,-9} {1,10}  {2}" -f $label, (Format-AiTokenCount $value), (Format-AiTokenBar -Value $value -Total $stats.Total))
  }
}

function Get-CodexBaseUrl {
  param([Parameter(Mandatory = $true)]$Profile)

  $profilePath = Get-CodexProfilePath -Profile $Profile
  $baseUrl = Get-TomlStringValue -Path $profilePath -Key "base_url"
  if (-not $baseUrl) {
    $baseUrl = Get-TomlStringValue -Path (Join-Path (Get-CodexHome -Profile $Profile) "config.toml") -Key "openai_base_url"
  }
  if (-not $baseUrl) {
    $baseUrl = "built-in OpenAI/ChatGPT endpoint"
  }

  return $baseUrl
}

function Write-CodexSwitchStatus {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [string]$SecretSource
  )

  $mode = Get-AiProfileMode -Profile $Profile
  $profilePath = Get-CodexProfilePath -Profile $Profile
  Write-Host "Codex state switched: $(Get-AiProfileName -Profile $Profile)"
  Write-Host "  Run next: codex"
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  CODEX_HOME: $env:CODEX_HOME"
  if (Test-Path -LiteralPath $profilePath) {
    Write-Host "  Profile: $(Get-CodexRuntimeProfileName -Profile $Profile) ($profilePath)"
  } else {
    Write-Host "  Profile: <default> ($profilePath missing)"
  }
  Write-Host "  Base URL: $(Get-CodexBaseUrl -Profile $Profile)"
  Write-Host "  Probe model: $(Get-AiProbeModel -Tool codex -Profile $Profile)"
  Write-Host "  Cached login: $(Get-CodexLoginStatusText)"

  if ($mode -eq "api") {
    Write-Host "  OPENAI_API_KEY: $(Format-AiSecretPreview $env:OPENAI_API_KEY)"
    Write-Host "  Secret source: $SecretSource"
    Write-Host "  API local check: profile file=$((Test-Path -LiteralPath $profilePath)); key=$([bool]$env:OPENAI_API_KEY)"
  } else {
    Write-Host "  OPENAI_API_KEY: <cleared>"
    Write-Host "  Subscription quota: not exposed by Codex CLI"
  }

  # Cached health line (instant — no network). `codex doctor` is deliberately
  # NOT run here: it does live network/websocket checks that stall the switch.
  # Use `cx doctor` for the full diagnostic on demand.
  $h = Get-AiProfileHealthCached -Tool "codex" -Profile $Profile -CacheOnly
  Write-Host (Format-AiHealthStatusLine $h)
}

function Write-ClaudeSwitchStatus {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [string]$SecretSource
  )

  $mode = Get-AiProfileMode -Profile $Profile
  Write-Host "Claude Code state switched: $(Get-AiProfileName -Profile $Profile)"
  Write-Host "  Run next: claude"
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  Probe model: $(Get-AiProbeModel -Tool claude -Profile $Profile)"
  if ($mode -eq "api") {
    Write-Host "  ANTHROPIC_BASE_URL: $env:ANTHROPIC_BASE_URL"
    Write-Host "  ANTHROPIC_API_KEY: $(Format-AiSecretPreview $env:ANTHROPIC_API_KEY)"
    Write-Host "  ANTHROPIC_AUTH_TOKEN: $(Format-AiSecretPreview $env:ANTHROPIC_AUTH_TOKEN)"
    Write-Host "  Secret source: $SecretSource"
    Write-Host "  API local check: auth=$([bool]($env:ANTHROPIC_API_KEY -or $env:ANTHROPIC_AUTH_TOKEN)); url=$([bool]$env:ANTHROPIC_BASE_URL)"
  } else {
    Write-Host "  Anthropic API env: <cleared>"
    Write-Host "  Subscription status: local Claude login is used if present"
  }

  $h = Get-AiProfileHealthCached -Tool "claude" -Profile $Profile -CacheOnly
  Write-Host (Format-AiHealthStatusLine $h)
  Write-ClaudeExternalStatus
}

function Get-CodexProfileRows {
  $saved = Get-AiSavedProfileName -Tool "codex"
  foreach ($profile in Get-AiToolProfiles -Tool "codex") {
    $mode = Get-AiProfileMode -Profile $profile
    $profileHome = Get-CodexHome -Profile $profile
    $profilePath = Get-CodexProfilePath -Profile $profile
    $secretOk = if ($mode -eq "api") {
      (Test-AiTomlSecretValues -Tool "codex" -Profile $profile -Names @("OPENAI_API_KEY", "CODEX_API_KEY")) -or
        ((Get-AiSecretPath -Profile $profile) -and (Test-Path -LiteralPath (Get-AiSecretPath -Profile $profile)))
    } else {
      $true
    }
    $configOk = Test-Path -LiteralPath $profilePath
    $ready = if ($mode -eq "api" -and -not $configOk) {
      "missing config"
    } elseif (-not $secretOk) {
      "missing secret"
    } elseif ($mode -eq "sub" -and -not $configOk) {
      "ok default"
    } else {
      "ok"
    }
    $name = Get-AiProfileName -Profile $profile
    [pscustomobject]@{
      Sel = if ($name -eq $saved) { "*" } else { " " }
      Name = $name
      Mode = $mode
      Health = Get-AiHealthCellCached -Tool "codex" -Profile $profile
      Profile = Get-CodexRuntimeProfileName -Profile $profile
      Ready = $ready
      Home = $profileHome
      Config = if (Test-Path -LiteralPath $profilePath) { $profilePath } else { "<missing> $profilePath" }
      Secret = if ($mode -eq "api") { Get-AiSecretDisplay -Tool "codex" -Profile $profile -Names @("OPENAI_API_KEY", "CODEX_API_KEY") } else { "<none>" }
      BaseUrl = Get-CodexBaseUrl -Profile $profile
      Env = Get-AiProfileEnvSummary -Profile $profile
    }
  }
}

function Get-ClaudeProfileRows {
  $saved = Get-AiSavedProfileName -Tool "claude"
  foreach ($profile in Get-AiToolProfiles -Tool "claude") {
    $mode = Get-AiProfileMode -Profile $profile
    $secret = if ($mode -eq "api") { Get-AiSecretPath -Profile $profile } else { "<none>" }
    $secretOk = if ($mode -eq "api") {
      (Test-AiTomlSecretValues -Tool "claude" -Profile $profile -Names @("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")) -or
        ($secret -and (Test-Path -LiteralPath $secret))
    } else {
      $true
    }
    $name = Get-AiProfileName -Profile $profile
    $baseUrl = if ($mode -eq "api") {
      $secretId = Get-AiSecretId -Tool "claude" -Profile $profile
      $tomlSection = Get-AiTomlSecretSection -SecretId $secretId
      if ($tomlSection.ContainsKey("ANTHROPIC_BASE_URL") -and $tomlSection["ANTHROPIC_BASE_URL"]) {
        $tomlSection["ANTHROPIC_BASE_URL"]
      } elseif ($secret -and (Test-Path -LiteralPath $secret)) {
        $configured = Get-PowerShellEnvAssignment -Path $secret -Name "ANTHROPIC_BASE_URL"
        if ($configured) { $configured } else { Get-AiProperty -Object $profile -Name "base_url" -Default $script:ClaudeRouterBaseUrl }
      } else {
        Get-AiProperty -Object $profile -Name "base_url" -Default $script:ClaudeRouterBaseUrl
      }
    } else {
      "local Claude subscription login"
    }

    [pscustomobject]@{
      Sel = if ($name -eq $saved) { "*" } else { " " }
      Name = $name
      Mode = $mode
      Health = Get-AiHealthCellCached -Tool "claude" -Profile $profile
      Ready = if ($secretOk) { "ok" } else { "missing secret" }
      Secret = if ($mode -eq "api") { Get-AiSecretDisplay -Tool "claude" -Profile $profile -Names @("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN") } else { "<none>" }
      BaseUrl = $baseUrl
      Env = Get-AiProfileEnvSummary -Profile $profile
    }
  }
}

function Show-CodexList {
  Write-Host "Codex profiles ($script:AiRegistryPath):"
  Get-CodexProfileRows | Format-Table Sel, Name, Mode, Health, Profile, BaseUrl -AutoSize
  Write-Host "  (Health = cached snapshot, ⏭=stale/unprobed; run 'cx health' to refresh)" -ForegroundColor DarkGray
}

function Show-ClaudeList {
  Write-Host "Claude Code profiles ($script:AiRegistryPath):"
  Get-ClaudeProfileRows | Format-Table Sel, Name, Mode, Health, BaseUrl -AutoSize
  Write-Host "  (Health = cached snapshot, ⏭=stale/unprobed; run 'cc health' to refresh)" -ForegroundColor DarkGray
}

function Show-CodexStatus {
  param([switch]$Fresh)
  $saved = Get-AiSavedProfileName -Tool "codex"
  $profile = Get-AiProfileByName -Tool "codex" -Name ($env:AI_CODEX_LABEL ?? $saved)
  if (-not $profile) {
    $profile = Get-AiProfileByName -Tool "codex" -Name (Get-AiDefaultProfileName -Tool "codex")
  }

  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Get-CodexHome -Profile $profile }
  Write-Host "Codex state:"
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  State: $script:AiStatePath"
  Write-Host "  Saved: $saved"
  Write-Host "  Process label: $($env:AI_CODEX_LABEL ?? '<unset>')"
  Write-Host "  Process profile: $($env:AI_CODEX_PROFILE ?? '<unset>')"
  Write-Host "  CODEX_HOME: $codexHome"
  Write-Host "  OPENAI_API_KEY: $(Format-AiSecretPreview $env:OPENAI_API_KEY)"
  Write-Host "  Cached login: $(Get-CodexLoginStatusText)"
  if ($profile) {
    Write-Host "  Probe model: $(Get-AiProbeModel -Tool codex -Profile $profile)"
    $h = Get-AiProfileHealthCached -Tool "codex" -Profile $profile -Fresh:$Fresh -CacheOnly:(-not $Fresh)
    Write-Host (Format-AiHealthStatusLine $h)
  }
}

function Show-CodexDoctor {
  $saved = Get-AiSavedProfileName -Tool "codex"
  $profile = Get-AiProfileByName -Tool "codex" -Name ($env:AI_CODEX_LABEL ?? $saved)
  if (-not $profile) { $profile = Get-AiProfileByName -Tool "codex" -Name (Get-AiDefaultProfileName -Tool "codex") }
  if (-not $profile) { Write-Host "No codex profile to diagnose."; return }
  Write-CodexDoctorSummary -Profile $profile
}

function Show-ClaudeStatus {
  param([switch]$Fresh)
  $saved = Get-AiSavedProfileName -Tool "claude"
  Write-Host "Claude Code state:"
  Write-Host "  Registry: $script:AiRegistryPath"
  Write-Host "  State: $script:AiStatePath"
  Write-Host "  Saved: $saved"
  Write-Host "  Process label: $($env:AI_CLAUDE_LABEL ?? '<unset>')"
  Write-Host "  ANTHROPIC_BASE_URL: $($env:ANTHROPIC_BASE_URL ?? '<unset>')"
  Write-Host "  ANTHROPIC_API_KEY: $(Format-AiSecretPreview $env:ANTHROPIC_API_KEY)"
  Write-Host "  ANTHROPIC_AUTH_TOKEN: $(Format-AiSecretPreview $env:ANTHROPIC_AUTH_TOKEN)"
  $cprofile = Get-AiProfileByName -Tool "claude" -Name ($env:AI_CLAUDE_LABEL ?? $saved)
  if (-not $cprofile) { $cprofile = Get-AiProfileByName -Tool "claude" -Name (Get-AiDefaultProfileName -Tool "claude") }
  if ($cprofile) {
    Write-Host "  Probe model: $(Get-AiProbeModel -Tool claude -Profile $cprofile)"
    $h = Get-AiProfileHealthCached -Tool "claude" -Profile $cprofile -Fresh:$Fresh -CacheOnly:(-not $Fresh)
    Write-Host (Format-AiHealthStatusLine $h)
  }
  Write-ClaudeExternalStatus
}
