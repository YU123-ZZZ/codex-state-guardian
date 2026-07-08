@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
set "GUARDIAN_SELF=%~f0"
set "GUARDIAN_PAYLOAD="
:make_payload_name
set "GUARDIAN_PAYLOAD=%TEMP%\codex-state-guardian-%RANDOM%-%RANDOM%-%RANDOM%-%TIME::=%.ps1"
set "GUARDIAN_PAYLOAD=%GUARDIAN_PAYLOAD: =0%"
if exist "%GUARDIAN_PAYLOAD%" goto make_payload_name
powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwB0AG8AcAAnAAoAJAByAGEAdwA9AFsASQBPAC4ARgBpAGwAZQBdADoAOgBSAGUAYQBkAEEAbABsAFQAZQB4AHQAKAAkAGUAbgB2ADoARwBVAEEAUgBEAEkAQQBOAF8AUwBFAEwARgAsAFsAVABlAHgAdAAuAEUAbgBjAG8AZABpAG4AZwBdADoAOgBVAFQARgA4ACkACgAkAG0AYQByAGsAPQAnACMAIABQAE8AVwBFAFIAUwBIAEUATABMAC0AQgBFAEcASQBOACcACgAkAGkAPQAkAHIAYQB3AC4ATABhAHMAdABJAG4AZABlAHgATwBmACgAJABtAGEAcgBrACkACgBpAGYAKAAkAGkAIAAtAGwAdAAgADAAKQB7ACAAdABoAHIAbwB3ACAAJwBQAG8AdwBlAHIAUwBoAGUAbABsACAAcABhAHkAbABvAGEAZAAgAG0AYQByAGsAZQByACAAbgBvAHQAIABmAG8AdQBuAGQALgAnACAAfQAKACQAcABhAHkAbABvAGEAZAA9ACQAcgBhAHcALgBTAHUAYgBzAHQAcgBpAG4AZwAoACQAaQArACQAbQBhAHIAawAuAEwAZQBuAGcAdABoACkALgBUAHIAaQBtAFMAdABhAHIAdAAoACkACgBbAEkATwAuAEYAaQBsAGUAXQA6ADoAVwByAGkAdABlAEEAbABsAFQAZQB4AHQAKAAkAGUAbgB2ADoARwBVAEEAUgBEAEkAQQBOAF8AUABBAFkATABPAEEARAAsACQAcABhAHkAbABvAGEAZAAsAFsAVABlAHgAdAAuAEUAbgBjAG8AZABpAG4AZwBdADoAOgBVAG4AaQBjAG8AZABlACkA
if not "%ERRORLEVEL%"=="0" (
  echo [Codex守护] 无法准备内置脚本。
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%GUARDIAN_PAYLOAD%" %*
set "ERR=%ERRORLEVEL%"
del "%GUARDIAN_PAYLOAD%" >nul 2>nul
if not "%ERR%"=="0" (
  echo.
  echo [Codex守护] 运行失败，退出码：%ERR%。
)
if "%~1"=="" (
  echo.
  pause
)
exit /b %ERR%

# POWERSHELL-BEGIN
param(
  [Alias('操作')]
  [string]$Action = '',
  [Alias('备份文件夹')]
  [string]$BackupName = '',
  [Alias('数据目录')]
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [Alias('备份目录')]
  [string]$BackupRoot = '',
  [Alias('最多保留')]
  [int]$MaxBackups = 5,
  [Alias('最少健康备份')]
  [int]$MinHealthyBackups = 2,
  [Alias('最短间隔分钟')]
  [int]$MinBackupIntervalMinutes = 10,
  [Alias('强制')]
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptPath = $env:GUARDIAN_SELF
$ScriptDir = Split-Path -Parent $ScriptPath
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
  $BackupRoot = Join-Path $ScriptDir 'codex-state-backups'
}

$ToolVersion = '2026-06-30-single-cmd'
$ProtectedItems = @(
  @{ Path = 'config.toml'; Type = 'File'; Category = 'settings' },
  @{ Path = '.codex-global-state.json'; Type = 'File'; Category = 'settings' },
  @{ Path = 'session_index.jsonl'; Type = 'File'; Category = 'chat' },
  @{ Path = 'state_5.sqlite'; Type = 'File'; Category = 'chat' },
  @{ Path = 'state_5.sqlite-wal'; Type = 'File'; Category = 'chat' },
  @{ Path = 'state_5.sqlite-shm'; Type = 'File'; Category = 'chat' },
  @{ Path = 'sessions'; Type = 'Directory'; Category = 'chat' },
  @{ Path = 'archived_sessions'; Type = 'Directory'; Category = 'chat' }
)
$DuplicateComparisonPaths = @(
  'config.toml',
  '.codex-global-state.json',
  'session_index.jsonl',
  'state_5.sqlite',
  'state_5.sqlite-wal',
  'state_5.sqlite-shm',
  'sessions',
  'archived_sessions'
)
$BackupVerificationAttempts = 3
$BackupRetryDelayMilliseconds = 700

function Should-PreserveConfigTopLevelKey([string]$Key) {
  return ($Key -eq 'model' -or $Key -like 'model_*')
}

function Should-PreserveConfigSection([string]$Name) {
  return ($Name -eq 'model_providers' -or $Name -like 'model_providers.*')
}

function Get-ConfigBlocks {
  param([string]$Text)

  $normalized = $Text -replace "`r`n", "`n"
  $lines = [regex]::Split($normalized, "`n")
  $blocks = New-Object 'System.Collections.Generic.List[hashtable]'
  $currentName = '__TOP__'
  $currentLines = New-Object 'System.Collections.Generic.List[string]'

  foreach ($line in $lines) {
    if ($line -match '^\s*\[(.+)\]\s*$') {
      $blocks.Add(@{
          Name = $currentName
          Lines = @($currentLines.ToArray())
        })
      $currentName = $matches[1]
      $currentLines = New-Object 'System.Collections.Generic.List[string]'
    }
    $currentLines.Add($line)
  }

  $blocks.Add(@{
      Name = $currentName
      Lines = @($currentLines.ToArray())
    })
  return @($blocks.ToArray())
}

function Get-ConfigBlockLines {
  param(
    [hashtable[]]$Blocks,
    [string]$Name
  )

  foreach ($block in $Blocks) {
    if ($block.Name -eq $Name) {
      return @($block.Lines)
    }
  }
  return @()
}

function Merge-ConfigTopLevelBlock {
  param(
    [string[]]$BackupLines,
    [string[]]$CurrentLines
  )

  $currentPreservedLookup = @{}
  $currentPreservedOrder = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in $CurrentLines) {
    if ($line -match '^\s*([A-Za-z0-9_\-]+)\s*=') {
      $key = $matches[1]
      if ((Should-PreserveConfigTopLevelKey -Key $key) -and -not $currentPreservedLookup.ContainsKey($key)) {
        $currentPreservedLookup[$key] = $line
        $null = $currentPreservedOrder.Add($key)
      }
    }
  }

  $merged = New-Object 'System.Collections.Generic.List[string]'
  $usedKeys = @{}
  foreach ($line in $BackupLines) {
    if ($line -match '^\s*([A-Za-z0-9_\-]+)\s*=') {
      $key = $matches[1]
      if ((Should-PreserveConfigTopLevelKey -Key $key) -and $currentPreservedLookup.ContainsKey($key)) {
        $merged.Add($currentPreservedLookup[$key])
        $usedKeys[$key] = $true
        continue
      }
    }
    $merged.Add($line)
  }

  foreach ($key in $currentPreservedOrder) {
    if (-not $usedKeys.ContainsKey($key)) {
      $merged.Add($currentPreservedLookup[$key])
    }
  }

  return @($merged.ToArray())
}

