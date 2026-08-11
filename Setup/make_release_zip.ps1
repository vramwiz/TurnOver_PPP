$ErrorActionPreference = 'Stop'

$packageName = 'TurnOver_PPP'
$pluginDir = 'C:\ProgramData\aviutl2\Plugin\TurnOver_PPP'
$pluginFile = Join-Path $pluginDir 'TurnOver_PPP.auf2'
$debugDll = Join-Path $pluginDir 'TurnOver_PPP.dll'
$debugSymbols = Join-Path $pluginDir 'TurnOver_PPP.rsm'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$readmeFile = Join-Path $projectRoot 'README.md'
$workDir = Join-Path $PSScriptRoot $packageName
$zipFile = Join-Path $PSScriptRoot "$packageName.zip"

if (-not (Test-Path -LiteralPath $pluginFile -PathType Leaf)) {
  Write-Host 'Filter plugin not found:'
  Write-Host "  $pluginFile"
  Write-Host 'Build the Release configuration first, then run this batch again.'
  exit 1
}

if ((Test-Path -LiteralPath $debugDll -PathType Leaf) -or
    (Test-Path -LiteralPath $debugSymbols -PathType Leaf)) {
  Write-Host 'Debug build files remain in the plugin directory.'
  Write-Host 'Build the Release configuration first, then run this batch again.'
  Write-Host "  $pluginDir"
  exit 1
}

if (-not (Test-Path -LiteralPath $readmeFile -PathType Leaf)) {
  Write-Host 'README not found:'
  Write-Host "  $readmeFile"
  exit 1
}

$readmeText = Get-Content -LiteralPath $readmeFile -Raw
if ($readmeText -notmatch 'TurnOver_PPP' -or
    $readmeText -match '(?m)^#\s+Shake_PPP') {
  Write-Host 'README does not describe TurnOver_PPP:'
  Write-Host "  $readmeFile"
  exit 1
}

$setupRoot = [System.IO.Path]::GetFullPath($PSScriptRoot +
  [System.IO.Path]::DirectorySeparatorChar)
$resolvedWorkDir = [System.IO.Path]::GetFullPath($workDir)
$resolvedZipFile = [System.IO.Path]::GetFullPath($zipFile)
$staleOutputs = @(
  [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Shake_PPP')),
  [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Shake_PPP.zip'))
)
if (-not $resolvedWorkDir.StartsWith($setupRoot,
    [System.StringComparison]::OrdinalIgnoreCase) -or
    -not $resolvedZipFile.StartsWith($setupRoot,
    [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'Package output escaped the Setup directory.'
}

foreach ($staleOutput in $staleOutputs) {
  if (-not $staleOutput.StartsWith($setupRoot,
      [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Stale package output escaped the Setup directory.'
  }
  if (Test-Path -LiteralPath $staleOutput) {
    Remove-Item -LiteralPath $staleOutput -Recurse -Force
  }
}

if (Test-Path -LiteralPath $resolvedWorkDir) {
  Remove-Item -LiteralPath $resolvedWorkDir -Recurse -Force
}

if (Test-Path -LiteralPath $resolvedZipFile) {
  Remove-Item -LiteralPath $resolvedZipFile -Force
}

try {
  New-Item -ItemType Directory -Path $resolvedWorkDir -Force | Out-Null
  Copy-Item -LiteralPath $pluginFile -Destination $resolvedWorkDir -Force
  Copy-Item -LiteralPath $readmeFile -Destination $resolvedWorkDir -Force
  Compress-Archive -Path $resolvedWorkDir -DestinationPath $resolvedZipFile -Force

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedZipFile)
  try {
    $entryNames = @($archive.Entries | ForEach-Object {
      $_.FullName.Replace('\', '/')
    })
    $requiredEntries = @(
      "$packageName/$packageName.auf2",
      "$packageName/README.md"
    )
    foreach ($requiredEntry in $requiredEntries) {
      if ($entryNames -notcontains $requiredEntry) {
        throw "Required zip entry is missing: $requiredEntry"
      }
    }
    if ($entryNames | Where-Object { $_ -match 'Shake_PPP' }) {
      throw 'The zip contains a stale Shake_PPP entry.'
    }
  }
  finally {
    $archive.Dispose()
  }
}
finally {
  if (Test-Path -LiteralPath $resolvedWorkDir) {
    Remove-Item -LiteralPath $resolvedWorkDir -Recurse -Force
  }
}

Write-Host 'Created:'
Write-Host "  $resolvedZipFile"
