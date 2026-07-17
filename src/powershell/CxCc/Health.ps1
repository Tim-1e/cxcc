function Join-Path-Uri {
  param([Parameter(Mandatory = $true)][string]$Origin, [Parameter(Mandatory = $true)][string]$Relative)
  $o = $Origin.TrimEnd('/')
  $r = $Relative.TrimStart('/')
  return "$o/$r"
}

function Get-AiProbeModel {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile
  )

  if ((Get-AiProfileMode -Profile $Profile) -ne "api") {
    return "-"
  }
  $explicit = Get-AiProperty -Object $Profile -Name "probe_model"
  if ($explicit) {
    return [string]$explicit
  }

  if ($Tool -eq "claude") {
    $secretId = Get-AiSecretId -Tool $Tool -Profile $Profile
    $section = Get-AiTomlSecretSection -SecretId $secretId
    if ($section.ContainsKey("ANTHROPIC_MODEL") -and $section["ANTHROPIC_MODEL"]) {
      return [string]$section["ANTHROPIC_MODEL"]
    }

    $legacyPath = Get-AiSecretPath -Profile $Profile
    if ($legacyPath -and (Test-Path -LiteralPath $legacyPath)) {
      $legacyModel = Get-PowerShellEnvAssignment -Path $legacyPath -Name "ANTHROPIC_MODEL"
      if ($legacyModel) {
        return $legacyModel
      }
    }

    $profileModel = Get-AiProfileEnvValue -Profile $Profile -Name "ANTHROPIC_MODEL"
    if ($profileModel) {
      return $profileModel
    }

    $processModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_MODEL")
    if ($processModel) {
      return $processModel
    }

    $userModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_MODEL", "User")
    if ($userModel) {
      return $userModel
    }

    if ($section.ContainsKey("ANTHROPIC_DEFAULT_HAIKU_MODEL") -and $section["ANTHROPIC_DEFAULT_HAIKU_MODEL"]) {
      return [string]$section["ANTHROPIC_DEFAULT_HAIKU_MODEL"]
    }

    if ($legacyPath -and (Test-Path -LiteralPath $legacyPath)) {
      $legacyHaikuModel = Get-PowerShellEnvAssignment -Path $legacyPath -Name "ANTHROPIC_DEFAULT_HAIKU_MODEL"
      if ($legacyHaikuModel) {
        return $legacyHaikuModel
      }
    }

    $profileHaikuModel = Get-AiProfileEnvValue -Profile $Profile -Name "ANTHROPIC_DEFAULT_HAIKU_MODEL"
    if ($profileHaikuModel) {
      return $profileHaikuModel
    }

    $processHaikuModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL")
    if ($processHaikuModel) {
      return $processHaikuModel
    }

    $userHaikuModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", "User")
    if ($userHaikuModel) {
      return $userHaikuModel
    }

    return "claude-3-5-haiku-20241022"
  }

  $profilePath = Get-CodexProfilePath -Profile $Profile
  $model = Get-TomlStringValue -Path $profilePath -Key "model"
  if (-not $model) {
    $model = Get-TomlStringValue -Path (Join-Path (Get-CodexHome -Profile $Profile) "config.toml") -Key "model"
  }
  if ($model) {
    return $model
  }

  return "gpt-5.4-mini"
}

