#Requires -Version 5.1
<#
.SYNOPSIS
    Provision (and report on) the Windows host prerequisites for EmberbirdOS M2.

.DESCRIPTION
    M2 (Guest Boot Proof) needs four host-side things that this machine does not ship
    with: QEMU for Windows, OVMF UEFI firmware, Android platform-tools (adb), and a
    working Windows Hypervisor Platform (WHPX) so the frozen M0 launcher
    (launch-emberbird.ps1) can actually boot a guest.

    This script is the single place that KNOWS how to check for those, and the only
    place allowed to acquire them. It has one hard rule, inherited from the M1/M2
    governance posture: it never silently changes the host.

      * -Check (DEFAULT)      read-only. Reports what is present/missing and prints the
                              exact remediation command for each gap. Starts nothing.
      * -FetchPlatformTools   downloads Android platform-tools into a user directory
                              (no administrator rights required) and reports the hash.
      * -InstallQemu          runs the winget package for QEMU. Windows will raise its
                              own UAC prompt - the elevation decision stays the user's.

    It does NOT touch `bcdedit`, does NOT disable the hypervisor, and does NOT change
    any boot configuration. HYPERV-SEC-01 (the anti-cheat trade-off) is documented and
    operator-controlled only - see docs/M1-RUNTIME-ARCHITECTURE.md section 10.

    M2 evidence hooks: -Check prints the readiness report that backs
    docs/evidence/M2/env-probe.txt, and -EvidencePath tees that report to a file so it
    can be committed as durable evidence.

.PARAMETER Check
    (Default) Probe only. Nothing is installed, downloaded, or modified.

.PARAMETER FetchPlatformTools
    Download the current Android platform-tools zip to -Destination and expand it.
    User-scope; needs no elevation.

.PARAMETER InstallQemu
    Install/upgrade QEMU via winget. Expect a UAC prompt. Nothing is installed
    unattended.

.PARAMETER Destination
    Where -FetchPlatformTools unpacks platform-tools. Default: <repo>/tools/platform-tools

.PARAMETER QemuPath
    Directory holding qemu-system-x86_64.exe, used to locate OVMF next to QEMU.
    Auto-detected from PATH when omitted.

