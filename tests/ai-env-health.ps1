[CmdletBinding()]
param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

# Offline health-subsystem tests. No real network: Get-AiProfileHealth is
# replaced with a fake that maps profile names to canned results, so we test
# the cache / prune / auto-select / status-mapping / command logic only.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestProcessEnvironment.ps1")
$previousProcessEnvironment = Save-TestProcessEnvironment

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-env-health-" + [guid]::NewGuid().ToString("N"))
$testHome = Join-Path $tmpRoot "home"
$previousAiEnvHome = $env:AI_ENV_HOME
$previousNonInteractive = $env:AI_ENV_NONINTERACTIVE
$previousHealthColumns = $env:AI_HEALTH_COLUMNS
$previousAnthropicModel = $env:ANTHROPIC_MODEL
$previousAnthropicDefaultHaikuModel = $env:ANTHROPIC_DEFAULT_HAIKU_MODEL
$env:AI_ENV_HOME = $testHome
$env:AI_ENV_NONINTERACTIVE = "1"
$env:AI_HEALTH_COLUMNS = "80"
Remove-Item Env:ANTHROPIC_MODEL -ErrorAction SilentlyContinue
Remove-Item Env:ANTHROPIC_DEFAULT_HAIKU_MODEL -ErrorAction SilentlyContinue

$aiEnvDir = Join-Path $testHome ".ai-env"
$profilesPath = Join-Path $aiEnvDir "profiles.json"
$secretsDir = Join-Path $testHome ".ai-secrets"
$secretsPath = Join-Path $secretsDir "secrets.toml"
$healthPath = Join-Path $aiEnvDir "health.json"

function Assert-Eq($Name, $Actual, $Expected) {
  if ($Actual -ne $Expected) { throw "ASSERT $Name : expected '$Expected', got '$Actual'" }
  Write-Host "  ok: $Name = '$Actual'"
}
function Assert-Match($Name, $Actual, $Pattern) {
  if ($Actual -notmatch $Pattern) { throw "ASSERT $Name : '$Actual' did not match /$Pattern/" }
  Write-Host "  ok: $Name matches /$Pattern/"
}
function Get-TestDisplayWidth([string]$Text) {
  $width = 0
  foreach ($char in $Text.ToCharArray()) {
    $code = [int]$char
    $width += if (
      ($code -ge 0x1100 -and $code -le 0x115f) -or
      ($code -ge 0x2e80 -and $code -le 0xa4cf) -or
      ($code -ge 0xac00 -and $code -le 0xd7a3) -or
      ($code -ge 0xf900 -and $code -le 0xfaff) -or
      ($code -ge 0xfe10 -and $code -le 0xfe6f) -or
      ($code -ge 0xff00 -and $code -le 0xff60)
    ) { 2 } else { 1 }
  }
  return $width
}
function Assert-LinesBounded($Name, [string]$Output, [int]$MaxWidth) {
  foreach ($line in ($Output -split "`r?`n")) {
    $plain = $line -replace "`e\[[0-?]*[ -/]*[@-~]", ""
    $width = Get-TestDisplayWidth $plain
    if ($width -gt $MaxWidth) { throw "ASSERT $Name : line width $width exceeds $MaxWidth`: $plain" }
  }
  Write-Host "  ok: $Name <= $MaxWidth display columns"
}