function Get-AiProfileProbeTarget {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile
  )

  $result = [pscustomobject]@{
    BaseOrigin  = $null
    Headers     = @{}
    ProbeModel  = $null
    SecretOk    = $false
    SecretLabel = "<none>"
  }

  $mode = Get-AiProfileMode -Profile $Profile
  if ($mode -ne "api") {
    return $result
  }

  $secretId = Get-AiSecretId -Tool $Tool -Profile $Profile
  $section = Get-AiTomlSecretSection -SecretId $secretId
  $legacyPath = Get-AiSecretPath -Profile $Profile

  if ($Tool -eq "claude") {
    $baseUrl = $null
    if ($section.ContainsKey("ANTHROPIC_BASE_URL") -and $section["ANTHROPIC_BASE_URL"]) {
      $baseUrl = [string]$section["ANTHROPIC_BASE_URL"]
    } elseif ($legacyPath -and (Test-Path -LiteralPath $legacyPath)) {
      $baseUrl = Get-PowerShellEnvAssignment -Path $legacyPath -Name "ANTHROPIC_BASE_URL"
    }
    if (-not $baseUrl) {
      $baseUrl = [string](Get-AiProperty -Object $Profile -Name "base_url" -Default $script:ClaudeRouterBaseUrl)
    }

    $authToken = $null
    $apiKey = $null
    if ($section.ContainsKey("ANTHROPIC_AUTH_TOKEN") -and $section["ANTHROPIC_AUTH_TOKEN"]) {
      $authToken = [string]$section["ANTHROPIC_AUTH_TOKEN"]
    }
    if ($section.ContainsKey("ANTHROPIC_API_KEY") -and $section["ANTHROPIC_API_KEY"]) {
      $apiKey = [string]$section["ANTHROPIC_API_KEY"]
    }
    if (-not $authToken -and -not $apiKey -and $legacyPath -and (Test-Path -LiteralPath $legacyPath)) {
      $authToken = Get-PowerShellEnvAssignment -Path $legacyPath -Name "ANTHROPIC_AUTH_TOKEN"
      $apiKey = Get-PowerShellEnvAssignment -Path $legacyPath -Name "ANTHROPIC_API_KEY"
    }
    if (-not $authToken) { $authToken = [Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User") }
    if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User") }

    $probeModel = Get-AiProbeModel -Tool $Tool -Profile $Profile
    $headers = @{ "anthropic-version" = "2023-06-01" }
    if ($authToken) { $headers["Authorization"] = "Bearer $authToken" }
    if ($apiKey) { $headers["x-api-key"] = $apiKey }
    if ($probeModel -match '\[1m\]') { $headers["anthropic-beta"] = "context-1m-2025-08-07" }
    # Some relays gate on User-Agent (e.g. AixHan rejects unknown clients with a
    # 400 "Client not allowed ..."). Identify as the real Claude Code CLI so the
    # probe sees what an actual session sees. Override per-profile via `probe_ua`.
    $headers["User-Agent"] = [string](Get-AiProperty -Object $Profile -Name "probe_ua" -Default "claude-cli/1.0.119 (external, cli)")

    $result.BaseOrigin = $baseUrl
    $result.Headers = $headers
    $result.SecretOk = [bool]($authToken -or $apiKey)
    $result.SecretLabel = if ($result.SecretOk) { "$script:AiSecretsPath#$secretId" } else { "<none>" }
    $result.ProbeModel = $probeModel
    return $result
  }

  # codex
  $apiKey = $null
  if ($section.ContainsKey("OPENAI_API_KEY") -and $section["OPENAI_API_KEY"]) {
    $apiKey = [string]$section["OPENAI_API_KEY"]
  }
  if (-not $apiKey -and $section.ContainsKey("CODEX_API_KEY") -and $section["CODEX_API_KEY"]) {
    $apiKey = [string]$section["CODEX_API_KEY"]
  }
  if (-not $apiKey -and $legacyPath -and (Test-Path -LiteralPath $legacyPath)) {
    $apiKey = Get-PowerShellEnvAssignment -Path $legacyPath -Name "OPENAI_API_KEY"
  }
  if (-not $apiKey) { $apiKey = Get-LegacyCodexApiKey }

  $result.BaseOrigin = (Get-CodexBaseUrl -Profile $Profile)
  $result.Headers = if ($apiKey) { @{ "Authorization" = "Bearer $apiKey" } } else { @{} }
  # Identify as the real Codex CLI for relays that gate on User-Agent.
  $result.Headers["User-Agent"] = [string](Get-AiProperty -Object $Profile -Name "probe_ua" -Default "codex_cli_rs/0.40.0 (external, cli)")
  $result.SecretOk = [bool]$apiKey
  $result.SecretLabel = if ($apiKey) { "$script:AiSecretsPath#$secretId" } else { "<none>" }

  $result.ProbeModel = Get-AiProbeModel -Tool $Tool -Profile $Profile
  return $result
}

function Get-AiProfileProbePlan {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile
  )

  $mode = Get-AiProfileMode -Profile $Profile
  if ($mode -ne "api") {
    return @{ Early = [pscustomobject]@{ Status = "skip"; LatencyMs = 0; Method = $null; Error = "subscription mode (no remote probe)" } }
  }

  $target = Get-AiProfileProbeTarget -Tool $Tool -Profile $Profile
  if (-not $target.BaseOrigin) {
    return @{ Early = [pscustomobject]@{ Status = "down"; LatencyMs = 0; Method = $null; Error = "missing base_url" } }
  }
  if (-not $target.SecretOk) {
    return @{ Early = [pscustomobject]@{ Status = "down"; LatencyMs = 0; Method = $null; Error = "missing credentials" } }
  }

  $origin = [string]$target.BaseOrigin
  $origin = $origin.TrimEnd('/')
  $candidates = @()
  $effLabel = $null; $altLabel = $null

  if ($Tool -eq "claude") {
    $apiBase = if ($origin -match '/v1$') { ($origin -replace '/v1$', '') } else { $origin }
    $candidates += @{
      Label = "messages"
      Url   = Join-Path-Uri $apiBase "v1/messages"
      Body  = @{ model = $target.ProbeModel; max_tokens = 1; messages = @(@{ role = "user"; content = "." }) } |
        ConvertTo-Json -Depth 5 -Compress
      Check = "messages"
    }
  } else {
    $hasVersion   = $origin -match '/v\d+$'
    $responsesRel = if ($hasVersion) { "responses" } else { "v1/responses" }
    $chatRel      = if ($hasVersion) { "chat/completions" } else { "v1/chat/completions" }
    $model        = if ($target.ProbeModel) { $target.ProbeModel } else { "probe" }
    $candidates += @{
      Label = "responses"
      Url   = Join-Path-Uri $origin $responsesRel
      Body  = @{ model = $model; input = "."; max_output_tokens = 1 } | ConvertTo-Json -Depth 5 -Compress
      Check = "responses"
    }
    $candidates += @{
      Label = "chat"
      Url   = Join-Path-Uri $origin $chatRel
      Body  = @{ model = $model; max_tokens = 1; messages = @(@{ role = "user"; content = "." }) } |
        ConvertTo-Json -Depth 5 -Compress
      Check = "chat"
    }
    # verdict endpoint = the configured wire_api (default responses)
    $cfgPath = Get-CodexProfilePath -Profile $Profile
    $wireApi = $null
    if ($cfgPath -and (Test-Path -LiteralPath $cfgPath)) {
      $wireApi = Get-TomlStringValue -Path $cfgPath -Key "wire_api"
    }
    $effLabel = if ($wireApi -and $wireApi -match "chat") { "chat" } else { "responses" }
    $altLabel = if ($effLabel -eq "chat") { "responses" } else { "chat" }
  }

  return @{ Headers = $target.Headers; Kind = $Tool; Candidates = $candidates; EffLabel = $effLabel; AltLabel = $altLabel }
}

