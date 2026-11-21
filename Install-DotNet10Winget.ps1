<#
.SYNOPSIS
    GUI that installs, upgrades and uninstalls .NET 10 packages using winget.

.DESCRIPTION
    A single list shows two groups:

    INSTALL - The .NET 10 packages available from the winget repository: .NET Runtime, Desktop Runtime,
    ASP.NET Core Runtime, Hosting Bundle and SDK. Each row shows the latest version in winget and the installed
    version. Checked packages are installed one at a time, silently, when "Install" is clicked:

        winget install --id <Id> --exact --source winget --silent
               --accept-package-agreements --accept-source-agreements --disable-interactivity

    "winget install" on a package that is already installed upgrades it to the latest version.

    INSTALLED - The .NET 10 runtimes, Hosting Bundles and SDKs already on the device, found through the
    Add/Remove Programs registry keys and the dotnet folders on disk. When an installed entry is checked, an
    "Uninstall" button appears. It runs the product's registered quiet uninstaller (/uninstall /quiet /norestart).
    SDKs installed by Visual Studio, and runtimes with no standalone uninstaller (installed as part of
    Visual Studio or an SDK), are listed for information only and cannot be checked.

    No other .NET major version can be installed by this script, and other versions are not listed.

    The script is built to run as SYSTEM from a ConfigMgr (SCCM) application with
    "Allow users to view and interact with the program installation" enabled.

    Exit codes:  0 = success / nothing to do,  3010 = success, reboot required,
                 1603 = one or more operations failed,  1 = winget not usable / invalid parameters.

.PARAMETER PackageId
    Optional. Skip the GUI and install the given winget IDs, e.g. -PackageId Microsoft.DotNet.Runtime.10
    Only .NET 10 IDs are accepted.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install-DotNet10Winget.ps1

.EXAMPLE
    .\Install-DotNet10Winget.ps1 -PackageId Microsoft.DotNet.Runtime.10,Microsoft.DotNet.DesktopRuntime.10
#>
[CmdletBinding()]
param(
    [string[]]$PackageId
)

$ErrorActionPreference = 'Stop'

# "powershell.exe -File" passes "-PackageId A,B" as one string: split on commas / semicolons / spaces.
$PackageId = @($PackageId -split '[,;\s]+' | Where-Object { $_ })

#region ---------------- Configuration ----------------
$TargetMajor = '10'                                  # the only .NET major version this script installs and lists
$Products    = [ordered]@{                           # winget ID segment = display name
    'Runtime'        = '.NET Runtime'
    'DesktopRuntime' = '.NET Desktop Runtime'
    'AspNetCore'     = 'ASP.NET Core Runtime'
    'HostingBundle'  = 'ASP.NET Core Hosting Bundle'
    'SDK'            = '.NET SDK'
}
$LogFileName = "DotNet$($TargetMajor)WingetInstaller.log"
$MarkerKey   = "HKLM:\SOFTWARE\DotNetWingetInstaller\NET$TargetMajor"   # written on success; used by the Detect script

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
$Sync = [hashtable]::Synchronized(@{
    Queue       = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    LogLock     = New-Object object
    LogDir      = $null
    LogFile     = $null
    Winget      = $null
    Console     = $false
    Busy        = $false
    TargetMajor = $TargetMajor
    Items       = [ordered]@{}     # install rows:   Id  -> @{ Id; Name; Latest; Installed; Status }
    Inventory   = [ordered]@{}     # installed rows: Key -> @{ Key; Type; Name; Version; Arch; Removable; Action; ... }
    Selected    = $null            # @{ Install = @(ids); Remove = @(keys) }
    Results     = [ordered]@{}
    Labels      = @{}
})

foreach ($p in $Products.Keys) {
    $id = "Microsoft.DotNet.$p.$TargetMajor"
    $Sync.Items[$id] = @{ Id = $id; Name = "$($Products[$p]) $TargetMajor"; Latest = $null; Installed = $null; Status = $null }
}
#endregion