function Add-ConfigBlockLines {
  param(
    [System.Collections.Generic.List[string]]$Output,
    [string[]]$Lines
  )

  foreach ($line in $Lines) {
    $Output.Add($line)
  }
}

function Merge-ConfigTomlText {
  param(
    [string]$CurrentText,
    [string]$BackupText
  )

  $currentBlocks = @(Get-ConfigBlocks -Text $CurrentText)
  $backupBlocks = @(Get-ConfigBlocks -Text $BackupText)
  $currentProviderBlocks = @($currentBlocks | Where-Object { Should-PreserveConfigSection -Name $_.Name })
  $backupHasProviderBlocks = @($backupBlocks | Where-Object { Should-PreserveConfigSection -Name $_.Name }).Count -gt 0
  $currentTopLevelLines = @(Get-ConfigBlockLines -Blocks $currentBlocks -Name '__TOP__')

  $mergedLines = New-Object 'System.Collections.Generic.List[string]'
  $providerBlocksInserted = $false

  foreach ($block in $backupBlocks) {
    if ($block.Name -eq '__TOP__') {
      Add-ConfigBlockLines -Output $mergedLines -Lines (Merge-ConfigTopLevelBlock -BackupLines $block.Lines -CurrentLines $currentTopLevelLines)
      if (-not $backupHasProviderBlocks -and $currentProviderBlocks.Count -gt 0) {
        foreach ($providerBlock in $currentProviderBlocks) {
          Add-ConfigBlockLines -Output $mergedLines -Lines $providerBlock.Lines
        }
        $providerBlocksInserted = $true
      }
      continue
    }

    if (Should-PreserveConfigSection -Name $block.Name) {
      if (-not $providerBlocksInserted) {
        foreach ($providerBlock in $currentProviderBlocks) {
          Add-ConfigBlockLines -Output $mergedLines -Lines $providerBlock.Lines
        }
        $providerBlocksInserted = $true
      }
      continue
    }

    Add-ConfigBlockLines -Output $mergedLines -Lines $block.Lines
  }

  if (-not $providerBlocksInserted -and $currentProviderBlocks.Count -gt 0) {
    if ($mergedLines.Count -gt 0 -and $mergedLines[$mergedLines.Count - 1] -ne '') {
      $mergedLines.Add('')
    }
    foreach ($providerBlock in $currentProviderBlocks) {
      Add-ConfigBlockLines -Output $mergedLines -Lines $providerBlock.Lines
    }
  }

  $mergedText = (@($mergedLines.ToArray()) -join "`r`n").TrimEnd("`r", "`n")
  return "$mergedText`r`n"
}

function Write-Info([string]$Message) {
  Write-Host "[Codex守护] $Message"
}

function Write-Detail([string]$Message) {
  Write-Host "  $Message"
}

function Write-Warn([string]$Message) {
  Write-Host "[警告] $Message" -ForegroundColor Yellow
}

function Format-YesNo([object]$Value) {
  if ([bool]$Value) { return '是' }
  return '否'
}

function Format-SavedTime([object]$Value) {
  if ($null -eq $Value) { return '未知' }
  try {
    return ([datetime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
      )).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
  } catch {
    return [string]$Value
  }
}

function Get-BackupKindLabel([string]$Kind) {
  switch ($Kind) {
    'healthy' { return '健康备份' }
    '健康备份' { return '健康备份' }
    'pre-restore' { return '恢复前备份' }
    '恢复前备份' { return '恢复前备份' }
    default {
      if ([string]::IsNullOrWhiteSpace($Kind)) { return '未知' }
      return $Kind
    }
  }
}

function Test-HealthyBackupKind([string]$Kind) {
  $label = Get-BackupKindLabel -Kind $Kind
  return $label -eq '健康备份'
}

function Test-BackupDirectoryName([string]$Name) {
  return (
    $Name -like '健康备份-*' -or
    $Name -like '恢复前备份-*' -or
    $Name -like 'healthy-*' -or
    $Name -like 'pre-restore-*'
  )
}

function Test-Confirmed([string]$Answer) {
  if ($null -eq $Answer) { return $false }
  $text = $Answer.Trim()
  return ($text -eq '确认' -or $text.ToUpperInvariant() -eq 'YES')
}

function Assert-SafePath {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Root
  )

  $resolvedRoot = [IO.Path]::GetFullPath($Root)
  $resolvedPath = [IO.Path]::GetFullPath($Path)
  if (-not $resolvedRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) {
    $resolvedRoot += [IO.Path]::DirectorySeparatorChar
  }

  if (-not $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝访问根目录外的不安全路径：$resolvedPath"
  }
}