function Invoke-AiProbeRequest {
  param($Url, $Headers, $Body, [int]$TimeoutSec = 20)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $r = [pscustomobject]@{ Ok = $false; Code = 0; LatencyMs = 0; Detail = $null; Body = $null }
  try {
    $j = Invoke-RestMethod -Uri $Url -Method Post -Headers $Headers -Body $Body `
      -ContentType "application/json" -TimeoutSec $TimeoutSec -ErrorAction Stop
    $sw.Stop()
    $r.Code = 200
    $r.LatencyMs = [int]$sw.ElapsedMilliseconds
    $r.Body = $j
  } catch {
    $sw.Stop()
    $r.LatencyMs = [int]$sw.ElapsedMilliseconds
    if ($_.Exception.Response) {
      $r.Code = [int]$_.Exception.Response.StatusCode
      $bodyText = [string]$_.ErrorDetails.Message
      if ($bodyText) {
        try {
          $bodyJson = $bodyText | ConvertFrom-Json -ErrorAction Stop
          $message = if ($bodyJson.error -and $bodyJson.error.message) { [string]$bodyJson.error.message } elseif ($bodyJson.message) { [string]$bodyJson.message } else { $null }
          if ($message) { $bodyText = $message }
        } catch { }
        $bodyText = ConvertFrom-AiPrintableUnicodeEscapes $bodyText
        $bodyText = ($bodyText -replace "\s+", " ").Trim()
        if ($bodyText.Length -gt 240) { $bodyText = $bodyText.Substring(0, 240) }
        $r.Detail = "HTTP $($r.Code) $bodyText"
      } else {
        $r.Detail = "HTTP $($r.Code)"
      }
    } else {
      $r.Detail = $_.Exception.Message
    }
  }
  return $r
}

function Test-AiProbeBody {
  param($Req, [string]$Check)
  if ($Req.Code -lt 200 -or $Req.Code -ge 300) { return }
  $valid = $false
  $j = $Req.Body
  switch ($Check) {
    "messages"  { $valid = (($j.content -is [array]) -and ($j.content.Count -gt 0)) -or ($j.type -eq "message") }
    "responses" { $valid = (($j.output -is [array] -and $j.output.Count -gt 0) -or $j.output_text -or $j.status -eq "completed") }
    "chat"      { $valid = (($j.choices -is [array]) -and ($j.choices.Count -gt 0)) }
  }
  $Req.Ok = $valid
  if (-not $valid -and -not $Req.Detail) { $Req.Detail = "200 but no generated content" }
}

function ConvertFrom-AiPrintableUnicodeEscapes {
  param([AllowNull()][string]$Text)
  if (-not $Text) { return "" }
  $decoded = [regex]::Replace($Text, '\\u([0-9a-fA-F]{4})', {
      param($match)
      $code = [Convert]::ToInt32($match.Groups[1].Value, 16)
      if ($code -lt 0x20 -or ($code -ge 0x7f -and $code -lt 0xa0)) { return "?" }
      return [char]$code
    })
  return [regex]::Replace($decoded, '[\x00-\x1f\x7f-\x9f]', '?')
}

function Get-AiFallbackDisplayWidth {
  param([AllowNull()][string]$Text)
  if (-not $Text) { return 0 }
  $width = 0
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $code = if ([char]::IsHighSurrogate($Text[$i]) -and ($i + 1) -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) {
      $value = [char]::ConvertToUtf32($Text[$i], $Text[$i + 1])
      $i += 1
      $value
    } else { [int]$Text[$i] }
    if ($code -ge 0xd800 -and $code -le 0xdfff) {
      $width += 1
      continue
    }
    $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory([char]::ConvertFromUtf32($code), 0)
    if ($category -in @(
        [Globalization.UnicodeCategory]::Control,
        [Globalization.UnicodeCategory]::Format,
        [Globalization.UnicodeCategory]::NonSpacingMark,
        [Globalization.UnicodeCategory]::EnclosingMark
      )) { continue }
    $isWide =
      ($code -ge 0x1100 -and $code -le 0x115f) -or $code -eq 0x2329 -or $code -eq 0x232a -or
      ($code -ge 0x2e80 -and $code -le 0xa4cf) -or ($code -ge 0xac00 -and $code -le 0xd7a3) -or
      ($code -ge 0xf900 -and $code -le 0xfaff) -or ($code -ge 0xfe10 -and $code -le 0xfe19) -or
      ($code -ge 0xfe30 -and $code -le 0xfe6f) -or ($code -ge 0xff00 -and $code -le 0xff60) -or
      ($code -ge 0xffe0 -and $code -le 0xffe6) -or ($code -ge 0x1f1e6 -and $code -le 0x1f1ff) -or
      ($code -ge 0x1f300 -and $code -le 0x1faff)
    $width += if ($isWide) { 2 } else { 1 }
  }
  return $width
}

function Get-AiDisplayWidth {
  param([AllowNull()][string]$Text)
  if (-not $Text) { return 0 }
  try { return [int]$Host.UI.RawUI.LengthInBufferCells($Text) } catch { return Get-AiFallbackDisplayWidth $Text }
}

function Limit-AiDisplayText {
  param(
    [AllowNull()][string]$Text,
    [int]$MaxWidth
  )
  if (-not $Text -or $MaxWidth -le 0) { return "" }
  if ((Get-AiDisplayWidth $Text) -le $MaxWidth) { return $Text }
  $suffix = if ($MaxWidth -gt 3) { "..." } else { "" }
  $limit = [Math]::Max(0, $MaxWidth - (Get-AiDisplayWidth $suffix))
  $result = [System.Text.StringBuilder]::new()
  $width = 0
  $elements = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)
  while ($elements.MoveNext()) {
    $element = $elements.GetTextElement()
    $elementWidth = Get-AiDisplayWidth $element
    if (($width + $elementWidth) -gt $limit) { break }
    [void]$result.Append($element)
    $width += $elementWidth
  }
  return $result.ToString() + $suffix
}

function Get-AiHealthOutputWidth {
  $width = $script:AiHealthMaxOutputWidth
  $configured = 0
  if ([int]::TryParse($env:AI_HEALTH_COLUMNS, [ref]$configured) -and $configured -gt 0) {
    return [Math]::Min($width, $configured)
  }
  if (-not [Console]::IsOutputRedirected) {
    try {
      if ([Console]::WindowWidth -gt 0) { $width = [Math]::Min($width, [Console]::WindowWidth) }
    } catch { }
  }
  return [Math]::Max(1, $width)
}

function ConvertTo-AiProbeError {
  param([string]$Detail)
  if (-not $Detail) { return "" }
  if (Test-AiProbeModelUnsupported $Detail) { return "probe model unsupported; set probe_model" }
  if ($Detail -match "^(HTTP \d|200 but)") { return $Detail }
  $l = $Detail.ToLower()
  if ($l -match "timeout|canceled|timed out|httpclient\.timeout") { return "timeout" }
  if ($l -match "ssl|handshake|eproto|sslv3|certificate|trust") { return "TLS handshake failed" }
  if ($l -match "econnrefused|connection refused") { return "connection refused" }
  if ($l -match "enotfound|getaddrinfo|nodata|getaddr|dns") { return "DNS failed" }
  if ($l -match "econnreset|socket hang up|reset by peer|reset") { return "connection reset" }
  return $Detail
}

function Test-AiProbeModelUnsupported {
  param([string]$Detail)
  if (-not $Detail) { return $false }
  $l = (ConvertFrom-AiPrintableUnicodeEscapes $Detail).ToLowerInvariant()
  return ($l -match "no available providers|model_not_found|model not found|model does not exist|unknown model|unsupported model|model .*not supported|not support.*model|invalid model|model_not_supported|模型不存在|模型.*不存在|请检查模型代码")
}

function ConvertTo-AiHealthDisplayError {
  param([string]$Detail)
  if (-not $Detail) { return "" }
  $text = ((ConvertFrom-AiPrintableUnicodeEscapes $Detail) -replace "\s+", " ").Trim()
  function ShortProbeDetail([string]$Item) {
    $itemText = ($Item -replace "\s+", " ").Trim()
    if (Test-AiProbeModelUnsupported $itemText) {
      return "probe model unsupported; set probe_model"
    }
    if ($itemText -match "^(HTTP \d{3})(?:\s+(.+))?$") {
      $code = $Matches[1]
      $body = if ($Matches.Count -gt 2) { $Matches[2] } else { "" }
      if (-not $body) { return $code }
      try {
        $json = $body | ConvertFrom-Json -ErrorAction Stop
        $msg = $null
        if ($json.error -and $json.error.message) { $msg = [string]$json.error.message }
        elseif ($json.message) { $msg = [string]$json.message }
        elseif ($json.error) { $msg = [string]$json.error }
        elseif ($json.type) { $msg = [string]$json.type }
        if ($msg) { return ($code + " " + (($msg -replace "\s+", " ").Trim())) }
      } catch { }
      if ($body -match '"message"\s*:\s*"([^"]+)"') {
        return ($code + " " + (($Matches[1] -replace "\s+", " ").Trim()))
      }
      return $itemText
    }
    return $itemText
  }
  if ($text -match "^(POST\s+/\S+\s+->\s+)(.+?)(;\s+/\S+\s+->\s+)(.+)$") {
    $prefix = $Matches[1]
    $first = $Matches[2]
    $middle = $Matches[3]
    $second = $Matches[4]
    return $prefix + (ShortProbeDetail $first) + $middle + (ShortProbeDetail $second)
  }
  if ($text -match "^(POST\s+/\S+\s+->\s+)(.+?)(;\s+but\s+/\S+\s+works\s+->\s+.+)$") {
    $prefix = $Matches[1]
    $first = $Matches[2]
    $suffix = $Matches[3]
    return $prefix + (ShortProbeDetail $first) + $suffix
  }
  if ($text -match "^(POST\s+/\S+\s+)(.+)$") {
    $prefix = $Matches[1]
    $detail = $Matches[2]
    return $prefix + (ShortProbeDetail $detail)
  }
  return ShortProbeDetail $text
}

function Resolve-AiProfileHealth {
  param($Plan, $Results, [int]$DegradedMs = 8000)

  if ($Plan.Kind -eq "claude") {
    $m = $Results["messages"]
    if ($m.Ok) {
      $st = if ($m.LatencyMs -gt $DegradedMs) { "degraded" } else { "healthy" }
      return [pscustomobject]@{ Status = $st; LatencyMs = $m.LatencyMs; Method = "generation"; Error = $null }
    }
    if (Test-AiProbeModelUnsupported $m.Detail) {
      return [pscustomobject]@{ Status = "degraded"; LatencyMs = $m.LatencyMs; Method = "none"; Error = ("POST /v1/messages " + $m.Detail) }
    }
    $md = ConvertTo-AiProbeError $m.Detail
    if ($m.Code -eq 429 -or ($m.Code -ge 500 -and $m.Code -lt 600)) {
      return [pscustomobject]@{ Status = "degraded"; LatencyMs = $m.LatencyMs; Method = "none"; Error = ("POST /v1/messages " + $md + " (transient)") }
    }
    return [pscustomobject]@{ Status = "down"; LatencyMs = $m.LatencyMs; Method = "none"; Error = ("POST /v1/messages " + $md) }
  }

  # codex: verdict = the endpoint matching the configured wire_api.
  $eff = $Results[$Plan.EffLabel]
  $alt = $Results[$Plan.AltLabel]
  if ($eff.Ok) {
    $st = if ($eff.LatencyMs -gt $DegradedMs) { "degraded" } else { "healthy" }
    return [pscustomobject]@{ Status = $st; LatencyMs = $eff.LatencyMs; Method = "generation:$($Plan.EffLabel)"; Error = $null }
  }
  $effD = ConvertTo-AiProbeError $eff.Detail
  $altD = ConvertTo-AiProbeError $alt.Detail
  $note = "POST /$($Plan.EffLabel) -> $($eff.Detail)"
  if ($alt.Ok) {
    $note += "; but /$($Plan.AltLabel) works -> set wire_api = `"$($Plan.AltLabel)`" in config.toml"
    return [pscustomobject]@{ Status = "degraded"; LatencyMs = $eff.LatencyMs; Method = "none"; Error = $note }
  }
  if ((Test-AiProbeModelUnsupported $eff.Detail) -or (Test-AiProbeModelUnsupported $alt.Detail)) {
    $note += "; /$($Plan.AltLabel) -> $($alt.Detail)"
    return [pscustomobject]@{ Status = "degraded"; LatencyMs = $eff.LatencyMs; Method = "none"; Error = $note }
  }
  $note = "POST /$($Plan.EffLabel) -> $effD"
  if ($eff.Code -eq 429 -or ($eff.Code -ge 500 -and $eff.Code -lt 600)) {
    $note += "; /$($Plan.AltLabel) -> $altD (transient)"
    return [pscustomobject]@{ Status = "degraded"; LatencyMs = $eff.LatencyMs; Method = "none"; Error = $note }
  }
  $note += "; /$($Plan.AltLabel) -> $altD"
  return [pscustomobject]@{ Status = "down"; LatencyMs = $eff.LatencyMs; Method = "none"; Error = $note }
}

