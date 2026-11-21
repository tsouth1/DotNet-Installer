<#
.SYNOPSIS
    GUI and headless installer for .NET 10 that uses local .exe installers (no winget).

.DESCRIPTION
    The script reads its installers from the folder it lives in (or -SourcePath). That folder has one subfolder
    per package, named <PackageIdentifier>_<Version>, for example:

        Microsoft.DotNet.Runtime.10_10.0.15\
            Microsoft .NET Runtime 10.0_10.0.15_Machine_X64_burn_en-US.yaml   <- winget manifest (metadata)
            Microsoft .NET Runtime 10.0_10.0.15_Machine_X64_burn_en-US.exe    <- installer

    From each YAML manifest the script reads the version, architecture, SHA256 hash, ProductCode, Add/Remove Programs
    name, installer switches and return codes. The .exe in the folder is the one named like the YAML. If there is no
    exe with that name, the only .exe in the folder is used, or whichever .exe matches the hash.

    Before each installer runs, its SHA256 is checked against the YAML. An installer that does not match is blocked,
    unless -SkipHashCheck is given.

    Install command (built from the YAML InstallerSwitches):
        "<installer>.exe" /install /quiet /norestart /log "<LogDir>\install_<Package>_<Version>_<timestamp>.log"

    GUI - A single list with two groups:
        Install .NET 10   - the packages found in the source folder, with the installer version, the installed
                            version and the status. Check packages and click "Install".
        Installed .NET 10 - .NET 10 runtimes, Hosting Bundles and SDKs already on the device. Checking one shows an
                            "Uninstall" button. Entries managed by Visual Studio, and runtimes with no standalone
                            uninstaller, are listed for information only.

    HEADLESS - -Install and/or -Uninstall with package names (Runtime, DesktopRuntime, AspNetCore, HostingBundle, SDK
    or All). -Uninstall removes every standalone .NET 10 installation of that product (all patch versions and
    architectures). It skips anything managed by Visual Studio. When both are given, uninstalls run first.

    The script is built to run as SYSTEM from a ConfigMgr (SCCM) application. Each package can be its own
    deployment type that calls headless mode.

    Exit codes:  0 = success / nothing to do,  3010 = success, reboot required,
                 1603 = one or more operations failed,  1 = invalid parameters / no installers found.

.PARAMETER Install
    Headless: package(s) to install. Runtime, DesktopRuntime, AspNetCore, HostingBundle, SDK or All.

.PARAMETER Uninstall
    Headless: package(s) to uninstall. Runtime, DesktopRuntime, AspNetCore, HostingBundle, SDK or All.

.PARAMETER SkipHashCheck
    Run installers even when their SHA256 does not match the YAML manifest. Not recommended.

.PARAMETER SourcePath
    Folder that contains the package subfolders. Default: the folder this script is in.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install-DotNet10Offline.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Install-DotNet10Offline.ps1 -Install Runtime,DesktopRuntime

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Install-DotNet10Offline.ps1 -Uninstall HostingBundle
#>
[CmdletBinding()]
param(
    [string[]]$Install,      # validated below; "powershell.exe -File" passes "A,B" as one string, so commas are split manually
    [string[]]$Uninstall,
    [switch]$SkipHashCheck,
    [string]$SourcePath      # default: the folder this script is in (resolved below; $PSScriptRoot is empty in a 5.1 param default)
)

$ErrorActionPreference = 'Stop'

#region ---------------- Configuration ----------------
$TargetMajor = '10'                                  # the only .NET major version this script installs and lists
$Products    = [ordered]@{                           # package key (winget ID segment) = display name
    'Runtime'        = '.NET Runtime'
    'DesktopRuntime' = '.NET Desktop Runtime'
    'AspNetCore'     = 'ASP.NET Core Runtime'
    'HostingBundle'  = 'ASP.NET Core Hosting Bundle'
    'SDK'            = '.NET SDK'
}
$LogFileName = "DotNet$($TargetMajor)OfflineInstaller.log"
$MarkerKey   = "HKLM:\SOFTWARE\DotNetOfflineInstaller\NET$TargetMajor"   # written on success; used by the Detect script

# GUI colour scheme
$Theme = @{
    Body         = '#F4F7FB'   # window background (light)
    Header       = '#1F3A5F'   # heading text
    SubText      = '#4A5568'   # secondary text
    Pane         = '#EAF1FA'   # package list background
    PaneText     = '#1B2A3A'   # package list text
    Button       = '#1F3A5F'   # primary buttons (dark navy)
    ButtonHover  = '#2C5282'
    Danger       = '#9B2C2C'   # Uninstall button (dark red)
    DangerHover  = '#B83232'
    Neutral      = '#4A5568'   # Close / Clear (dark slate)
    NeutralHover = '#5F6B7D'
    Disabled     = '#97A3B4'
    ButtonText   = '#FFFFFF'
    LogBack      = '#FFFFFF'
    LogText      = '#1B2A3A'
    Ok           = '#1E7B34'
    Warn         = '#B45309'
    Bad          = '#B42318'
    Busy         = '#1D4ED8'
    Muted        = '#718096'
}
#endregion

#region ---------------- Shared state ----------------
if (-not $SourcePath) { $SourcePath = $PSScriptRoot }
if (-not $SourcePath -and $MyInvocation.MyCommand.Path) { $SourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $SourcePath) { $SourcePath = (Get-Location).Path }
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
$Sync = [hashtable]::Synchronized(@{
    Queue         = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    LogLock       = New-Object object
    LogDir        = $null
    LogFile       = $null
    Console       = $false
    Busy          = $false
    TargetMajor   = $TargetMajor
    Products      = $Products
    SourcePath    = $SourcePath
    SkipHashCheck = [bool]$SkipHashCheck
    Items         = [ordered]@{}     # packages:       Key -> @{ Key; Id; Name; Version; Arch; Exe; Sha256; HashOk; ProductCode; ... }
    Inventory     = [ordered]@{}     # installed rows: Key -> @{ Key; Type; Name; Version; Arch; Removable; Action; ... }
    Selected      = $null            # @{ Install = @(keys); Remove = @(inventory keys) }
    Results       = [ordered]@{}
    Labels        = @{}
})
#endregion