function Get-TextHash([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally {
    $sha.Dispose()
  }
}

function Copy-FileSharedRead {
  param(
    [Parameter(Mandatory)] [string]$Source,
    [Parameter(Mandatory)] [string]$Destination
  )

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
  $inputStream = $null
  $outputStream = $null
  try {
    $inputStream = [IO.File]::Open(
      $Source,
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      [IO.FileShare]::ReadWrite
    )
    $outputStream = [IO.File]::Open(
      $Destination,
      [IO.FileMode]::Create,
      [IO.FileAccess]::Write,
      [IO.FileShare]::None
    )
    $inputStream.CopyTo($outputStream)
    $outputStream.Flush()
  } finally {
    if ($null -ne $outputStream) { $outputStream.Dispose() }
    if ($null -ne $inputStream) { $inputStream.Dispose() }
  }

  $sourceInfo = Get-Item -LiteralPath $Source
  $destInfo = Get-Item -LiteralPath $Destination
  $destInfo.LastWriteTimeUtc = $sourceInfo.LastWriteTimeUtc
}

function Copy-DirectoryContents {
  param(
    [Parameter(Mandatory)] [string]$Source,
    [Parameter(Mandatory)] [string]$Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  $sourceRoot = [IO.Path]::GetFullPath($Source)
  if (-not $sourceRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) {
    $sourceRoot += [IO.Path]::DirectorySeparatorChar
  }

  foreach ($dir in Get-ChildItem -LiteralPath $Source -Recurse -Force -Directory -ErrorAction SilentlyContinue) {
    $relative = $dir.FullName.Substring($sourceRoot.Length)
    New-Item -ItemType Directory -Force -Path (Join-Path $Destination $relative) | Out-Null
  }

  foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -Force -File -ErrorAction SilentlyContinue) {
    $relative = $file.FullName.Substring($sourceRoot.Length)
    Copy-FileSharedRead -Source $file.FullName -Destination (Join-Path $Destination $relative)
  }
}

function Get-EnabledPlugins {
  param([string]$ConfigPath)

  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return @()
  }

  $text = Get-Content -LiteralPath $ConfigPath -Raw
  $matches = [regex]::Matches(
    $text,
    '(?ms)^\[plugins\."([^"]+)"\]\s*\r?\n(?:(?!^\[).)*?^\s*enabled\s*=\s*true\s*$'
  )
  return @($matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Test-CodexStateJson {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @{ Ok = $false; Reason = '文件不存在' }
  }

  try {
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return @{ Ok = $false; Reason = '文件为空' }
    }
    $null = $raw | ConvertFrom-Json
    return @{ Ok = $true; Reason = '正常' }
  } catch {
    $raw = Get-Content -LiteralPath $Path -Raw
    $hasSignature = $raw.Contains('"electron-persisted-atom-state"') -and
      $raw.Contains('"electron-main-window-bounds"')
    if ($hasSignature) {
      return @{ Ok = $true; Reason = '严格 JSON 解析失败，但存在 Codex 状态特征' }
    }
    return @{ Ok = $false; Reason = 'JSON 无效，并且缺少 Codex 状态特征' }
  }
}

function Get-ProtectedItemSummary {
  param(
    [string]$Root,
    [hashtable]$Item
  )

  $relative = [string]$Item.Path
  $type = [string]$Item.Type
  $path = Join-Path $Root $relative

  if ($type -eq 'File') {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      return @{
        type = $type
        category = $Item.Category
        exists = $false
        fileCount = 0
        size = 0
        lastWriteTimeUtc = $null
        fingerprint = $null
      }
    }

    $file = Get-Item -LiteralPath $path
    return @{
      type = $type
      category = $Item.Category
      exists = $true
      fileCount = 1
      size = [int64]$file.Length
      lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
      fingerprint = Get-TextHash "$relative|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
    }
  }

  if (-not (Test-Path -LiteralPath $path -PathType Container)) {
    return @{
      type = $type
      category = $Item.Category
      exists = $false
      fileCount = 0
      size = 0
      lastWriteTimeUtc = $null
      fingerprint = $null
    }
  }

  $rootFull = [IO.Path]::GetFullPath($path)
  if (-not $rootFull.EndsWith([IO.Path]::DirectorySeparatorChar)) {
    $rootFull += [IO.Path]::DirectorySeparatorChar
  }

  $files = @(Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object FullName)
  $totalSize = [int64]0
  $latestWrite = $null
  $lines = New-Object Collections.Generic.List[string]

  foreach ($file in $files) {
    $relativeFile = $file.FullName.Substring($rootFull.Length).Replace('\', '/')
    $totalSize += [int64]$file.Length
    if ($null -eq $latestWrite -or $file.LastWriteTimeUtc -gt $latestWrite) {
      $latestWrite = $file.LastWriteTimeUtc
    }
    $lines.Add("$relativeFile|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)")
  }

  return @{
    type = $type
    category = $Item.Category
    exists = $true
    fileCount = $files.Count
    size = $totalSize
    lastWriteTimeUtc = if ($null -eq $latestWrite) { $null } else { $latestWrite.ToString('o') }
    fingerprint = Get-TextHash (($lines | Sort-Object) -join "`n")
  }
}

function Get-StateItem {
  param(
    [hashtable]$State,
    [string]$RelativePath
  )

  if ($State.ContainsKey('items') -and $State.items.ContainsKey($RelativePath)) {
    return $State.items[$RelativePath]
  }
  return $null
}

function Get-ItemFingerprint {
  param([hashtable]$Item)

  if ($null -eq $Item) { return $null }
  if ($Item.ContainsKey('fingerprint')) { return $Item.fingerprint }
  if ($Item.ContainsKey('sha256')) { return $Item.sha256 }
  return $null
}

function Get-ChatSummary {
  param([hashtable]$State)

  $chatFiles = 0
  $chatBytes = [int64]0
  $activeFiles = 0
  $archivedFiles = 0
  $indexExists = $false
  $dbFiles = 0

  foreach ($item in $ProtectedItems) {
    if ($item.Category -ne 'chat') { continue }
    $summary = Get-StateItem -State $State -RelativePath $item.Path
    if ($null -eq $summary -or -not [bool]$summary.exists) { continue }

    $chatFiles += [int]$summary.fileCount
    $chatBytes += [int64]$summary.size

    switch ($item.Path) {
      'sessions' { $activeFiles = [int]$summary.fileCount }
      'archived_sessions' { $archivedFiles = [int]$summary.fileCount }
      'session_index.jsonl' { $indexExists = $true }
      default {
        if ([string]$item.Path -like 'state_5.sqlite*') {
          $dbFiles += [int]$summary.fileCount
        }
      }
    }
  }

  return @{
    fileCount = $chatFiles
    size = $chatBytes
    activeSessionFiles = $activeFiles
    archivedSessionFiles = $archivedFiles
    sessionIndexExists = $indexExists
    stateDbFiles = $dbFiles
  }
}