#region ---------------- Core functions (used by GUI thread and background runspaces) ----------------
$CoreScript = {
    function Write-Log {
        param([string]$Message, [ValidateSet('Info', 'Warning', 'Error')][string]$Severity = 'Info')
        $now  = Get-Date
        $type = @{ Info = 1; Warning = 2; Error = 3 }[$Severity]
        # CMTrace format
        $line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="DotNet{6}Winget" context="{3}" type="{4}" thread="{5}" file="">' -f `
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

    function Invoke-Winget {
        param([string[]]$Arguments, [switch]$Stream)
        $ErrorActionPreference = 'Continue'   # PS 5.1: 2>&1 on native stderr must not throw
        $out = New-Object System.Collections.Generic.List[string]
        $BlockChars = "[{0}-{1}]" -f [char]0x2580, [char]0x259F   # progress-bar glyphs
        & $Sync.Winget @Arguments 2>&1 | ForEach-Object {
            $parts = @("$_" -split "`r" | Where-Object { $_.Trim() })   # spinner overwrites use bare CR
            $l = ''; if ($parts.Count -gt 0) { $l = $parts[-1].TrimEnd() }
            # drop spinner / progress-bar noise
            if ($l -match '^[\s\-\\|/]*$' -or $l -match $BlockChars -or $l -match '^\s*[\d\.]+\s*(B|KB|MB|GB)\s*/\s*[\d\.]+') { return }
            $out.Add($l)
            if ($Stream) { Write-Log "    $l" }
        }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }

    function Get-WingetResult {
        param([int]$Code)
        switch ($Code) {
            0           { 'Success' }
            -1978335189 { 'UpToDate' }   # 0x8A15002B  No applicable upgrade (already latest)
            -1978335135 { 'UpToDate' }   # 0x8A150061  Package already installed
            -1978334963 { 'UpToDate' }   # 0x8A15010D  Installer: already installed
            -1978334967 { 'Reboot' }     # 0x8A150109  Reboot required to finish
            -1978334966 { 'Reboot' }     # 0x8A15010A  Reboot required for install
            3010        { 'Reboot' }
            1641        { 'Reboot' }
            default     { 'Failed' }
        }
    }

    function Get-InstalledPackages {
        # winget export gives clean JSON (no console-width truncation like 'winget list')
        $file = Join-Path ([IO.Path]::GetTempPath()) ('dotnet-winget-export-{0}.json' -f [guid]::NewGuid())
        $map  = @{}
        $r = Invoke-Winget -Arguments @('export', '-o', $file, '--include-versions', '--source', 'winget',
                                        '--accept-source-agreements', '--disable-interactivity')
        if (Test-Path $file) {
            try {
                $json = Get-Content $file -Raw | ConvertFrom-Json
                foreach ($src in $json.Sources) { foreach ($p in $src.Packages) { $map[$p.PackageIdentifier] = $p.Version } }
            }
            catch { Write-Log "Could not parse winget export: $_" Warning }
            finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
        }
        else {
            Write-Log ('winget export failed (exit {0}, 0x{0:X8}): {1}' -f $r.ExitCode, ($r.Output -join ' ')) Warning
        }
        $map
    }

    function Get-LatestVersion {
        param([string]$Id)
        $r = Invoke-Winget -Arguments @('show', '--id', $Id, '--exact', '--source', 'winget',
                                        '--accept-source-agreements', '--disable-interactivity')
        if ($r.ExitCode -ne 0) {
            Write-Log ('winget show {0} failed (exit {1}, 0x{1:X8})' -f $Id, $r.ExitCode) Warning
            return $null
        }
        foreach ($l in $r.Output) { if ($l -match '^\s*Version:\s*(\S+)') { return $Matches[1] } }
        foreach ($l in $r.Output) { if ($l -match '^[^:]+:\s*(\d+\.\d+\.\d+(\.\d+)?)\s*$') { return $Matches[1] } }  # non-English fallback
        'Unknown'
    }

    function Test-UpToDate {
        param($Installed, $Latest)
        if (-not $Installed -or -not $Latest -or $Latest -eq 'Unknown') { return $false }
        try { return ([version]$Installed -ge [version]$Latest) } catch { return ($Installed -eq $Latest) }
    }

    function Get-ItemStatus {
        param($Item)
        if (-not $Item.Latest)                            { return 'Not found in winget' }
        if (-not $Item.Installed)                         { return 'Not installed' }
        if (Test-UpToDate $Item.Installed $Item.Latest)   { return 'Up to date' }
        'Update available'
    }

    function Install-DotNetPackage {
        param([string]$Id)
        $wgLog  = Join-Path $Sync.LogDir ('winget_{0}_{1}.log' -f $Id, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $wgArgs = @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity',
                    '--log', $wgLog)
        Write-Log "Running: winget $($wgArgs -join ' ')"
        $r   = Invoke-Winget -Arguments $wgArgs -Stream
        $res = Get-WingetResult $r.ExitCode
        $sev = 'Info'; if ($res -eq 'Failed') { $sev = 'Error' }
        Write-Log ('{0}: exit code {1} (0x{1:X8}) -> {2}' -f $Id, $r.ExitCode, $res) $sev
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
                'UpToDate' { 'Already up to date' }
                'Reboot'   { 'Installed (reboot required)' }
                default    { 'FAILED - see log' }
            }
        }
    }

    # ----- Installed versions of the target .NET major -----

    function Get-DotNetSortVersion {
        param([string]$Version)
        try { [version]($Version.Split('-')[0]) } catch { [version]'0.0' }
    }

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
    $candidates = @("$env:windir\CCM\Logs", "$env:ProgramData\DotNetWingetInstaller\Logs", $env:TEMP)
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