#region ---------------- Core functions (used by GUI thread and background runspaces) ----------------
$CoreScript = {
    function Write-Log {
        param([string]$Message, [ValidateSet('Info', 'Warning', 'Error')][string]$Severity = 'Info')
        $now  = Get-Date
        $type = @{ Info = 1; Warning = 2; Error = 3 }[$Severity]
        # CMTrace format
        $line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="DotNet{6}Offline" context="{3}" type="{4}" thread="{5}" file="">' -f `
            $Message, $now.ToString('HH:mm:ss.fff+000'), $now.ToString('MM-dd-yyyy'), $env:USERNAME, $type, [Threading.Thread]::CurrentThread.ManagedThreadId, $Sync.TargetMajor
        if ($Sync.LogFile) {
            [Threading.Monitor]::Enter($Sync.LogLock)
            try { [IO.File]::AppendAllText($Sync.LogFile, $line + "`r`n", [Text.Encoding]::UTF8) } catch { } finally { [Threading.Monitor]::Exit($Sync.LogLock) }
        }
        if ($Sync.Console) {
            $color = @{ Info = 'Gray'; Warning = 'Yellow'; Error = 'Red' }[$Severity]
            Write-Host ('{0}  {1}' -f $now.ToString('HH:mm:ss'), $Message) -ForegroundColor $color
        }
        else {
            $Sync.Queue.Enqueue(@{ Type = 'Log'; Text = ('{0}  {1}' -f $now.ToString('HH:mm:ss'), $Message); Severity = $Severity })
        }
    }

    function Get-DotNetSortVersion {
        param([string]$Version)
        try { [version]($Version.Split('-')[0]) } catch { [version]'0.0' }
    }

    # ----- Source packages (folder + YAML manifest + .exe) -----

    function Read-InstallerManifest {
        # Minimal reader for the winget YAML fields this script needs (no YAML module in Windows PowerShell 5.1).
        param([string]$Path)
        $t = Get-Content -LiteralPath $Path -Raw
        $get = { param($Pattern) if ($t -match $Pattern) { $Matches[1].Trim() } else { $null } }
        $codes = @{}
        foreach ($m in [regex]::Matches($t, '(?m)InstallerReturnCode:\s*(-?\d+)\s*\r?\n\s*ReturnResponse:\s*(\S+)')) { $codes[$m.Groups[1].Value] = $m.Groups[2].Value }
        $pc = & $get '(?m)^\s*ProductCode:\s*(.+)$'; if ($pc) { $pc = $pc.Trim("'", '"') }
        @{
            Id          = & $get '(?m)^PackageIdentifier:\s*(.+)$'
            Version     = & $get '(?m)^PackageVersion:\s*(.+)$'
            PackageName = & $get '(?m)^PackageName:\s*(.+)$'
            Arch        = & $get '(?m)^\s*-\s*Architecture:\s*(.+)$'
            Sha256      = & $get '(?m)^\s*InstallerSha256:\s*([0-9A-Fa-f]{64})'
            Url         = & $get '(?m)^\s*InstallerUrl:\s*(\S+)'
            ProductCode = $pc
            DisplayName = & $get '(?m)^\s*-\s*DisplayName:\s*(.+)$'
            Silent      = & $get '(?m)^\s*Silent:\s*(.+)$'
            Custom      = & $get '(?m)^\s*Custom:\s*(.+)$'
            LogSwitch   = & $get '(?m)^\s*Log:\s*(.+)$'
            ReturnCodes = $codes
        }
    }

    function Get-PackageCatalog {
        $major = $Sync.TargetMajor
        $cat   = [ordered]@{}
        foreach ($key in $Sync.Products.Keys) {
            $dirs = @(Get-ChildItem -LiteralPath $Sync.SourcePath -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "Microsoft.DotNet.$key.${major}_*" } |
                      Sort-Object @{ e = { Get-DotNetSortVersion (($_.Name -split '_', 2)[1]) }; Descending = $true })
            if ($dirs.Count -eq 0) { Write-Log "No source folder found for $key (expected Microsoft.DotNet.$key.${major}_<version>)." Warning; continue }
            if ($dirs.Count -gt 1) { Write-Log "Several source folders found for ${key}; using the newest: $($dirs[0].Name)" Warning }
            $dir  = $dirs[0]
            $yaml = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.yaml' -File -ErrorAction SilentlyContinue)[0]
            if (-not $yaml) { Write-Log "$($dir.Name): no .yaml manifest found; package skipped." Warning; continue }
            $m = Read-InstallerManifest $yaml.FullName
            if ($m.Id -and $m.Id -ne "Microsoft.DotNet.$key.$major") { Write-Log "$($yaml.Name): PackageIdentifier is '$($m.Id)', expected 'Microsoft.DotNet.$key.$major'." Warning }
            $exes     = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue)
            $expected = [IO.Path]::GetFileNameWithoutExtension($yaml.Name) + '.exe'
            $exe      = @($exes | Where-Object { $_.Name -eq $expected })[0]
            if (-not $exe -and $exes.Count -eq 1) { $exe = $exes[0] }
            $version = $m.Version; if (-not $version) { $version = ($dir.Name -split '_', 2)[1] }
            $cat[$key] = @{
                Key = $key; Id = $m.Id; Name = "$($Sync.Products[$key]) $major"; Version = $version; Arch = $m.Arch
                Folder = $dir.FullName; Yaml = $yaml.FullName; ExpectedExe = $expected
                Exe = $(if ($exe) { $exe.FullName } else { $null }); Candidates = @($exes | ForEach-Object { $_.FullName })
                Sha256 = $m.Sha256; HashOk = $null; ProductCode = $m.ProductCode; DisplayName = $m.DisplayName
                Silent = $m.Silent; Custom = $m.Custom; LogSwitch = $m.LogSwitch; ReturnCodes = $m.ReturnCodes
                Installed = $null; Status = 'Checking...'; Installable = $false
            }
        }
        $cat
    }

    function Get-Sha256 {
        # .NET instead of Get-FileHash: that cmdlet is not loaded in the background runspaces under Windows PowerShell 5.1.
        param([string]$Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        $fs  = [IO.File]::OpenRead($Path)
        try { -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('X2') }) }
        finally { $fs.Dispose(); $sha.Dispose() }
    }

    function Test-InstallerHash {
        # Sets $Item.HashOk ($true / $false / $null when nothing to check) and picks the matching .exe when unsure.
        param($Item)
        $cands = @($Item.Candidates); if ($Item.Exe) { $cands = @($Item.Exe) }
        if ($cands.Count -eq 0) { $Item.HashOk = $null; return }
        if (-not $Item.Sha256) { Write-Log "$($Item.Name): the YAML has no InstallerSha256; the hash cannot be checked." Warning; $Item.HashOk = $null; return }
        foreach ($c in $cands) {
            Write-Log "Verifying SHA256 of $(Split-Path $c -Leaf)..."
            $h = Get-Sha256 $c
            if ($h -eq $Item.Sha256) { $Item.Exe = $c; $Item.HashOk = $true; return }
            Write-Log ("{0}: SHA256 mismatch. Expected {1}, file has {2}." -f (Split-Path $c -Leaf), $Item.Sha256, $h) Warning
        }
        if (-not $Item.Exe) { $Item.Exe = $cands[0] }
        $Item.HashOk = $false
    }

    function Test-ProductInstalled {
        param([string]$ProductCode)
        if (-not $ProductCode) { return $false }
        foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
            if (Test-Path -LiteralPath (Join-Path $root $ProductCode)) { return $true }
        }
        $false
    }

    function Update-PackageStatus {
        param($Item, $Inventory)
        $best = @($Inventory.Values | Where-Object { $_.Source -eq 'Registry' -and $_.Type -eq $Item.Key } |
                  Sort-Object @{ e = { Get-DotNetSortVersion $_.Version }; Descending = $true })[0]
        $Item.Installed = $(if ($best) { $best.Version } else { $null })
        if (-not $Item.Exe) {
            $Item.Installable = $false; $Item.Status = 'Installer .exe missing'
        }
        elseif ($Item.HashOk -eq $false -and -not $Sync.SkipHashCheck) {
            $Item.Installable = $false; $Item.Status = 'Hash mismatch - blocked'
        }
        else {
            $Item.Installable = $true
            if (Test-ProductInstalled $Item.ProductCode) { $Item.Status = 'Installed (this version)' }
            elseif ($best) {
                $c = (Get-DotNetSortVersion $Item.Version).CompareTo((Get-DotNetSortVersion $best.Version))
                if     ($c -gt 0) { $Item.Status = 'Update available' }
                elseif ($c -lt 0) { $Item.Status = 'Newer version installed' }
                else              { $Item.Status = 'Installed' }
            }
            else { $Item.Status = 'Not installed' }
        }
    }

    function Install-OfflinePackage {
        param($Item)
        if (-not $Item.Exe -or -not (Test-Path -LiteralPath $Item.Exe)) {
            Write-Log "$($Item.Name): installer not found in $($Item.Folder) (expected $($Item.ExpectedExe))." Error
            return 'Failed'
        }
        Test-InstallerHash $Item   # always re-check right before running
        if ($Item.HashOk -eq $false) {
            if ($Sync.SkipHashCheck) { Write-Log "$($Item.Name): SHA256 mismatch ignored because -SkipHashCheck was given." Warning }
            else { Write-Log "$($Item.Name): installer blocked because its SHA256 does not match the YAML manifest." Error; return 'Failed' }
        }
        $ilog = Join-Path $Sync.LogDir ('install_{0}_{1}_{2}.log' -f $Item.Key, $Item.Version, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $silent = $Item.Silent;    if (-not $silent) { $silent = '/quiet' }
        $custom = $Item.Custom;    if (-not $custom) { $custom = '/norestart' }
        $logSw  = $Item.LogSwitch; if (-not $logSw)  { $logSw  = '/log "<LOGPATH>"' }
        $argLine = '/install {0} {1} {2}' -f $silent, $custom, $logSw.Replace('<LOGPATH>', $ilog)
        Write-Log "Running: `"$($Item.Exe)`" $argLine"
        $p    = Start-Process -FilePath $Item.Exe -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
        $code = $p.ExitCode
        $res  = switch ($code) { 0 { 'Success' } 3010 { 'Reboot' } 1641 { 'Reboot' } 1638 { 'UpToDate' } default { 'Failed' } }
        $why  = $Item.ReturnCodes["$code"]; if ($why) { $why = " ($why)" }
        $sev  = 'Info'; if ($res -eq 'Failed') { $sev = 'Error' }
        Write-Log ('{0}: exit code {1}{2} -> {3}' -f $Item.Name, $code, $why, $res) $sev
        $res
    }

    function Get-FriendlyResult {
        param([string]$Result, [string]$Kind = 'Install')
        if ($Kind -eq 'Remove') {
            switch ($Result) {
                'Success'  { 'Uninstalled' }
                'UpToDate' { 'Already uninstalled' }
                'Reboot'   { 'Uninstalled (reboot required)' }
                default    { 'FAILED - see log' }
            }
        }
        else {
            switch ($Result) {
                'Success'  { 'Installed' }
                'UpToDate' { 'Already installed' }
                'Reboot'   { 'Installed (reboot required)' }
                default    { 'FAILED - see log' }
            }
        }
    }

    # ----- Installed versions of the target .NET major -----

    function Get-DotNetInventory {
        $typeNames = @{ Runtime = '.NET Runtime'; DesktopRuntime = '.NET Desktop Runtime'; AspNetCore = 'ASP.NET Core Runtime'
                        HostingBundle = 'ASP.NET Core Hosting Bundle'; SDK = '.NET SDK' }
        $major = $Sync.TargetMajor
        $rows  = New-Object System.Collections.Generic.List[object]
        $seen  = @{}

        # 1) Add/Remove Programs entries (visible bundles only; SystemComponent=1 MSIs are internal parts of a bundle)
        $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        foreach ($root in $roots) {
            foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                if ($seen.ContainsKey($k.PSChildName)) { continue }
                $e = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                $name = [string]$e.DisplayName
                if (-not $name -or $e.SystemComponent -eq 1) { continue }
                $type = $null
                if     ($name -match '^Microsoft \.NET (Core )?SDK ')                            { $type = 'SDK' }
                elseif ($name -match 'Windows Server Hosting|Hosting Bundle')                    { $type = 'HostingBundle' }
                elseif ($name -match '^Microsoft Windows Desktop Runtime')                       { $type = 'DesktopRuntime' }
                elseif ($name -match '^Microsoft ASP\.NET Core .*(Shared Framework|Runtime)')     { $type = 'AspNetCore' }
                elseif ($name -match '^Microsoft \.NET (Core )?Runtime')                         { $type = 'Runtime' }
                if (-not $type) { continue }
                if ($name -notmatch '(\d+\.\d+\.\d+(?:-[0-9A-Za-z\.\-]+)?)') { continue }
                $ver = $Matches[1]
                if ($ver.Split('.')[0] -ne $major) { continue }
                $arch = '-'; if ($name -match '\((x64|x86|arm64)\)') { $arch = $Matches[1] }
                $seen[$k.PSChildName] = $true
                $row = @{
                    Key = "reg:$($k.PSChildName)"; Source = 'Registry'; Type = $type; Name = $typeNames[$type]; DisplayName = $name
                    Version = $ver; Arch = $arch; Quiet = [string]$e.QuietUninstallString; Uninstall = [string]$e.UninstallString
                    Removable = $false; Action = ''
                }
                if     ($name -match 'from Visual Studio')        { $row.Action = 'Managed by Visual Studio' }
                elseif (-not ($row.Quiet -or $row.Uninstall))     { $row.Action = 'No uninstaller registered' }
                elseif ($ver -match '-')                          { $row.Removable = $true; $row.Action = 'Installed (preview build)' }
                else                                              { $row.Removable = $true; $row.Action = 'Installed' }
                $rows.Add($row)
            }
        }

        # 2) Files on disk with no matching uninstall entry (installed as part of Visual Studio or an SDK)
        $native = 'x64'; if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $native = 'arm64' }
        $pf = $env:ProgramW6432; if (-not $pf) { $pf = $env:ProgramFiles }
        $diskRoots = @(@{ Path = Join-Path $pf 'dotnet'; Arch = $native })
        if (${env:ProgramFiles(x86)}) { $diskRoots += @{ Path = Join-Path ${env:ProgramFiles(x86)} 'dotnet'; Arch = 'x86' } }
        $folders   = @{ 'Microsoft.NETCore.App' = 'Runtime'; 'Microsoft.WindowsDesktop.App' = 'DesktopRuntime'; 'Microsoft.AspNetCore.App' = 'AspNetCore' }
        # which uninstall-entry types put each kind of folder on disk
        $coveredBy = @{ Runtime = @('Runtime', 'DesktopRuntime', 'HostingBundle'); DesktopRuntime = @('DesktopRuntime')
                        AspNetCore = @('AspNetCore', 'HostingBundle'); SDK = @('SDK') }
        $disk = [ordered]@{}
        foreach ($dr in $diskRoots) {
            $found = @()
            foreach ($f in $folders.Keys) {
                foreach ($d in @(Get-ChildItem (Join-Path $dr.Path "shared\$f") -Directory -ErrorAction SilentlyContinue)) { $found += @{ Type = $folders[$f]; Version = $d.Name } }
            }
            foreach ($d in @(Get-ChildItem (Join-Path $dr.Path 'sdk') -Directory -ErrorAction SilentlyContinue)) { $found += @{ Type = 'SDK'; Version = $d.Name } }
            foreach ($x in $found) {
                if ($x.Version -notmatch '^\d+\.\d+\.\d+' -or $x.Version.Split('.')[0] -ne $major) { continue }
                $owners  = $coveredBy[$x.Type]
                $covered = @($rows | Where-Object { $_.Version -eq $x.Version -and $owners -contains $_.Type -and ($_.Arch -eq '-' -or $_.Arch -eq $dr.Arch) }).Count -gt 0
                if ($covered) { continue }
                $dk = "disk:$($x.Type):$($x.Version)"
                if (-not $disk.Contains($dk)) {
                    $disk[$dk] = @{
                        Key = $dk; Source = 'Disk'; Type = $x.Type; Name = $typeNames[$x.Type]; DisplayName = "$($typeNames[$x.Type]) $($x.Version)"
                        Version = $x.Version; Arch = $dr.Arch; Quiet = ''; Uninstall = ''
                        Removable = $false; Action = 'No uninstaller (part of VS or an SDK)'
                    }
                }
                elseif ($disk[$dk].Arch -notmatch [regex]::Escape($dr.Arch)) { $disk[$dk].Arch += ", $($dr.Arch)" }
            }
        }
        foreach ($d in $disk.Values) { $rows.Add($d) }

        # Sort: product, then newest version first, then architecture
        $order  = @{ Runtime = 0; DesktopRuntime = 1; AspNetCore = 2; HostingBundle = 3; SDK = 4 }
        $sorted = @($rows | Sort-Object @{ e = { $order[$_.Type] } },
                                        @{ e = { Get-DotNetSortVersion $_.Version }; Descending = $true },
                                        @{ e = { $_.Arch } })
        $inv = [ordered]@{}
        foreach ($r in $sorted) { $inv[$r.Key] = $r }
        $inv
    }

    function Uninstall-DotNetEntry {
        param($Entry)
        $safe  = ('{0}_{1}_{2}' -f $Entry.Type, $Entry.Version, $Entry.Arch) -replace '[^\w\.\-]', '_'
        $ulog  = Join-Path $Sync.LogDir ('uninstall_{0}_{1}.log' -f $safe, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $exe   = $null; $argLine = ''
        if ($Entry.Uninstall -match '(?i)msiexec(\.exe)?\s.*?(\{[0-9A-F\-]{36}\})') {
            $exe = Join-Path $env:windir 'System32\msiexec.exe'
            $argLine = '/x {0} /qn /norestart /l*v "{1}"' -f $Matches[2], $ulog
        }
        else {
            $cmd = $Entry.Quiet; if (-not $cmd) { $cmd = $Entry.Uninstall }
            if ($cmd -match '^\s*"([^"]+)"\s*(.*)$' -or $cmd -match '^\s*(\S+)\s*(.*)$') { $exe = $Matches[1]; $argLine = $Matches[2].Trim() }
            if ($exe) {
                if ($argLine -notmatch '(?i)/uninstall')               { $argLine += ' /uninstall' }
                if ($argLine -notmatch '(?i)/(quiet|silent|passive)')  { $argLine += ' /quiet' }
                $argLine += (' /norestart /log "{0}"' -f $ulog)
            }
        }
        if (-not $exe) { Write-Log "$($Entry.DisplayName): no usable uninstall command." Error; return 'Failed' }
        if (-not (Test-Path -LiteralPath $exe)) { Write-Log "$($Entry.DisplayName): uninstaller not found (package cache missing?): $exe" Error; return 'Failed' }
        Write-Log "Running: `"$exe`" $argLine"
        $p = Start-Process -FilePath $exe -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
        $code = $p.ExitCode
        $res = switch ($code) { 0 { 'Success' } 3010 { 'Reboot' } 1641 { 'Reboot' } 1605 { 'UpToDate' } 1614 { 'UpToDate' } default { 'Failed' } }
        $sev = 'Info'; if ($res -eq 'Failed') { $sev = 'Error' }
        Write-Log ('{0}: exit code {1} (0x{1:X8}) -> {2}' -f $Entry.DisplayName, $code, $res) $sev
        $res
    }
}
. $CoreScript
#endregion