function Get-CurrentState {
  param([string]$Root)

  $items = @{}
  foreach ($item in $ProtectedItems) {
    $items[$item.Path] = Get-ProtectedItemSummary -Root $Root -Item $item
  }

  $plugins = Get-EnabledPlugins -ConfigPath (Join-Path $Root 'config.toml')
  $state = @{
    toolVersion = $ToolVersion
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    codexHome = [IO.Path]::GetFullPath($Root)
    enabledPlugins = @($plugins)
    enabledPluginCount = @($plugins).Count
    globalStateJson = Test-CodexStateJson -Path (Join-Path $Root '.codex-global-state.json')
    items = $items
  }
  $state.chat = Get-ChatSummary -State $state
  return $state
}

function Test-StateHealthy {
  param([hashtable]$State)

  $problems = New-Object Collections.Generic.List[string]
  $config = Get-StateItem -State $State -RelativePath 'config.toml'
  $global = Get-StateItem -State $State -RelativePath '.codex-global-state.json'
  $sessionIndex = Get-StateItem -State $State -RelativePath 'session_index.jsonl'
  $sessions = Get-StateItem -State $State -RelativePath 'sessions'
  $archived = Get-StateItem -State $State -RelativePath 'archived_sessions'

  if ($null -eq $config -or -not [bool]$config.exists -or [int64]$config.size -lt 1) {
    $problems.Add('config.toml 缺失或为空')
  }
  if (-not [bool]$State.globalStateJson.Ok) {
    $problems.Add(".codex-global-state.json 状态：$($State.globalStateJson.Reason)")
  }
  if ($null -eq $global -or -not [bool]$global.exists -or [int64]$global.size -lt 1) {
    $problems.Add('.codex-global-state.json 缺失或为空')
  }

  if ($null -eq $sessionIndex -or -not [bool]$sessionIndex.exists) {
    $problems.Add('session_index.jsonl 缺失')
  }
  if ($null -eq $sessions -or -not [bool]$sessions.exists) {
    $problems.Add('sessions 文件夹缺失')
  }
  if ($null -eq $archived -or -not [bool]$archived.exists) {
    $problems.Add('archived_sessions 文件夹缺失')
  }

  return @{
    Ok = $problems.Count -eq 0
    Problems = @($problems)
  }
}

function Get-BackupTimestamp {
  param(
    [string]$BackupName,
    [datetime]$Fallback
  )

  $match = [regex]::Match($BackupName, '(\d{8}-\d{6})')
  if ($match.Success) {
    try {
      return [datetime]::ParseExact(
        $match.Groups[1].Value,
        'yyyyMMdd-HHmmss',
        [Globalization.CultureInfo]::InvariantCulture
      )
    } catch {
      return $Fallback
    }
  }
  return $Fallback
}

function Get-BackupDirectories {
  param([string]$Root)

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return @()
  }

  return @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-BackupDirectoryName -Name $_.Name } |
    Sort-Object @{ Expression = { Get-BackupTimestamp -BackupName $_.Name -Fallback $_.LastWriteTime }; Descending = $true }, Name)
}

function Read-Manifest {
  param([string]$BackupDir)

  $manifestPath = Join-Path $BackupDir 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    return $null
  }

  $object = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  return ConvertTo-PlainHash $object
}

function ConvertTo-PlainHash {
  param([object]$Object)

  if ($null -eq $Object) { return $null }
  if ($Object -is [Collections.IDictionary]) {
    $hash = @{}
    foreach ($key in $Object.Keys) { $hash[$key] = ConvertTo-PlainHash $Object[$key] }
    return $hash
  }
  if ($Object -is [Management.Automation.PSCustomObject]) {
    $hash = @{}
    foreach ($property in $Object.PSObject.Properties) { $hash[$property.Name] = ConvertTo-PlainHash $property.Value }
    return $hash
  }
  if ($Object -is [Array] -and -not ($Object -is [string])) {
    return @($Object | ForEach-Object { ConvertTo-PlainHash $_ })
  }
  return $Object
}

function Get-LatestHealthyBackup {
  param([string]$Root)

  foreach ($dir in (Get-BackupDirectories -Root $Root | Where-Object { $_.Name -like '健康备份-*' -or $_.Name -like 'healthy-*' })) {
    $manifest = Read-Manifest -BackupDir $dir.FullName
    if ($null -ne $manifest -and (Test-HealthyBackupKind -Kind ([string]$manifest.kind))) {
      return @{ Directory = $dir.FullName; Manifest = $manifest }
    }
  }
  return $null
}

function Get-RunningCodexProcesses {
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ProcessName -match 'Codex|OpenAI\.Codex'
    })
}

function Resolve-Backup {
  param(
    [string]$Root,
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Name)) {
    $latest = Get-LatestHealthyBackup -Root $Root
    if ($null -eq $latest) { throw '没有找到健康备份。' }
    return $latest
  }

  $dir = if ([IO.Path]::IsPathRooted($Name)) { $Name } else { Join-Path $Root $Name }
  Assert-SafePath -Path $dir -Root $Root
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    throw "没有找到备份：$Name"
  }

  $manifest = Read-Manifest -BackupDir $dir
  if ($null -eq $manifest) {
    throw "备份缺少 manifest.json：$dir"
  }

  return @{ Directory = [IO.Path]::GetFullPath($dir); Manifest = $manifest }
}

function Test-SameAsLatest {
  param(
    [hashtable]$Current,
    [hashtable]$Latest
  )

  if ($null -eq $Latest) { return $false }
  $baseline = $Latest.Manifest.state

  return (Compare-StateFingerprints -Left $Current -Right $baseline).Ok
}

