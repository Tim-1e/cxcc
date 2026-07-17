# ===========================================================================
# MCP module. ~/.ai-env/mcp.toml is the single source of truth for MCP servers
# across Claude Code and Codex. `mcp sync` pushes each enabled server to its
# targets (global):
#   Claude -> ~/.claude.json mcpServers      (direct JSON merge, atomic)
#   Codex  -> ~/.codex/config.toml [mcp_servers.NAME]  (native enabled flag)
# `enabled` is uniform: Claude has no per-server flag (disabled = omitted);
# Codex uses native enabled = false. Edit ONLY mcp.toml (mcp edit).
# Target paths honor env overrides (AI_CLAUDE_JSON_PATH / AI_CODEX_CONFIG_PATH)
# so tests can isolate without touching the real config files.
# ===========================================================================

function Get-AiMcpRegistryPath {
  return (Join-Path $script:AiConfigDir "mcp.toml")
}
function Get-AiClaudeJsonPath {
  if ($env:AI_CLAUDE_JSON_PATH) { return $env:AI_CLAUDE_JSON_PATH }
  return (Join-Path $HOME '.claude.json')
}
function Get-AiCodexConfigPath {
  if ($env:AI_CODEX_CONFIG_PATH) { return $env:AI_CODEX_CONFIG_PATH }
  return (Join-Path $HOME '.codex\config.toml')
}

# TOML array of strings: ["a", "b"] -> @('a','b')
function ConvertFrom-AiTomlStringArray {
  param([AllowNull()][string]$Raw)
  $list = @()
  if (-not $Raw) { return $list }
  foreach ($m in [regex]::Matches($Raw, '"((?:\\.|[^"])*)"')) { $list += $m.Groups[1].Value }
  return $list
}
# TOML inline table of strings: { K = "V" } -> @{K='V'}
function ConvertFrom-AiTomlInlineTable {
  param([AllowNull()][string]$Raw)
  $h = @{}
  if (-not $Raw) { return $h }
  foreach ($m in [regex]::Matches($Raw, '([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"((?:\\.|[^"])*)"')) { $h[$m.Groups[1].Value] = $m.Groups[2].Value }
  return $h
}

# Read mcp.toml -> ordered hashtable name -> entry(pscustomobject).
function Read-AiMcpRegistry {
  $path = Get-AiMcpRegistryPath
  $result = [ordered]@{}
  if (-not (Test-Path -LiteralPath $path)) { return $result }
  $current = $null
  foreach ($line in Get-Content -LiteralPath $path) {
    $t = "$line".Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    if ($t -match '^\[mcp\.([^\]]+)\]\s*$') {
      $current = $Matches[1].Trim()
      $result[$current] = [pscustomobject]@{
        Name = $current; Kind = 'stdio'; Command = @(); Url = $null; Env = @{}; Sync = @('claude', 'codex'); Enabled = $true
      }
      continue
    }
    if ($t -match '^\[') { $current = $null; continue }
    if (-not $current) { continue }
    if ($t -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') {
      $key = $Matches[1]; $raw = $Matches[2].Trim()
      $e = $result[$current]
      switch ($key) {
        'command' { $e.Kind = 'stdio'; $e.Command = @(ConvertFrom-AiTomlStringArray $raw) }
        'url'     { $e.Kind = 'http'; $e.Url = [string](ConvertFrom-AiTomlValue $raw) }
        'env'     { $e.Env = ConvertFrom-AiTomlInlineTable $raw }
        'sync'    { $e.Sync = @(ConvertFrom-AiTomlStringArray $raw) }
        'enabled' { $e.Enabled = ($raw -match 'true') }
      }
    }
  }
  return $result
}

