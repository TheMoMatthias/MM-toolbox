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

.PARAMETER RemoveLock
    Remove the lock task and leave auto-logon alone, so the machine boots straight
    to an unlocked desktop. Needs no password.

.PARAMETER UserName
    Defaults to the account you run this as, which is nearly always what you want.

.EXAMPLE
    .\enable-autologon.ps1 -Status
    .\enable-autologon.ps1
    .\enable-autologon.ps1 -LockAfterLogon
    .\enable-autologon.ps1 -RemoveLock
    .\enable-autologon.ps1 -Disable
#>
[CmdletBinding()]
param(
    [switch]$Disable,
    [switch]$Status,
    [switch]$LockAfterLogon,

    # Take the lock task away WITHOUT touching auto-logon. Deliberately its own
    # switch: re-running the enable path without -LockAfterLogon also removes it,
    # but makes you retype your password to change something a password does not
    # protect.
    [switch]$RemoveLock,

    [string]$UserName,

    # Re-launch elevated in a window of its own and exit. This is what the .bat
    # passes; you would not normally type it.
    [switch]$Elevate
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }

$WinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$PwLessKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
$LockTask    = 'ClaudeSessionLockAfterLogon'

# This script runs in a window that is elevated, sometimes hidden, and easy to
# close before it is read -- and when it went wrong the evidence went with it. It
# leaves a trail. NOTHING here is ever handed a password: the prompt reads into a
# SecureString and no message carries it.
$ALogPath = Join-Path (Join-Path $here '.state') 'autologon.log'
function Write-ALog {
    param([string]$Message)
    try {
        $d = Split-Path -Parent $ALogPath
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Add-Content -LiteralPath $ALogPath -Encoding utf8 `
            -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Write-Ok   { param($m) Write-Host "  [ok]   $m" -ForegroundColor Green;  Write-ALog "[ok]   $m" }
function Write-Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red;    Write-ALog "[FAIL] $m" }
function Write-Warn { param($m) Write-Host "  [warn] $m" -ForegroundColor Yellow; Write-ALog "[warn] $m" }
function Write-Step { param($m) Write-Host "  $m";                                Write-ALog "       $m" }

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

# --- credential check -------------------------------------------------------
# LogonUser goes through the real authentication packages, so the cloud provider
# gets a look at a Microsoft-account credential. PrincipalContext('Machine') does
# not, and silently rejects a correct MSA password.
#
# Two logon types are tried per identity. INTERACTIVE is what the logon screen
# uses and is the truest test, but it needs SeInteractiveLogonRight; NETWORK needs
# no rights at all and still proves the password. Either one passing is enough.
$logonSource = @'
using System;
using System.Runtime.InteropServices;

public static class SRLogon
{
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LogonUserW(string user, string domain, string password,
                                  int logonType, int logonProvider, out IntPtr token);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    public static int LastError = 0;

    const int LOGON32_LOGON_INTERACTIVE = 2;
    const int LOGON32_LOGON_NETWORK     = 3;
    const int LOGON32_PROVIDER_DEFAULT  = 0;

    public static bool Check(string user, string domain, string password)
    {
        foreach (int type in new int[] { LOGON32_LOGON_INTERACTIVE, LOGON32_LOGON_NETWORK })
        {
            IntPtr token;
            bool ok = LogonUserW(user, string.IsNullOrEmpty(domain) ? null : domain,
                                 password, type, LOGON32_PROVIDER_DEFAULT, out token);
            if (ok) { CloseHandle(token); LastError = 0; return true; }
            LastError = Marshal.GetLastWin32Error();
        }
        return false;
    }
}
'@
if (-not ('SRLogon' -as [type])) { Add-Type -TypeDefinition $logonSource -Language CSharp }

# A bare error number tells the operator nothing, and "wrong password" and "this
# account is not allowed to log on" need completely different reactions.
function Get-LogonErrorMeaning {
    param([int]$Code)
    switch ($Code) {
        0     { 'no error reported - the identity form was probably wrong, not the password' }
        1326  { 'wrong user name or password' }
        1327  { 'account restriction - often a BLANK PASSWORD on an account that forbids it' }
        1330  { 'the password has expired' }
        1331  { 'the account is disabled' }
        1385  { 'this account is not granted the requested logon type' }
        1907  { 'the password must be changed before the account can be used' }
        default { 'see "net helpmsg ' + $Code + '"' }
    }
}

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
    } else {
        Write-Step "task '$LockTask' was not registered"
    }
}

# ---------------------------------------------------------------------------
# 🪤 Re-launch through WINDOWS TERMINAL, not a bare powershell.exe. Elevating a
# plain powershell from a non-interactive parent has repeatedly produced a process
# with NO console -- the same trap spawn-claude-session documents -- and this script
# then reaches Read-Host, gets end-of-file, and exits having silently done nothing.
# wt.exe reliably gives a real window. It falls back to powershell.exe if Windows
# Terminal is absent, and says which it used so a failure is attributable.
if ($Elevate) {
    if (Test-Admin) {
        Write-Warn "-Elevate was passed but this shell is ALREADY elevated - continuing here."
    } else {
        . (Join-Path $here '_common.ps1')   # Resolve-SRWindowsTerminal + ConvertTo-SRArg

        # Forward the real switches, never $Elevate itself: that would recurse.
        $fwd = @()
        if ($Disable)        { $fwd += '-Disable' }
        if ($LockAfterLogon) { $fwd += '-LockAfterLogon' }
        if ($RemoveLock)     { $fwd += '-RemoveLock' }
        if ($UserName)       { $fwd += @('-UserName', (ConvertTo-SRArg $UserName)) }

        $me = Join-Path $here 'enable-autologon.ps1'
        $wt = Resolve-SRWindowsTerminal
        $target = $null; $cmdline = $null

        if ($wt) {
            $target  = $wt
            # -w -1 forces a NEW window: an elevated tab cannot join a
            # non-elevated one anyway, and joining silently would hide it.
            $cmdline = (@('-w', '-1', 'new-tab', '--title', (ConvertTo-SRArg 'Claude auto-logon'),
                          'powershell.exe', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                          '-File', (ConvertTo-SRArg $me)) + $fwd) -join ' '
        } else {
            $target  = 'powershell.exe'
            $cmdline = (@('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                          '-File', (ConvertTo-SRArg $me)) + $fwd) -join ' '
        }

        Write-Host ""
        Write-Host "Opening an elevated window$(if ($wt) { ' (Windows Terminal)' } else { ' (PowerShell - Windows Terminal not found)' })..." -ForegroundColor Cyan
        Write-Host "  Accept the UAC prompt, then type your password IN THAT WINDOW." -ForegroundColor Cyan
        Write-Host "  It stays open afterwards so you can read the result."
        Write-Host ""
        try {
            # One STRING. -ArgumentList @(...) joins with spaces and quotes nothing.
            Start-Process -FilePath $target -ArgumentList $cmdline -Verb RunAs | Out-Null
        } catch {
            Write-Fail "could not elevate: $($_.Exception.Message)"
            Write-Host ""
            Write-Host "  Right-click 'Enable Auto Logon.bat' -> Run as administrator instead."
            Write-Host ""
            exit 1
        }
        exit 0
    }
}

if ($Status) { Write-State; exit 0 }

if (-not (Test-Admin)) {
    Write-Host ""
    Write-Fail "this needs an elevated shell - it writes HKLM and the LSA secret store."
    Write-Host ""
    Write-Host "  Right-click 'Enable Auto Logon.bat' -> Run as administrator."
    # One STRING, not an array: -ArgumentList @(...) joins with spaces and quotes
    # nothing, so an array form breaks the moment the path has a space in it.
    Write-Host "  Or:  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit -NoProfile -File `"$PSCommandPath`"'"
    Write-Host ""
    exit 1
}

# 🪤 THIS SCRIPT ASKS FOR A PASSWORD, SO IT NEEDS A REAL CONSOLE -- and it is
# routinely started from things that do not have one. Measured 2026-08-21: launched
# from an agent's non-interactive shell it elevated, reached Read-Host, got EOF,
# treated that as "no password given", and exited having changed NOTHING. The
# operator went looking for a window that was never there.
# Refuse LOUDLY instead. A tool whose failure mode is silence is the bug this whole
# folder exists to avoid.
$hasConsole = $true
try {
    if (-not [Environment]::UserInteractive) { $hasConsole = $false }
    elseif ([Console]::IsInputRedirected)     { $hasConsole = $false }
    else { $null = [Console]::WindowWidth }   # throws when there is no console at all
} catch { $hasConsole = $false }

# -RemoveLock and -Disable never prompt, so they need no console.
if (-not $hasConsole -and -not $Status -and -not $Disable -and -not $RemoveLock) {
    Write-Host ""
    Write-Fail "no interactive console - there is nowhere to type a password, so NOTHING was changed."
    Write-Host ""
    Write-Host "  This happens when the script is started from an agent, a scheduled task, or any"
    Write-Host "  other non-interactive parent: it elevates, reaches the prompt, reads end-of-file"
    Write-Host "  and exits looking like you declined."
    Write-Host ""
    Write-Host "  Run it YOURSELF instead:  right-click 'Enable Auto Logon.bat' -> Run as administrator"
    Write-Host ""
    exit 1
}

if ($RemoveLock) {
    Write-Host ""
    Write-Host "Removing the lock-after-logon task" -ForegroundColor Cyan
    Write-Host ""
    Unregister-LockTask
    if (-not (Get-ScheduledTask -TaskName $LockTask -ErrorAction SilentlyContinue)) {
        Write-Step 'the machine will now boot straight to an unlocked desktop'
    }
    Write-State
    exit 0
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

# 🪤 THIS ACCOUNT MAY NOT BE THE ONE YOU LOG IN AS. A Microsoft-account sign-in
# leaves a LOCAL shadow account (KAMPFSTATION\mauri, SID S-1-5-21-...) while the
# credential that actually authenticates belongs to the MSA identity
# (maurice.matthias@gmx.de, SID S-1-11-96-...). Measured 2026-08-21: the first
# version validated against the local SAM with PrincipalContext('Machine') and
# REJECTED THE OPERATOR'S CORRECT PASSWORD, because the local store cannot check an
# MSA credential -- and the DefaultUserName it would then have written named the
# wrong identity anyway, so even a "successful" run would have failed at boot.
$msaIdentity = $null
try {
    $cacheRoot = 'HKLM:\SOFTWARE\Microsoft\IdentityStore\LogonCache\D7F9888F-E3FC-49b0-9EA6-A85B5F392A4F\Sid2Name'
    foreach ($k in (Get-ChildItem $cacheRoot -ErrorAction SilentlyContinue)) {
        $n = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).IdentityName
        if ($n -and $n -like '*@*') { $msaIdentity = $n; break }
    }
} catch { }

Write-Host ""
Write-Host "Enabling auto-logon" -ForegroundColor Cyan
Write-Host ""
Write-Step ("local account   : {0}\{1}" -f $domain, $user)
if ($msaIdentity) {
    Write-Step ("Microsoft account: {0}   <- this is the password Windows will want" -f $msaIdentity)
} else {
    Write-Step "Microsoft account: none found - this looks like a pure local account"
}
Write-Host ""
Write-Host "  This machine will sign in by itself at every boot. Anyone who can reach the" -ForegroundColor Yellow
Write-Host "  power button reaches your desktop, signed in, with your sessions on it." -ForegroundColor Yellow
if (-not $LockAfterLogon) {
    Write-Host "  -LockAfterLogon locks the screen once the sessions are up, if you want that." -ForegroundColor DarkYellow
}
Write-Host ""

$prompt = if ($msaIdentity) { "  Password for $msaIdentity" } else { "  Windows password for $domain\$user" }
$sec = Read-Host $prompt -AsSecureString
if ($sec.Length -eq 0) { Write-Fail 'no password given - nothing changed'; exit 1 }

# The identity that actually authenticated, which is what gets written to the
# registry. Guessing it is how auto-logon "succeeds" and then fails at boot.
$winDomain = $null; $winUser = $null

$bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
try {
    # LogonUser, not PrincipalContext: it goes through the SAME authentication
    # packages the logon screen does, so the cloud provider gets a look at an MSA
    # credential. Every plausible identity form is tried and the winner is recorded.
    $candidates = @()
    if ($msaIdentity) {
        $candidates += ,@('MicrosoftAccount', $msaIdentity)
        $candidates += ,@('',                 $msaIdentity)
    }
    $candidates += ,@('.',     $user)
    $candidates += ,@($domain, $user)

    $lastErr = 0
    foreach ($c in $candidates) {
        if ([SRLogon]::Check($c[1], $c[0], $plain)) {
            $winDomain = $c[0]; $winUser = $c[1]
            break
        }
        $lastErr = [SRLogon]::LastError
    }

    if (-not $winUser) {
        Write-Fail "Windows rejected that password - NOTHING was changed."
        Write-Host ""
        Write-Step ("last Win32 error: {0}  ({1})" -f $lastErr, (Get-LogonErrorMeaning $lastErr))
        Write-Host ""
        if ($msaIdentity) {
            Write-Host "  This account signs in with the MICROSOFT ACCOUNT $msaIdentity." -ForegroundColor Yellow
            Write-Host "  That is the password to type here - not a PIN, and not a local password." -ForegroundColor Yellow
            Write-Host "  If you only ever use a PIN or Windows Hello, reset or look it up at" -ForegroundColor Yellow
            Write-Host "  https://account.microsoft.com/security first." -ForegroundColor Yellow
        }
        Write-Host ""
        exit 1
    }

    Write-Ok ("password verified by Windows as {0}" -f $(if ($winDomain) { "$winDomain\$winUser" } else { $winUser }))
    Set-LsaSecret -Key 'DefaultPassword' -Value $plain
    Write-Ok 'password stored in the LSA secret store (encrypted, SYSTEM-only)'
}
finally {
    # Do not leave it in memory any longer than the calls above need it.
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if (Get-Variable plain -ErrorAction SilentlyContinue) { Remove-Variable plain -Force }
}

# Write the identity that AUTHENTICATED. For a Microsoft account Winlogon expects
# the domain literal 'MicrosoftAccount' and the e-mail as the user name; writing the
# local shadow account instead is the classic "auto-logon does nothing" cause.
$regUser   = $winUser
$regDomain = $winDomain
if ($regDomain -eq '.' -or [string]::IsNullOrWhiteSpace($regDomain)) {
    $regDomain = if ($winUser -like '*@*') { 'MicrosoftAccount' } else { $env:COMPUTERNAME }
}
Set-ItemProperty $WinlogonKey -Name AutoAdminLogon    -Value '1'       -Type String
Set-ItemProperty $WinlogonKey -Name DefaultUserName   -Value $regUser   -Type String
Set-ItemProperty $WinlogonKey -Name DefaultDomainName -Value $regDomain -Type String
Write-Ok "AutoAdminLogon = 1, as $regDomain\$regUser"

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
