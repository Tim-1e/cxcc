[CmdletBinding()]
param(
  [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

# Offline MCP tests. Targets are redirected via AI_CLAUDE_JSON_PATH /
# AI_CODEX_CONFIG_PATH to temp files, so the real ~/.claude.json and
# ~/.codex/config.toml are never touched.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestProcessEnvironment.ps1")
$previousProcessEnvironment = Save-TestProcessEnvironment

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-env-mcp-" + [guid]::NewGuid().ToString("N"))
$home2 = Join-Path $tmpRoot "home"
$loaderPath = Join-Path $SourceDir "src/powershell/CxCc/CxCc.ps1"
$mcpModulePath = Join-Path $SourceDir "src/powershell/CxCc/Mcp.ps1"
$expectedMcpFunctionNames = @(
  "Get-AiMcpRegistryPath"
  "Get-AiClaudeJsonPath"
  "Get-AiCodexConfigPath"
  "ConvertFrom-AiTomlStringArray"
  "ConvertFrom-AiTomlInlineTable"
  "Read-AiMcpRegistry"
  "Read-ClaudeMcpServerNames"
  "ConvertTo-ClaudeMcpEntry"
  "Set-ClaudeMcpServer"
  "Test-CodexMcpServer"
  "ConvertTo-CodexMcpBlock"
  "Set-CodexMcpServer"
  "Sync-AiMcp"
  "Read-ClaudeMcpServers"
  "Read-CodexMcpServers"
  "ConvertFrom-ClaudeMcpTarget"
  "ConvertFrom-CodexMcpTarget"
  "ConvertTo-McpTomlBlock"
  "Import-AiMcpFromTargets"
  "Show-AiMcpList"
  "Show-AiMcpGet"
  "Edit-AiMcpRegistry"
  "Show-AiMcpHelp"
  "mcp"
)
$prev = @{
  H  = $env:AI_ENV_HOME
  CJ = $env:AI_CLAUDE_JSON_PATH
  CC = $env:AI_CODEX_CONFIG_PATH
  NI = $env:AI_ENV_NONINTERACTIVE
}
$env:AI_ENV_HOME = $home2
$env:AI_ENV_NONINTERACTIVE = "1"
$env:AI_CLAUDE_JSON_PATH = Join-Path $tmpRoot "claude.json"
$env:AI_CODEX_CONFIG_PATH = Join-Path $tmpRoot "codex-config.toml"

function Assert-Eq($n, $a, $e) { if ($a -ne $e) { throw "ASSERT $n : expected '$e', got '$a'" }; Write-Host "  ok: $n = '$a'" }
function Assert-True($n, $a) { if (-not $a) { throw "ASSERT $n : expected true, got '$a'" }; Write-Host "  ok: $n" }

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $home2 ".ai-env"), (Join-Path $home2 ".ai-secrets") | Out-Null
  "" | Set-Content (Join-Path $home2 ".ai-secrets/secrets.toml")
  Copy-Item (Join-Path $SourceDir "templates/profiles.json") (Join-Path $home2 ".ai-env/profiles.json") -Force
  if (-not (Test-Path -LiteralPath $mcpModulePath -PathType Leaf)) {
    throw "MCP module is missing: $mcpModulePath"
  }

  $moduleTokens = $null
  $moduleErrors = $null
  $moduleAst = [Management.Automation.Language.Parser]::ParseFile($mcpModulePath, [ref]$moduleTokens, [ref]$moduleErrors)
  if ($moduleErrors.Count -gt 0) { throw "MCP module has parser errors" }
  $moduleFunctionNames = @($moduleAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
  $missingModuleFunctions = @($expectedMcpFunctionNames | Where-Object { $_ -notin $moduleFunctionNames })
  $unexpectedModuleFunctions = @($moduleFunctionNames | Where-Object { $_ -notin $expectedMcpFunctionNames })
  $duplicateModuleFunctions = @($moduleFunctionNames | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
  if ($missingModuleFunctions -or $unexpectedModuleFunctions -or $duplicateModuleFunctions -or $moduleFunctionNames.Count -ne $expectedMcpFunctionNames.Count) {
    throw "MCP module function set mismatch: missing=$($missingModuleFunctions -join ','), unexpected=$($unexpectedModuleFunctions -join ','), duplicate=$($duplicateModuleFunctions -join ',')"
  }

  . $loaderPath
  $expectedMcpModulePath = [IO.Path]::GetFullPath($mcpModulePath)
  foreach ($functionName in $expectedMcpFunctionNames) {
    $mcpCommand = Get-Command $functionName -CommandType Function -ErrorAction Stop
    $actualMcpModulePath = [IO.Path]::GetFullPath($mcpCommand.ScriptBlock.File)
    if (-not $actualMcpModulePath.Equals($expectedMcpModulePath, [StringComparison]::OrdinalIgnoreCase)) {
      throw "$functionName loaded from '$actualMcpModulePath', expected '$expectedMcpModulePath'"
    }
  }

  @'
[mcp.context7]
command = ["npx", "-y", "@upstash/context7-mcp"]
env = {}
sync = ["claude", "codex"]
enabled = true

[mcp.filesystem]
command = ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
env = { ALLOW_DIR = "/tmp" }
sync = ["claude"]
enabled = true

[mcp.figma]
url = "https://mcp.figma.com/mcp"
sync = ["codex"]
enabled = false
'@ | Set-Content (Get-AiMcpRegistryPath)

  Write-Host "[1] Read-AiMcpRegistry parses mcp.toml"
  $reg = Read-AiMcpRegistry
  Assert-Eq "entry count" $reg.Count 3
  Assert-Eq "context7 kind" $reg.context7.Kind "stdio"
  Assert-Eq "context7 cmd0" $reg.context7.Command[0] "npx"
  Assert-Eq "context7 cmd count" $reg.context7.Command.Count 3
  Assert-True "context7 enabled" $reg.context7.Enabled
  Assert-Eq "filesystem env ALLOW_DIR" $reg.filesystem.Env.ALLOW_DIR "/tmp"
  Assert-Eq "filesystem sync (claude only)" ($reg.filesystem.Sync -join ',') "claude"
  Assert-Eq "figma kind" $reg.figma.Kind "http"
  Assert-Eq "figma url" $reg.figma.Url "https://mcp.figma.com/mcp"
  Assert-True "figma disabled" (-not $reg.figma.Enabled)

  Write-Host "[2] entry -> target converters"
  $ce = ConvertTo-ClaudeMcpEntry $reg.context7
  Assert-Eq "claude entry command" $ce.command "npx"
  Assert-Eq "claude entry args0" $ce.args[0] "-y"
  $cf = ConvertTo-ClaudeMcpEntry $reg.figma
  Assert-Eq "claude http type" $cf.type "http"
  Assert-Eq "claude http url" $cf.url "https://mcp.figma.com/mcp"
  $cb = ConvertTo-CodexMcpBlock $reg.context7
  Assert-True "codex block header" ($cb -match '\[mcp_servers\.context7\]')
  Assert-True "codex block enabled true" ($cb -match 'enabled = true')

  Write-Host "[3] Claude target: upsert/remove + preserve nested keys (no -Depth truncation)"
  '{"projects":{"p1":{"history":[1,2,{"deep":{"a":{"b":{"c":42}}}}]}},"mcpServers":{"oldserver":{"command":"x"}}}' |
    Set-Content $env:AI_CLAUDE_JSON_PATH
  Set-ClaudeMcpServer -Name "context7" -Entry $reg.context7
  $d = Get-Content -Raw $env:AI_CLAUDE_JSON_PATH | ConvertFrom-Json
  Assert-True "claude has context7" ($d.mcpServers.PSObject.Properties.Name -contains 'context7')
  Assert-True "claude kept oldserver" ($d.mcpServers.PSObject.Properties.Name -contains 'oldserver')
  Assert-Eq "claude deep nested preserved (depth)" $d.projects.p1.history[2].deep.a.b.c 42
  Set-ClaudeMcpServer -Name "oldserver" -Entry $null
  $d2 = Get-Content -Raw $env:AI_CLAUDE_JSON_PATH | ConvertFrom-Json
  Assert-True "claude removed oldserver" (-not ($d2.mcpServers.PSObject.Properties.Name -contains 'oldserver'))

  Write-Host "[4] Codex target: upsert/remove + preserve other config.toml content"
  @'
model = "gpt-test"
model_provider = "openai"

[mcp_servers.userkept]
command = ["echo"]
'@ | Set-Content $env:AI_CODEX_CONFIG_PATH
  Set-CodexMcpServer -Name "context7" -Block (ConvertTo-CodexMcpBlock $reg.context7)
  $toml = Get-Content -Raw $env:AI_CODEX_CONFIG_PATH
  Assert-True "codex has context7" ($toml -match '\[mcp_servers\.context7\]')
  Assert-True "codex kept model" ($toml -match 'model = "gpt-test"')
  Assert-True "codex kept userkept" ($toml -match '\[mcp_servers\.userkept\]')
  Set-CodexMcpServer -Name "context7" -Block ""
  $toml2 = Get-Content -Raw $env:AI_CODEX_CONFIG_PATH
  Assert-True "codex removed context7" (-not ($toml2 -match '\[mcp_servers\.context7\]'))
  Assert-True "codex still has userkept" ($toml2 -match '\[mcp_servers\.userkept\]')
  Assert-True "codex kept model after remove" ($toml2 -match 'model = "gpt-test"')

  Write-Host "[5] Sync-AiMcp end-to-end (enabled/sync respected)"
  '{"mcpServers":{}}' | Set-Content $env:AI_CLAUDE_JSON_PATH
  "" | Set-Content $env:AI_CODEX_CONFIG_PATH
  Sync-AiMcp | Out-Null
  $cd = Get-Content -Raw $env:AI_CLAUDE_JSON_PATH | ConvertFrom-Json
  Assert-True "sync claude has context7" ($cd.mcpServers.PSObject.Properties.Name -contains 'context7')
  Assert-True "sync claude has filesystem" ($cd.mcpServers.PSObject.Properties.Name -contains 'filesystem')
  Assert-True "sync claude NOT figma (sync=codex)" (-not ($cd.mcpServers.PSObject.Properties.Name -contains 'figma'))
  $ct = Get-Content -Raw $env:AI_CODEX_CONFIG_PATH
  Assert-True "sync codex has context7" ($ct -match '\[mcp_servers\.context7\]')
  Assert-True "sync codex NOT filesystem (sync=claude)" (-not ($ct -match '\[mcp_servers\.filesystem\]'))
  Assert-True "sync codex NOT figma (disabled)" (-not ($ct -match '\[mcp_servers\.figma\]'))

  Write-Host "[6] mcp list / get render"
  Assert-True "mcp list shows context7" ((& { mcp list } 6>&1 | Out-String) -match 'context7')
  Assert-True "mcp get figma shows url" ((& { mcp get figma } 6>&1 | Out-String) -match 'mcp.figma.com')

  Write-Host "[7] mcp pull: import existing servers from targets -> mcp.toml"
  @'
[mcp.onlymine]
command = ["x"]
enabled = true
'@ | Set-Content (Get-AiMcpRegistryPath)
  '{"mcpServers":{"shared":{"command":"scmd","args":["sarg"]},"clonly":{"command":"conly"}}}' | Set-Content $env:AI_CLAUDE_JSON_PATH
  @'
[mcp_servers.shared]
command = ["scmd", "sarg"]
enabled = true

[mcp_servers.cxonly]
command = ["cx"]
enabled = false
'@ | Set-Content $env:AI_CODEX_CONFIG_PATH
  $pullOut = (& { mcp pull } 6>&1 | Out-String)
  Assert-True "pull added 3" ($pullOut -match '\+3 added')
  $pr = Read-AiMcpRegistry
  Assert-True "pull kept onlymine" ($pr.Contains('onlymine'))
  Assert-Eq "pull total 4 entries" $pr.Count 4
  Assert-Eq "shared sync (both)" ($pr.shared.Sync -join ',') 'claude,codex'
  Assert-Eq "shared command (cmd+args)" ($pr.shared.Command -join ' ') 'scmd sarg'
  Assert-Eq "clonly sync (claude)" ($pr.clonly.Sync -join ',') 'claude'
  Assert-Eq "cxonly sync (codex)" ($pr.cxonly.Sync -join ',') 'codex'
  Assert-True "cxonly disabled preserved" (-not $pr.cxonly.Enabled)
  $pullOut2 = (& { mcp pull } 6>&1 | Out-String)
  Assert-True "re-pull adds 0" ($pullOut2 -match '\+0 added')

  Write-Host ""
  Write-Host "AI env MCP check passed." -ForegroundColor Green
}
finally {
  if ($null -ne $prev.H) { $env:AI_ENV_HOME = $prev.H } else { Remove-Item Env:AI_ENV_HOME -ErrorAction SilentlyContinue }
  if ($null -ne $prev.CJ) { $env:AI_CLAUDE_JSON_PATH = $prev.CJ } else { Remove-Item Env:AI_CLAUDE_JSON_PATH -ErrorAction SilentlyContinue }
  if ($null -ne $prev.CC) { $env:AI_CODEX_CONFIG_PATH = $prev.CC } else { Remove-Item Env:AI_CODEX_CONFIG_PATH -ErrorAction SilentlyContinue }
  if ($null -ne $prev.NI) { $env:AI_ENV_NONINTERACTIVE = $prev.NI } else { Remove-Item Env:AI_ENV_NONINTERACTIVE -ErrorAction SilentlyContinue }
  Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  Restore-TestProcessEnvironment -Snapshot $previousProcessEnvironment
}