#region ---------------- Helpers (main thread only) ----------------
function Initialize-Log {
    $candidates = @("$env:windir\CCM\Logs", "$env:ProgramData\DotNetOfflineInstaller\Logs", $env:TEMP)
    if (-not (Test-Path "$env:windir\CCM\Logs")) { $candidates = $candidates[1..2] }
    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
            $file = Join-Path $dir $LogFileName
            [IO.File]::AppendAllText($file, '')   # write test
            $Sync.LogDir = $dir; $Sync.LogFile = $file
            return
        }
        catch { }
    }
}

function Get-OverallExitCode {
    param($Results)
    $vals = @($Results.Values)
    if ($vals -contains 'Failed') { return 1603 }
    if ($vals -contains 'Reboot') { return 3010 }
    0
}

function Set-Marker {
    param([int]$ExitCode, $Results)
    if ($ExitCode -ne 0 -and $ExitCode -ne 3010) { return }
    try {
        if (-not (Test-Path $MarkerKey)) { New-Item -Path $MarkerKey -Force | Out-Null }
        Set-ItemProperty -Path $MarkerKey -Name 'LastRunUtc'   -Value ((Get-Date).ToUniversalTime().ToString('o'))
        Set-ItemProperty -Path $MarkerKey -Name 'LastExitCode' -Value $ExitCode -Type DWord
        Set-ItemProperty -Path $MarkerKey -Name 'LastPackages' -Value (($Results.GetEnumerator() | ForEach-Object { "$($Sync.Labels[$_.Key])=$($_.Value)" }) -join ';')
    }
    catch { Write-Log "Could not write marker key ${MarkerKey}: $_" Warning }
}

