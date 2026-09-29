#Requires -Version 5.1
<#
.SYNOPSIS
    EmberbirdOS M0 launcher - boots an Android-x86_64 guest under QEMU + WHPX.

.DESCRIPTION
    The first concrete EmberbirdOS artifact (milestone M0 in PLAN.md). It:
      * verifies host prerequisites (Windows Hypervisor Platform / WHPX, QEMU,
        OVMF UEFI firmware) and reports WSL2 coexistence, without touching a VM
        when run with -Check;
      * creates a persistent virtio userdata disk on first boot;
      * auto-selects the best available accelerated virtio-gpu device
        (rutabaga/gfxstream > virtio-vga-gl > virtio-gpu-gl > virtio-gpu);
      * boots a BlissOS 'arcadia-x86' (or any Android-x86_64) .iso/.img with
        WHPX acceleration, virtio-net, and host-forwarded ADB.

    This is a launcher only - no guest modification. It is safe to run alongside
    an existing WSL2/Hyper-V install (all are clients of the one MS hypervisor).

.PARAMETER Image
    Path to the Android-x86_64 guest image. An .iso boots from CD; a writable
    disk image attaches over virtio with its QEMU block driver inferred from the
    file extension (.qcow2->qcow2, .vhdx->vhdx, .vhd->vpc, .vmdk->vmdk,
    .vdi->vdi, and .img/.raw or anything else -> raw). The driver is always set
    explicitly so QEMU never format-probes a writable disk.

.PARAMETER Check
    Verify prerequisites and print a readiness report, then exit. Starts no VM.

.PARAMETER Cores        Guest vCPU count (default 4).
.PARAMETER Memory       Guest RAM, e.g. '4G' or '4096M' (default 4G).
.PARAMETER Cpu          QEMU -cpu model (default 'max'; WHPX-friendly).
.PARAMETER DataDisk     Path to the persistent userdata qcow2 (auto-created).
.PARAMETER DataDiskSizeGB  Size of a freshly-created userdata disk (default 8).
.PARAMETER QemuPath     Directory containing qemu-system-x86_64.exe (else PATH/known locations).
.PARAMETER OvmfCode     Path to OVMF_CODE.fd (UEFI firmware code).
.PARAMETER OvmfVars     Path to a writable OVMF_VARS.fd (per-VM NVRAM; auto-copied).
.PARAMETER AdbPort      Host loopback port forwarded to guest adbd:5555 (default 58526, WSA's port).
.PARAMETER Gpu          'gfxstream' (default, auto-fallback), 'virgl', or 'none'.
.PARAMETER Display      'gtk' (default), 'sdl', or 'none' (headless).
.PARAMETER NoAccel      Boot with TCG (software) instead of WHPX - very slow; debugging only.
.PARAMETER DryRun       Print the assembled QEMU command line and exit; launch nothing.

.EXAMPLE
    .\launch-emberbird.ps1 -Check
.EXAMPLE
    .\launch-emberbird.ps1 -Image C:\images\bliss_arcadia-x86.iso
.EXAMPLE
    .\launch-emberbird.ps1 -Image C:\images\bliss.iso -Cores 6 -Memory 8G -DryRun
#>
[CmdletBinding(DefaultParameterSetName = 'Boot')]
param(
    [Parameter(ParameterSetName = 'Boot', Position = 0)]
    [string] $Image,

    [Parameter(ParameterSetName = 'Check', Mandatory = $true)]
    [switch] $Check,

    [ValidateRange(1, 64)]
    [int] $Cores = 4,

    [ValidatePattern('^\d+[MG]$')]
    [string] $Memory = '4G',

    [string] $Cpu = 'max',

    # Default resolved in the body from $PSScriptRoot, not here: a param default
    # that reads $PSScriptRoot evaluates to an empty string when the script
    # declares explicit parameter sets (Boot/Check), breaking -Check. See below.
    [string] $DataDisk,

    [ValidateRange(1, 1024)]
    [int] $DataDiskSizeGB = 8,

    [string] $QemuPath,

    [string] $OvmfCode,

    [string] $OvmfVars,

    [ValidateRange(1, 65535)]
    [int] $AdbPort = 58526,

    [ValidateSet('gfxstream', 'virgl', 'none')]
    [string] $Gpu = 'gfxstream',

    [ValidateSet('gtk', 'sdl', 'none')]
    [string] $Display = 'gtk',

    [switch] $NoAccel,

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the default userdata-disk path here rather than in the param block. A
# parameter default that reads $PSScriptRoot evaluates to an empty string when the
# script declares explicit parameter sets (this one has Boot/Check), so -Check
# would otherwise die during param binding with a Join-Path empty-Path error
# before any work runs. In the script body $PSScriptRoot is always populated.
if ([string]::IsNullOrEmpty($DataDisk)) {
    $DataDisk = Join-Path $PSScriptRoot '..\..\image\out\userdata.qcow2'
}

# --- console helpers -------------------------------------------------------
$script:Failures = 0
function Write-Section([string] $Text) { Write-Host ''; Write-Host "== $Text ==" -ForegroundColor Cyan }
function Write-Ok     ([string] $Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn   ([string] $Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Info   ([string] $Text) { Write-Host "  [INFO] $Text" -ForegroundColor Gray }
function Write-Fail   ([string] $Text) { $script:Failures++; Write-Host "  [FAIL] $Text" -ForegroundColor Red }
# --- QEMU discovery --------------------------------------------------------
# Resolve qemu-system-x86_64.exe from -QemuPath, then PATH, then well-known install dirs.
function Resolve-QemuExe {
    param([string] $Name)
    if ($QemuPath) {
        $candidate = Join-Path $QemuPath $Name
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        throw "QemuPath '$QemuPath' does not contain $Name."
    }
    $onPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $wellKnown = @(
        "$env:ProgramFiles\qemu",
        "${env:ProgramFiles(x86)}\qemu",
        "$env:ProgramW6432\qemu",
        'C:\msys64\ucrt64\bin',
        'C:\msys64\mingw64\bin'
    )
    foreach ($dir in $wellKnown) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir $Name))) {
            return (Resolve-Path -LiteralPath (Join-Path $dir $Name)).Path
        }
    }
    return $null
}

