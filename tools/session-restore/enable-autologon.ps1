#requires -Version 5.1
<#
.SYNOPSIS
    Let this PC log itself in at boot, so the session restore runs without anyone
    typing a password.

.DESCRIPTION
    The logon-triggered task is what brings your conversations back, and it cannot
    fire until someone signs in. Auto-logon removes that step: power on, Windows
    signs in, the restore runs, the tabs are there.

    WHAT IT COSTS. Anyone who can press the power button gets your desktop, already
    signed in, with every restored conversation and its Remote Control session
    attached. Full-disk encryption does not help here -- the machine unlocks itself.
    Weigh that against how physically exposed this PC is. -LockAfterLogon buys most
    of it back: the sessions still start, the screen still locks.

    WHERE THE PASSWORD GOES. Into the LSA private-data store, which is what
    Sysinternals Autologon uses -- encrypted, and readable only by SYSTEM.

    It is NOT written to
        HKLM\...\Winlogon\DefaultPassword
    which is where every "enable autologon" registry snippet on the internet puts
    it, IN PLAINTEXT, readable by any process running as you. This script deletes
    that value if it finds one.

    Windows 11 hides the netplwiz checkbox once Hello-only sign-in is on
    (DevicePasswordLessBuildVersion = 2). This clears it to 0, which is the same
    thing that checkbox does.

.PARAMETER Disable
    Undo it: clear AutoAdminLogon, delete the stored secret, and put Hello-only
    sign-in back the way it was.

.PARAMETER Status
    Report the current state and change nothing.

.PARAMETER LockAfterLogon
    Also register a task that locks the workstation a minute after the restore has
    run. The machine signs itself in, your sessions come up, and the screen is
    locked -- reachable from Remote Control, not from whoever walks past.

.PARAMETER UserName
    Defaults to the account you run this as, which is nearly always what you want.

.EXAMPLE
    .\enable-autologon.ps1 -Status
    .\enable-autologon.ps1
    .\enable-autologon.ps1 -LockAfterLogon
    .\enable-autologon.ps1 -Disable
#>
[CmdletBinding()]
param(
    [switch]$Disable,
    [switch]$Status,
    [switch]$LockAfterLogon,
    [string]$UserName
)

$ErrorActionPreference = 'Stop'

$WinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$PwLessKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
$LockTask    = 'ClaudeSessionLockAfterLogon'

function Write-Ok   { param($m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Warn { param($m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Step { param($m) Write-Host "  $m" }

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- the LSA private-data store --------------------------------------------
# LsaStorePrivateData is the documented way to write the secret Winlogon reads.
# Passing a NULL buffer deletes it, which is how -Disable removes the password
# rather than leaving it behind with auto-logon merely switched off.
$lsaSource = @'
using System;
using System.Runtime.InteropServices;

public static class SRLsa
{
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }

    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES {
        public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
        public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes,
                                     uint DesiredAccess, out IntPtr PolicyHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaStorePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, IntPtr PrivateData);

    [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint Status);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr ObjectHandle);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr Buffer);

    const uint POLICY_CREATE_SECRET = 0x00000020;
    const uint POLICY_GET_PRIVATE_INFORMATION = 0x00000004;

    static LSA_UNICODE_STRING Str(string s)
    {
        LSA_UNICODE_STRING u = new LSA_UNICODE_STRING();
        u.Buffer = Marshal.StringToHGlobalUni(s);
        u.Length = (ushort)(s.Length * 2);
        u.MaximumLength = (ushort)((s.Length + 1) * 2);
        return u;
    }

    // value == null deletes the secret.
    public static void Store(string key, string value)
    {
        LSA_OBJECT_ATTRIBUTES oa = new LSA_OBJECT_ATTRIBUTES();
        oa.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr policy;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref oa, POLICY_CREATE_SECRET | POLICY_GET_PRIVATE_INFORMATION, out policy);
        if (st != 0) throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(st),
            "LsaOpenPolicy failed - this needs an elevated shell.");

        LSA_UNICODE_STRING k = Str(key);
        IntPtr dataPtr = IntPtr.Zero;
        GCHandle pin = default(GCHandle);
        try
        {
            if (value != null)
            {
                LSA_UNICODE_STRING d = Str(value);
                pin = GCHandle.Alloc(d, GCHandleType.Pinned);
                dataPtr = pin.AddrOfPinnedObject();
            }
            st = LsaStorePrivateData(policy, ref k, dataPtr);
            if (st != 0) throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(st),
                "LsaStorePrivateData failed.");
        }
        finally
        {
            if (pin.IsAllocated) pin.Free();
            if (k.Buffer != IntPtr.Zero) Marshal.FreeHGlobal(k.Buffer);
            LsaClose(policy);
        }
    }
}
'@