# --- Claude target (~/.claude.json mcpServers) ---
function Read-ClaudeMcpServerNames {
  $path = Get-AiClaudeJsonPath
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  try {
    $d = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ($d.mcpServers) { return @($d.mcpServers.PSObject.Properties.Name) }
  } catch { }
  return @()
}
# Build the object Claude stores for a server.
function ConvertTo-ClaudeMcpEntry {
  param([Parameter(Mandatory = $true)]$Entry)
  if ($Entry.Kind -eq 'http') { return [pscustomobject]@{ type = 'http'; url = [string]$Entry.Url } }
  $cmd = @($Entry.Command)
  $obj = [ordered]@{}
  if ($cmd.Count -gt 0) { $obj['command'] = [string]$cmd[0] }
  $obj['args'] = if ($cmd.Count -gt 1) { @($cmd[1..($cmd.Count - 1)]) } else { @() }
  if ($Entry.Env.Count -gt 0) { $obj['env'] = ($Entry.Env) }
  return [pscustomobject]$obj
}
# Upsert ($Entry) or remove ($Entry=$null) a server in .claude.json mcpServers.
# Atomic (tmp+move); preserves all other keys. Backs up once per path.
function Set-ClaudeMcpServer {
  param([Parameter(Mandatory = $true)][string]$Name, $Entry)
  $path = Get-AiClaudeJsonPath
  $bak = "$path.aienv.bak"
  if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $bak)) {
    Copy-Item -LiteralPath $path -Destination $bak -Force
  }
  $d = $null
  if (Test-Path -LiteralPath $path) {
    try { $d = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { $d = $null }
  }
  if (-not $d) { $d = [pscustomobject]@{ } }
  # copy existing mcpServers into a mutable hashtable (preserves siblings),
  # then upsert/remove the one entry, and write it back.
  $ms = @{ }
  if ($d.PSObject.Properties.Name -contains 'mcpServers' -and $d.mcpServers) {
    foreach ($p in $d.mcpServers.PSObject.Properties) { $ms[$p.Name] = $p.Value }
  }
  if ($Entry) {
    $ms[$Name] = (ConvertTo-ClaudeMcpEntry $Entry)
  } elseif ($ms.ContainsKey($Name)) {
    $ms.Remove($Name)
  }
  $d | Add-Member -NotePropertyName mcpServers -NotePropertyValue $ms -Force
  $tmp = "$path.tmp"
  ($d | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

# --- Codex target (~/.codex/config.toml [mcp_servers.NAME]) ---
function Test-CodexMcpServer {
  param([Parameter(Mandatory = $true)][string]$Name)
  $path = Get-AiCodexConfigPath
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  return [bool](Select-String -LiteralPath $path -Pattern ('^\[mcp_servers\.' + [regex]::Escape($Name) + '\]') -Quiet)
}
function ConvertTo-CodexMcpBlock {
  param([Parameter(Mandatory = $true)]$Entry)
  $lines = @("[mcp_servers.$($Entry.Name)]")
  if ($Entry.Kind -eq 'http') {
    $lines += 'url = "' + [string]$Entry.Url + '"'
  } else {
    $arr = (@($Entry.Command) | ForEach-Object { '"' + [string]$_ + '"' }) -join ', '
    $lines += 'command = [' + $arr + ']'
    if ($Entry.Env.Count -gt 0) {
      $pairs = ($Entry.Env.GetEnumerator() | ForEach-Object { [string]$_.Key + ' = "' + [string]$_.Value + '"' }) -join ', '
      $lines += 'env = { ' + $pairs + ' }'
    }
  }
  $lines += 'enabled = ' + $(if ($Entry.Enabled) { 'true' } else { 'false' })
  return ($lines -join "`n")
}
# Remove [mcp_servers.NAME] section; if $Block, append it. Preserves all other
# config.toml content (model, providers, user-managed mcp_servers, etc.).
function Set-CodexMcpServer {
  param([Parameter(Mandatory = $true)][string]$Name, [AllowEmptyString()][string]$Block)
  $path = Get-AiCodexConfigPath
  if (-not (Test-Path -LiteralPath $path)) {
    if (-not $Block) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    "" | Set-Content -LiteralPath $path -Encoding UTF8
  }
  $lines = @(Get-Content -LiteralPath $path)
  $out = New-Object System.Collections.Generic.List[string]
  $header = "[mcp_servers.$Name]"
  $skip = $false
  foreach ($l in $lines) {
    if ("$l".Trim() -match '^\[([^\]]+)\]\s*$') { $skip = ("[" + $Matches[1].Trim() + "]") -ceq $header }
    if ($skip) { continue }
    $out.Add($l)
  }
  if ($Block) {
    if ($out.Count -gt 0 -and "$($out[$out.Count - 1])".Trim() -ne '') { $out.Add('') }
    $out.Add($Block.TrimEnd())
  }
  ($out -join "`n") | Set-Content -LiteralPath $path -Encoding UTF8
}

# Push every mcp.toml entry to its targets (idempotent).
function Sync-AiMcp {
  $reg = Read-AiMcpRegistry
  $path = Get-AiMcpRegistryPath
  if ($reg.Count -eq 0) {
    Write-Host "No MCP servers in $path. Run 'mcp edit' to define some."
    return
  }
  $upserts = 0; $removes = 0
  foreach ($entry in $reg.Values) {
    foreach ($tool in @('claude', 'codex')) {
      $want = ($entry.Enabled -and ($entry.Sync -contains $tool))
      if ($tool -eq 'claude') {
        if ($want) { Set-ClaudeMcpServer -Name $entry.Name -Entry $entry; $upserts++ }
        else { Set-ClaudeMcpServer -Name $entry.Name -Entry $null; $removes++ }
      } else {
        $block = if ($want) { ConvertTo-CodexMcpBlock -Entry $entry } else { '' }
        Set-CodexMcpServer -Name $entry.Name -Block $block
        if ($want) { $upserts++ } else { $removes++ }
      }
    }
  }
  Write-Host "MCP sync done: $upserts upsert(s), $removes remove(s). Targets: Claude ($(Get-AiClaudeJsonPath)), Codex ($(Get-AiCodexConfigPath))."
}

# --- reverse direction: pull existing servers from targets into mcp.toml ---
function Read-ClaudeMcpServers {
  $path = Get-AiClaudeJsonPath
  $result = [ordered]@{ }
  if (-not (Test-Path -LiteralPath $path)) { return $result }
  try {
    $d = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ($d.mcpServers) { foreach ($p in $d.mcpServers.PSObject.Properties) { $result[$p.Name] = $p.Value } }
  } catch { }
  return $result
}
function Read-CodexMcpServers {
  $path = Get-AiCodexConfigPath
  $result = [ordered]@{ }
  if (-not (Test-Path -LiteralPath $path)) { return $result }
  $current = $null
  foreach ($line in Get-Content -LiteralPath $path) {
    $t = "$line".Trim()
    if ($t -match '^\[mcp_servers\.([^\]]+)\]\s*$') {
      $current = $Matches[1].Trim()
      $result[$current] = [pscustomobject]@{ Name = $current; Command = @(); Url = $null; Env = @{}; Enabled = $true }
      continue
    }
    if ($t -match '^\[') { $current = $null; continue }
    if (-not $current) { continue }
    if ($t -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') {
      $key = $Matches[1]; $raw = $Matches[2].Trim(); $e = $result[$current]
      switch ($key) {
        'command' { $e.Command = @(ConvertFrom-AiTomlStringArray $raw) }
        'url'     { $e.Url = [string](ConvertFrom-AiTomlValue $raw) }
        'env'     { $e.Env = ConvertFrom-AiTomlInlineTable $raw }
        'enabled' { $e.Enabled = ($raw -match 'true') }
      }
    }
  }
  return $result
}
# Convert a Claude target entry -> mcp.toml entry shape.
function ConvertFrom-ClaudeMcpTarget {
  param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Entry)
  $e = [pscustomobject]@{ Name = $Name; Kind = 'stdio'; Command = @(); Url = $null; Env = @{}; Sync = @('claude'); Enabled = $true }
  if ("$Entry.type" -in @('http', 'sse') -or $Entry.url) {
    $e.Kind = 'http'; $e.Url = [string]$Entry.url
  } else {
    if ($Entry.command -is [array]) { $e.Command = @($Entry.command) }
    else {
      $cmd = @(); if ($Entry.command) { $cmd += [string]$Entry.command }
      if ($Entry.args) { $cmd += @($Entry.args) }
      $e.Command = $cmd
    }
    if ($Entry.env) { foreach ($p in $Entry.env.PSObject.Properties) { $e.Env[$p.Name] = [string]$p.Value } }
  }
  return $e
}
# Convert a Codex target entry -> mcp.toml entry shape.
function ConvertFrom-CodexMcpTarget {
  param([Parameter(Mandatory = $true)]$Entry)
  $e = [pscustomobject]@{ Name = $Entry.Name; Kind = 'stdio'; Command = @(); Url = $null; Env = @{}; Sync = @('codex'); Enabled = $Entry.Enabled }
  if ($Entry.Url) { $e.Kind = 'http'; $e.Url = $Entry.Url } else { $e.Command = @($Entry.Command); $e.Env = $Entry.Env }
  return $e
}
# Serialize an mcp.toml entry -> TOML block text.
function ConvertTo-McpTomlBlock {
  param([Parameter(Mandatory = $true)]$Entry)
  $lines = @("[mcp.$($Entry.Name)]")
  if ($Entry.Kind -eq 'http') {
    $lines += 'url = "' + [string]$Entry.Url + '"'
  } else {
    $arr = (@($Entry.Command) | ForEach-Object { '"' + [string]$_ + '"' }) -join ', '
    $lines += 'command = [' + $arr + ']'
    if ($Entry.Env.Count -gt 0) {
      $pairs = ($Entry.Env.GetEnumerator() | ForEach-Object { [string]$_.Key + ' = "' + [string]$_.Value + '"' }) -join ', '
      $lines += 'env = { ' + $pairs + ' }'
    }
  }
  $lines += 'sync = [' + ((@($Entry.Sync) | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']'
  $lines += 'enabled = ' + $(if ($Entry.Enabled) { 'true' } else { 'false' })
  return ($lines -join "`n")
}
# Pull existing MCP servers from Claude + Codex targets into mcp.toml. Adds only
# names not already present (preserves your mcp.toml edits). -Name pulls one.
function Import-AiMcpFromTargets {
  param([string]$Name)
  $claude = Read-ClaudeMcpServers
  $codex = Read-CodexMcpServers
  $existing = Read-AiMcpRegistry
  if ($Name) {
    $names = @($Name)
    if (-not ($claude.Contains($Name) -or $codex.Contains($Name))) { Write-Host "'$Name' not found in Claude or Codex targets."; return }
  } else {
    $names = @(@($claude.Keys) + @($codex.Keys) | Select-Object -Unique)
  }
  if ($names.Count -eq 0) { Write-Host "No MCP servers found in targets to pull."; return }
  $added = 0; $skipped = 0; $newBlocks = @()
  foreach ($n in $names) {
    if ($existing.Contains($n)) { $skipped++; continue }
    $inC = $claude.Contains($n); $inX = $codex.Contains($n)
    if ($inC) { $e = ConvertFrom-ClaudeMcpTarget -Name $n -Entry $claude[$n] } else { $e = ConvertFrom-CodexMcpTarget -Entry $codex[$n] }
    $sync = @(); if ($inC) { $sync += 'claude' }; if ($inX) { $sync += 'codex' }
    $e.Sync = $sync
    $newBlocks += (ConvertTo-McpTomlBlock -Entry $e)
    $added++
  }
  if ($added -gt 0) {
    $path = Get-AiMcpRegistryPath
    if (-not (Test-Path -LiteralPath $path)) {
      New-Item -ItemType Directory -Force -Path $script:AiConfigDir | Out-Null
      "# ~/.ai-env/mcp.toml - pulled from Claude Code & Codex. Edit freely; run mcp sync to push back." | Set-Content -LiteralPath $path
    }
    $tail = (Get-Content -Raw -LiteralPath $path).TrimEnd()
    $sep = if ($tail -ne '') { "`n`n" } else { "" }
    Add-Content -LiteralPath $path -Value ($sep + ($newBlocks -join "`n`n") + "`n")
  }
  Write-Host "MCP pull: +$added added, $skipped skipped (already in mcp.toml). -> $(Get-AiMcpRegistryPath)"
}

function Show-AiMcpList {
  $reg = Read-AiMcpRegistry
  $path = Get-AiMcpRegistryPath
  if ($reg.Count -eq 0) { Write-Host "No MCP servers in $path. Run 'mcp edit'."; return }
  $claude = Read-ClaudeMcpServerNames
  $rows = foreach ($e in $reg.Values) {
    [pscustomobject]@{
      Name    = $e.Name
      Type    = if ($e.Kind -eq 'http') { 'http' } else { 'stdio' }
      Claude  = if ($claude -contains $e.Name) { 'yes' } else { '-' }
      Codex   = if (Test-CodexMcpServer -Name $e.Name) { 'yes' } else { '-' }
      Enabled = if ($e.Enabled) { 'on' } else { 'off' }
      Sync    = ($e.Sync -join ',')
    }
  }
  $rows | Format-Table -AutoSize
  Write-Host "  (yes = present in target's live config; run 'mcp sync' to align)" -ForegroundColor DarkGray
}

function Show-AiMcpGet {
  param([string]$Name)
  $reg = Read-AiMcpRegistry
  if (-not $Name) { Write-Host "Usage: mcp get NAME"; return }
  if (-not $reg.Contains($Name)) { Write-Host "No MCP server '$Name' in mcp.toml."; return }
  $e = $reg[$Name]
  Write-Host "mcp.$Name :"
  Write-Host "  kind    : $($e.Kind)"
  if ($e.Kind -eq 'http') { Write-Host "  url     : $($e.Url)" } else { Write-Host "  command : $($e.Command -join ' ')" }
  if ($e.Env.Count -gt 0) { Write-Host "  env     : " + (($e.Env.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') }
  Write-Host "  sync    : $($e.Sync -join ', ')"
  Write-Host "  enabled : $($e.Enabled)"
  $claude = Read-ClaudeMcpServerNames
  Write-Host "  claude  : $(if ($claude -contains $Name) { 'present' } else { '-' })"
  Write-Host "  codex   : $(if (Test-CodexMcpServer -Name $Name) { 'present' } else { '-' })"
}

function Edit-AiMcpRegistry {
  $path = Get-AiMcpRegistryPath
  if (-not (Test-Path -LiteralPath $path)) {
    New-Item -ItemType Directory -Force -Path $script:AiConfigDir | Out-Null
    @'
# ~/.ai-env/mcp.toml — single source of truth for MCP servers (Claude Code + Codex).
# `mcp sync` pushes each enabled server to global targets:
#   Claude -> ~/.claude.json mcpServers
#   Codex  -> ~/.codex/config.toml [mcp_servers.NAME]
# A server is EITHER stdio (command = [...]) OR http (url = "...").
# sync  = which tools get it (omit = both). enabled = false keeps it defined but skips it.

# [mcp.context7]
# command = ["npx", "-y", "@upstash/context7-mcp@3.2.4"]
# env = {}
# sync = ["claude", "codex"]
# enabled = false

# [mcp.figma]
# url = "https://mcp.figma.com/mcp"
# sync = ["codex"]
# enabled = false
'@ | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Created starter mcp.toml at $path"
  }
  $editor = if ($env:EDITOR) { $env:EDITOR } elseif ($env:VISUAL) { $env:VISUAL } elseif ($IsWindows) { 'notepad' } else { 'vi' }
  # mcp edit should open-and-return (non-blocking): drop any --wait/-w flag so
  # GUI editors (cursor/code) launch and hand the shell back immediately. The
  # global $EDITOR keeps --wait for tools that need blocking (e.g. git commit).
  $parts = @($editor -split '\s+' | Where-Object { $_ -and $_ -notin @('--wait', '-w') })
  if ($parts.Count -eq 0) { $parts = @('notepad') }
  $rest = @(); if ($parts.Count -gt 1) { $rest = @($parts[1..($parts.Count - 1)]) }; $rest += $path
  Write-Host "Opening $path with $($parts[0]) ..."
  & $parts[0] @rest
}

function Show-AiMcpHelp {
  @'
mcp - manage MCP servers across Claude Code & Codex from ~/.ai-env/mcp.toml

Usage:
  mcp                 Show this help
  mcp list            List servers + whether each target has them
  mcp edit            Open mcp.toml in EDITOR (creates a starter if absent)
  mcp sync            Push mcp.toml -> Claude (~/.claude.json) & Codex (~/.codex/config.toml)
  mcp pull [NAME]     Import existing MCP servers FROM Claude & Codex into mcp.toml
  mcp get NAME        Show one server's config + target status

mcp.toml is the single source of truth; edit it, then `mcp sync` (idempotent).
enabled = false keeps a server defined but skips it on sync.
sync = ["claude"] or ["codex"] limits a server to one tool (omit = both).
'@ | Write-Host
}

function mcp {
  $remaining = @($args)
  if ($remaining.Count -eq 0 -or ($remaining[0] -in @('help', '-h', '--help'))) { Show-AiMcpHelp; return }
  switch (($remaining[0]).ToString().ToLowerInvariant()) {
    'list' { Show-AiMcpList; return }
    'edit' { Edit-AiMcpRegistry; return }
    'sync' { Sync-AiMcp; return }
    { $_ -in @('pull', 'import') } { Import-AiMcpFromTargets -Name ($remaining[1]); return }
    { $_ -in @('get', 'show') } { Show-AiMcpGet -Name ($remaining[1]); return }
    default { Write-Host "Unknown mcp command '$($remaining[0])'."; Show-AiMcpHelp; return }
  }
}