# --- OVMF (UEFI firmware) discovery ---------------------------------------
# OVMF ships CODE and VARS as a build-matched PAIR: an OVMF_CODE from one build family
# only boots with the OVMF_VARS from the SAME family (a 4MB code image will not boot a
# 2MB varstore, and vice versa). Resolving code and vars by two independent first-match
# searches can therefore pick a mismatched pair on a host that has several OVMF builds
# installed. So we search ordered (code, vars) FAMILIES and take the first family whose
# BOTH members exist in the same directory. Explicit -OvmfCode / -OvmfVars always win
# (each independently); a single explicit file is paired against its family partner.
# The combined 'OVMF.fd' image is deliberately NOT a family here: it packs code+vars into
# one blob, unusable for the split readonly-CODE + writable-VARS pflash layout we use.

# Ordered CODE+VARS families, most-preferred first; each row is a set shipped together.
$script:OvmfFamilies = @(
    [pscustomobject]@{ Code = 'edk2-x86_64-code.fd'; Vars = 'edk2-i386-vars.fd' },  # qemu.weilnetz.de / msys2
    [pscustomobject]@{ Code = 'OVMF_CODE_4M.fd';     Vars = 'OVMF_VARS_4M.fd'    },  # 4MB build (Debian/Fedora)
    [pscustomobject]@{ Code = 'OVMF_CODE.fd';        Vars = 'OVMF_VARS.fd'       }   # 2MB / legacy build
)

function Get-OvmfSearchDirs {
    $dirs = @()
    if ($script:QemuExe) { $dirs += Split-Path -Parent $script:QemuExe }
    $dirs += @(
        "$env:ProgramFiles\qemu\share",
        "$env:ProgramFiles\qemu",
        'C:\msys64\ucrt64\share\qemu',
        'C:\msys64\mingw64\share\qemu'
    )
    return @($dirs | Where-Object { $_ })
}