function Start-Worker {
    param([scriptblock]$Work)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $Sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($CoreScript.ToString() + "`r`n" + $Work.ToString())
    [void]$ps.BeginInvoke()
}

function Split-PackageNames {
    # "-File" mode passes "Runtime,SDK" as a single string: split on commas / spaces / semicolons and validate.
    param([string[]]$Names)
    $valid = @($Sync.Products.Keys) + 'All'
    $out = @()
    foreach ($n in @($Names -split '[,;\s]+' | Where-Object { $_ })) {
        $match = @($valid | Where-Object { $_ -eq $n })[0]   # case-insensitive
        if (-not $match) { throw "Unknown package name '$n'. Valid names: $($valid -join ', ')" }
        $out += $match
    }
    $out
}

function Resolve-PackageNames {
    param([string[]]$Names)
    if ($Names -contains 'All') { return @($Sync.Products.Keys) }
    @($Sync.Products.Keys | Where-Object { $Names -contains $_ })   # keep catalog order
}

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
Initialize-Log
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$runAs    = $identity.Name; if ($identity.IsSystem) { $runAs = 'SYSTEM' }
$headless = [bool]($Install -or $Uninstall)
if ($headless) {
    $Sync.Console = $true
    try { $Install = Split-PackageNames $Install; $Uninstall = Split-PackageNames $Uninstall }
    catch { Write-Log "$_" Error; exit 1 }
}
Write-Log ('===== Start (.NET {0} offline): running as {1} (admin={2}), PS {3}, {4}-bit =====' -f $TargetMajor, $runAs, $isAdmin, $PSVersionTable.PSVersion, ([IntPtr]::Size * 8))
Write-Log "Source folder: $SourcePath"
if ($SkipHashCheck) { Write-Log '-SkipHashCheck given: installers with a SHA256 mismatch will still run.' Warning }
if (-not $isAdmin) { Write-Log 'Not running elevated: each install/uninstall will prompt for UAC.' Warning }