function Get-AiProfileHealth {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile,
    [int]$TimeoutSec = 20,
    [int]$DegradedMs = 8000
  )

  # Single-profile path (used by `cx doctor`, switch-time, etc.). `cc/cx health`
  # builds plans for ALL profiles and fires requests concurrently via
  # Invoke-AiProbeRequest directly; this wrapper stays sequential for one-off use.
  $plan = Get-AiProfileProbePlan -Tool $Tool -Profile $Profile
  if ($plan.ContainsKey("Early")) { return $plan.Early }

  $results = @{}
  foreach ($c in $plan.Candidates) {
    $req = Invoke-AiProbeRequest -Url $c.Url -Headers $plan.Headers -Body $c.Body -TimeoutSec $TimeoutSec
    Test-AiProbeBody -Req $req -Check $c.Check
    $results[$c.Label] = $req
  }
  return Resolve-AiProfileHealth -Plan $plan -Results $results -DegradedMs $DegradedMs
}

function Get-AiHealthCachePath {
  return (Join-Path $script:AiConfigDir "health.json")
}

function Read-AiHealthCache {
  $path = Get-AiHealthCachePath
  if (-not (Test-Path -LiteralPath $path)) { return @{} }
  try {
    $obj = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $h = @{}
    if ($obj) { foreach ($prop in $obj.PSObject.Properties) { $h[$prop.Name] = $prop.Value } }
    return $h
  } catch { return @{} }
}