# Given one resolved OVMF file, find its opposite member in the SAME directory: try the
# family whose $Field name matches this file first, then any family's $Want name there.
function Find-OvmfPartner {
    param([string] $KnownPath, [string] $Field, [string] $Want)
    $dir  = Split-Path -Parent $KnownPath
    $leaf = Split-Path -Leaf   $KnownPath
    $fam  = $script:OvmfFamilies | Where-Object { $_.$Field -ieq $leaf } | Select-Object -First 1
    if ($fam) {
        $cand = Join-Path $dir $fam.$Want
        if (Test-Path -LiteralPath $cand) { return (Resolve-Path -LiteralPath $cand).Path }
    }
    foreach ($f in $script:OvmfFamilies) {
        $cand = Join-Path $dir $f.$Want
        if (Test-Path -LiteralPath $cand) { return (Resolve-Path -LiteralPath $cand).Path }
    }
    return $null
}
# Return @{ Code = <path|null>; Vars = <path|null> } as a matched pair (see the family
# note above). Throws only when an explicitly-passed file is missing; a failed AUTO search
# leaves the missing side $null for the caller's pre-flight to report.
function Resolve-OvmfPair {
    param([string] $ExplicitCode, [string] $ExplicitVars)
    $out = [ordered]@{ Code = $null; Vars = $null }

    if ($ExplicitCode) {
        if (-not (Test-Path -LiteralPath $ExplicitCode)) { throw "OVMF_CODE file '$ExplicitCode' not found." }
        $out.Code = (Resolve-Path -LiteralPath $ExplicitCode).Path
    }
    if ($ExplicitVars) {
        if (-not (Test-Path -LiteralPath $ExplicitVars)) { throw "OVMF_VARS file '$ExplicitVars' not found." }
        $out.Vars = (Resolve-Path -LiteralPath $ExplicitVars).Path
    }
    if ($out.Code -and $out.Vars) { return $out }

    # One side explicit: pair it with its family partner from the explicit file's own dir.
    if ($out.Code -and -not $out.Vars) { $out.Vars = Find-OvmfPartner -KnownPath $out.Code -Field 'Code' -Want 'Vars'; return $out }
    if ($out.Vars -and -not $out.Code) { $out.Code = Find-OvmfPartner -KnownPath $out.Vars -Field 'Vars' -Want 'Code'; return $out }

    # Neither side explicit: first family whose BOTH members exist in one directory.
    foreach ($dir in (Get-OvmfSearchDirs)) {
        foreach ($fam in $script:OvmfFamilies) {
            $codePath = Join-Path $dir $fam.Code
            $varsPath = Join-Path $dir $fam.Vars
            if ((Test-Path -LiteralPath $codePath) -and (Test-Path -LiteralPath $varsPath)) {
                $out.Code = (Resolve-Path -LiteralPath $codePath).Path
                $out.Vars = (Resolve-Path -LiteralPath $varsPath).Path
                return $out
            }
        }
    }
    return $out
}
# --- hypervisor / WHPX detection ------------------------------------------
# Returns a hashtable describing WHPX readiness. WHPX needs BOTH the
# "HypervisorPlatform" optional feature enabled AND a running root hypervisor.
function Get-WhpxStatus {
    $status = [ordered]@{ HypervisorPresent = $false; PlatformFeature = 'Unknown'; Ready = $false }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $status.HypervisorPresent = [bool] $cs.HypervisorPresent
    } catch { Write-Info "Could not query Win32_ComputerSystem: $($_.Exception.Message)" }
    try {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName 'HypervisorPlatform' -ErrorAction Stop
        $status.PlatformFeature = "$($feat.State)"
    } catch {
        # Querying optional features can require elevation; fall back to a soft probe.
        $status.PlatformFeature = 'Unknown (needs elevation to query)'
    }
    $status.Ready = $status.HypervisorPresent -and
                    ($status.PlatformFeature -eq 'Enabled' -or $status.PlatformFeature -like 'Unknown*')
    return $status
}