$Sync.Items = Get-PackageCatalog
foreach ($i in $Sync.Items.Values) {
    $exeName = '(missing)'; if ($i.Exe) { $exeName = Split-Path $i.Exe -Leaf }
    Write-Log ('Package {0} {1} [{2}]: {3}' -f $i.Key, $i.Version, $i.Arch, $exeName)
}
#endregion

#region ---------------- Headless mode ----------------
if ($headless) {
    $results = [ordered]@{}
    if ($Uninstall) {
        $types = Resolve-PackageNames $Uninstall
        $inv   = Get-DotNetInventory
        foreach ($t in $types) {
            $all     = @($inv.Values | Where-Object { $_.Type -eq $t })
            $targets = @($all | Where-Object { $_.Removable })
            foreach ($e in @($all | Where-Object { -not $_.Removable })) { Write-Log ('Skipping {0} [{1}]: {2}' -f $e.DisplayName, $e.Arch, $e.Action) Warning }
            if ($targets.Count -eq 0) { Write-Log "Uninstall ${t}: no standalone .NET $TargetMajor $t installation found." }
            foreach ($e in $targets) {
                $k = "remove:$($e.Key)"; $Sync.Labels[$k] = "Uninstall $($e.DisplayName)"
                Write-Log "----- Uninstall $($e.DisplayName) -----"
                try { $results[$k] = Uninstall-DotNetEntry -Entry $e } catch { Write-Log "$($e.DisplayName): $_" Error; $results[$k] = 'Failed' }
            }
        }
    }
    if ($Install) {
        foreach ($t in (Resolve-PackageNames $Install)) {
            $k = "install:$t"; $Sync.Labels[$k] = "Install $t"
            $item = $Sync.Items[$t]
            if (-not $item) { Write-Log "Install ${t}: no source folder / manifest found in $SourcePath." Error; $results[$k] = 'Failed'; continue }
            $Sync.Labels[$k] = "Install $($item.Name) $($item.Version)"
            Write-Log "----- Install $($item.Name) $($item.Version) -----"
            try { $results[$k] = Install-OfflinePackage -Item $item } catch { Write-Log "${t}: $_" Error; $results[$k] = 'Failed' }
        }
    }
    $code = Get-OverallExitCode $results
    Set-Marker -ExitCode $code -Results $results
    Write-Log "===== Finished: exit code $code ====="
    exit $code
}
#endregion

#region ---------------- GUI ----------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$C = @{}; foreach ($k in $Theme.Keys) { $C[$k] = [System.Drawing.ColorTranslator]::FromHtml($Theme[$k]) }
$Title = ".NET $TargetMajor Offline Installer"

if ($Sync.Items.Count -eq 0) {
    $msg = "No .NET $TargetMajor installer folders were found in:`r`n$SourcePath`r`n`r`nExpected subfolders such as Microsoft.DotNet.Runtime.$($TargetMajor)_<version> containing a .yaml manifest and the .exe installer."
    Write-Log $msg Error
    [void][System.Windows.Forms.MessageBox]::Show("$msg`r`n`r`nLog: $($Sync.LogFile)", $Title, 'OK', 'Error')
    exit 1
}

$script:AllResults = [ordered]@{}

$form = New-Object System.Windows.Forms.Form
$form.Text          = "$Title  -  running as $runAs"
$form.Size          = New-Object System.Drawing.Size(960, 760)
$form.MinimumSize   = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor     = $C.Body
$form.ForeColor     = $C.PaneText

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock        = 'Fill'
$layout.Padding     = New-Object System.Windows.Forms.Padding(14, 12, 14, 12)
$layout.ColumnCount = 1
$layout.RowCount    = 5
$layout.BackColor   = $C.Body
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))      # 0 header
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 64)))   # 1 package list
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))      # 2 buttons
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))      # 3 progress
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 36)))   # 4 log
$form.Controls.Add($layout)

