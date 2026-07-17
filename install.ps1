[CmdletBinding()]
param(
  [string]$Version,
  [string]$ArtifactPath,
  [string]$Sha256,
  [string]$InstallRoot,
  [switch]$Rollback,
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$repository = "Tim-1e/cxcc"
$versionPattern = '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
$rootMarkerContent = "cxcc-install-root-v1"

function Resolve-CxccInstallRoot {
  param([string]$RequestedRoot)

  $root = if ($RequestedRoot) {
    [Environment]::ExpandEnvironmentVariables($RequestedRoot)
  } elseif ($env:CXCC_HOME) {
    [Environment]::ExpandEnvironmentVariables($env:CXCC_HOME)
  } else {
    Join-Path $HOME ".local\share\cxcc"
  }
  $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
  $homeRoot = [IO.Path]::GetFullPath($HOME).TrimEnd('\', '/')
  $volumeRoot = [IO.Path]::GetPathRoot($fullRoot).TrimEnd('\', '/')
  if (-not $fullRoot -or $fullRoot -eq $volumeRoot -or $fullRoot.Equals($homeRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $fullRoot) -ine "cxcc") {
    throw "Refusing unsafe cxcc install root: $fullRoot"
  }
  return $fullRoot
}

function Assert-CxccRootMarker {
  param([string]$Root, [switch]$RequireLayout)
  $markerPath = Join-Path $Root ".cxcc-root"
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or (Get-Content -LiteralPath $markerPath -Raw).Trim() -cne $script:rootMarkerContent) {
    throw "Refusing to use an unrecognized cxcc install root: $Root"
  }
  if ($RequireLayout) {
    foreach ($relativePath in @("current.json", "load.ps1", "load.sh", "versions")) {
      if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath))) {
        throw "Refusing to remove an incomplete cxcc install root: $Root"
      }
    }
    $reparsePoint = Get-ChildItem -LiteralPath $Root -Force -Recurse | Where-Object {
      ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    } | Select-Object -First 1
    if ($reparsePoint) { throw "Refusing to remove a cxcc root containing a reparse point: $($reparsePoint.FullName)" }
  }
}

function Assert-CxccInstallDestination {
  param([string]$Root)
  if (-not (Test-Path -LiteralPath $Root)) { return }
  $rootItem = Get-Item -LiteralPath $Root -Force
  if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing a reparse-point cxcc install root: $Root"
  }
  $markerPath = Join-Path $Root ".cxcc-root"
  if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    Assert-CxccRootMarker -Root $Root
  } elseif (@(Get-ChildItem -LiteralPath $Root -Force).Count -gt 0) {
    throw "Refusing to install into a non-empty unrecognized directory: $Root"
  }
}

function Assert-CxccVersion {
  param([string]$Value)
  if (-not $Value -or $Value -notmatch $script:versionPattern) {
    throw "Version must be an exact release tag such as v0.1.0."
  }
}

function Get-CxccCurrent {
  param([string]$Root)
  $path = Join-Path $Root "current.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try {
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  } catch {
    throw "cxcc current.json is invalid: $($_.Exception.Message)"
  }
  Assert-CxccVersion -Value ([string]$state.version)
  if ($null -ne $state.previous -and [string]$state.previous) {
    Assert-CxccVersion -Value ([string]$state.previous)
  }
  return $state
}

function Complete-CxccFileAtomic {
  param([string]$TempPath, [string]$Destination)
  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    $backupPath = "$Destination.$([guid]::NewGuid().ToString("N")).backup"
    try {
      [IO.File]::Replace($TempPath, $Destination, $backupPath)
    } finally {
      Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
  } else {
    [IO.File]::Move($TempPath, $Destination)
  }
}