function Get-Wsl2Status {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) { return 'not installed' }
    try {
        $null = & wsl.exe --status 2>&1
        return 'installed (coexists with WHPX - both use the MS hypervisor)'
    } catch { return 'present' }
}

# --- device capability probe ----------------------------------------------
# Query `qemu -device help` once and pick the best accelerated virtio-gpu device.
function Get-QemuDeviceList {
    if ($null -ne $script:DeviceList) { return $script:DeviceList }
    try { $script:DeviceList = (& $script:QemuExe -device help 2>&1) -join "`n" }
    catch { $script:DeviceList = '' }
    return $script:DeviceList
}
function Test-QemuDevice([string] $Name) { return (Get-QemuDeviceList) -match [regex]::Escape($Name) }
# Choose the GPU device string based on -Gpu and what this QEMU build supports.
# Preference for 'gfxstream': rutabaga(gfxstream) > virtio-vga-gl > virtio-gpu-gl > virtio-gpu.
function Select-GpuDevice {
    param([string] $Mode)
    switch ($Mode) {
        'none' { return @{ Device = 'virtio-gpu-pci'; Gl = $false; Note = 'no host GL (virtio-gpu, unaccelerated)' } }
        'virgl' {
            if (Test-QemuDevice 'virtio-vga-gl')  { return @{ Device = 'virtio-vga-gl';  Gl = $true; Note = 'virgl (virtio-vga-gl)' } }
            if (Test-QemuDevice 'virtio-gpu-gl-pci') { return @{ Device = 'virtio-gpu-gl-pci'; Gl = $true; Note = 'virgl (virtio-gpu-gl)' } }
        }
        default { # gfxstream, with graceful fallback
            if (Test-QemuDevice 'virtio-gpu-rutabaga') {
                return @{ Device = 'virtio-gpu-rutabaga,gfxstream-vulkan=on,hostmem=256M,blob=true'; Gl = $false;
                          Note = 'gfxstream via virtio-gpu-rutabaga (target config)' }
            }
            Write-Warn "This QEMU build lacks virtio-gpu-rutabaga (gfxstream); falling back to virgl/GL."
            if (Test-QemuDevice 'virtio-vga-gl')  { return @{ Device = 'virtio-vga-gl';  Gl = $true; Note = 'fallback: virtio-vga-gl (virgl)' } }
            if (Test-QemuDevice 'virtio-gpu-gl-pci') { return @{ Device = 'virtio-gpu-gl-pci'; Gl = $true; Note = 'fallback: virtio-gpu-gl' } }
        }
    }
    Write-Warn "No accelerated GPU device available; using plain virtio-gpu (software)."
    return @{ Device = 'virtio-gpu-pci'; Gl = $false; Note = 'software (virtio-gpu)' }
}

# --- persistent userdata disk ---------------------------------------------
function Initialize-DataDisk {
    if (Test-Path -LiteralPath $DataDisk) { return (Resolve-Path -LiteralPath $DataDisk).Path }
    $dir = Split-Path -Parent $DataDisk
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Guard here, not only in -Check / the boot pre-flight: qemu-img can be missing on a
    # partial install where qemu-system was found. Fail with the same clean, actionable
    # message the other missing-tool guards use, rather than an opaque '& $null' invocation.
    if (-not $script:QemuImgExe) { throw 'qemu-img.exe not found (ships with QEMU). Install QEMU or pass -QemuPath. Run -Check for details.' }
    Write-Info "Creating $DataDiskSizeGB GB userdata disk at $DataDisk"
    & $script:QemuImgExe create -f qcow2 $DataDisk "${DataDiskSizeGB}G" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "qemu-img failed to create the userdata disk (exit $LASTEXITCODE)." }
    return (Resolve-Path -LiteralPath $DataDisk).Path
}