function Write-AiHealthCacheEntry {
  param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)]$Entry)
  $path = Get-AiHealthCachePath
  $h = Read-AiHealthCache
  $h[$Key] = $Entry
  New-Item -ItemType Directory -Force -Path $script:AiConfigDir | Out-Null
  $h | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Clear-AiHealthCache {
  $path = Get-AiHealthCachePath
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
}

function Get-AiProfileHealthCached {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile,
    [switch]$Fresh,
    [switch]$CacheOnly,
    [int]$TtlSec = 300
  )

  $name = Get-AiProfileName -Profile $Profile
  $key = "$Tool.$name"

  # Fresh cache hit short-circuits (whether or not CacheOnly).
  if (-not $Fresh) {
    $cache = Read-AiHealthCache
    if ($cache.ContainsKey($key)) {
      $entry = $cache[$key]
      $probedAt = 0
      try { $probedAt = [int64]$entry.probedAt } catch { }
      $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      if ($probedAt -gt 0 -and ($now - $probedAt) -lt $TtlSec) {
        return [pscustomobject]@{
          Status    = [string]$entry.status
          LatencyMs = [int]$entry.latencyMs
          Method    = [string]$entry.method
          Error     = $entry.error
          ProbedAt  = $probedAt
          Cached    = $true
        }
      }
    }
  }

  # CacheOnly: never probe (keeps `list`/`status`/switch instant — a stale or
  # unprobed entry shows as skip ⏭, matching the lean list). Use `health` /
  # `status --refresh` to force a live probe.
  if ($CacheOnly) {
    return [pscustomobject]@{ Status = "skip"; LatencyMs = 0; Method = $null; Error = $null; ProbedAt = 0; Cached = $false }
  }

  $result = Get-AiProfileHealth -Tool $Tool -Profile $Profile
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  Write-AiHealthCacheEntry -Key $key -Entry ([pscustomobject]@{
      status    = $result.Status
      latencyMs = $result.LatencyMs
      method    = $result.Method
      error     = $result.Error
      probedAt  = $now
    })

  return [pscustomobject]@{
    Status    = $result.Status
    LatencyMs = $result.LatencyMs
    Method    = $result.Method
    Error     = $result.Error
    ProbedAt  = $now
    Cached    = $false
  }
}

function Format-AiHealthCell {
  param([AllowNull()]$H)
  if (-not $H) { return "?" }
  $code = $null
  if ($H.Error -and ($H.Error -match 'HTTP (\d{3})')) { $code = $Matches[1] }
  switch ($H.Status) {
    "healthy"  { "🟢" + $H.LatencyMs + "ms" }
    "degraded" { "🟡" + ($(if ($code) { $code } else { "slow" })) }
    "down"     { "🔴" + ($(if ($code) { $code } else { "err" })) }
    "skip"     { "⏭" }
    default    { "?" }
  }
}

function Format-AiHealthStatusLine {
  param([AllowNull()]$H)
  $line = "  Health: " + (Format-AiHealthCell $H)
  if ($H -and $H.Error) { $line += "  " + (ConvertTo-AiHealthDisplayError ([string]$H.Error)) }
  return Limit-AiDisplayText $line (Get-AiHealthOutputWidth)
}

function Test-AiFreshFlag {
  param([AllowNull()][string[]]$Tokens)
  if (-not $Tokens) { return $false }
  foreach ($t in $Tokens) { if ($t -in @("--fresh", "-f", "--refresh", "-r")) { return $true } }
  return $false
}