function Write-CxccFileAtomic {
  param([string]$Destination, [string]$Content)

  $directory = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $tempPath = Join-Path $directory ("." + (Split-Path -Leaf $Destination) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    [IO.File]::WriteAllText($tempPath, $Content, [Text.UTF8Encoding]::new($false))
    Complete-CxccFileAtomic -TempPath $tempPath -Destination $Destination
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}

function Copy-CxccFileAtomic {
  param([string]$Source, [string]$Destination)
  $bytes = [IO.File]::ReadAllBytes($Source)
  $directory = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $tempPath = Join-Path $directory ("." + (Split-Path -Leaf $Destination) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    [IO.File]::WriteAllBytes($tempPath, $bytes)
    Complete-CxccFileAtomic -TempPath $tempPath -Destination $Destination
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-CxccLoaders {
  param([string]$Root, [string]$VersionRoot)
  foreach ($name in @("load.ps1", "load.sh")) {
    $destination = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
      Copy-CxccFileAtomic -Source (Join-Path $VersionRoot $name) -Destination $destination
    }
  }
}

function Write-CxccCurrent {
  param([string]$Root, [string]$CurrentVersion, [AllowNull()][string]$PreviousVersion)
  $state = [ordered]@{ schema = 1; version = $CurrentVersion; previous = $PreviousVersion }
  $json = ($state | ConvertTo-Json -Compress) + "`n"
  Write-CxccFileAtomic -Destination (Join-Path $Root "current.json") -Content $json
}

function Assert-CxccPayload {
  param([string]$PayloadRoot, [string]$ExpectedVersion)

  $required = @(
    "VERSION",
    "load.ps1",
    "load.sh",
    "src\powershell\CxCc\CxCc.ps1",
    "src\shell\cxcc.sh",
    "src\shell\ai-health.mjs",
    "src\bridge\CodexProviderBridge\CodexProviderBridge.csproj",
    "templates\profiles.json"
  )
  foreach ($relativePath in $required) {
    $path = Join-Path $PayloadRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "cxcc artifact is missing $relativePath."
    }
  }
  $actualVersion = (Get-Content -LiteralPath (Join-Path $PayloadRoot "VERSION") -Raw).Trim()
  if ($actualVersion -cne $ExpectedVersion) {
    throw "cxcc artifact VERSION is '$actualVersion', expected '$ExpectedVersion'."
  }
}

function Assert-CxccZipSafe {
  param([string]$Path)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($Path)
  try {
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or ("/$name/" -match '/\.\./')) {
        throw "cxcc artifact contains an unsafe path: $name"
      }
      $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
      if ($unixType -notin @(0, 0x4000, 0x8000)) {
        throw "cxcc artifact contains a link or special file: $name"
      }
    }
  } finally {
    $zip.Dispose()
  }
}

function Get-CxccManifestSha256 {
  param([string]$ManifestPath, [string]$AssetName)
  foreach ($line in Get-Content -LiteralPath $ManifestPath) {
    if ($line -match '^([0-9A-Fa-f]{64})\s+\*?(.+)$' -and $Matches[2] -ceq $AssetName) {
      return $Matches[1].ToLowerInvariant()
    }
  }
  throw "SHA256SUMS does not contain $AssetName."
}