# --- writable per-VM UEFI NVRAM -------------------------------------------
function Initialize-OvmfVars {
    param([string] $Template)
    $localVars = Join-Path $PSScriptRoot 'OVMF_VARS.local.fd'
    if (-not (Test-Path -LiteralPath $localVars)) {
        Copy-Item -LiteralPath $Template -Destination $localVars -Force
        Write-Info "Initialized writable UEFI NVRAM at $localVars"
    }
    return (Resolve-Path -LiteralPath $localVars).Path
}
# --- readiness report ------------------------------------------------------
function Invoke-ReadinessReport {
    Write-Section 'EmberbirdOS M0 - host readiness check'

    Write-Section 'QEMU'
    if ($script:QemuExe)    { Write-Ok "qemu-system-x86_64: $script:QemuExe" } else { Write-Fail 'qemu-system-x86_64.exe not found (install QEMU or pass -QemuPath).' }
    if ($script:QemuImgExe) { Write-Ok "qemu-img: $script:QemuImgExe" }         else { Write-Fail 'qemu-img.exe not found (ships with QEMU).' }
    if ($script:QemuExe) {
        $ver = (& $script:QemuExe --version 2>&1 | Select-Object -First 1)
        Write-Info $ver
    }

    Write-Section 'Windows Hypervisor Platform (WHPX)'
    $whpx = Get-WhpxStatus
    if ($whpx.HypervisorPresent) { Write-Ok 'A root hypervisor is running (required by WHPX).' }
    else { Write-Fail 'No running hypervisor. Enable Windows Hypervisor Platform / Virtual Machine Platform, then reboot.' }
    switch -Wildcard ($whpx.PlatformFeature) {
        'Enabled'  { Write-Ok 'HypervisorPlatform optional feature: Enabled.' }
        'Unknown*' { Write-Warn "HypervisorPlatform feature state: $($whpx.PlatformFeature). Run elevated to confirm, or: DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All" }
        default    { Write-Fail "HypervisorPlatform feature: $($whpx.PlatformFeature). Enable with: DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All (reboot)." }
    }

    Write-Section 'OVMF (UEFI firmware)'
    if ($script:OvmfCodeResolved) { Write-Ok "OVMF_CODE: $script:OvmfCodeResolved" } else { Write-Fail 'OVMF_CODE.fd not found. Install QEMU firmware or pass -OvmfCode.' }
    if ($script:OvmfVarsResolved) { Write-Ok "OVMF_VARS: $script:OvmfVarsResolved" } else { Write-Fail 'OVMF_VARS.fd not found. Pass -OvmfVars.' }

    Write-Section 'GPU device support'
    if ($script:QemuExe) {
        foreach ($d in 'virtio-gpu-rutabaga','virtio-vga-gl','virtio-gpu-gl-pci','virtio-gpu-pci') {
            if (Test-QemuDevice $d) { Write-Ok "supported: $d" } else { Write-Info "absent:    $d" }
        }
    }

    Write-Section 'WSL2 coexistence'
    Write-Info "WSL2: $(Get-Wsl2Status)"

    Write-Section 'Anti-cheat note'
    Write-Warn 'With WHPX enabled, Windows runs atop the MS hypervisor; some kernel anti-cheat (Vanguard/EAC/BE strict) may refuse to run.'
    Write-Info 'To fully disable the hypervisor for gaming: bcdedit /set hypervisorlaunchtype off  (reboot). Re-enable: ... auto.'

    Write-Section 'Result'
    if ($script:Failures -eq 0) { Write-Host '  READY: all prerequisites satisfied.' -ForegroundColor Green; return 0 }
    Write-Host "  NOT READY: $($script:Failures) blocking item(s) above." -ForegroundColor Red
    return 1
}
# === main ==================================================================
$script:QemuExe    = Resolve-QemuExe 'qemu-system-x86_64.exe'
$script:QemuImgExe = Resolve-QemuExe 'qemu-img.exe'
$script:DeviceList = $null

