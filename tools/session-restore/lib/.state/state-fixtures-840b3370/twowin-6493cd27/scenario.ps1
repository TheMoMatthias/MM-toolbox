. (Join-Path $PSScriptRoot '_common.ps1')
$seed = [PSCustomObject]@{ version = 2; lastScan = $null; directories = @(
    [PSCustomObject]@{ path = 'C:/probe'; enabled = $true; missing = $false; sessions = @(
        [PSCustomObject]@{ sessionId = 'aaa'; title = 'A'; enabled = $false; lastActive = (Get-Date).ToString('o') },
        [PSCustomObject]@{ sessionId = 'bbb'; title = 'B'; enabled = $false; lastActive = (Get-Date).ToString('o') }) } ) }
Save-SRRegistry -Registry $seed
$stampA = Get-SRRegistryStamp

# Window B reads, ticks 'B' and saves. The ordinary path.
$b = Get-SRRegistry
$b.directories[0].sessions[1].enabled = $true
Save-SRRegistry -Registry $b

# Window A, still holding the stamp from before B wrote, tries to save.
$a = Get-SRRegistry
Set-SRRegistryStamp $stampA
$a.directories[0].sessions[0].enabled = $true
try { Save-SRRegistry -Registry $a; 'A_SAVED' } catch { 'A_REFUSED' }
$f = Get-SRRegistry
'B_KEPT=' + [bool]$f.directories[0].sessions[1].enabled

# A normal save after re-reading must still work, or this is a tool that cannot save.
$c = Get-SRRegistry
$c.directories[0].sessions[0].enabled = $true
try { Save-SRRegistry -Registry $c; 'NORMAL_OK' } catch { 'NORMAL_REFUSED' }

# -Force is the deliberate override.
Set-SRRegistryStamp 'not-the-current-stamp'
try { Save-SRRegistry -Registry $c -Force; 'FORCE_OK' } catch { 'FORCE_REFUSED' }