function Compare-StateFingerprints {
  param(
    [hashtable]$Left,
    [hashtable]$Right,
    [string[]]$Paths = $DuplicateComparisonPaths
  )

  $differences = New-Object Collections.Generic.List[string]

  foreach ($path in $Paths) {
    $leftItem = Get-StateItem -State $Left -RelativePath $path
    $rightItem = Get-StateItem -State $Right -RelativePath $path
    if ($null -eq $leftItem -and $null -eq $rightItem) { continue }
    if ($null -eq $leftItem -or $null -eq $rightItem) {
      $differences.Add("${path}:missing")
      continue
    }
    if ([bool]$leftItem.exists -ne [bool]$rightItem.exists) {
      $differences.Add("${path}:exists")
      continue
    }
    if ((Get-ItemFingerprint $leftItem) -ne (Get-ItemFingerprint $rightItem)) {
      $differences.Add("${path}:fingerprint")
    }
  }

  return @{
    Ok = $differences.Count -eq 0
    Differences = @($differences)
  }
}

function Compare-AgainstBaseline {
  param(
    [hashtable]$Current,
    [hashtable]$Latest
  )

  $problems = New-Object Collections.Generic.List[string]
  if ($null -eq $Latest) { return @() }
  $baseline = $Latest.Manifest.state

  $oldPlugins = @($baseline.enabledPlugins)
  $newPlugins = @($Current.enabledPlugins)
  if ($oldPlugins.Count -gt 0) {
    $missing = @($oldPlugins | Where-Object { $newPlugins -notcontains $_ })
    $threshold = [Math]::Max(1, [Math]::Floor($oldPlugins.Count * 0.7))
    if ($newPlugins.Count -lt $threshold) {
      $problems.Add("已启用插件数量从 $($oldPlugins.Count) 降到 $($newPlugins.Count)")
    }
    if ($missing.Count -gt 0) {
      $problems.Add("缺少插件：$($missing -join ', ')")
    }
  }

  if ($baseline.ContainsKey('chat')) {
    $oldCount = [int]$baseline.chat.fileCount
    $newCount = [int]$Current.chat.fileCount
    if ($oldCount -gt 5 -and $newCount -lt [Math]::Max(1, [Math]::Floor($oldCount * 0.5))) {
      $problems.Add("聊天文件数量从 $oldCount 降到 $newCount")
    }
  }

  return @($problems)
}

function Copy-ItemToBackup {
  param(
    [string]$SourceRoot,
    [string]$BackupDir,
    [hashtable]$Item
  )

  $source = Join-Path $SourceRoot $Item.Path
  $dest = Join-Path $BackupDir $Item.Path
  if ($Item.Type -eq 'File') {
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      Copy-FileSharedRead -Source $source -Destination $dest
    }
    return
  }

  if (Test-Path -LiteralPath $source -PathType Container) {
    Copy-DirectoryContents -Source $source -Destination $dest
  }
}

function New-Backup {
  param(
    [string]$SourceRoot,
    [string]$Root,
    [hashtable]$State,
    [string]$Kind
  )

  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $kindName = Get-BackupKindLabel -Kind $Kind
  $baseName = "$kindName-$stamp"
  $dest = Join-Path $Root $baseName
  $suffix = 1
  while (Test-Path -LiteralPath $dest) {
    $dest = Join-Path $Root "$baseName-$suffix"
    $suffix += 1
  }

  New-Item -ItemType Directory -Path $dest | Out-Null
  foreach ($item in $ProtectedItems) {
    Copy-ItemToBackup -SourceRoot $SourceRoot -BackupDir $dest -Item $item
  }

  $manifest = @{
    toolVersion = $ToolVersion
    kind = $Kind
    createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    protectedItems = $ProtectedItems
    state = $State
  }
  $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $dest 'manifest.json') -Encoding UTF8
  return $dest
}

function Remove-BackupDirectory {
  param(
    [Parameter(Mandatory)] [string]$Root,
    [Parameter(Mandatory)] [string]$Path
  )

  Assert-SafePath -Path $Path -Root $Root
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
}

function New-VerifiedBackup {
  param(
    [Parameter(Mandatory)] [string]$SourceRoot,
    [Parameter(Mandatory)] [string]$Root,
    [Parameter(Mandatory)] [hashtable]$State,
    [Parameter(Mandatory)] [string]$Kind,
    [int]$Attempts = $BackupVerificationAttempts,
    [int]$RetryDelayMilliseconds = $BackupRetryDelayMilliseconds
  )

  $lastReason = ''
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $stateBefore = if ($attempt -eq 1) { $State } else { Get-CurrentState -Root $SourceRoot }
    $backupPath = New-Backup -SourceRoot $SourceRoot -Root $Root -State $stateBefore -Kind $Kind
    $stateAfter = Get-CurrentState -Root $SourceRoot
    $backupState = Get-CurrentState -Root $backupPath
    $sourceComparison = Compare-StateFingerprints -Left $stateBefore -Right $stateAfter
    $backupComparison = Compare-StateFingerprints -Left $stateBefore -Right $backupState

    if ($sourceComparison.Ok -and $backupComparison.Ok) {
      return @{
        Path = $backupPath
        Attempts = $attempt
      }
    }

    $reasonParts = New-Object Collections.Generic.List[string]
    if (-not $sourceComparison.Ok) {
      $reasonParts.Add("源数据变化：$($sourceComparison.Differences -join ', ')")
    }
    if (-not $backupComparison.Ok) {
      $reasonParts.Add("备份校验不一致：$($backupComparison.Differences -join ', ')")
    }
    $lastReason = $reasonParts -join '；'

    Write-Warn "第 $attempt 次备份校验未通过，已放弃本次结果：$lastReason"
    Remove-BackupDirectory -Root $Root -Path $backupPath

    if ($attempt -lt $Attempts) {
      Start-Sleep -Milliseconds $RetryDelayMilliseconds
    }
  }

  throw "未能创建可靠备份。请先关闭 Codex，稍后重试。最后一次原因：$lastReason"
}

function Acquire-OperationLock {
  param([Parameter(Mandatory)] [string]$Root)

  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $lockPath = Join-Path $Root '.codex-state-guardian.lock'

  try {
    $stream = [IO.File]::Open(
      $lockPath,
      [IO.FileMode]::OpenOrCreate,
      [IO.FileAccess]::ReadWrite,
      [IO.FileShare]::None
    )
  } catch {
    throw '另一个备份或恢复任务正在运行，请稍后再试。'
  }

  return @{
    Path = $lockPath
    Stream = $stream
  }
}

function Release-OperationLock {
  param($Lock)

  if ($null -ne $Lock -and $null -ne $Lock.Stream) {
    $Lock.Stream.Dispose()
  }
  if ($null -ne $Lock -and $null -ne $Lock.Path) {
    Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue
  }
}