# Resolve firmware (code is read-only; vars is a writable template we copy per-VM).
$script:OvmfCodeResolved = $null
$script:OvmfVarsResolved = $null
# Resolve as a build-matched (code, vars) PAIR (see Resolve-OvmfPair) so a host with
# several OVMF builds can't pair a code image with a foreign-family varstore (won't boot).
try {
    $ovmf = Resolve-OvmfPair -ExplicitCode $OvmfCode -ExplicitVars $OvmfVars
    $script:OvmfCodeResolved = $ovmf.Code
    $script:OvmfVarsResolved = $ovmf.Vars
} catch { Write-Warn $_.Exception.Message }

if ($Check) { exit (Invoke-ReadinessReport) }

# ---- boot path ----
if (-not $Image)                          { throw 'Specify -Image <path to .iso/.img>, or run with -Check. See -? for help.' }
if (-not (Test-Path -LiteralPath $Image)) { throw "Guest image not found: $Image" }
if (-not $script:QemuExe)                 { throw 'qemu-system-x86_64.exe not found. Install QEMU or pass -QemuPath. Run -Check for details.' }
if (-not $script:OvmfCodeResolved)        { throw 'OVMF firmware not found. Pass -OvmfCode / -OvmfVars. Run -Check for details.' }
if (-not $script:OvmfVarsResolved)        { throw 'OVMF_VARS template not found. Pass -OvmfVars. Run -Check for details.' }

# The WHPX probe is the slowest thing in this script (Get-WindowsOptionalFeature
# queries the component store, and Get-CimInstance is another WMI round trip), and it
# gates only an actual launch. -DryRun just assembles and prints a command line, so run
# the probe on the boot path only - a preview must not cost seconds to render.
if (-not $DryRun) {
    $whpx = Get-WhpxStatus
    if (-not $NoAccel -and -not $whpx.HypervisorPresent) {
        throw 'WHPX unavailable (no running hypervisor). Enable Windows Hypervisor Platform + reboot, or pass -NoAccel for slow software boot.'
    }
}

$imagePath  = (Resolve-Path -LiteralPath $Image).Path
# -DryRun must stay side-effect-free: it prints the assembled command and exits. Creating
# the userdata disk (qemu-img create) or copying the UEFI NVRAM here would write files just
# to render a preview, and would throw on a host without qemu-img - defeating the diagnostic.
# So under -DryRun compute the paths a real boot WOULD use, creating nothing; the boot branch
# below still materializes them for an actual launch.
if ($DryRun) {
    $dataPath = if (Test-Path -LiteralPath $DataDisk) { (Resolve-Path -LiteralPath $DataDisk).Path } else { $DataDisk }
    $varsPath = Join-Path $PSScriptRoot 'OVMF_VARS.local.fd'
} else {
    $dataPath = Initialize-DataDisk
    $varsPath = Initialize-OvmfVars -Template $script:OvmfVarsResolved
}
$gpuDev     = Select-GpuDevice -Mode $Gpu
# WHPX needs no interrupt-controller flag: QEMU-on-Windows already disables the
# in-kernel irqchip by default under WHPX (sidestepping the "a legacy-PIC IRQ won't
# wake the guest from HLT" quirk), so the default config needs none. -M kernel-irqchip=
# is a QEMU-documented debug-only option; hardcoding it contradicted PLAN.md section 6.1's
# launch shape. TCG is the software fallback for -NoAccel (debugging only, very slow).
$accel      = if ($NoAccel) { 'tcg' } else { 'whpx' }
$isIso      = ([System.IO.Path]::GetExtension($imagePath)).ToLowerInvariant() -eq '.iso'