try {
  New-Item -ItemType Directory -Force -Path $aiEnvDir, $secretsDir | Out-Null
  Copy-Item -LiteralPath (Join-Path $SourceDir "templates/profiles.json") -Destination $profilesPath -Force
  "" | Set-Content -LiteralPath $secretsPath -Encoding UTF8

  . (Join-Path $SourceDir "src/powershell/CxCc/CxCc.ps1")

  # --- FAKE the network probe: map profile names to canned health (no HTTP) ---
  $script:ProbeCalls = 0
  function Get-AiProfileHealth {
    param($Tool, $Profile, $TimeoutSec = 20, $DegradedMs = 6000)
    $script:ProbeCalls += 1
    switch (Get-AiProfileName -Profile $Profile) {
      "hgood" { [pscustomobject]@{ Status = "healthy";  LatencyMs = 120;  Method = "generation"; Error = $null } }
      "hbad"  { [pscustomobject]@{ Status = "down";     LatencyMs = 0;    Method = "none"; Error = "POST /v1/messages HTTP 401" } }
      "hslow" { [pscustomobject]@{ Status = "degraded"; LatencyMs = 9999; Method = "generation"; Error = "POST /v1/messages HTTP 429 (transient)" } }
      "hcn"   { [pscustomobject]@{ Status = "degraded"; LatencyMs = 10;   Method = "none"; Error = 'POST /v1/messages HTTP 400 {"type":"error","error":{"message":"[1211][模型不存在，请检查模型代码。]"}}' } }
      "hescaped" { [pscustomobject]@{ Status = "degraded"; LatencyMs = 10; Method = "none"; Error = ('POST /v1/messages HTTP 500 ' + [char]0x1b + '[2J{"error":{"message":"\u539f\u56e0\u8d85\u957f\uff1a\u8fd9\u662f\u4e00\u6bb5\u4e2d\u6587\u9519\u8bef\u539f\u56e0"}} trailing') } }
      default { [pscustomobject]@{ Status = "down"; LatencyMs = 0; Method = "none"; Error = "POST /v1/messages HTTP 404" } }
    }
  }

  # Register test api profiles (no secrets needed: we only probe via the fake
  # and resolve names, never actually switch into them).
  cc add-api hgood --base-url https://h.test | Out-Null
  cc add-api hbad  --base-url https://h.test | Out-Null
  cc add-api hslow --base-url https://h.test | Out-Null
  cc add-api hcn   --base-url https://h.test | Out-Null
  cc add-api hescaped --base-url https://h.test | Out-Null
  cc add-api cyc-a --base-url https://h.test | Out-Null
  cc add-api cyc-b --base-url https://h.test | Out-Null
  cc add-api h1m --base-url https://h.test | Out-Null

  Write-Host "[1] Format-AiHealthCell status icons"
  Assert-Match "healthy cell" (Format-AiHealthCell ([pscustomobject]@{ Status = "healthy"; LatencyMs = 120; Error = $null })) "🟢120ms"
  Assert-Match "degraded cell" (Format-AiHealthCell ([pscustomobject]@{ Status = "degraded"; Error = "HTTP 429 (transient)" })) "🟡429"
  Assert-Match "down cell" (Format-AiHealthCell ([pscustomobject]@{ Status = "down"; Error = "HTTP 401" })) "🔴401"
  Assert-Eq "skip cell" (Format-AiHealthCell ([pscustomobject]@{ Status = "skip"; Error = "x" })) "⏭"

  Write-Host "[2] probe-model set / clear"
  cc probe-model hgood my-sonnet | Out-Null
  $pm = (Get-AiProfileProbeTarget -Tool claude -Profile (Get-AiProfileByName -Tool claude -Name hgood)).ProbeModel
  Assert-Eq "probe_model set" $pm "my-sonnet"
  cc probe-model hgood | Out-Null
  $pm2 = (Get-AiProfileProbeTarget -Tool claude -Profile (Get-AiProfileByName -Tool claude -Name hgood)).ProbeModel
  Assert-Eq "probe_model cleared -> default haiku" $pm2 "claude-3-5-haiku-20241022"

  @(
    ""
    "[claude.hgood]"
    'ANTHROPIC_MODEL = "secret-sonnet"'
    'ANTHROPIC_AUTH_TOKEN = "sk-test-hgood"'
    ""
    "[claude.hescaped]"
    'ANTHROPIC_AUTH_TOKEN = "sk-test-hescaped"'
  ) | Add-Content -LiteralPath $secretsPath -Encoding UTF8
  $pm3 = (Get-AiProfileProbeTarget -Tool claude -Profile (Get-AiProfileByName -Tool claude -Name hgood)).ProbeModel
  Assert-Eq "probe_model clear -> ANTHROPIC_MODEL" $pm3 "secret-sonnet"

  cc add-api envmodel --base-url https://h.test --env ANTHROPIC_DEFAULT_HAIKU_MODEL=env-haiku | Out-Null
  $pm4 = (Get-AiProfileProbeTarget -Tool claude -Profile (Get-AiProfileByName -Tool claude -Name envmodel)).ProbeModel
  Assert-Eq "probe_model clear -> profile haiku env" $pm4 "env-haiku"
  cc probe-model h1m 'claude-opus-4-8[1m]' | Out-Null
  $h1mHeaders = (Get-AiProfileProbeTarget -Tool claude -Profile (Get-AiProfileByName -Tool claude -Name h1m)).Headers
  Assert-Eq "1m probe adds beta header" $h1mHeaders["anthropic-beta"] "context-1m-2025-08-07"
  cc probe-model h1m 'claude-opus-4-8' | Out-Null
  $h1mPlainHeaders = (Get-AiProfileProbeTarget -Tool claude -Profile (Get-AiProfileByName -Tool claude -Name h1m)).Headers
  if ($h1mPlainHeaders.ContainsKey("anthropic-beta")) { throw "plain probe_model should not add anthropic-beta" }
  Write-Host "  ok: plain probe_model omits beta header"

  Write-Host "[3] default show / set"
  cc default hbad | Out-Null
  Assert-Eq "default set" (Get-AiDefaultProfileName -Tool claude) "hbad"
  Assert-Match "default show" (& { cc default } 6>&1 | Out-String) "claude default = hbad"

  Write-Host "[4] cache write / hit / fresh"
  Clear-AiHealthCache
  $pgood = Get-AiProfileByName -Tool claude -Name hgood
  $r1 = Get-AiProfileHealthCached -Tool claude -Profile $pgood
  Assert-Eq "first probe cached=false" $r1.Cached $false
  Assert-Eq "first probe status=healthy" $r1.Status "healthy"
  Assert-Eq "second probe cached=true" (Get-AiProfileHealthCached -Tool claude -Profile $pgood).Cached $true
  Assert-Eq "fresh probe cached=false" (Get-AiProfileHealthCached -Tool claude -Profile $pgood -Fresh).Cached $false
  Assert-Match "health.json written" (Get-Content -Raw -LiteralPath $healthPath) "claude.hgood"

  Write-Host "[5] orphan prune (Sync-AiHealthCache)"
  $cache = Read-AiHealthCache
  $cache["claude.ghost"] = [pscustomobject]@{ status = "down"; latencyMs = 0; error = "orphan"; probedAt = 1 }
  $cache | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $healthPath
  Sync-AiHealthCache -Tool claude
  $after = Read-AiHealthCache
  if ($after.ContainsKey("claude.ghost")) { throw "prune did NOT remove orphan claude.ghost" }
  if (-not $after.ContainsKey("claude.hgood")) { throw "prune removed a still-valid entry claude.hgood" }
  Write-Host "  ok: orphan pruned, valid entry kept"

  Write-Host "[6] auto-select skips down, picks first non-down (default first)"
  cc default hbad | Out-Null   # default is down
  Assert-Eq "auto-select picks healthy hgood" (Get-AiHealthyProfileName -Tool claude) "hgood"

  Write-Host "[7] next cycle (Get-AiNextProfileName)"
  Save-AiSelectedProfile -Tool claude -Name cyc-a
  Assert-Eq "next after cyc-a is cyc-b" (Get-AiNextProfileName -Tool claude) "cyc-b"

  Write-Host "[8] health command probes live; list shows cached Health WITHOUT probing"
  $healthOut = (& { cc health } 6>&1 | Out-String -Width 4096)
  Assert-Match "health header" $healthOut "profile health"
  Assert-Match "health shows hgood" $healthOut "hgood"
  # list shows a Health column (from cache) but must NOT trigger a live probe
  $keysBefore = (Read-AiHealthCache).Count
  $listOut = (& { cc list } 6>&1 | Out-String -Width 4096)
  $keysAfter = (Read-AiHealthCache).Count
  Assert-Match "list header" $listOut "Claude Code profiles"
  Assert-Match "list has Health col" $listOut "Health"
  if ($keysAfter -ne $keysBefore) { throw "cc list probed live (cache keys $keysBefore->$keysAfter); list must be cache-only" }
  Write-Host "  ok: list shows cached Health, did NOT probe (cache keys unchanged)"

  Write-Host "[9] status/switch show probe model and status --fresh probes"
  Save-AiSelectedProfile -Tool claude -Name hgood
  Remove-Item Env:AI_CLAUDE_LABEL -ErrorAction SilentlyContinue
  $beforeStatus = $script:ProbeCalls
  $statusOut = (& { cc status } 6>&1 | Out-String -Width 4096)
  Assert-Match "status has probe model" $statusOut "Probe model: secret-sonnet"
  Assert-Match "status has Health" $statusOut "Health:"
  Assert-Eq "status cache-only probe count" $script:ProbeCalls $beforeStatus
  $freshOut = (& { cc status --fresh } 6>&1 | Out-String -Width 4096)
  Assert-Match "status fresh has probe model" $freshOut "Probe model:"
  if ($script:ProbeCalls -le $beforeStatus) { throw "cc status --fresh did not call live probe" }
  $switchOut = (& { cc hgood } 6>&1 | Out-String -Width 4096)
  Assert-Match "switch has probe model" $switchOut "Probe model: secret-sonnet"
  Assert-Match "switch has Health" $switchOut "Health:"

  Write-Host "[10] health table shortens Chinese unsupported model note"
  Clear-AiHealthCache
  $pcn = Get-AiProfileByName -Tool claude -Name hcn
  $cn = Get-AiProfileHealthCached -Tool claude -Profile $pcn -Fresh
  Write-AiHealthCacheEntry -Key "claude.hcn" -Entry ([pscustomobject]@{
      status = $cn.Status; latencyMs = $cn.LatencyMs; method = $cn.Method; error = $cn.Error; probedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    })
  $short = ConvertTo-AiHealthDisplayError $cn.Error
  Assert-Match "Chinese model note short" $short "probe model unsupported; set probe_model"
  if ($cn.Error -notmatch "模型不存在") { throw "cached/status error should preserve original Chinese detail" }
  Save-AiSelectedProfile -Tool claude -Name hcn
  Remove-Item Env:AI_CLAUDE_LABEL -ErrorAction SilentlyContinue
  $statusCn = (& { cc status --fresh } 6>&1 | Out-String -Width 4096)
  Assert-Match "status shortens Chinese detail" $statusCn "probe model unsupported; set probe_model"
  Assert-Match "status Chinese has probe model" $statusCn "Probe model:"

  Write-Host "[11] escaped Chinese is decoded and health output is hard-bounded"
  Assert-Eq "fallback width counts Chinese cells" (Get-AiFallbackDisplayWidth "原因") 4
  $pescaped = Get-AiProfileByName -Tool claude -Name hescaped
  $escaped = Get-AiProfileHealthCached -Tool claude -Profile $pescaped -Fresh
  Write-AiHealthCacheEntry -Key "claude.hescaped" -Entry ([pscustomobject]@{
      status = $escaped.Status; latencyMs = $escaped.LatencyMs; method = $escaped.Method; error = $escaped.Error; probedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    })
  Write-AiHealthCacheEntry -Key "claude.hgood" -Entry ([pscustomobject]@{
      status = "healthy"; latencyMs = 120; method = "generation"; error = $null; probedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    })
  $boundedHealth = (& { cc health } 6>&1 | Out-String -Width 4096)
  Assert-Match "health decodes escaped Chinese" $boundedHealth "原因超长"
  if ($boundedHealth -match '\\u[0-9a-fA-F]{4}') { throw "health output leaked a Unicode escape: $($Matches[0])" }
  if ($boundedHealth.Contains([char]0x1b)) { throw "health output leaked an ESC control character" }
  Assert-LinesBounded "health output" $boundedHealth 80
  Save-AiSelectedProfile -Tool claude -Name hescaped
  Remove-Item Env:AI_CLAUDE_LABEL -ErrorAction SilentlyContinue
  $boundedStatus = (& { cc status --fresh } 6>&1 | Out-String -Width 4096)
  Assert-Match "status decodes escaped Chinese" $boundedStatus "原因超长"
  if ($boundedStatus -match '\\u[0-9a-fA-F]{4}') { throw "status output leaked a Unicode escape: $($Matches[0])" }
  if ($boundedStatus.Contains([char]0x1b)) { throw "status output leaked an ESC control character" }
  Assert-LinesBounded "status health line" (($boundedStatus -split "`r?`n" | Where-Object { $_ -match '^  Health:' }) -join "`n") 80

  Write-Host ""
  Write-Host "AI env health check passed." -ForegroundColor Green
}
finally {
  if ($null -ne $previousAiEnvHome) { $env:AI_ENV_HOME = $previousAiEnvHome } else { Remove-Item Env:AI_ENV_HOME -ErrorAction SilentlyContinue }
  if ($null -ne $previousNonInteractive) { $env:AI_ENV_NONINTERACTIVE = $previousNonInteractive } else { Remove-Item Env:AI_ENV_NONINTERACTIVE -ErrorAction SilentlyContinue }
  if ($null -ne $previousHealthColumns) { $env:AI_HEALTH_COLUMNS = $previousHealthColumns } else { Remove-Item Env:AI_HEALTH_COLUMNS -ErrorAction SilentlyContinue }
  if ($null -ne $previousAnthropicModel) { $env:ANTHROPIC_MODEL = $previousAnthropicModel } else { Remove-Item Env:ANTHROPIC_MODEL -ErrorAction SilentlyContinue }
  if ($null -ne $previousAnthropicDefaultHaikuModel) { $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $previousAnthropicDefaultHaikuModel } else { Remove-Item Env:ANTHROPIC_DEFAULT_HAIKU_MODEL -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  Restore-TestProcessEnvironment -Snapshot $previousProcessEnvironment
}