function Get-AiHealthCellCached {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [Parameter(Mandatory = $true)]$Profile,
    [int]$TtlSec = 300
  )
  $key = "$Tool." + (Get-AiProfileName -Profile $Profile)
  $cache = Read-AiHealthCache
  if (-not $cache.ContainsKey($key)) { return "⏭" }
  $e = $cache[$key]
  $probedAt = 0
  try { $probedAt = [int64]$e.probedAt } catch { }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($probedAt -gt 0 -and ($now - $probedAt) -lt $TtlSec) {
    return Format-AiHealthCell $e
  }
  return "⏭"
}

function Get-AiHealthyProfileName {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  $defaultName = Get-AiDefaultProfileName -Tool $Tool
  $profiles = @(Get-AiToolProfiles -Tool $Tool | Where-Object { Test-AiProfileEnabled -Profile $_ })
  $defaultProfile = $null
  $others = @()
  foreach ($p in $profiles) {
    if ((Get-AiProfileName -Profile $p) -eq $defaultName) { $defaultProfile = $p } else { $others += $p }
  }
  $ordered = if ($defaultProfile) { @($defaultProfile) + $others } else { $others }

  foreach ($p in $ordered) {
    # Cache-only: no-arg cc/cx must stay instant. If the cache is empty/stale
    # every entry reads skip (not "down"), so the default is chosen without
    # probing. Run `cc health` first to populate health for auto-failover.
    $h = Get-AiProfileHealthCached -Tool $Tool -Profile $p -CacheOnly
    # Only auto-select a profile with a cached POSITIVE signal (healthy/
    # degraded). Unprobed api profiles and subscription profiles both read
    # "skip" and are NOT auto-selected (we can't confirm they're up). Run
    # `cc health` first to populate health for real auto-failover.
    if ($h.Status -eq "healthy" -or $h.Status -eq "degraded") {
      return (Get-AiProfileName -Profile $p)
    }
  }
  return $defaultName
}