$qargs = [System.Collections.Generic.List[string]]::new()
$qargs.AddRange([string[]]@(
    '-name', 'EmberbirdOS',
    '-machine', "q35,accel=$accel",
    '-cpu', $Cpu,
    '-smp', "cores=$Cores",
    '-m', $Memory,
    '-drive', "if=pflash,format=raw,readonly=on,file=$script:OvmfCodeResolved",
    '-drive', "if=pflash,format=raw,file=$varsPath",
    # Suppress the q35 machine's default emulated VGA. Without this, q35's
    # default_display='std' creates a std-VGA adapter as the PRIMARY console in
    # front of our accelerated virtio-gpu device (adding -device virtio-gpu-*
    # does NOT suppress it); legacy VGA is also very slow under WHPX.
    '-vga', 'none',
    '-device', $gpuDev.Device,
    '-device', 'virtio-net-pci,netdev=net0',
    '-netdev', "user,id=net0,hostfwd=tcp:127.0.0.1:$AdbPort-:5555",
    '-drive', "file=$dataPath,if=virtio,format=qcow2,cache=writeback",
    '-device', 'virtio-tablet-pci',
    '-device', 'virtio-keyboard-pci',
    '-rtc', 'base=localtime',
    '-usb'
))
if ($isIso) { $qargs.AddRange([string[]]@('-cdrom', $imagePath, '-boot', 'd')) }
else {
    # Attach a writable disk image over virtio. Force the block driver from the
    # file extension: an explicit format= disables QEMU's format probing (a
    # flagged security hazard), and mislabeling e.g. a qcow2 as raw makes QEMU
    # read the qcow2 header as boot sectors -> unbootable, and corrupts the image
    # on first write. The userdata disk above is qcow2; this is the guest image.
    $imgExt = ([System.IO.Path]::GetExtension($imagePath)).ToLowerInvariant()
    $imgFmt = switch ($imgExt) {
        '.qcow2' { 'qcow2' }
        '.vhdx'  { 'vhdx' }
        '.vhd'   { 'vpc' }
        '.vmdk'  { 'vmdk' }
        '.vdi'   { 'vdi' }
        default  { 'raw' }   # .img / .raw and any other raw disk image
    }
    $qargs.AddRange([string[]]@('-drive', "file=$imagePath,if=virtio,format=$imgFmt"))
}
if ($Display -eq 'none') { $qargs.AddRange([string[]]@('-display', 'none', '-serial', 'mon:stdio')) }
else {
    $disp = $Display; if ($gpuDev.Gl) { $disp = "$Display,gl=on" }
    $qargs.AddRange([string[]]@('-display', $disp))
}
# --- summary + launch ------------------------------------------------------
Write-Section 'EmberbirdOS - launch configuration'
Write-Info "QEMU        : $script:QemuExe"
Write-Info "Guest image : $imagePath$(if ($isIso) { ' (ISO, boot from CD)' })"
Write-Info "Accel       : $accel$(if ($NoAccel) { '  (software - expect very low fps)' })"
Write-Info "vCPU / RAM  : $Cores cores / $Memory   CPU model: $Cpu"
Write-Info "GPU         : $($gpuDev.Note)"
Write-Info "Userdata    : $dataPath"
Write-Info "UEFI NVRAM  : $varsPath"
Write-Info "ADB         : host 127.0.0.1:$AdbPort  ->  guest :5555   (adb connect 127.0.0.1:$AdbPort)"
if (-not $NoAccel) {
    Write-Warn 'WHPX active: kernel anti-cheat (Vanguard/EAC/BE strict) may block while this runs. bcdedit /set hypervisorlaunchtype off (reboot) to disable.'
}

$pretty = ($qargs | ForEach-Object { if ($_ -match '[\s,=]') { '"' + $_ + '"' } else { $_ } }) -join ' '
Write-Section 'QEMU command'
Write-Host "  $script:QemuExe $pretty" -ForegroundColor DarkGray

if ($DryRun) { Write-Host ''; Write-Info 'DryRun: not launching.'; exit 0 }

Write-Section 'Booting'
& $script:QemuExe @qargs
$code = $LASTEXITCODE
if ($code -ne 0) { Write-Fail "QEMU exited with code $code."; exit $code }
Write-Ok 'QEMU exited cleanly.'
exit 0