# --- header ---
$hdr = New-Object System.Windows.Forms.TableLayoutPanel
$hdr.AutoSize = $true; $hdr.Dock = 'Fill'; $hdr.ColumnCount = 1; $hdr.RowCount = 2
$hdr.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$hdrTitle = New-Object System.Windows.Forms.Label
$hdrTitle.AutoSize = $true; $hdrTitle.Text = ".NET $TargetMajor"
$hdrTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$hdrTitle.ForeColor = $C.Header
$hdrText = New-Object System.Windows.Forms.Label
$hdrText.AutoSize = $true; $hdrText.ForeColor = $C.SubText
$hdrText.MaximumSize = New-Object System.Drawing.Size(900, 0)
$hdrText.Text = "Check a package to install it from the local installer files, or check an installed version to uninstall it.`r`n" +
                "Installer source: $SourcePath"
$hdr.Controls.Add($hdrTitle, 0, 0); $hdr.Controls.Add($hdrText, 0, 1)
$layout.Controls.Add($hdr, 0, 0)

# --- single package list ---
$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
$lv.HideSelection = $true; $lv.MultiSelect = $false; $lv.Dock = 'Fill'
$lv.BackColor = $C.Pane; $lv.ForeColor = $C.PaneText; $lv.BorderStyle = 'FixedSingle'
$lv.ShowItemToolTips = $true
[void]$lv.Columns.Add('Package', 250)
[void]$lv.Columns.Add('Installer version', 120)
[void]$lv.Columns.Add('Installed', 120)
[void]$lv.Columns.Add('Arch', 80)
[void]$lv.Columns.Add('Status', 300)
$grpInstall   = New-Object System.Windows.Forms.ListViewGroup('install',   "Install .NET $TargetMajor  -  from local installer files")
$grpInstalled = New-Object System.Windows.Forms.ListViewGroup('installed', "Installed .NET $TargetMajor on this device  -  check to uninstall")
[void]$lv.Groups.Add($grpInstall); [void]$lv.Groups.Add($grpInstalled)

function Set-SubColors($li, [System.Drawing.Color]$Color) {
    foreach ($s in $li.SubItems) { $s.ForeColor = $Color; $s.BackColor = $C.Pane }
}

$script:InventoryLoaded = $false
$layout.Controls.Add($lv, 0, 1)

# --- buttons ---
function New-ThemedButton([string]$Text, [int]$Width, [System.Drawing.Color]$Back, [System.Drawing.Color]$Hover) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Size = New-Object System.Drawing.Size($Width, 34)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $Hover; $b.FlatAppearance.MouseDownBackColor = $Hover
    $b.BackColor = $Back; $b.ForeColor = $C.ButtonText; $b.Tag = $Back
    $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $b.UseVisualStyleBackColor = $false
    $b.Add_EnabledChanged({ if ($this.Enabled) { $this.BackColor = $this.Tag } else { $this.BackColor = $C.Disabled } })
    $b
}

$btnRow = New-Object System.Windows.Forms.FlowLayoutPanel
$btnRow.Dock = 'Fill'; $btnRow.AutoSize = $true; $btnRow.FlowDirection = 'RightToLeft'; $btnRow.WrapContents = $false
$btnRow.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 8)
$btnClose     = New-ThemedButton 'Close'           100 $C.Neutral $C.NeutralHover
$btnInstall   = New-ThemedButton 'Install'         120 $C.Button  $C.ButtonHover
$btnUninstall = New-ThemedButton 'Uninstall'       120 $C.Danger  $C.DangerHover
$btnClear     = New-ThemedButton 'Clear selection' 130 $C.Neutral $C.NeutralHover
$lblStatus    = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $true; $lblStatus.ForeColor = $C.SubText
$lblStatus.Margin = New-Object System.Windows.Forms.Padding(0, 9, 16, 0)
$lblStatus.Text = 'Verifying installers and reading installed versions...'
$btnInstall.Enabled = $false
$btnUninstall.Visible = $false
$btnRow.Controls.AddRange(@($btnClose, $btnInstall, $btnUninstall, $btnClear, $lblStatus))
$layout.Controls.Add($btnRow, 0, 2)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Fill'; $progress.Height = 16; $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30
$progress.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$layout.Controls.Add($progress, 0, 3)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock = 'Fill'; $logBox.ReadOnly = $true; $logBox.BorderStyle = 'FixedSingle'
$logBox.BackColor = $C.LogBack; $logBox.ForeColor = $C.LogText
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9); $logBox.WordWrap = $false
$layout.Controls.Add($logBox, 0, 4)

function Get-CheckedIds  { @($lv.CheckedItems | Where-Object { $_.Group -eq $grpInstall }   | ForEach-Object { $_.Name }) }
function Get-CheckedKeys { @($lv.CheckedItems | Where-Object { $_.Group -eq $grpInstalled } | ForEach-Object { $_.Name }) }

function Update-Buttons {
    $nInstall = (Get-CheckedIds).Count
    $nRemove  = (Get-CheckedKeys).Count
    $btnInstall.Enabled   = (-not $Sync.Busy) -and ($nInstall -gt 0)
    $btnUninstall.Visible = ($nRemove -gt 0)
    $btnUninstall.Enabled = (-not $Sync.Busy) -and ($nRemove -gt 0)
    $btnClear.Enabled     = (-not $Sync.Busy)
}

function Get-StatusColor([string]$Status) {
    # first matching pattern wins (switch -Wildcard would otherwise return every match)
    @(switch -Wildcard ($Status) {
        'Installed (this*'        { $C.Ok }
        'Installed (preview*'     { $C.Warn }
        'Installed*'              { $C.Ok }
        'Already*'                { $C.Ok }
        'Uninstalled*'            { $C.Ok }
        'Newer version installed' { $C.Ok }
        'Update available'        { $C.Warn }
        'FAILED*'                 { $C.Bad }
        'Hash mismatch*'          { $C.Bad }
        'Installer .exe missing'  { $C.Bad }
        'Installing*'             { $C.Busy }
        'Uninstalling*'           { $C.Busy }
        'Verifying*'              { $C.Busy }
        default                   { $C.PaneText }
    })[0]
}

function Set-PackageRowStyle {
    param($li, $item)
    Set-SubColors $li $C.PaneText
    $li.SubItems[4].ForeColor = Get-StatusColor $li.SubItems[4].Text
    if ($item -and -not $item.Installable -and $item.Status -ne 'Checking...') { foreach ($i in 0, 1, 2, 3) { $li.SubItems[$i].ForeColor = $C.Muted } }
}

