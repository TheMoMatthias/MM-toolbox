# Local adapter/registry checks. No terminal or agent session is launched.
$ErrorActionPreference = "Stop"
$launcher = Join-Path $PSScriptRoot "spawn.ps1"
$registryPath = Join-Path $PSScriptRoot "runtimes.local.json"
$recovery = Join-Path $PSScriptRoot "recover.ps1"
$registry = Get-Content -Raw -LiteralPath $registryPath -Encoding UTF8 | ConvertFrom-Json

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$names = @($registry.runtimes.psobject.Properties.Name | Sort-Object)
Assert-That (($names -join ",") -eq "claude,pi") "only Pi and Claude are registered"
foreach ($name in $names) {
    $runtime = $registry.runtimes.$name
    foreach ($field in @("executable", "interactiveLaunchArgs", "resumeGuidance", "verificationLevel")) {
        Assert-That ($null -ne $runtime.$field) "$name declares $field"
    }
    foreach ($field in @("modelDiscoveryArgs", "modelArgs")) {
        Assert-That ($runtime.psobject.Properties.Name -contains $field) "$name explicitly declares optional $field"
    }
}
Assert-That ($registry.runtimes.pi.verificationLevel -eq "preassigned-id-prompt-correlation") "Pi verification contract"
Assert-That ($registry.runtimes.claude.verificationLevel -eq "adapter-verified") "Claude verification contract"

$dry = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Runtime pi -Mode analysis -Name spawn-session-test -Prompt "test prompt with (parens) and `$dollar" -DryRun 2>&1
Assert-That ($LASTEXITCODE -eq 0) "Pi dry run succeeds"
Assert-That (($dry -join "`n") -match "Runtime\s+: pi") "Pi dry run selects Pi"
Assert-That (($dry -join "`n") -match "opening prompt") "Pi dry run prints prompt plan"
Assert-That (($dry -join "`n") -match "--session-id [0-9a-f-]{36}") "Pi launch preassigns a durable session id"
Assert-That (($dry -join "`n") -match "Resume\s+: pi --session [0-9a-f-]{36}") "Pi dry run prints deterministic resume command"
Assert-That (($dry -join "`n") -notmatch "--thinking") "Pi launch has no thinking selector"

$claudeDry = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Runtime claude -Mode analysis -Name spawn-session-claude-test -Prompt "Claude dry run" -DryRun 2>&1
Assert-That ($LASTEXITCODE -eq 0) "Claude adapter dry run succeeds"
Assert-That (($claudeDry -join "`n") -match "Env scrub") "Claude routing delegates to the existing adapter"

$ErrorActionPreference = "Continue"
$unknown = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Runtime not-configured -Prompt x -DryRun 2>&1
$unknownExit = $LASTEXITCODE
$duplicate = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Runtime pi -Mode implementation -AllowDuplicate -Prompt x -DryRun 2>&1
$duplicateExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"
Assert-That ($unknownExit -eq 1) "unknown runtime refuses"
Assert-That (($unknown -join "`n") -match "not configured") "unknown runtime gives setup direction"

Assert-That ($duplicateExit -eq 1) "implementation duplicate override refuses"
Assert-That (($duplicate -join "`n") -match "analysis-only") "duplicate refusal explains mode policy"

$fixtureRoot = Join-Path $PSScriptRoot ".test-sessions"
try {
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
    $sessionId = "11111111-2222-4333-8444-555555555555"
    $fixturePath = Join-Path $fixtureRoot ("fixture_" + $sessionId + ".jsonl")
    $header = @{ type = "session"; version = 3; id = $sessionId; timestamp = "2026-01-01T00:00:00.000Z"; cwd = "C:\fixture\project" } | ConvertTo-Json -Compress
    $oldName = @{ type = "session_info"; id = "aaaaaaaa"; parentId = $null; timestamp = "2026-01-01T00:00:01.000Z"; name = "old-name" } | ConvertTo-Json -Compress
    $newName = @{ type = "session_info"; id = "bbbbbbbb"; parentId = "aaaaaaaa"; timestamp = "2026-01-01T00:00:02.000Z"; name = "major-app-change" } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllLines($fixturePath, [string[]]@($header, $oldName, $newName), (New-Object System.Text.UTF8Encoding($false)))

    $recoveryDry = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recovery -Name major-app-change -SessionRoot $fixtureRoot -DryRun 2>&1
    Assert-That ($LASTEXITCODE -eq 0) "Pi recovery dry run succeeds"
    Assert-That (($recoveryDry -join "`n") -match [regex]::Escape($sessionId)) "Pi recovery finds exact persisted id"
    Assert-That (($recoveryDry -join "`n") -match "C:\\fixture\\project") "Pi recovery reports original cwd"
    Assert-That (($recoveryDry -join "`n") -match "pi --session") "Pi recovery emits direct resume command"
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "spawn-session adapter/registry tests passed"