function Get-WingetPath {
    # SYSTEM has no winget alias on PATH: resolve the App Installer package folder directly.
    $pf = $env:ProgramW6432; if (-not $pf) { $pf = $env:ProgramFiles }
    $found = @(Resolve-Path -Path (Join-Path $pf 'WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe') -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ProviderPath } |
        Sort-Object -Descending -Property { try { [version](((Split-Path (Split-Path $_ -Parent) -Leaf) -split '_')[1]) } catch { [version]'0.0' } })
    if ($found.Count -gt 0) { return $found[0] }
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $null
}

function Test-Winget {
    $Sync.Winget = Get-WingetPath
    if (-not $Sync.Winget) { return 'winget.exe was not found (App Installer is not installed or not provisioned on this device).' }
    Write-Log "winget path: $($Sync.Winget)"
    try {
        $r = Invoke-Winget -Arguments @('--version')
        if ($r.ExitCode -ne 0) {
            return ('winget failed to start (exit {0}, 0x{0:X8}). This often means a missing dependency such as Microsoft.VCLibs / UI.Xaml when running as SYSTEM.' -f $r.ExitCode)
        }
        Write-Log "winget version: $($r.Output -join ' ')"
    }
    catch { return "winget failed to start: $_" }
    $null
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

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
Initialize-Log
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$runAs    = $identity.Name; if ($identity.IsSystem) { $runAs = 'SYSTEM' }
Write-Log ('===== Start (.NET {0} edition): running as {1} (admin={2}), PS {3}, {4}-bit =====' -f $TargetMajor, $runAs, $isAdmin, $PSVersionTable.PSVersion, ([IntPtr]::Size * 8))
if (-not $isAdmin) { Write-Log 'Not running elevated: each install/uninstall will prompt for UAC.' Warning }
#endregion

#region ---------------- Headless mode ----------------
if ($PackageId) {
    $Sync.Console = $true
    $bad = @($PackageId | Where-Object { $_ -and -not $Sync.Items.Contains($_) })
    if ($bad.Count -gt 0) {
        Write-Log "Only .NET $TargetMajor packages can be installed by this script. Rejected: $($bad -join ', ')" Error
        Write-Log "Allowed: $($Sync.Items.Keys -join ', ')" Error
        exit 1
    }
    $err = Test-Winget
    if ($err) { Write-Log $err Error; exit 1 }
    $results = [ordered]@{}
    foreach ($id in $PackageId) {
        $k = "install:$id"; $Sync.Labels[$k] = $id
        try { $results[$k] = Install-DotNetPackage -Id $id } catch { Write-Log "${id}: $_" Error; $results[$k] = 'Failed' }
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
$Title = ".NET $TargetMajor Installer"

$wingetError = Test-Winget
if ($wingetError) {
    Write-Log $wingetError Error
    [void][System.Windows.Forms.MessageBox]::Show("$wingetError`r`n`r`nLog: $($Sync.LogFile)", $Title, 'OK', 'Error')
    exit 1
}

$script:AllResults = [ordered]@{}

$form = New-Object System.Windows.Forms.Form
$form.Text          = "$Title (winget)  -  running as $runAs"
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
$hdrText.Text = "Check a package to install the latest .NET $TargetMajor from winget (installed packages are upgraded), " +
                "or check an installed version to uninstall it."
$hdr.Controls.Add($hdrTitle, 0, 0); $hdr.Controls.Add($hdrText, 0, 1)
$layout.Controls.Add($hdr, 0, 0)

# --- single package list ---
$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
$lv.HideSelection = $true; $lv.MultiSelect = $false; $lv.Dock = 'Fill'
$lv.BackColor = $C.Pane; $lv.ForeColor = $C.PaneText; $lv.BorderStyle = 'FixedSingle'
$lv.ShowItemToolTips = $true
[void]$lv.Columns.Add('Package', 250)
[void]$lv.Columns.Add('Latest', 110)
[void]$lv.Columns.Add('Installed', 130)
[void]$lv.Columns.Add('Arch', 80)
[void]$lv.Columns.Add('Status', 300)
$grpInstall   = New-Object System.Windows.Forms.ListViewGroup('install',   "Install .NET $TargetMajor  -  latest version from winget")
$grpInstalled = New-Object System.Windows.Forms.ListViewGroup('installed', "Installed .NET $TargetMajor on this device  -  check to uninstall")
[void]$lv.Groups.Add($grpInstall); [void]$lv.Groups.Add($grpInstalled)

function Set-SubColors($li, [System.Drawing.Color]$Color) {
    foreach ($s in $li.SubItems) { $s.ForeColor = $Color; $s.BackColor = $C.Pane }
}

foreach ($item in $Sync.Items.Values) {
    $li = New-Object System.Windows.Forms.ListViewItem($item.Name)
    $li.Name = $item.Id; $li.Group = $grpInstall; $li.ToolTipText = $item.Id
    $li.UseItemStyleForSubItems = $false
    [void]$li.SubItems.Add('...'); [void]$li.SubItems.Add('...'); [void]$li.SubItems.Add('-'); [void]$li.SubItems.Add('Checking...')
    Set-SubColors $li $C.PaneText
    [void]$lv.Items.Add($li)
}
$phLi = New-Object System.Windows.Forms.ListViewItem('Scanning...')
$phLi.Name = 'placeholder'; $phLi.Group = $grpInstalled; $phLi.UseItemStyleForSubItems = $false
Set-SubColors $phLi $C.Muted
[void]$lv.Items.Add($phLi)
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
$lblStatus.Text = 'Reading installed and latest versions...'
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
        'Up to date'          { $C.Ok }
        'Already*'            { $C.Ok }
        'Installed (preview*' { $C.Warn }
        'Installed*'          { $C.Ok }
        'Uninstalled*'        { $C.Ok }
        'Update available'    { $C.Warn }
        'FAILED*'             { $C.Bad }
        'Not found in winget' { $C.Bad }
        'Installing*'         { $C.Busy }
        'Uninstalling*'       { $C.Busy }
        default               { $C.PaneText }
    })[0]
}