function Set-ItemRow {
    param($Msg)
    $li = $lv.Items[$Msg.Id]
    if (-not $li) { return }
    if ($Msg.ContainsKey('Installed')) { $v = $Msg.Installed; if (-not $v) { $v = '-' }; $li.SubItems[2].Text = $v }
    if ($Msg.ContainsKey('Status'))    { $li.SubItems[4].Text = $Msg.Status }
    if ($Msg.ContainsKey('Exe') -and $Msg.Exe) { $li.ToolTipText = $Msg.Exe }
    Set-PackageRowStyle $li $Sync.Items[$Msg.Id]
}

function Set-InstalledRowStatus {
    param($Msg)
    $li = $lv.Items[$Msg.Key]
    if (-not $li) { return }
    $li.SubItems[4].Text = $Msg.Status
    $li.SubItems[4].ForeColor = Get-StatusColor $Msg.Status
}

function Update-ListRows {
    # Rebuilds the whole list in one update. Removing only some rows from a grouped ListView
    # can leave the other group unpainted, so both groups are recreated every time.
    $checked = @(Get-CheckedIds)
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        foreach ($item in $Sync.Items.Values) {
            $li = New-Object System.Windows.Forms.ListViewItem($item.Name)
            $li.Name = $item.Key; $li.Group = $grpInstall
            $li.ToolTipText = $(if ($item.Exe) { $item.Exe } else { "Missing: $(Join-Path $item.Folder $item.ExpectedExe)" })
            $li.UseItemStyleForSubItems = $false
            $inst = '...'; if ($item.Status -ne 'Checking...') { $inst = $item.Installed; if (-not $inst) { $inst = '-' } }
            [void]$li.SubItems.Add($item.Version); [void]$li.SubItems.Add($inst); [void]$li.SubItems.Add($item.Arch); [void]$li.SubItems.Add($item.Status)
            Set-PackageRowStyle $li $item
            [void]$lv.Items.Add($li)
            if ($checked -contains $item.Key) { $li.Checked = $true }
        }
        if (-not $script:InventoryLoaded) {
            $li = New-Object System.Windows.Forms.ListViewItem('Scanning...')
            $li.Name = 'placeholder'; $li.Group = $grpInstalled; $li.UseItemStyleForSubItems = $false
            Set-SubColors $li $C.Muted
            [void]$lv.Items.Add($li)
            return
        }
        foreach ($e in $Sync.Inventory.Values) {
            $li = New-Object System.Windows.Forms.ListViewItem($e.Name)
            $li.Name = $e.Key; $li.Group = $grpInstalled; $li.ToolTipText = $e.DisplayName
            $li.UseItemStyleForSubItems = $false
            [void]$li.SubItems.Add('')
            [void]$li.SubItems.Add($e.Version)
            [void]$li.SubItems.Add($e.Arch)
            [void]$li.SubItems.Add($e.Action)
            if ($e.Removable) { Set-SubColors $li $C.PaneText; $li.SubItems[4].ForeColor = Get-StatusColor $e.Action }
            else              { Set-SubColors $li $C.Muted }
            [void]$lv.Items.Add($li)
        }
        if ($Sync.Inventory.Count -eq 0) {
            $li = New-Object System.Windows.Forms.ListViewItem("No .NET $TargetMajor runtimes or SDKs are installed.")
            $li.Name = 'placeholder'; $li.Group = $grpInstalled; $li.UseItemStyleForSubItems = $false
            Set-SubColors $li $C.Muted
            [void]$lv.Items.Add($li)
        }
    }
    finally { $lv.EndUpdate() }
}

$LoadWorker = {
    try {
        Write-Log "Scanning installed .NET $($Sync.TargetMajor) versions (Add/Remove Programs + dotnet folders)..."
        $Sync.Inventory = Get-DotNetInventory
        Write-Log ('Found {0} installed .NET {1} entries, {2} can be uninstalled.' -f $Sync.Inventory.Count, $Sync.TargetMajor, @($Sync.Inventory.Values | Where-Object { $_.Removable }).Count)
        $Sync.Queue.Enqueue(@{ Type = 'Inventory' })
        foreach ($item in $Sync.Items.Values) {
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $item.Key; Status = 'Verifying installer...' })
            if ($item.Exe -or $item.Candidates.Count) { Test-InstallerHash $item }
            Update-PackageStatus $item $Sync.Inventory
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $item.Key; Installed = $item.Installed; Status = $item.Status; Exe = $item.Exe })
        }
        Write-Log 'Ready.'
    }
    catch { Write-Log "Error while reading package information: $_" Error }
    finally { $Sync.Queue.Enqueue(@{ Type = 'LoadDone' }) }
}

$WorkWorker = {
    $results = [ordered]@{}
    try {
        $ids   = @($Sync.Selected.Install)
        $keys  = @($Sync.Selected.Remove)
        $total = $ids.Count + $keys.Count
        $n = 0
        foreach ($id in $ids) {
            $item = $Sync.Items[$id]
            $Sync.Queue.Enqueue(@{ Type = 'Progress'; Value = [int](100 * $n / $total); Text = ('{0} of {1}: installing {2}' -f ($n + 1), $total, $item.Name) })
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $id; Status = 'Installing...' })
            Write-Log "----- [$($n + 1)/$total] Install $($item.Name) $($item.Version) -----"
            try { $res = Install-OfflinePackage -Item $item } catch { Write-Log "${id}: $_" Error; $res = 'Failed' }
            $results["install:$id"] = $res
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $id; Status = (Get-FriendlyResult $res 'Install') })
            $n++
        }
        foreach ($key in $keys) {
            $e = $Sync.Inventory[$key]
            $Sync.Queue.Enqueue(@{ Type = 'Progress'; Value = [int](100 * $n / $total); Text = ('{0} of {1}: uninstalling {2} {3}' -f ($n + 1), $total, $e.Name, $e.Version) })
            $Sync.Queue.Enqueue(@{ Type = 'InstalledRow'; Key = $key; Status = 'Uninstalling...' })
            Write-Log "----- [$($n + 1)/$total] Uninstall $($e.DisplayName) -----"
            try { $res = Uninstall-DotNetEntry -Entry $e } catch { Write-Log "$($e.DisplayName): $_" Error; $res = 'Failed' }
            $results["remove:$key"] = $res
            $Sync.Queue.Enqueue(@{ Type = 'InstalledRow'; Key = $key; Status = (Get-FriendlyResult $res 'Remove') })
            $n++
        }
        $Sync.Queue.Enqueue(@{ Type = 'Progress'; Value = 100; Text = 'Refreshing installed versions...' })
        Write-Log 'Refreshing installed versions...'
        $Sync.Inventory = Get-DotNetInventory
        foreach ($item in $Sync.Items.Values) { Update-PackageStatus $item $Sync.Inventory }
        $Sync.Queue.Enqueue(@{ Type = 'Inventory' })
    }
    catch { Write-Log "Unexpected error: $_" Error }
    finally {
        $Sync.Results = $results
        $Sync.Queue.Enqueue(@{ Type = 'WorkDone' })
    }
}