function Restore-ConfigTomlFromBackup {
  param(
    [Parameter(Mandatory)] [string]$Source,
    [Parameter(Mandatory)] [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    Write-Warn '备份里缺少 config.toml，已跳过。'
    return
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null

  if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Info '已恢复：config.toml'
    return
  }

  try {
    $currentText = Get-Content -LiteralPath $Destination -Raw
    $backupText = Get-Content -LiteralPath $Source -Raw
    $mergedText = Merge-ConfigTomlText -CurrentText $currentText -BackupText $backupText
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Destination, $mergedText, $utf8NoBom)
    Write-Info '已恢复：config.toml（已保留当前模型、提供商和密钥相关配置）'
  } catch {
    Write-Warn "config.toml 合并恢复失败，已保留当前配置：$($_.Exception.Message)"
  }
}

function Remove-OldBackups {
  param(
    [string]$Root,
    [int]$Keep,
    [int]$MinHealthyKeep = 2
  )

  if ($Keep -lt 1) { throw '最多保留备份数量必须至少为 1。' }
  if ($MinHealthyKeep -lt 1) { $MinHealthyKeep = 1 }

  $backups = @(Get-BackupDirectories -Root $Root)
  $healthy = @($backups | Where-Object {
      $manifest = Read-Manifest -BackupDir $_.FullName
      $null -ne $manifest -and (Test-HealthyBackupKind -Kind ([string]$manifest.kind))
    } | Select-Object -First $MinHealthyKeep)
  $protectedHealthy = @{}
  foreach ($backup in $healthy) {
    $protectedHealthy[[IO.Path]::GetFullPath($backup.FullName)] = $true
  }

  $old = New-Object Collections.Generic.List[object]
  for ($i = $backups.Count - 1; $i -ge 0; $i--) {
    if ($backups.Count - $old.Count -le $Keep) { break }
    $candidate = $backups[$i]
    $candidatePath = [IO.Path]::GetFullPath($candidate.FullName)
    if ($protectedHealthy.ContainsKey($candidatePath)) { continue }
    $old.Add($candidate)
  }

  foreach ($backup in $old) {
    Assert-SafePath -Path $backup.FullName -Root $Root
    Remove-Item -LiteralPath $backup.FullName -Recurse -Force
    Write-Info "已删除旧备份：$($backup.Name)"
  }
}

function Show-Status {
  $current = Get-CurrentState -Root $CodexHome
  $health = Test-StateHealthy -State $current
  $latest = Get-LatestHealthyBackup -Root $BackupRoot
  $baselineProblems = @(Compare-AgainstBaseline -Current $current -Latest $latest)

  Write-Info "Codex 配置目录：$CodexHome"
  Write-Info "备份目录：$BackupRoot"
  Write-Info "已启用插件数量：$($current.enabledPluginCount)"
  Write-Info "全局状态文件：$($current.globalStateJson.Reason)"
  Write-Info "聊天相关文件：$($current.chat.fileCount) 个，$($current.chat.size) 字节"
  Write-Detail "未归档聊天=$($current.chat.activeSessionFiles)，已归档聊天=$($current.chat.archivedSessionFiles)，索引存在=$(Format-YesNo $current.chat.sessionIndexExists)，状态数据库文件=$($current.chat.stateDbFiles)"

  foreach ($item in $ProtectedItems) {
    $summary = Get-StateItem -State $current -RelativePath $item.Path
    $kind = if ($summary.type -eq 'File') { '文件' } else { '文件夹' }
    Write-Detail "$($item.Path) | 类型=$kind | 存在=$(Format-YesNo $summary.exists) | 文件数=$($summary.fileCount) | 大小=$($summary.size)"
  }

  if ($null -ne $latest) {
    Write-Info "最新健康备份：$($latest.Directory)"
  } else {
    Write-Info '还没有健康备份。'
  }
  if (-not $health.Ok) {
    Write-Warn "健康检查问题：$($health.Problems -join '；')"
  }
  if ($baselineProblems.Count -gt 0) {
    Write-Warn "与最新备份的差异：$($baselineProblems -join '；')"
  }
}

function Show-Backups {
  Write-Info "备份目录：$BackupRoot"
  $backups = Get-BackupDirectories -Root $BackupRoot
  if ($backups.Count -eq 0) {
    Write-Info '没有找到备份。'
    return
  }

  $latest = Get-LatestHealthyBackup -Root $BackupRoot
  $latestDir = if ($null -ne $latest) { [IO.Path]::GetFullPath($latest.Directory) } else { '' }

  foreach ($backup in $backups) {
    $marker = if ([IO.Path]::GetFullPath($backup.FullName) -eq $latestDir) { ' 最新健康备份' } else { '' }
    try {
      $manifest = Read-Manifest -BackupDir $backup.FullName
      $state = $manifest.state
      $chat = if ($state.ContainsKey('chat')) { $state.chat } else { @{ fileCount = '未保存'; size = '未保存' } }
      $kind = Get-BackupKindLabel -Kind ([string]$manifest.kind)
      Write-Detail "$($backup.Name) | 类型=$kind | 插件=$($state.enabledPluginCount) | 聊天文件=$($chat.fileCount) | 聊天大小=$($chat.size) | 保存时间=$(Format-SavedTime $manifest.createdAtUtc)$marker"
    } catch {
      Write-Detail "$($backup.Name) | 无法读取：$($_.Exception.Message)"
    }
  }
}

function Invoke-Check {
  if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {
    throw "没有找到 Codex 数据目录：$CodexHome"
  }

  $current = Get-CurrentState -Root $CodexHome
  $health = Test-StateHealthy -State $current
  $latest = Get-LatestHealthyBackup -Root $BackupRoot
  $baselineProblems = @(Compare-AgainstBaseline -Current $current -Latest $latest)

  Write-Info "已启用插件数量：$($current.enabledPluginCount)"
  Write-Info "聊天相关文件：$($current.chat.fileCount) 个，$($current.chat.size) 字节"

  if (-not $health.Ok) {
    Write-Warn "当前状态未通过健康检查：$($health.Problems -join '；')"
    Write-Info '未创建健康备份。如需恢复旧备份，请选择菜单 4 或菜单 5。'
  } elseif ($Force) {
    if ($baselineProblems.Count -gt 0) {
      Write-Warn "与最新健康备份相比有变化：$($baselineProblems -join '；')"
    }
    $backupPath = New-Backup -SourceRoot $CodexHome -Root $BackupRoot -State $current -Kind 'healthy'
    Write-Info "已强制创建健康备份：$backupPath"
  } elseif (Test-SameAsLatest -Current $current -Latest $latest) {
    Write-Info '当前设置和聊天记录与最新健康备份一致，跳过重复备份。'
  } else {
    if ($baselineProblems.Count -gt 0) {
      Write-Warn "与最新健康备份相比有变化：$($baselineProblems -join '；')"
    }
    $backupPath = New-Backup -SourceRoot $CodexHome -Root $BackupRoot -State $current -Kind 'healthy'
    Write-Info "已创建健康备份：$backupPath"
  }

  Remove-OldBackups -Root $BackupRoot -Keep $MaxBackups -MinHealthyKeep $MinHealthyBackups
}