function Set-ItemRow {
    param($Msg)
    $li = $lv.Items[$Msg.Id]
    if (-not $li) { return }
    if ($Msg.ContainsKey('Latest'))    { $v = $Msg.Latest;    if (-not $v) { $v = '-' }; $li.SubItems[1].Text = $v }
    if ($Msg.ContainsKey('Installed')) { $v = $Msg.Installed; if (-not $v) { $v = '-' }; $li.SubItems[2].Text = $v }
    if ($Msg.ContainsKey('Status'))    { $li.SubItems[4].Text = $Msg.Status; $li.SubItems[4].ForeColor = Get-StatusColor $Msg.Status }
}

function Set-InstalledRowStatus {
    param($Msg)
    $li = $lv.Items[$Msg.Key]
    if (-not $li) { return }
    $li.SubItems[4].Text = $Msg.Status
    $li.SubItems[4].ForeColor = Get-StatusColor $Msg.Status
}

function Update-InstalledRows {
    $lv.BeginUpdate()
    try {
        foreach ($li in @($lv.Items)) { if ($li.Group -eq $grpInstalled) { $lv.Items.Remove($li) } }
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

        Write-Log 'Reading installed packages (winget export)...'
        $installed = Get-InstalledPackages
        foreach ($item in $Sync.Items.Values) {
            $item.Installed = $installed[$item.Id]
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $item.Id; Installed = $item.Installed })
        }
        Write-Log 'Reading latest versions from the winget source...'
        foreach ($item in $Sync.Items.Values) {
            $item.Latest = Get-LatestVersion $item.Id
            $item.Status = Get-ItemStatus $item
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $item.Id; Latest = $item.Latest; Status = $item.Status })
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
            Write-Log "----- [$($n + 1)/$total] Install $($item.Name) ($id) -----"
            try { $res = Install-DotNetPackage -Id $id } catch { Write-Log "${id}: $_" Error; $res = 'Failed' }
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
        $installed = Get-InstalledPackages
        foreach ($item in $Sync.Items.Values) {
            $item.Installed = $installed[$item.Id]
            $item.Status    = Get-ItemStatus $item
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $item.Id; Installed = $item.Installed })
        }
        $Sync.Inventory = Get-DotNetInventory
        $Sync.Queue.Enqueue(@{ Type = 'Inventory' })
    }
    catch { Write-Log "Unexpected error: $_" Error }
    finally {
        $Sync.Results = $results
        $Sync.Queue.Enqueue(@{ Type = 'WorkDone' })
    }
}