.PARAMETER EvidencePath
    Tee the full report to this file (use under docs/evidence/ to keep evidence durable).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\qemu\provision-host.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\qemu\provision-host.ps1 `
        -Check -EvidencePath .\docs\evidence\M2\env-probe.txt

.EXAMPLE
    # acquire the one prerequisite that needs no administrator rights
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\qemu\provision-host.ps1 -FetchPlatformTools

.OUTPUTS
    Exit code 0 = ready (or the requested acquisition succeeded). 1 = a blocking
    prerequisite is still missing. 2 = the requested action failed.

.NOTES
    Part of EmberbirdOS M0/M2. The launcher itself is frozen for M2; this script is
    host provisioning only and is never invoked by the launcher.
#>
[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Check')]
    [switch] $Check,

    [Parameter(ParameterSetName = 'Tools', Mandatory = $true)]
    [switch] $FetchPlatformTools,

    [Parameter(ParameterSetName = 'Qemu', Mandatory = $true)]
    [switch] $InstallQemu,

    [string] $Destination,

    [string] $QemuPath,

    [string] $EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Destination) { $Destination = Join-Path $repoRoot 'tools\platform-tools' }

$script:Blocking = 0
$script:Transcript = New-Object System.Collections.Generic.List[string]

function Emit([string] $Line, [string] $Color = 'Gray') {
    Write-Host $Line -ForegroundColor $Color
    $script:Transcript.Add($Line)
}
function Section([string] $Title) {
    Emit ''
    Emit ("== {0} ==" -f $Title) 'Cyan'
}
function Ok([string] $Msg) { Emit ("  [OK]   {0}" -f $Msg) 'Green' }
function Warn([string] $Msg) { Emit ("  [WARN] {0}" -f $Msg) 'Yellow' }
function Fail([string] $Msg) { $script:Blocking++; Emit ("  [FAIL] {0}" -f $Msg) 'Red' }
function Info([string] $Msg) { Emit ("  [INFO] {0}" -f $Msg) }

function Find-Executable([string] $Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-OvmfCandidates([string] $Dir) {
    # Families the launcher accepts. A CODE/VARS pair must come from ONE family -
    # never a cross-family mix, and never the combined OVMF.fd as a split member.
    $pairs = @(
        @{ Family = 'edk2';   Code = 'edk2-x86_64-code.fd'; Vars = 'edk2-i386-vars.fd' },
        @{ Family = 'OVMF';   Code = 'OVMF_CODE.fd';        Vars = 'OVMF_VARS.fd' }
    )
    $found = @()
    if (-not $Dir) { return $found }
    foreach ($p in $pairs) {
        $code = Join-Path $Dir $p.Code
        $vars = Join-Path $Dir $p.Vars
        if ((Test-Path -LiteralPath $code) -and (Test-Path -LiteralPath $vars)) {
            $found += [pscustomobject]@{ Family = $p.Family; Code = $code; Vars = $vars }
        }
    }
    return $found
}

# ---------------------------------------------------------------- acquisition ---
function Invoke-FetchPlatformTools {
    Section 'Android platform-tools (adb)'
    $url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
    Info ("source: {0}" -f $url)
    Info ("destination: {0}" -f $Destination)

    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('platform-tools-' + $PID + '.zip')

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
        Fail ("download failed: {0}" -f $_.Exception.Message)
        return $false
    }

    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $size = (Get-Item -LiteralPath $zip).Length
    Ok ("downloaded {0} bytes" -f $size)
    Info ("sha256: {0}" -f $hash)

    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    # .NET's ZipFile instead of Expand-Archive, which is very slow over platform-tools'
    # thousands of entries (it walks the archive per entry and writes progress output).
    # The destination was just removed, so -Force's overwrite behaviour is not needed.
    # Fall back to Expand-Archive on a host where the compression assembly is absent.
    $zipApi = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zipApi = [System.IO.Compression.ZipFile]
    } catch {
        $zipApi = $null
    }
    if ($zipApi) {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $parent)
    } else {
        Expand-Archive -LiteralPath $zip -DestinationPath $parent -Force
    }
    Remove-Item -LiteralPath $zip -Force

    $adb = Join-Path $Destination 'adb.exe'
    if (Test-Path -LiteralPath $adb) {
        Ok ("adb: {0}" -f $adb)
        Info 'add that directory to PATH, or pass it to the launcher host, to use adb on the host'
        return $true
    }
    Fail 'adb.exe not found after extraction'
    return $false
}

function Invoke-InstallQemu {
    Section 'QEMU for Windows (winget)'
    $winget = Find-Executable 'winget'
    if (-not $winget) {
        Fail 'winget is not available; install "App Installer" from the Microsoft Store, or install QEMU manually from https://qemu.weilnetz.de/w64/'
        return $false
    }
    $id = 'SoftwareFreedomConservancy.QEMU'
    Warn ("this runs: winget install --id {0} --exact --accept-package-agreements --accept-source-agreements" -f $id)
    Warn 'Windows will raise its own UAC prompt - the elevation decision is yours. Nothing is changed if you decline.'
    try {
        & $winget install --id $id --exact --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Fail ("winget exited {0}" -f $LASTEXITCODE); return $false }
    } catch {
        Fail ("winget failed: {0}" -f $_.Exception.Message)
        return $false
    }
    Ok 'winget reported success; re-run -Check (a new shell may be needed for PATH)'
    return $true
}

# ---------------------------------------------------------------------- check ---
function Invoke-Check {
    Emit 'EmberbirdOS M2 - host provisioning report'
    Emit ("captured (UTC): {0}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    try {
        $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue)
        Emit ("host: {0}  os: {1} {2}" -f $env:COMPUTERNAME, $os.Caption, $os.Version)
    } catch {
        Emit ("host: {0}  os: (unavailable)" -f $env:COMPUTERNAME)
    }
    if (-not $Check) { Emit 'mode: acquisition' } else { Emit 'mode: check (read-only; nothing installed or started)' }

    Section 'tool availability (Get-Command)'
    $tools = @('git', 'python', 'curl', 'qemu-system-x86_64', 'qemu-img', 'adb', 'repo', 'winget')
    foreach ($t in $tools) {
        $p = Find-Executable $t
        if ($p) {
            $version = ''
            try {
                if ($t -eq 'git') { $version = (& git --version) }
                elseif ($t -eq 'python') { $version = (& python --version) }
            } catch { $version = '' }
            Emit ("  {0,-22} PRESENT  {1}  {2}" -f $t, $p, $version)
        } else {
            Emit ("  {0,-22} ABSENT" -f $t)
        }
    }

    Section 'QEMU'
    $qemuExe = Find-Executable 'qemu-system-x86_64'
    $qemuDir = $null
    if (-not $qemuExe) { $qemuExe = Find-Executable 'qemu-system-x86_64.exe' }
    if ($qemuExe) {
        $qemuDir = Split-Path -Parent $qemuExe
        Ok ("qemu-system-x86_64: {0}" -f $qemuExe)
    } elseif ($QemuPath -and (Test-Path -LiteralPath (Join-Path $QemuPath 'qemu-system-x86_64.exe'))) {
        $qemuDir = (Resolve-Path -LiteralPath $QemuPath).Path
        Ok ("qemu-system-x86_64 (via -QemuPath): {0}" -f (Join-Path $qemuDir 'qemu-system-x86_64.exe'))
    } else {
        Fail 'qemu-system-x86_64 not found. Install QEMU (https://qemu.weilnetz.de/w64/ or -InstallQemu) or pass -QemuPath.'
    }
    if (Find-Executable 'qemu-img') { Ok 'qemu-img present (needed for the userdata qcow2)' }
    else { Fail 'qemu-img.exe not found (ships with QEMU)' }

    Section 'OVMF (UEFI firmware)'
    $searchDirs = @()
    if ($qemuDir) { $searchDirs += $qemuDir; $searchDirs += (Join-Path $qemuDir 'share') }
    $searchDirs += @(
        'C:\Program Files\qemu\share', 'C:\Program Files\qemu',
        'C:\Program Files (x86)\qemu\share', 'C:\Program Files (x86)\qemu'
    )
    $ovmf = @()
    foreach ($d in ($searchDirs | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $d) { $ovmf += Get-OvmfCandidates $d }
    }
    if ($ovmf.Count -gt 0) {
        foreach ($pair in $ovmf) {
            Ok ("{0}: {1} + {2}" -f $pair.Family, $pair.Code, $pair.Vars)
        }
        $families = ($ovmf | ForEach-Object { $_.Family }) -join ', '
        Info ("launcher invocation: -OvmfCode `"{0}`" -OvmfVars `"{1}`"" -f $ovmf[0].Code, $ovmf[0].Vars)
        Info ("families available: {0} (use ONE family as a pair)" -f $families)
    } else {
        Fail 'no OVMF CODE/VARS pair found. Install QEMU (which bundles firmware) or pass -OvmfCode/-OvmfVars to the launcher.'
    }

    Section 'Windows Hypervisor Platform (WHPX)'
    $hvPresent = $false
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $hvPresent = [bool] $cs.HypervisorPresent
    } catch {
        Warn 'could not query Win32_ComputerSystem.HypervisorPresent'
    }
    if ($hvPresent) { Ok 'a root hypervisor is running (required by WHPX)' }
    else { Fail 'no root hypervisor detected. Enable WHPX (elevated) and reboot: DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All' }
    try {
        $feat = & dism.exe /online /Get-FeatureInfo /FeatureName:HypervisorPlatform 2>&1
        if ($feat -match 'State\s*:\s*Enabled') { Ok 'HypervisorPlatform feature: Enabled' }
        elseif ($feat -match 'State\s*:\s*Disabled') { Fail 'HypervisorPlatform feature: Disabled. Run (elevated): DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All' }
        else { Warn 'HypervisorPlatform feature state: Unknown (needs elevation to query)' }
    } catch {
        Warn 'HypervisorPlatform feature state: Unknown (needs elevation to query). Run elevated to confirm, or: DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All'
    }

    Section 'WSL2 coexistence'
    if (Find-Executable 'wsl') { Info 'WSL2: present (WHPX is a client of the same Microsoft hypervisor, so both can run)' }
    else { Info 'WSL2: not detected' }

    Section 'disk (full arcadia-x86 repo sync + build needs hundreds of GB)'
    try {
        $drive = (Get-PSDrive -Name ($repoRoot.Substring(0, 1)) -ErrorAction Stop)
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        $totalGB = [math]::Round(($drive.Free + $drive.Used) / 1GB, 1)
        Emit ("  {0}: free {1} GB / total {2} GB" -f $drive.Name, $freeGB, $totalGB)
        if ($freeGB -lt 400) {
            Warn 'less than ~400 GB free: a from-source guest build is NOT feasible on this drive.'
            Info 'use the .github/workflows/guest-build.yml path (big-disk runner) or acquire a pinned prebuilt (M2 4.2 alternative).'
        }
    } catch {
        Warn 'could not read free disk space'
    }

    Section 'Android platform-tools (adb)'
    $adb = Find-Executable 'adb'
    if ($adb) { Ok ("adb: {0}" -f $adb) }
    else {
        # NOT a boot blocker: adb is required for the X4/X5 liveness evidence, while the
        # launcher reaches a usable UI without it. Counted separately from $Blocking.
        $localAdb = Join-Path $Destination 'adb.exe'
        if (Test-Path -LiteralPath $localAdb) {
            Warn ("adb present but not on PATH: {0}" -f $localAdb)
            Info 'add its directory to PATH to run adb connect 127.0.0.1:58526 from any shell'
        } else {
            Warn 'adb not found. Run with -FetchPlatformTools (no administrator rights needed), then add the directory to PATH.'
        }
        Info 'adb gates the X4/X5 evidence, not the boot itself - tracked separately from the blocking count'
    }

    Section 'anti-cheat note'
    Warn 'With WHPX enabled, Windows runs atop the MS hypervisor; some kernel anti-cheat (Vanguard/EAC/BE strict) may refuse to run.'
    Info 'To fully disable the hypervisor for gaming: bcdedit /set hypervisorlaunchtype off  (reboot). Re-enable: bcdedit /set hypervisorlaunchtype auto.'
    Info 'EmberbirdOS never runs bcdedit for you; the trade-off is operator-controlled. See docs/M1-RUNTIME-ARCHITECTURE.md section 10.'

    Section 'result'
    if ($script:Blocking -eq 0) {
        Emit '  READY: the frozen M0 launcher can be run with -Check, -DryRun and a boot.' 'Green'
    } else {
        Emit ("  NOT READY: {0} blocking item(s) above." -f $script:Blocking) 'Red'
    }
}

# ----------------------------------------------------------------------- main ---
try {
    if ($FetchPlatformTools) {
        $ok = Invoke-FetchPlatformTools
        if ($EvidencePath) { ($script:Transcript -join [Environment]::NewLine) | Set-Content -LiteralPath $EvidencePath -Encoding UTF8 }
        exit ($(if ($ok) { 0 } else { 2 }))
    }

    if ($InstallQemu) {
        $ok = Invoke-InstallQemu
        if ($EvidencePath) { ($script:Transcript -join [Environment]::NewLine) | Set-Content -LiteralPath $EvidencePath -Encoding UTF8 }
        exit ($(if ($ok) { 0 } else { 2 }))
    }

    Invoke-Check
    if ($EvidencePath) {
        $dir = Split-Path -Parent $EvidencePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($script:Transcript -join [Environment]::NewLine) | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
        Write-Host ''
        Write-Host ("wrote {0}" -f $EvidencePath) -ForegroundColor Cyan
    }
    exit ($(if ($script:Blocking -eq 0) { 0 } else { 1 }))
} catch {
    Write-Host ("provision-host.ps1 FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 2
}