function Set-LsaSecret {
    param([Parameter(Mandatory)][string]$Key, [AllowNull()][string]$Value)
    if (-not ('SRLsa' -as [type])) { Add-Type -TypeDefinition $lsaSource -Language CSharp }
    [SRLsa]::Store($Key, $Value)
}

# --- state ------------------------------------------------------------------
function Get-State {
    $w  = Get-ItemProperty $WinlogonKey -ErrorAction SilentlyContinue
    $pw = (Get-ItemProperty $PwLessKey -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
    return [PSCustomObject]@{
        AutoAdminLogon    = "$($w.AutoAdminLogon)"
        DefaultUserName   = "$($w.DefaultUserName)"
        DefaultDomainName = "$($w.DefaultDomainName)"
        PlaintextPassword = [bool]$w.DefaultPassword
        PasswordLess      = $pw
        LockTask          = [bool](Get-ScheduledTask -TaskName $LockTask -ErrorAction SilentlyContinue)
    }
}

function Write-State {
    $s = Get-State
    Write-Host ""
    Write-Host "Auto-logon" -ForegroundColor Cyan
    Write-Host ""
    $on = ($s.AutoAdminLogon -eq '1')
    Write-Step ("enabled            : {0}" -f $(if ($on) { "YES - signs in as $($s.DefaultDomainName)\$($s.DefaultUserName)" } else { 'no' }))
    Write-Step ("Hello-only sign-in : {0}" -f $(if ($s.PasswordLess -eq 0) { 'off  (auto-logon is possible)' } else { "on   (DevicePasswordLessBuildVersion=$($s.PasswordLess)) - blocks auto-logon" }))
    Write-Step ("lock after logon   : {0}" -f $(if ($s.LockTask) { "YES - task '$LockTask'" } else { 'no  - the desktop stays unlocked after boot' }))
    if ($s.PlaintextPassword) {
        Write-Warn "a PLAINTEXT password is sitting in the registry at $WinlogonKey\DefaultPassword"
        Write-Warn "run this script without -Status to move it into the encrypted store"
    }
    Write-Host ""
}

# --- lock-after-logon task --------------------------------------------------
function Register-LockTask {
    # 3 minutes: the restore task fires at 45s and spends ~500 ms per tab, so this
    # lands after the last one is up. Locking does not disturb them -- they keep
    # running, which is the whole point.
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trg.Delay = 'PT3M'
    Register-ScheduledTask -TaskName $LockTask -Force `
        -Principal (New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited) `
        -Settings  (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew) `
        -Trigger   $trg `
        -Action    (New-ScheduledTaskAction -Execute 'rundll32.exe' -Argument 'user32.dll,LockWorkStation') `
        -Description 'Lock the workstation after the Claude session restore has run, so auto-logon does not leave the desktop open.' | Out-Null
    Write-Ok "task '$LockTask' - locks the screen 3 min after logon (the sessions keep running)"
}

function Unregister-LockTask {
    if (Get-ScheduledTask -TaskName $LockTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $LockTask -Confirm:$false
        Write-Ok "task '$LockTask' removed"
    }
}

# ---------------------------------------------------------------------------
if ($Status) { Write-State; exit 0 }

if (-not (Test-Admin)) {
    Write-Host ""
    Write-Fail "this needs an elevated shell - it writes HKLM and the LSA secret store."
    Write-Host ""
    Write-Host "  Double-click 'Enable Auto Logon.bat' instead; it asks for elevation itself."
    # One STRING, not an array: -ArgumentList @(...) joins with spaces and quotes
    # nothing, so an array form breaks the moment the path has a space in it.
    Write-Host "  Or:  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit -NoProfile -File `"$PSCommandPath`"'"
    Write-Host ""
    exit 1
}

if ($Disable) {
    Write-Host ""
    Write-Host "Disabling auto-logon" -ForegroundColor Cyan
    Write-Host ""
    Set-ItemProperty $WinlogonKey -Name AutoAdminLogon -Value '0' -Type String
    Write-Ok 'AutoAdminLogon = 0'
    foreach ($n in 'DefaultPassword', 'AutoLogonCount') {
        if ($null -ne (Get-ItemProperty $WinlogonKey -Name $n -ErrorAction SilentlyContinue).$n) {
            Remove-ItemProperty $WinlogonKey -Name $n -Force
            Write-Ok "removed $n from the registry"
        }
    }
    # Clearing the flag is not enough on its own: the secret would survive, and
    # re-enabling later would silently reuse a password you had forgotten about.
    try { Set-LsaSecret -Key 'DefaultPassword' -Value $null; Write-Ok 'stored password deleted from the LSA secret store' }
    catch { Write-Warn "could not clear the LSA secret: $($_.Exception.Message)" }
    if (Test-Path $PwLessKey) {
        Set-ItemProperty $PwLessKey -Name DevicePasswordLessBuildVersion -Value 2 -Type DWord
        Write-Ok 'Hello-only sign-in restored (DevicePasswordLessBuildVersion = 2)'
    }
    Unregister-LockTask
    Write-State
    exit 0
}

# --- enable ----------------------------------------------------------------
$user = $UserName
if (-not $user) { $user = $env:USERNAME }
$domain = $env:USERDOMAIN

Write-Host ""
Write-Host "Enabling auto-logon for $domain\$user" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This machine will sign in by itself at every boot. Anyone who can reach the" -ForegroundColor Yellow
Write-Host "  power button reaches your desktop, signed in, with your sessions on it." -ForegroundColor Yellow
if (-not $LockAfterLogon) {
    Write-Host "  -LockAfterLogon locks the screen once the sessions are up, if you want that." -ForegroundColor DarkYellow
}
Write-Host ""

$sec = Read-Host "  Windows password for $domain\$user" -AsSecureString
if ($sec.Length -eq 0) { Write-Fail 'no password given - nothing changed'; exit 1 }

$bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
try {
    # Validate BEFORE writing anything. A wrong password here does not fail loudly
    # -- it fails at the next boot, on the logon screen, where you cannot read an
    # error message and cannot tell it apart from auto-logon simply not working.
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine')
    if (-not $ctx.ValidateCredentials($user, $plain)) {
        Write-Fail "Windows rejected that password for $domain\$user - nothing was changed."
        exit 1
    }
    Write-Ok 'password verified against Windows'

    Set-LsaSecret -Key 'DefaultPassword' -Value $plain
    Write-Ok 'password stored in the LSA secret store (encrypted, SYSTEM-only)'
}
finally {
    # Do not leave it in memory any longer than the two calls above need it.
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if (Get-Variable plain -ErrorAction SilentlyContinue) { Remove-Variable plain -Force }
}

Set-ItemProperty $WinlogonKey -Name AutoAdminLogon    -Value '1'    -Type String
Set-ItemProperty $WinlogonKey -Name DefaultUserName   -Value $user  -Type String
Set-ItemProperty $WinlogonKey -Name DefaultDomainName -Value $domain -Type String
Write-Ok "AutoAdminLogon = 1, as $domain\$user"

# Anything that ever wrote the plaintext value wins over the secret store, so it
# has to go or the encrypted copy is decoration.
if ($null -ne (Get-ItemProperty $WinlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue).DefaultPassword) {
    Remove-ItemProperty $WinlogonKey -Name DefaultPassword -Force
    Write-Ok 'deleted the plaintext DefaultPassword that was in the registry'
}

if (-not (Test-Path $PwLessKey)) { New-Item -Path $PwLessKey -Force | Out-Null }
Set-ItemProperty $PwLessKey -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
Write-Ok 'Hello-only sign-in turned off (this is what the netplwiz checkbox does)'

if ($LockAfterLogon) { Register-LockTask } else { Unregister-LockTask }

Write-State
Write-Host "  Hold SHIFT during boot to get the normal logon screen once."
Write-Host "  Undo it all with:  enable-autologon.ps1 -Disable"
Write-Host ""
exit 0