function Start-Batch {
    param([string[]]$Ids, [string[]]$Keys, [string]$Verb)
    $Ids = @($Ids | Where-Object { $_ }); $Keys = @($Keys | Where-Object { $_ })
    if ($Ids.Count + $Keys.Count -eq 0) { return }
    if ($Ids.Count) {
        $text = "Install the following packages?`r`n`r`n" + (($Ids | ForEach-Object { '  + ' + $Sync.Items[$_].Name }) -join "`r`n")
    }
    else {
        $text = "Uninstall the following?`r`n`r`n" + (($Keys | ForEach-Object { $e = $Sync.Inventory[$_]; '  - {0} {1} ({2})' -f $e.Name, $e.Version, $e.Arch }) -join "`r`n") +
                "`r`n`r`nApplications that use these versions will stop working until another compatible version is installed."
    }
    $answer = [System.Windows.Forms.MessageBox]::Show($text, $Title, 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    foreach ($id in $Ids) { $Sync.Labels["install:$id"] = $Sync.Items[$id].Name }
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
    if (-not $block -and $li.Group -eq $grpInstalled) {
        $entry = $Sync.Inventory[$li.Name]
        $block = (-not $entry) -or (-not $entry.Removable)
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
            'Inventory'    { Update-InstalledRows; Update-Buttons }
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
                foreach ($item in $Sync.Items.Values) { Set-ItemRow @{ Id = $item.Id; Status = $item.Status } }
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