function Resolve-CxccArtifact {
  param([string]$RequestedPath, [string]$RequestedSha256, [string]$RequestedVersion)

  if ($RequestedPath) {
    if (-not $RequestedSha256) { throw "-Sha256 is required with -ArtifactPath." }
    $resolvedPath = (Resolve-Path -LiteralPath $RequestedPath).Path
    return [pscustomobject]@{ Path = $resolvedPath; Sha256 = $RequestedSha256.ToLowerInvariant(); TempRoot = $null }
  }
  if ($RequestedSha256) { throw "-ArtifactPath is required with -Sha256." }

  $assetName = "cxcc-$RequestedVersion-windows-x64.zip"
  $releaseBase = "https://github.com/$script:repository/releases/download/$RequestedVersion"
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("cxcc-download-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  try {
    $manifestPath = Join-Path $tempRoot "SHA256SUMS"
    $archivePath = Join-Path $tempRoot $assetName
    Invoke-WebRequest -Uri "$releaseBase/SHA256SUMS" -OutFile $manifestPath
    Invoke-WebRequest -Uri "$releaseBase/$assetName" -OutFile $archivePath
    $expected = Get-CxccManifestSha256 -ManifestPath $manifestPath -AssetName $assetName
    return [pscustomobject]@{ Path = $archivePath; Sha256 = $expected; TempRoot = $tempRoot }
  } catch {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Install-CxccVersion {
  param([string]$Root, [string]$RequestedVersion, [string]$RequestedPath, [string]$RequestedSha256)

  Assert-CxccVersion -Value $RequestedVersion
  $artifact = Resolve-CxccArtifact -RequestedPath $RequestedPath -RequestedSha256 $RequestedSha256 -RequestedVersion $RequestedVersion
  $stagingPath = $null
  try {
    if ($artifact.Sha256 -notmatch '^[0-9a-f]{64}$') { throw "SHA-256 must contain 64 hexadecimal characters." }
    $actualSha256 = (Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -cne $artifact.Sha256) {
      throw "cxcc artifact checksum mismatch. Expected $($artifact.Sha256), got $actualSha256."
    }
    Assert-CxccZipSafe -Path $artifact.Path
    Assert-CxccInstallDestination -Root $Root
    $markerPath = Join-Path $Root ".cxcc-root"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
      Write-CxccFileAtomic -Destination $markerPath -Content "$script:rootMarkerContent`n"
    }

    $versionsRoot = Join-Path $Root "versions"
    $targetPath = Join-Path $versionsRoot $RequestedVersion
    $current = Get-CxccCurrent -Root $Root
    if (Test-Path -LiteralPath $targetPath -PathType Container) {
      Assert-CxccPayload -PayloadRoot $targetPath -ExpectedVersion $RequestedVersion
      $installedShaPath = Join-Path $targetPath ".artifact-sha256"
      if (-not (Test-Path -LiteralPath $installedShaPath -PathType Leaf) -or (Get-Content -LiteralPath $installedShaPath -Raw).Trim() -cne $actualSha256) {
        throw "Installed $RequestedVersion differs from the verified artifact."
      }
    } else {
      New-Item -ItemType Directory -Force -Path $versionsRoot | Out-Null
      $stagingPath = Join-Path $Root (".staging-" + [guid]::NewGuid().ToString("N"))
      New-Item -ItemType Directory -Path $stagingPath | Out-Null
      Expand-Archive -LiteralPath $artifact.Path -DestinationPath $stagingPath
      Assert-CxccPayload -PayloadRoot $stagingPath -ExpectedVersion $RequestedVersion
      [IO.File]::WriteAllText((Join-Path $stagingPath ".artifact-sha256"), "$actualSha256`n", [Text.UTF8Encoding]::new($false))
      Move-Item -LiteralPath $stagingPath -Destination $targetPath
      $stagingPath = $null
    }

    Ensure-CxccLoaders -Root $Root -VersionRoot $targetPath
    if ($current -and [string]$current.version -ceq $RequestedVersion) {
      Write-Host "cxcc $RequestedVersion is already installed."
      return
    }
    $previous = if ($current) { [string]$current.version } else { $null }
    Write-CxccCurrent -Root $Root -CurrentVersion $RequestedVersion -PreviousVersion $previous
    Write-Host "cxcc $RequestedVersion installed at $Root"
  } finally {
    if ($stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue }
    if ($artifact.TempRoot) { Remove-Item -LiteralPath $artifact.TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-CxccRollback {
  param([string]$Root)
  Assert-CxccRootMarker -Root $Root -RequireLayout
  $current = Get-CxccCurrent -Root $Root
  if (-not $current -or -not [string]$current.previous) { throw "No previous cxcc version is available for rollback." }
  $previous = [string]$current.previous
  $targetPath = Join-Path (Join-Path $Root "versions") $previous
  Assert-CxccPayload -PayloadRoot $targetPath -ExpectedVersion $previous
  Write-CxccCurrent -Root $Root -CurrentVersion $previous -PreviousVersion ([string]$current.version)
  Write-Host "cxcc rolled back to $previous."
}

if ($Rollback -and $Uninstall) { throw "Choose either -Rollback or -Uninstall." }
$resolvedInstallRoot = Resolve-CxccInstallRoot -RequestedRoot $InstallRoot
if ($Uninstall) {
  if (Test-Path -LiteralPath $resolvedInstallRoot) {
    Assert-CxccInstallDestination -Root $resolvedInstallRoot
    Assert-CxccRootMarker -Root $resolvedInstallRoot -RequireLayout
    Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force
  }
  Write-Host "cxcc uninstalled from $resolvedInstallRoot. User state was preserved."
} elseif ($Rollback) {
  Invoke-CxccRollback -Root $resolvedInstallRoot
} else {
  Install-CxccVersion -Root $resolvedInstallRoot -RequestedVersion $Version -RequestedPath $ArtifactPath -RequestedSha256 $Sha256
}