function Start-Batch {
    param([string[]]$Ids, [string[]]$Keys)
    $Ids = @($Ids | Where-Object { $_ }); $Keys = @($Keys | Where-Object { $_ })
    if ($Ids.Count + $Keys.Count -eq 0) { return }
    if ($Ids.Count) {
        $text = "Install the following packages?`r`n`r`n" + (($Ids | ForEach-Object { '  + {0} {1}' -f $Sync.Items[$_].Name, $Sync.Items[$_].Version }) -join "`r`n")
    }
    else {
        $text = "Uninstall the following?`r`n`r`n" + (($Keys | ForEach-Object { $e = $Sync.Inventory[$_]; '  - {0} {1} ({2})' -f $e.Name, $e.Version, $e.Arch }) -join "`r`n") +
                "`r`n`r`nApplications that use these versions will stop working until another compatible version is installed."
    }
    $answer = [System.Windows.Forms.MessageBox]::Show($text, $Title, 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    foreach ($id in $Ids) { $Sync.Labels["install:$id"] = '{0} {1}' -f $Sync.Items[$id].Name, $Sync.Items[$id].Version }
    foreach ($k in $Keys) { $e = $Sync.Inventory[$k]; $Sync.Labels["remove:$k"] = 'Uninstall {0} {1} ({2})' -f $e.Name, $e.Version, $e.Arch }
    $Sync.Selected = @{ Install = $Ids; Remove = $Keys }
    $Sync.Busy     = $true
    Update-Buttons
    $btnClose.Enabled = $false
    $progress.Style   = 'Continuous'
    $progress.Value   = 0
    if ($Ids.Count) { Write-Log "Selected for install: $($Ids -join ', ')" }
    else            { Write-Log "Selected for uninstall: $((($Keys | ForEach-Object { $Sync.Inventory[$_].DisplayName }) -join ', '))" }
    Start-Worker $WorkWorker
}

$lv.Add_ItemCheck({
    param($s, $e)
    $li = $lv.Items[$e.Index]
    $block = $Sync.Busy -or $li.Name -eq 'placeholder'
    if (-not $block) {
        if ($li.Group -eq $grpInstalled) { $entry = $Sync.Inventory[$li.Name]; $block = (-not $entry) -or (-not $entry.Removable) }
        else                             { $item  = $Sync.Items[$li.Name];     $block = (-not $item)  -or (-not $item.Installable) }
    }
    if ($block) { $e.NewValue = $e.CurrentValue }
})
$lv.Add_ItemChecked({ Update-Buttons })

$btnClear.Add_Click({ foreach ($li in @($lv.CheckedItems)) { $li.Checked = $false } })
$btnInstall.Add_Click({ Start-Batch -Ids (Get-CheckedIds) -Keys @() })
$btnUninstall.Add_Click({ Start-Batch -Ids @() -Keys (Get-CheckedKeys) })
$btnClose.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    param($s, $e)
    if ($Sync.Busy -and $Sync.Selected -and -not $btnClose.Enabled) {
        [void][System.Windows.Forms.MessageBox]::Show('Please wait until the current operation finishes.', $Title, 'OK', 'Information')
        $e.Cancel = $true
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    $msg = $null
    while ($Sync.Queue.TryDequeue([ref]$msg)) {
        switch ($msg.Type) {
            'Log' {
                $logBox.SelectionStart  = $logBox.TextLength
                $logBox.SelectionLength = 0
                $logBox.SelectionColor  = @{ Info = $C.LogText; Warning = $C.Warn; Error = $C.Bad }[$msg.Severity]
                $logBox.AppendText($msg.Text + "`r`n")
                $logBox.ScrollToCaret()
            }
            'Item'         { Set-ItemRow $msg }
            'InstalledRow' { Set-InstalledRowStatus $msg }
            'Inventory'    { $script:InventoryLoaded = $true; Update-ListRows; Update-Buttons }
            'Progress'     { $progress.Value = [Math]::Min(100, $msg.Value); $lblStatus.Text = $msg.Text }
            'LoadDone' {
                $Sync.Busy = $false
                $progress.Style = 'Continuous'; $progress.Value = 0
                $lblStatus.Text = 'Ready.'
                Update-Buttons
            }
            'WorkDone' {
                foreach ($k in $Sync.Results.Keys) { $script:AllResults[$k] = $Sync.Results[$k] }
                $Sync.Selected = $null
                $Sync.Busy = $false
                foreach ($li in @($lv.CheckedItems)) { $li.Checked = $false }
                Update-ListRows
                $btnClose.Enabled = $true
                Update-Buttons
                $code = Get-OverallExitCode $Sync.Results
                $summary = ($Sync.Results.GetEnumerator() | ForEach-Object {
                    $kind = if ($_.Key -like 'remove:*') { 'Remove' } else { 'Install' }
                    '  {0}: {1}' -f $Sync.Labels[$_.Key], (Get-FriendlyResult $_.Value $kind) }) -join "`r`n"
                Write-Log "Batch finished (exit code $code)."
                $lblStatus.Text = 'Finished.'
                $icon = 'Information'; $extra = ''
                if ($code -eq 1603) { $icon = 'Error'; $extra = "`r`n`r`nLog: $($Sync.LogFile)" }
                if ($code -eq 3010) { $icon = 'Warning'; $extra = "`r`n`r`nA restart is required to complete the operation." }
                [void][System.Windows.Forms.MessageBox]::Show("Finished.`r`n`r`n$summary$extra", $Title, 'OK', $icon)
            }
        }
    }
})

$form.Add_Shown({
    $form.TopMost = $true; $form.Activate(); $form.TopMost = $false   # come to front when launched by SCCM
    Update-ListRows
    $timer.Start()
    $Sync.Busy = $true
    Update-Buttons
    Start-Worker $LoadWorker
})

[void]$form.ShowDialog()
$timer.Stop()

$exitCode = Get-OverallExitCode $script:AllResults
if ($script:AllResults.Count -eq 0) { Write-Log 'Closed without changing anything.' }
Set-Marker -ExitCode $exitCode -Results $script:AllResults
Write-Log "===== Finished: exit code $exitCode ====="
exit $exitCode
#endregion