function Sync-AiHealthCache {
  param([Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool)

  $cache = Read-AiHealthCache
  if ($cache.Count -eq 0) { return }
  $valid = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($p in Get-AiToolProfiles -Tool $Tool) {
    [void]$valid.Add("$Tool." + (Get-AiProfileName -Profile $p))
  }
  $changed = $false
  foreach ($k in @($cache.Keys)) {
    if ($k.StartsWith("$Tool.") -and -not $valid.Contains($k)) { $cache.Remove($k); $changed = $true }
  }
  if ($changed) {
    $path = Get-AiHealthCachePath
    New-Item -ItemType Directory -Force -Path $script:AiConfigDir | Out-Null
    $cache | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
  }
}

function Show-AiHealth {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Tool,
    [switch]$Fresh,
    [int]$DegradedMs = 8000,
    [int]$TimeoutSec = 10
  )
  Sync-AiHealthCache -Tool $Tool
  $label = if ($Tool -eq "codex") { "Codex" } else { "Claude Code" }
  $saved = Get-AiSavedProfileName -Tool $Tool
  $profiles = @(Get-AiToolProfiles -Tool $Tool)

  # Phase 1 (instant): build a plan per profile. Cached/Early results resolve
  # immediately; stale/missing profiles queue real requests. $display holds the
  # current cell/method/note for each profile so the table can be redrawn as
  # probes land (pending rows show ⏳…).
  $tasks = [System.Collections.Generic.List[object]]::new()
  $display = @{}            # name -> @{ Health; Method; Note; Pending }
  $plans = @{}              # name -> plan (for verdict)
  $expected = @{}           # name -> #candidates (1 claude / 2 codex)
  $cellOf = {
    param($h)
    if ($h) { Format-AiHealthCell $h } else { "?" }
  }
  foreach ($p in $profiles) {
    $n = Get-AiProfileName -Profile $p
    $plan = Get-AiProfileProbePlan -Tool $Tool -Profile $p
    if ($plan.ContainsKey("Early")) {
      $e = $plan.Early
      $display[$n] = @{ Health = (& $cellOf $e); Method = ($(if ($e.Method) { $e.Method } else { "-" })); Note = ($(if ($e.Error) { ConvertTo-AiHealthDisplayError $e.Error } else { "" })); Pending = $false }
      continue
    }
    $plans[$n] = $plan
    $useCache = $false
    if (-not $Fresh) {
      $cached = Get-AiProfileHealthCached -Tool $Tool -Profile $p -CacheOnly
      if ($cached.Cached) {
        $display[$n] = @{ Health = (& $cellOf $cached); Method = ($(if ($cached.Method) { $cached.Method } else { "-" })); Note = ($(if ($cached.Error) { ConvertTo-AiHealthDisplayError $cached.Error } else { "" })); Pending = $false }
        $useCache = $true
      }
    }
    if (-not $useCache) {
      $display[$n] = @{ Health = "⏳…"; Method = "-"; Note = "probing…"; Pending = $true }
      foreach ($c in $plan.Candidates) {
        $tasks.Add([pscustomobject]@{
          Name = $n; Label = $c.Label; Url = $c.Url; Headers = $plan.Headers; Body = $c.Body; Check = $c.Check; Timeout = $TimeoutSec
        })
      }
      $expected[$n] = @($plan.Candidates).Count
    }
  }

  $outputWidth = Get-AiHealthOutputWidth
  $buildLines = {
    param([int]$Tick = 0)
    $dots = ($Tick % 7) + 1
    $lines = @()
    $lines += Limit-AiDisplayText ("{0,-3} {1,-14} {2,-9} {3,-11} {4}" -f "Sel", "Name", "Health", "Method", "Note") $outputWidth
    $lines += Limit-AiDisplayText ("{0,-3} {1,-14} {2,-9} {3,-11} {4}" -f "---", "----", "------", "------", "----") $outputWidth
    foreach ($p in $profiles) {
      $n = Get-AiProfileName -Profile $p
      $d = $display[$n]
      if (-not $d) { $d = @{ Health = "?"; Method = "-"; Note = ""; Pending = $false } }
      if ($d.Pending) { $cell = "⏳"; $method = "-"; $note = "waiting ⏳" + ("." * $dots) }
      else { $cell = $d.Health; $method = $d.Method; $note = $d.Note }
      $sel = if ($n -eq $saved) { "*" } else { " " }
      $row = "{0,-3} {1,-14} {2,-9} {3,-11} {4}" -f $sel, $n, $cell, $method, $note
      $lines += Limit-AiDisplayText $row $outputWidth
    }
    $lines
  }

  # Probe block: builtins only (no engine functions in the child runsape). Body
  # is validated INSIDE the block — objects crossing the runsape boundary get
  # XML-serialized, so `-is [array]` would fail in the parent; returning only
  # primitives sidesteps that.
  $probeBlock = {
    $t = $_; $timeout = $t.Timeout
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = [pscustomobject]@{ Name = $t.Name; Label = $t.Label; Ok = $false; Code = 0; LatencyMs = 0; Detail = $null }
    try {
      $j = Invoke-RestMethod -Uri $t.Url -Method Post -Headers $t.Headers -Body $t.Body `
        -ContentType "application/json" -TimeoutSec $timeout -ErrorAction Stop
      $sw.Stop()
      $r.Code = 200; $r.LatencyMs = [int]$sw.ElapsedMilliseconds
      $valid = $false
      switch ($t.Check) {
        "messages"  { $valid = (($j.content -is [array]) -and ($j.content.Count -gt 0)) -or ($j.type -eq "message") }
        "responses" { $valid = (($j.output -is [array] -and $j.output.Count -gt 0) -or $j.output_text -or $j.status -eq "completed") }
        "chat"      { $valid = (($j.choices -is [array]) -and ($j.choices.Count -gt 0)) }
      }
      $r.Ok = $valid
      if (-not $valid) { $r.Detail = "200 but no generated content" }
    } catch {
      $sw.Stop()
      $r.LatencyMs = [int]$sw.ElapsedMilliseconds
      if ($_.Exception.Response) {
        $r.Code = [int]$_.Exception.Response.StatusCode
        $bodyText = [string]$_.ErrorDetails.Message
        if ($bodyText) {
          try {
            $bodyJson = $bodyText | ConvertFrom-Json -ErrorAction Stop
            $message = if ($bodyJson.error -and $bodyJson.error.message) { [string]$bodyJson.error.message } elseif ($bodyJson.message) { [string]$bodyJson.message } else { $null }
            if ($message) { $bodyText = $message }
          } catch { }
          $bodyText = [regex]::Replace($bodyText, '\\u([0-9a-fA-F]{4})', {
              param($match)
              $code = [Convert]::ToInt32($match.Groups[1].Value, 16)
              if ($code -lt 0x20 -or ($code -ge 0x7f -and $code -lt 0xa0)) { return "?" }
              return [char]$code
            })
          $bodyText = [regex]::Replace($bodyText, '[\x00-\x1f\x7f-\x9f]', '?')
          $bodyText = ($bodyText -replace "\s+", " ").Trim()
          if ($bodyText.Length -gt 240) { $bodyText = $bodyText.Substring(0, 240) }
          $r.Detail = "HTTP " + $r.Code + " " + $bodyText
        } else { $r.Detail = "HTTP " + $r.Code }
      }
      else { $r.Detail = $_.Exception.Message }
    }
    $r
  }

  # Cache + display update for a profile once ALL its candidates are in.
  $finalize = {
    param($n)
    $h = Resolve-AiProfileHealth -Plan $plans[$n] -Results $reqs[$n] -DegradedMs $DegradedMs
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-AiHealthCacheEntry -Key "$Tool.$n" -Entry ([pscustomobject]@{
        status = $h.Status; latencyMs = $h.LatencyMs; method = $h.Method; error = $h.Error; probedAt = $now
      })
    $display[$n] = @{ Health = (Format-AiHealthCell $h); Method = ($(if ($h.Method) { $h.Method } else { "-" })); Note = ($(if ($h.Error) { ConvertTo-AiHealthDisplayError $h.Error } else { "" })); Pending = $false }
  }

  $footer = "  (health " + ($(if ($Fresh) { "re-probed (fresh, parallel)" } else { "cached <=5min" })) + "; '" + $Tool + " health --fresh' re-probe, '" + $Tool + " health-clear' clears)"
  $titleStr = "$label profile health ($script:AiRegistryPath):"
  $pendingNames = @($expected.Keys)
  $isTty = (-not [Console]::IsOutputRedirected) -or ($env:AI_HEALTH_LIVE -eq '1')

  if ($pendingNames.Count -gt 0 -and $isTty) {
    # === Animated in-place table (TTY only) ===
    # Probes run in background runsapes (concurrency); the FOREGROUND ticks every
    # 300ms and redraws the table with [Console]::Write + relative cursor-up
    # (\e[<n>A). Only the main thread writes to the console, so there's no host
    # contention (the earlier in-place attempt used \e7/\e8 save-restore + Write-
    # Host in a ForEach-Object -Parallel consumer, which deadlocked). Pending rows
    # show "waiting ⏳" + dots cycling 1..7; each row fills when its probe lands.
    $esc = [char]27
    $probeScriptStr = @'
param($Candidates, $Headers, $TimeoutSec)
foreach ($c in $Candidates) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $r = [pscustomobject]@{ Label = $c.Label; Ok = $false; Code = 0; LatencyMs = 0; Detail = $null }
  try {
    $j = Invoke-RestMethod -Uri $c.Url -Method Post -Headers $Headers -Body $c.Body -ContentType "application/json" -TimeoutSec $TimeoutSec -ErrorAction Stop
    $sw.Stop(); $r.Code = 200; $r.LatencyMs = [int]$sw.ElapsedMilliseconds
    $valid = $false
    switch ($c.Check) {
      "messages"  { $valid = (($j.content -is [array]) -and ($j.content.Count -gt 0)) -or ($j.type -eq "message") }
      "responses" { $valid = (($j.output -is [array] -and $j.output.Count -gt 0) -or $j.output_text -or $j.status -eq "completed") }
      "chat"      { $valid = (($j.choices -is [array]) -and ($j.choices.Count -gt 0)) }
    }
    $r.Ok = $valid; if (-not $valid) { $r.Detail = "200 but no generated content" }
  } catch {
    $sw.Stop(); $r.LatencyMs = [int]$sw.ElapsedMilliseconds
    if ($_.Exception.Response) {
      $r.Code = [int]$_.Exception.Response.StatusCode
      $bodyText = [string]$_.ErrorDetails.Message
      if ($bodyText) {
        try {
          $bodyJson = $bodyText | ConvertFrom-Json -ErrorAction Stop
          $message = if ($bodyJson.error -and $bodyJson.error.message) { [string]$bodyJson.error.message } elseif ($bodyJson.message) { [string]$bodyJson.message } else { $null }
          if ($message) { $bodyText = $message }
        } catch { }
        $bodyText = [regex]::Replace($bodyText, '\\u([0-9a-fA-F]{4})', {
            param($match)
            $code = [Convert]::ToInt32($match.Groups[1].Value, 16)
            if ($code -lt 0x20 -or ($code -ge 0x7f -and $code -lt 0xa0)) { return "?" }
            return [char]$code
          })
        $bodyText = [regex]::Replace($bodyText, '[\x00-\x1f\x7f-\x9f]', '?')
        $bodyText = ($bodyText -replace "\s+", " ").Trim()
        if ($bodyText.Length -gt 240) { $bodyText = $bodyText.Substring(0, 240) }
        $r.Detail = "HTTP " + $r.Code + " " + $bodyText
      } else {
        $r.Detail = "HTTP " + $r.Code
      }
    } else { $r.Detail = $_.Exception.Message }
  }
  $r
}
'@
    $runspaces = @{}
    try {
      foreach ($n in $pendingNames) {
        $plan = $plans[$n]
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($probeScriptStr).AddArgument(@($plan.Candidates)).AddArgument($plan.Headers).AddArgument($TimeoutSec)
        $runspaces[$n] = @{ PS = $ps; Handle = $ps.BeginInvoke(); Plan = $plan }
      }

      [Console]::WriteLine((Limit-AiDisplayText $titleStr $outputWidth))
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $nlines = (& $buildLines 0).Count
      foreach ($l in & $buildLines 0) { [Console]::Write($l + "`n") }
      while ($pendingNames.Count -gt 0) {
        Start-Sleep -Milliseconds 300
        $done = @()
        foreach ($n in $pendingNames) {
          if ($runspaces[$n].Handle.IsCompleted) {
            $raw = $runspaces[$n].PS.EndInvoke($runspaces[$n].Handle)
            $results = @{}; foreach ($r in $raw) { $results[$r.Label] = $r }
            $h = Resolve-AiProfileHealth -Plan $runspaces[$n].Plan -Results $results -DegradedMs $DegradedMs
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Write-AiHealthCacheEntry -Key "$Tool.$n" -Entry ([pscustomobject]@{ status = $h.Status; latencyMs = $h.LatencyMs; method = $h.Method; error = $h.Error; probedAt = $now })
            $display[$n] = @{ Health = (Format-AiHealthCell $h); Method = ($(if ($h.Method) { $h.Method } else { "-" })); Note = ($(if ($h.Error) { ConvertTo-AiHealthDisplayError $h.Error } else { "" })); Pending = $false }
            $done += $n
          }
        }
        if ($done.Count -gt 0) { $pendingNames = @($pendingNames | Where-Object { $_ -notin $done }) }
        [Console]::Write($esc + "[" + $nlines + "A")
        $tick = [int][math]::Floor($sw.ElapsedMilliseconds / 400)
        foreach ($l in & $buildLines $tick) { [Console]::Write("`r" + $esc + "[K" + $l + "`n") }
      }
    } finally {
      foreach ($n in $expected.Keys) { if ($runspaces[$n] -and $runspaces[$n].PS) { $runspaces[$n].PS.Dispose() } }
    }
    [Console]::WriteLine((Limit-AiDisplayText $footer $outputWidth))
    return
  }

  # === Streaming fallback (pipes / CI / non-TTY): one line per completion ===
  Write-Host (Limit-AiDisplayText $titleStr $outputWidth)
  if ($tasks.Count -gt 0) {
    $probeProfileCount = 0
    foreach ($n in $expected.Keys) { $probeProfileCount += 1 }
    Write-Host (Limit-AiDisplayText ("  probing {0} profile(s) in parallel (results stream as they resolve)…" -f $probeProfileCount) $outputWidth) -ForegroundColor DarkGray
    $reqs = @{}; $doneCount = @{}
    $tasks | Microsoft.PowerShell.Core\ForEach-Object -Parallel $probeBlock -ThrottleLimit ([Math]::Max(8, $tasks.Count)) | ForEach-Object {
      if (-not $reqs.ContainsKey($_.Name)) { $reqs[$_.Name] = @{}; $doneCount[$_.Name] = 0 }
      $reqs[$_.Name][$_.Label] = $_
      $doneCount[$_.Name] += 1
      if ($doneCount[$_.Name] -ge $expected[$_.Name]) {
        & $finalize $_.Name
        $d = $display[$_.Name]
        Write-Host (Limit-AiDisplayText ("    {0} {1,-14} {2}" -f $d.Health, $_.Name, $d.Note) $outputWidth) -ForegroundColor DarkGray
      }
    }
  }

  # Final registry-ordered summary (cached profiles land here too).
  Write-Host ""
  foreach ($line in & $buildLines 0) { Write-Host $line }
  Write-Host (Limit-AiDisplayText $footer $outputWidth) -ForegroundColor DarkGray
}