function Restore-ItemFromBackup {
  param(
    [string]$BackupDir,
    [hashtable]$Item
  )

  $source = Join-Path $BackupDir $Item.Path
  $dest = Join-Path $CodexHome $Item.Path
  Assert-SafePath -Path $dest -Root $CodexHome

  if ($Item.Type -eq 'File') {
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
      Copy-Item -LiteralPath $source -Destination $dest -Force
      Write-Info "已恢复：$($Item.Path)"
    } else {
      Write-Warn "备份缺少文件，已跳过：$($Item.Path)"
    }
    return
  }

  if (Test-Path -LiteralPath $source -PathType Container) {
    if (Test-Path -LiteralPath $dest -PathType Container) {
      Remove-Item -LiteralPath $dest -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination (Split-Path -Parent $dest) -Recurse -Force
    Write-Info "已恢复：$($Item.Path)"
  } else {
    Write-Warn "备份缺少文件夹，已跳过：$($Item.Path)"
  }
}

function Invoke-Restore {
  param([hashtable]$SelectedBackup)

  if ($null -eq $SelectedBackup) {
    $SelectedBackup = Resolve-Backup -Root $BackupRoot -Name $BackupName
  }

  $backupDir = $SelectedBackup.Directory
  $manifest = $SelectedBackup.Manifest
  $chat = if ($manifest.state.ContainsKey('chat')) { $manifest.state.chat } else { @{ fileCount = '未保存' } }

  Write-Info "选择的备份：$(Split-Path -Leaf $backupDir)"
  $kind = Get-BackupKindLabel -Kind ([string]$manifest.kind)
  Write-Detail "类型：$kind"
  Write-Detail "保存时间：$(Format-SavedTime $manifest.createdAtUtc)"
  Write-Detail "已启用插件：$($manifest.state.enabledPluginCount)"
  Write-Detail "聊天文件：$($chat.fileCount)"

  $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ProcessName -match 'Codex|OpenAI\.Codex'
    })
  if ($running.Count -gt 0) {
    Write-Warn '检测到 Codex 可能正在运行。恢复前请关闭 Codex，避免它同时写入配置。'
  }

  if (-not $Force) {
    $answer = Read-Host "是否从此备份恢复设置和聊天记录？如确认请输入：确认"
    if (-not (Test-Confirmed $answer)) {
      Write-Info '已取消恢复，真实文件没有改变。'
      return
    }
  }

  $stateBefore = Get-CurrentState -Root $CodexHome
  $preRestore = New-Backup -SourceRoot $CodexHome -Root $BackupRoot -State $stateBefore -Kind 'pre-restore'
  Write-Info "已创建恢复前备份：$preRestore"

  foreach ($item in $ProtectedItems) {
    Restore-ItemFromBackup -BackupDir $backupDir -Item $item
  }

  Remove-OldBackups -Root $BackupRoot -Keep $MaxBackups -MinHealthyKeep $MinHealthyBackups
  Write-Info '恢复完成。请重新打开 Codex 检查设置和聊天记录。'
}

function Show-Menu {
  while ($true) {
    Write-Host ''
    Write-Host 'Codex 设置和聊天记录备份守护'
    Write-Host '================================'
    Write-Host '1. 检查并保存健康备份'
    Write-Host '2. 查看当前状态'
    Write-Host '3. 列出备份'
    Write-Host '4. 恢复最新健康备份'
    Write-Host '5. 恢复指定备份'
    Write-Host '6. 强制保存一份健康备份'
    Write-Host '0. 退出'
    Write-Host ''
    $choice = Read-Host '请选择'

    switch ($choice) {
      '1' { Invoke-Check; Read-Host '按回车键返回菜单' | Out-Null }
      '2' { Show-Status; Read-Host '按回车键返回菜单' | Out-Null }
      '3' { Show-Backups; Read-Host '按回车键返回菜单' | Out-Null }
      '4' { $script:BackupName = ''; Invoke-Restore; Read-Host '按回车键返回菜单' | Out-Null }
      '5' {
        Show-Backups
        $script:BackupName = Read-Host '输入完整备份文件夹名'
        if (-not [string]::IsNullOrWhiteSpace($script:BackupName)) {
          Invoke-Restore
        }
        Read-Host '按回车键返回菜单' | Out-Null
      }
      '6' { $script:Force = $true; Invoke-Check; $script:Force = $false; Read-Host '按回车键返回菜单' | Out-Null }
      '0' { return }
      default { Write-Warn '无效选择。' }
    }
  }
}

function Invoke-Check {
  if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {
    throw "没有找到 Codex 数据目录：$CodexHome"
  }

  $operationLock = Acquire-OperationLock -Root $BackupRoot
  try {
    $current = Get-CurrentState -Root $CodexHome
    $health = Test-StateHealthy -State $current
    $latest = Get-LatestHealthyBackup -Root $BackupRoot
    $baselineProblems = @(Compare-AgainstBaseline -Current $current -Latest $latest)

    Write-Info "已启用插件数量：$($current.enabledPluginCount)"
    Write-Info "聊天相关文件：$($current.chat.fileCount) 个，$($current.chat.size) 字节"

    if (-not $health.Ok) {
      Write-Warn "当前状态未通过健康检查：$($health.Problems -join '；')"
      Write-Info '未创建健康备份。如需恢复旧备份，请选择菜单 4 或菜单 5。'
    } elseif ($Force) {
      if ($baselineProblems.Count -gt 0) {
        Write-Warn "与最新健康备份相比有变化：$($baselineProblems -join '；')"
      }
      $backupResult = New-VerifiedBackup -SourceRoot $CodexHome -Root $BackupRoot -State $current -Kind 'healthy'
      Write-Info "已强制创建健康备份：$($backupResult.Path)"
    } elseif (Test-SameAsLatest -Current $current -Latest $latest) {
      Write-Info '当前设置和聊天记录与最新健康备份一致，跳过重复备份。'
    } else {
      if ($baselineProblems.Count -gt 0) {
        Write-Warn "与最新健康备份相比有变化：$($baselineProblems -join '；')"
      }
      $backupResult = New-VerifiedBackup -SourceRoot $CodexHome -Root $BackupRoot -State $current -Kind 'healthy'
      Write-Info "已创建健康备份：$($backupResult.Path)"
    }

    Remove-OldBackups -Root $BackupRoot -Keep $MaxBackups -MinHealthyKeep $MinHealthyBackups
  } finally {
    Release-OperationLock -Lock $operationLock
  }
}

function Invoke-Restore {
  param([hashtable]$SelectedBackup)

  $operationLock = Acquire-OperationLock -Root $BackupRoot
  try {
    if ($null -eq $SelectedBackup) {
      $SelectedBackup = Resolve-Backup -Root $BackupRoot -Name $BackupName
    }

    $backupDir = $SelectedBackup.Directory
    $manifest = $SelectedBackup.Manifest
    $chat = if ($manifest.state.ContainsKey('chat')) { $manifest.state.chat } else { @{ fileCount = '未保存' } }

    Write-Info "选择的备份：$(Split-Path -Leaf $backupDir)"
    $kind = Get-BackupKindLabel -Kind ([string]$manifest.kind)
    Write-Detail "类型：$kind"
    Write-Detail "保存时间：$(Format-SavedTime $manifest.createdAtUtc)"
    Write-Detail "已启用插件：$($manifest.state.enabledPluginCount)"
    Write-Detail "聊天文件：$($chat.fileCount)"

    $running = @(Get-RunningCodexProcesses)
    if ($running.Count -gt 0 -and -not $Force) {
      Write-Warn '检测到 Codex 仍在运行。请先关闭 Codex，再执行恢复。'
      return
    }
    if ($running.Count -gt 0) {
      Write-Warn '正在强制恢复。由于 Codex 仍在运行，恢复结果可能被当前进程再次改写。'
    }

    if (-not $Force) {
      $answer = Read-Host "是否从此备份恢复设置和聊天记录？如确认请输入：确认"
      if (-not (Test-Confirmed $answer)) {
        Write-Info '已取消恢复，真实文件没有改变。'
        return
      }
    }

    $stateBefore = Get-CurrentState -Root $CodexHome
    $preRestore = New-VerifiedBackup -SourceRoot $CodexHome -Root $BackupRoot -State $stateBefore -Kind 'pre-restore'
    Write-Info "已创建恢复前备份：$($preRestore.Path)"

    foreach ($item in $ProtectedItems) {
      Restore-ItemFromBackup -BackupDir $backupDir -Item $item
    }

    Remove-OldBackups -Root $BackupRoot -Keep $MaxBackups -MinHealthyKeep $MinHealthyBackups
    Write-Info '恢复完成。请重新打开 Codex 检查设置和聊天记录。'
  } finally {
    Release-OperationLock -Lock $operationLock
  }
}

function Restore-ItemFromBackup {
  param(
    [string]$BackupDir,
    [hashtable]$Item
  )

  $source = Join-Path $BackupDir $Item.Path
  $dest = Join-Path $CodexHome $Item.Path
  Assert-SafePath -Path $dest -Root $CodexHome

  if ($Item.Type -eq 'File') {
    if ($Item.Path -eq 'config.toml') {
      Restore-ConfigTomlFromBackup -Source $source -Destination $dest
      return
    }

    if (Test-Path -LiteralPath $source -PathType Leaf) {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
      Copy-Item -LiteralPath $source -Destination $dest -Force
      Write-Info "已恢复：$($Item.Path)"
    } else {
      Write-Warn "备份缺少文件，已跳过：$($Item.Path)"
    }
    return
  }

  if (Test-Path -LiteralPath $source -PathType Container) {
    if (Test-Path -LiteralPath $dest -PathType Container) {
      Remove-Item -LiteralPath $dest -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination (Split-Path -Parent $dest) -Recurse -Force
    Write-Info "已恢复：$($Item.Path)"
  } else {
    Write-Warn "备份缺少文件夹，已跳过：$($Item.Path)"
  }
}

New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

switch ($Action.ToLowerInvariant()) {
  '' { Show-Menu }
  '菜单' { Show-Menu }
  'menu' { Show-Menu }
  '检查' { Invoke-Check }
  '保存' { Invoke-Check }
  'check' { Invoke-Check }
  'backup' { Invoke-Check }
  '状态' { Show-Status }
  'status' { Show-Status }
  '列表' { Show-Backups }
  '备份列表' { Show-Backups }
  'list' { Show-Backups }
  '恢复' { Invoke-Restore }
  'restore' { Invoke-Restore }
  '恢复最新' { $BackupName = ''; Invoke-Restore }
  'restore-latest' { $BackupName = ''; Invoke-Restore }
  '指定恢复' {
    if ([string]::IsNullOrWhiteSpace($BackupName)) {
      Show-Backups
      $BackupName = Read-Host '输入完整备份文件夹名'
    }
    Invoke-Restore
  }
  'restore-selected' {
    if ([string]::IsNullOrWhiteSpace($BackupName)) {
      Show-Backups
      $BackupName = Read-Host '输入完整备份文件夹名'
    }
    Invoke-Restore
  }
  '帮助' {
    Write-Host '用法：codex-state-guardian.cmd [检查|状态|列表|恢复|指定恢复|恢复最新|菜单] [备份文件夹名] [-强制]'
    Write-Host '确认恢复时请输入：确认'
    Write-Host '旧英文命令仍可使用：check status list restore restore-selected'
  }
  'help' {
    Write-Host '用法：codex-state-guardian.cmd [检查|状态|列表|恢复|指定恢复|恢复最新|菜单] [备份文件夹名] [-强制]'
    Write-Host '确认恢复时请输入：确认'
    Write-Host '旧英文命令仍可使用：check status list restore restore-selected'
  }
  default {
    throw "未知操作：$Action"
  }
}
