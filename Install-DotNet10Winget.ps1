<#
.SYNOPSIS
    GUI that installs/upgrades .NET 10 packages with winget and removes out-of-support .NET versions.

.DESCRIPTION
    INSTALL - Only the .NET 10 packages can be installed: .NET Runtime, Desktop Runtime, ASP.NET Core Runtime,
    Hosting Bundle and SDK. The list shows the latest version in the winget repository and the installed version.
    Checked packages are installed one at a time, silently:

        winget install --id <Id> --exact --source winget --silent
               --accept-package-agreements --accept-source-agreements --disable-interactivity

    "winget install" on a package that is already installed upgrades it to the latest version.

    REMOVE - Every .NET (Core) runtime, Hosting Bundle and SDK installed on the device is listed, found through
    the Add/Remove Programs registry keys and the dotnet folders on disk. Only these entries can be checked for
    removal:
        - out of support (end-of-support date in $EndOfSupport has passed)
        - preview / release-candidate builds
        - an older patch that a newer patch of the same product, major version and architecture has superseded
    Supported versions, SDKs installed by Visual Studio, and runtimes with no standalone uninstaller (installed as
    part of Visual Studio or an SDK) are listed for information only. They cannot be checked.
    Removal runs the product's registered quiet uninstaller (/uninstall /quiet /norestart).

    The script is built to run as SYSTEM from a ConfigMgr (SCCM) application with
    "Allow users to view and interact with the program installation" enabled.

    Exit codes:  0 = success / nothing to do,  3010 = success, reboot required,
                 1603 = one or more operations failed,  1 = winget not usable / invalid parameters.

.PARAMETER PackageId
    Optional. Skip the GUI and install the given winget IDs, e.g. -PackageId Microsoft.DotNet.Runtime.10
    Only .NET 10 IDs are accepted.

.PARAMETER RemoveUnsupported
    Optional. Skip the GUI and remove every removable entry (out of support / preview / superseded).
    It can be combined with -PackageId. Installs run first.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install-DotNet10Winget.ps1

.EXAMPLE
    .\Install-DotNet10Winget.ps1 -PackageId Microsoft.DotNet.Runtime.10,Microsoft.DotNet.DesktopRuntime.10 -RemoveUnsupported
#>
[CmdletBinding()]
param(
    [string[]]$PackageId,
    [switch]$RemoveUnsupported
)

$ErrorActionPreference = 'Stop'

#region ---------------- Configuration ----------------
$TargetMajor = '10'                                  # the only .NET major version this script installs
$Products    = [ordered]@{                           # winget ID segment = display name
    'Runtime'        = '.NET Runtime'
    'DesktopRuntime' = '.NET Desktop Runtime'
    'AspNetCore'     = 'ASP.NET Core Runtime'
    'HostingBundle'  = 'ASP.NET Core Hosting Bundle'
    'SDK'            = '.NET SDK'
}
# End-of-support dates (yyyy-MM-dd) from https://dotnet.microsoft.com/platform/support/policy/dotnet-core
# Keys: major version for .NET 5+, major.minor for .NET Core 1.x-3.x.
# Versions missing from this table count as out of support if older than 5, and as supported if newer.
$EndOfSupport = @{
    '1.0' = '2019-06-27'; '1.1' = '2019-06-27'; '2.0' = '2018-10-01'; '2.1' = '2021-08-21'; '2.2' = '2019-12-23'
    '3.0' = '2020-03-03'; '3.1' = '2022-12-13'
    '5'   = '2022-05-10'; '6'   = '2024-11-12'; '7'   = '2024-05-14'; '8' = '2026-11-10'; '9' = '2026-11-10'
    '10'  = '2028-11-14'; '11'  = '2028-11-14'
}
$LogFileName = "DotNet$($TargetMajor)WingetInstaller.log"
$MarkerKey   = "HKLM:\SOFTWARE\DotNetWingetInstaller\NET$TargetMajor"   # written on success; used by the Detect script
#endregion

#region ---------------- Shared state ----------------
$Sync = [hashtable]::Synchronized(@{
    Queue        = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    LogLock      = New-Object object
    LogDir       = $null
    LogFile      = $null
    Winget       = $null
    Console      = $false
    Busy         = $false
    TargetMajor  = $TargetMajor
    Products     = $Products
    EndOfSupport = $EndOfSupport
    Items        = [ordered]@{}     # install rows:  Id -> @{ Id; Name; Latest; Installed; Status }
    Inventory    = [ordered]@{}     # removal rows:  Key -> @{ Key; Type; Version; Arch; ... Removable; Action }
    Selected     = $null            # @{ Install = @(ids); Remove = @(keys) }
    Results      = [ordered]@{}
    Labels       = @{}
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
                'Success'  { 'Removed' }
                'UpToDate' { 'Already removed' }
                'Reboot'   { 'Removed (reboot required)' }
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

    # ----- Inventory of installed .NET (Core) products -----

    function Split-DotNetVersion {
        # '9.0.23' -> [version]9.0.23, Pre=$null ; '11.0.0-rc.3.1' -> [version]11.0.0, Pre='rc.3.1'
        param([string]$Version)
        $parts = $Version.Split('-', 2)
        $v = $null; try { $v = [version]$parts[0] } catch { $v = [version]'0.0' }
        $pre = $null; if ($parts.Count -gt 1) { $pre = $parts[1] }
        @{ Version = $v; Pre = $pre }
    }

    function Compare-DotNetVersion {
        # returns -1 / 0 / 1 ; a release sorts above its own previews
        param([string]$A, [string]$B)
        $x = Split-DotNetVersion $A; $y = Split-DotNetVersion $B
        $c = $x.Version.CompareTo($y.Version)
        if ($c -ne 0) { return [Math]::Sign($c) }
        if (-not $x.Pre -and $y.Pre) { return 1 }
        if ($x.Pre -and -not $y.Pre) { return -1 }
        [Math]::Sign([string]::CompareOrdinal([string]$x.Pre, [string]$y.Pre))
    }

    function Get-SupportInfo {
        param([string]$Version)
        $p     = $Version.Split('-')[0].Split('.')
        $major = [int]$p[0]
        $key   = if ($major -lt 5) { '{0}.{1}' -f $p[0], $p[1] } else { [string]$major }
        $eos   = $Sync.EndOfSupport[$key]
        if ($eos) { $out = ([datetime]::Today -gt [datetime]::ParseExact($eos, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)) }
        else      { $out = ($major -lt 5) }
        $label = if ($major -lt 5) { ".NET Core $key" } else { ".NET $key" }
        @{ Key = $key; Major = $major; Label = $label; EndOfSupport = $eos; OutOfSupport = $out; Preview = ($Version -match '-') }
    }

    function Get-DotNetInventory {
        $typeNames = @{ Runtime = '.NET Runtime'; DesktopRuntime = '.NET Desktop Runtime'; AspNetCore = 'ASP.NET Core Runtime'
                        HostingBundle = 'ASP.NET Core Hosting Bundle'; SDK = '.NET SDK' }
        $rows = New-Object System.Collections.Generic.List[object]
        $seen = @{}

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
                $ver  = $Matches[1]
                $arch = '-'; if ($name -match '\((x64|x86|arm64)\)') { $arch = $Matches[1] }
                $seen[$k.PSChildName] = $true
                $s = Get-SupportInfo $ver
                $rows.Add(@{
                    Key = "reg:$($k.PSChildName)"; Source = 'Registry'; Type = $type; Name = $typeNames[$type]; DisplayName = $name
                    Version = $ver; Arch = $arch; Support = $s; VisualStudio = ($name -match 'from Visual Studio')
                    Quiet = [string]$e.QuietUninstallString; Uninstall = [string]$e.UninstallString
                    Superseded = $null; Removable = $false; Action = ''
                })
            }
        }

        # 2) Superseded patches: newer registry entry of the same product + major + arch
        foreach ($r in $rows) {
            foreach ($o in $rows) {
                if ($o -eq $r -or $o.Type -ne $r.Type -or $o.Arch -ne $r.Arch -or $o.Support.Key -ne $r.Support.Key -or $o.Support.Preview) { continue }
                if ((Compare-DotNetVersion $o.Version $r.Version) -gt 0 -and (-not $r.Superseded -or (Compare-DotNetVersion $o.Version $r.Superseded) -gt 0)) { $r.Superseded = $o.Version }
            }
        }

        foreach ($r in $rows) {
            if     ($r.VisualStudio)                     { $r.Action = 'Managed by Visual Studio' }
            elseif (-not ($r.Quiet -or $r.Uninstall))    { $r.Action = 'No uninstaller registered' }
            elseif ($r.Support.OutOfSupport)             { $r.Removable = $true; $r.Action = 'Remove (out of support)' }
            elseif ($r.Support.Preview)                  { $r.Removable = $true; $r.Action = 'Remove (preview build)' }
            elseif ($r.Superseded)                       { $r.Removable = $true; $r.Action = "Remove (superseded by $($r.Superseded))" }
            else                                         { $r.Action = 'Keep (supported)' }
        }

        # 3) Files on disk with no matching uninstall entry (installed as part of Visual Studio or an SDK)
        $native = 'x64'; if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $native = 'arm64' }
        $pf = $env:ProgramW6432; if (-not $pf) { $pf = $env:ProgramFiles }
        $diskRoots = @(@{ Path = Join-Path $pf 'dotnet'; Arch = $native })
        if (${env:ProgramFiles(x86)}) { $diskRoots += @{ Path = Join-Path ${env:ProgramFiles(x86)} 'dotnet'; Arch = 'x86' } }
        $folders = @{ 'Microsoft.NETCore.App' = 'Runtime'; 'Microsoft.WindowsDesktop.App' = 'DesktopRuntime'; 'Microsoft.AspNetCore.App' = 'AspNetCore' }
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
                if ($x.Version -notmatch '^\d+\.\d+\.\d+') { continue }
                $owners  = $coveredBy[$x.Type]
                $covered = @($rows | Where-Object { $_.Version -eq $x.Version -and $owners -contains $_.Type -and ($_.Arch -eq '-' -or $_.Arch -eq $dr.Arch) }).Count -gt 0
                if ($covered) { continue }
                $dk = "disk:$($x.Type):$($x.Version)"
                if (-not $disk.Contains($dk)) {
                    $s = Get-SupportInfo $x.Version
                    $disk[$dk] = @{
                        Key = $dk; Source = 'Disk'; Type = $x.Type; Name = $typeNames[$x.Type]; DisplayName = "$($typeNames[$x.Type]) $($x.Version)"
                        Version = $x.Version; Arch = $dr.Arch; Support = $s; VisualStudio = $false; Quiet = ''; Uninstall = ''
                        Superseded = $null; Removable = $false; Action = 'No uninstaller (part of VS or an SDK)'
                    }
                }
                elseif ($disk[$dk].Arch -notmatch [regex]::Escape($dr.Arch)) { $disk[$dk].Arch += ", $($dr.Arch)" }
            }
        }
        foreach ($d in $disk.Values) { $rows.Add($d) }

        # Sort: newest major first, then product, then newest version first
        $order = @{ Runtime = 0; DesktopRuntime = 1; AspNetCore = 2; HostingBundle = 3; SDK = 4 }
        $sorted = @($rows | Sort-Object @{ e = { $_.Support.Major }; Descending = $true },
                                        @{ e = { [version]($_.Support.Key + '.0') }; Descending = $true },
                                        @{ e = { $order[$_.Type] } },
                                        @{ e = { (Split-DotNetVersion $_.Version).Version }; Descending = $true },
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
if ($PackageId -or $RemoveUnsupported) {
    $Sync.Console = $true
    $bad = @($PackageId | Where-Object { $_ -and -not $Sync.Items.Contains($_) })
    if ($bad.Count -gt 0) {
        Write-Log "Only .NET $TargetMajor packages can be installed by this script. Rejected: $($bad -join ', ')" Error
        Write-Log "Allowed: $($Sync.Items.Keys -join ', ')" Error
        exit 1
    }
    $results = [ordered]@{}
    if ($PackageId) {
        $err = Test-Winget
        if ($err) { Write-Log $err Error; exit 1 }
        foreach ($id in $PackageId) {
            $k = "install:$id"; $Sync.Labels[$k] = $id
            try { $results[$k] = Install-DotNetPackage -Id $id } catch { Write-Log "${id}: $_" Error; $results[$k] = 'Failed' }
        }
    }
    if ($RemoveUnsupported) {
        $inv = Get-DotNetInventory
        foreach ($e in $inv.Values) { Write-Log ('Found: {0} [{1}] -> {2}' -f $e.DisplayName, $e.Arch, $e.Action) }
        $targets = @($inv.Values | Where-Object { $_.Removable })
        if ($targets.Count -eq 0) { Write-Log 'Nothing to remove.' }
        foreach ($e in $targets) {
            $k = "remove:$($e.Key)"; $Sync.Labels[$k] = "Remove $($e.DisplayName)"
            try { $results[$k] = Uninstall-DotNetEntry -Entry $e } catch { Write-Log "$($e.DisplayName): $_" Error; $results[$k] = 'Failed' }
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

$wingetError = Test-Winget
if ($wingetError) {
    Write-Log $wingetError Error
    [void][System.Windows.Forms.MessageBox]::Show("$wingetError`r`n`r`nLog: $($Sync.LogFile)", ".NET $TargetMajor Installer", 'OK', 'Error')
    exit 1
}

$script:AllResults = [ordered]@{}
$Title = ".NET $TargetMajor Installer"

$form = New-Object System.Windows.Forms.Form
$form.Text          = "$Title (winget)  -  running as $runAs"
$form.Size          = New-Object System.Drawing.Size(980, 880)
$form.MinimumSize   = New-Object System.Drawing.Size(820, 700)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
$boldFont           = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock        = 'Fill'
$layout.Padding     = New-Object System.Windows.Forms.Padding(10)
$layout.ColumnCount = 1
$layout.RowCount    = 7
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))       # 0 install header
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 140)))  # 1 install list
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))       # 2 remove header
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 62)))    # 3 remove list
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))       # 4 buttons
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))       # 5 progress
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 38)))    # 6 log
$form.Controls.Add($layout)

function New-Header([string]$Bold, [string]$Text) {
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.AutoSize = $true; $panel.Dock = 'Fill'; $panel.WrapContents = $true
    $panel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    $b = New-Object System.Windows.Forms.Label; $b.AutoSize = $true; $b.Font = $boldFont; $b.Text = $Bold
    $t = New-Object System.Windows.Forms.Label; $t.AutoSize = $true; $t.Text = $Text; $t.Margin = New-Object System.Windows.Forms.Padding(6, 1, 0, 0)
    $panel.Controls.AddRange(@($b, $t))
    $panel
}

$layout.Controls.Add((New-Header "Install .NET $TargetMajor" 'Latest version from the winget repository. Packages already installed are upgraded.'), 0, 0)

$lvInstall = New-Object System.Windows.Forms.ListView
$lvInstall.View = 'Details'; $lvInstall.CheckBoxes = $true; $lvInstall.FullRowSelect = $true
$lvInstall.HideSelection = $true; $lvInstall.MultiSelect = $false; $lvInstall.Dock = 'Fill'
[void]$lvInstall.Columns.Add('Package', 240)
[void]$lvInstall.Columns.Add('Winget ID', 270)
[void]$lvInstall.Columns.Add('Latest', 100)
[void]$lvInstall.Columns.Add('Installed', 100)
[void]$lvInstall.Columns.Add('Status', 190)
foreach ($item in $Sync.Items.Values) {
    $li = New-Object System.Windows.Forms.ListViewItem($item.Name)
    $li.Name = $item.Id
    [void]$li.SubItems.Add($item.Id)
    [void]$li.SubItems.Add('...')
    [void]$li.SubItems.Add('...')
    [void]$li.SubItems.Add('Checking...')
    $li.UseItemStyleForSubItems = $false
    [void]$lvInstall.Items.Add($li)
}
$layout.Controls.Add($lvInstall, 0, 1)

$layout.Controls.Add((New-Header 'Installed .NET on this device' 'Out-of-support, preview and superseded versions can be checked for removal. Other versions are listed for information.'), 0, 2)

$lvRemove = New-Object System.Windows.Forms.ListView
$lvRemove.View = 'Details'; $lvRemove.CheckBoxes = $true; $lvRemove.FullRowSelect = $true
$lvRemove.HideSelection = $true; $lvRemove.MultiSelect = $false; $lvRemove.Dock = 'Fill'
[void]$lvRemove.Columns.Add('Package', 230)
[void]$lvRemove.Columns.Add('Version', 150)
[void]$lvRemove.Columns.Add('Arch', 75)
[void]$lvRemove.Columns.Add('Support', 170)
[void]$lvRemove.Columns.Add('Action', 290)
$phLi = New-Object System.Windows.Forms.ListViewItem('Scanning installed .NET versions...')
$phLi.ForeColor = [System.Drawing.Color]::Gray
[void]$lvRemove.Items.Add($phLi)
$layout.Controls.Add($lvRemove, 0, 3)

$btnRow = New-Object System.Windows.Forms.FlowLayoutPanel
$btnRow.Dock = 'Fill'; $btnRow.AutoSize = $true; $btnRow.FlowDirection = 'RightToLeft'
$btnRow.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
$btnClose     = New-Object System.Windows.Forms.Button; $btnClose.Text     = 'Close';                 $btnClose.Size     = New-Object System.Drawing.Size(100, 30)
$btnApply     = New-Object System.Windows.Forms.Button; $btnApply.Text     = 'Apply selected';        $btnApply.Size     = New-Object System.Drawing.Size(130, 30)
$btnClear     = New-Object System.Windows.Forms.Button; $btnClear.Text     = 'Clear selection';       $btnClear.Size     = New-Object System.Drawing.Size(120, 30)
$btnSelectOld = New-Object System.Windows.Forms.Button; $btnSelectOld.Text = 'Select all removable';  $btnSelectOld.Size = New-Object System.Drawing.Size(150, 30)
$lblStatus    = New-Object System.Windows.Forms.Label;  $lblStatus.AutoSize = $true; $lblStatus.Margin = New-Object System.Windows.Forms.Padding(0, 8, 20, 0)
$lblStatus.Text = 'Reading installed and latest versions...'
$btnApply.Enabled = $false
$btnRow.Controls.AddRange(@($btnClose, $btnApply, $btnClear, $btnSelectOld, $lblStatus))
$layout.Controls.Add($btnRow, 0, 4)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Fill'; $progress.Height = 18; $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30
$layout.Controls.Add($progress, 0, 5)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock = 'Fill'; $logBox.ReadOnly = $true; $logBox.BackColor = [System.Drawing.Color]::White
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9); $logBox.WordWrap = $false
$layout.Controls.Add($logBox, 0, 6)

function Update-Buttons {
    $n = $lvInstall.CheckedItems.Count + $lvRemove.CheckedItems.Count
    $btnApply.Enabled     = (-not $Sync.Busy) -and ($n -gt 0)
    $btnClear.Enabled     = (-not $Sync.Busy)
    $btnSelectOld.Enabled = (-not $Sync.Busy) -and (@($Sync.Inventory.Values | Where-Object { $_.Removable }).Count -gt 0)
}

function Get-StatusColor([string]$Status) {
    switch -Wildcard ($Status) {
        'Up to date'          { [System.Drawing.Color]::Green }
        'Already*'            { [System.Drawing.Color]::Green }
        'Installed*'          { [System.Drawing.Color]::Green }
        'Removed*'            { [System.Drawing.Color]::Green }
        'Update available'    { [System.Drawing.Color]::DarkOrange }
        'FAILED*'             { [System.Drawing.Color]::Red }
        'Not found in winget' { [System.Drawing.Color]::Red }
        'Installing*'         { [System.Drawing.Color]::Blue }
        'Removing*'           { [System.Drawing.Color]::Blue }
        'Remove*'             { [System.Drawing.Color]::DarkOrange }
        default               { [System.Drawing.Color]::Black }
    }
}

function Set-ItemRow {
    param($Msg)
    $li = $lvInstall.Items[$Msg.Id]
    if (-not $li) { return }
    if ($Msg.ContainsKey('Latest'))    { $v = $Msg.Latest;    if (-not $v) { $v = '-' }; $li.SubItems[2].Text = $v }
    if ($Msg.ContainsKey('Installed')) { $v = $Msg.Installed; if (-not $v) { $v = '-' }; $li.SubItems[3].Text = $v }
    if ($Msg.ContainsKey('Status'))    { $li.SubItems[4].Text = $Msg.Status; $li.SubItems[4].ForeColor = Get-StatusColor $Msg.Status }
}

function Set-RemoveRowStatus {
    param($Msg)
    $li = $lvRemove.Items[$Msg.Key]
    if (-not $li) { return }
    $li.SubItems[4].Text = $Msg.Status
    $li.SubItems[4].ForeColor = Get-StatusColor $Msg.Status
}

function Update-RemoveList {
    $lvRemove.BeginUpdate()
    try {
        $lvRemove.Items.Clear(); $lvRemove.Groups.Clear()
        $groups = @{}
        foreach ($e in $Sync.Inventory.Values) {
            $s = $e.Support
            if (-not $groups.ContainsKey($s.Key)) {
                $title = $s.Label
                if     ($s.Key -eq $TargetMajor)  { $title += "  -  supported until $($s.EndOfSupport)  (installed by this tool)" }
                elseif ($s.OutOfSupport)          { if ($s.EndOfSupport) { $title += "  -  OUT OF SUPPORT since $($s.EndOfSupport)" } else { $title += '  -  OUT OF SUPPORT' } }
                elseif ($s.EndOfSupport)          { $title += "  -  supported until $($s.EndOfSupport)" }
                else                              { $title += '  -  support date unknown' }
                $g = New-Object System.Windows.Forms.ListViewGroup($s.Key, $title)
                [void]$lvRemove.Groups.Add($g); $groups[$s.Key] = $g
            }
            $li = New-Object System.Windows.Forms.ListViewItem($e.Name)
            $li.Name  = $e.Key
            $li.Group = $groups[$s.Key]
            $li.UseItemStyleForSubItems = $false
            $li.ToolTipText = $e.DisplayName
            [void]$li.SubItems.Add($e.Version)
            [void]$li.SubItems.Add($e.Arch)
            $sup = if ($s.Preview) { 'Preview (unsupported)' } elseif ($s.OutOfSupport) { 'Out of support' } else { 'Supported' }
            [void]$li.SubItems.Add($sup)
            [void]$li.SubItems.Add($e.Action)
            $li.SubItems[3].ForeColor = if ($s.OutOfSupport -or $s.Preview) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::Green }
            if ($e.Removable) { $li.SubItems[4].ForeColor = [System.Drawing.Color]::DarkOrange }
            else {
                foreach ($i in 0, 1, 2, 4) { $li.SubItems[$i].ForeColor = [System.Drawing.Color]::Gray }
            }
            [void]$lvRemove.Items.Add($li)
        }
        if ($Sync.Inventory.Count -eq 0) {
            $li = New-Object System.Windows.Forms.ListViewItem('No .NET (Core) runtimes or SDKs found.')
            $li.ForeColor = [System.Drawing.Color]::Gray
            [void]$lvRemove.Items.Add($li)
        }
    }
    finally { $lvRemove.EndUpdate() }
    $lvRemove.ShowItemToolTips = $true
}

$LoadWorker = {
    try {
        Write-Log 'Scanning installed .NET versions (Add/Remove Programs + dotnet folders)...'
        $Sync.Inventory = Get-DotNetInventory
        $nRem = @($Sync.Inventory.Values | Where-Object { $_.Removable }).Count
        Write-Log ('Found {0} installed .NET entries, {1} removable.' -f $Sync.Inventory.Count, $nRem)
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

$ApplyWorker = {
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
            $Sync.Queue.Enqueue(@{ Type = 'Progress'; Value = [int](100 * $n / $total); Text = ('{0} of {1}: removing {2} {3}' -f ($n + 1), $total, $e.Name, $e.Version) })
            $Sync.Queue.Enqueue(@{ Type = 'RemoveRow'; Key = $key; Status = 'Removing...' })
            Write-Log "----- [$($n + 1)/$total] Remove $($e.DisplayName) -----"
            try { $res = Uninstall-DotNetEntry -Entry $e } catch { Write-Log "$($e.DisplayName): $_" Error; $res = 'Failed' }
            $results["remove:$key"] = $res
            $Sync.Queue.Enqueue(@{ Type = 'RemoveRow'; Key = $key; Status = (Get-FriendlyResult $res 'Remove') })
            $n++
        }
        $Sync.Queue.Enqueue(@{ Type = 'Progress'; Value = 100; Text = 'Refreshing installed versions...' })
        $installed = Get-InstalledPackages
        foreach ($item in $Sync.Items.Values) {
            $item.Installed = $installed[$item.Id]
            $item.Status    = Get-ItemStatus $item
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $item.Id; Installed = $item.Installed })
        }
    }
    catch { Write-Log "Unexpected error: $_" Error }
    finally {
        $Sync.Results = $results
        $Sync.Queue.Enqueue(@{ Type = 'ApplyDone' })
    }
}

$RescanWorker = {
    try { $Sync.Inventory = Get-DotNetInventory; $Sync.Queue.Enqueue(@{ Type = 'Inventory' }) }
    catch { Write-Log "Error while rescanning: $_" Error }
}

$lvInstall.Add_ItemCheck({ param($s, $e) if ($Sync.Busy) { $e.NewValue = $e.CurrentValue } })
$lvRemove.Add_ItemCheck({
    param($s, $e)
    $entry = $Sync.Inventory[$lvRemove.Items[$e.Index].Name]
    if ($Sync.Busy -or -not $entry -or -not $entry.Removable) { $e.NewValue = $e.CurrentValue }
})
$lvInstall.Add_ItemChecked({ Update-Buttons })
$lvRemove.Add_ItemChecked({ Update-Buttons })

$btnClear.Add_Click({
    foreach ($li in @($lvInstall.CheckedItems)) { $li.Checked = $false }
    foreach ($li in @($lvRemove.CheckedItems))  { $li.Checked = $false }
})
$btnSelectOld.Add_Click({
    foreach ($li in $lvRemove.Items) { $e = $Sync.Inventory[$li.Name]; if ($e -and $e.Removable) { $li.Checked = $true } }
})

$btnApply.Add_Click({
    $ids  = @($lvInstall.CheckedItems | ForEach-Object { $_.Name })
    $keys = @($lvRemove.CheckedItems  | ForEach-Object { $_.Name })
    if ($ids.Count + $keys.Count -eq 0) { return }
    $text = ''
    if ($ids.Count)  { $text += "Install:`r`n" + (($ids | ForEach-Object { '  + ' + $Sync.Items[$_].Name }) -join "`r`n") + "`r`n`r`n" }
    if ($keys.Count) { $text += "Remove:`r`n"  + (($keys | ForEach-Object { $e = $Sync.Inventory[$_]; '  - {0} {1} ({2})' -f $e.Name, $e.Version, $e.Arch }) -join "`r`n") + "`r`n`r`n" }
    if ($keys.Count) { $text += "Applications that still target a removed version will stop working until they are updated.`r`n`r`n" }
    $answer = [System.Windows.Forms.MessageBox]::Show("${text}Continue?", $Title, 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    foreach ($id in $ids)  { $Sync.Labels["install:$id"] = $Sync.Items[$id].Name }
    foreach ($k in $keys)  { $e = $Sync.Inventory[$k]; $Sync.Labels["remove:$k"] = 'Remove {0} {1} ({2})' -f $e.Name, $e.Version, $e.Arch }
    $Sync.Selected = @{ Install = $ids; Remove = $keys }
    $Sync.Busy     = $true
    Update-Buttons
    $btnClose.Enabled = $false
    $progress.Style   = 'Continuous'
    $progress.Value   = 0
    Write-Log ('Selected: install [{0}], remove [{1}]' -f ($ids -join ', '), (($keys | ForEach-Object { $Sync.Inventory[$_].DisplayName }) -join ', '))
    Start-Worker $ApplyWorker
})

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
                $logBox.SelectionColor  = @{ Info = [System.Drawing.Color]::Black; Warning = [System.Drawing.Color]::DarkOrange; Error = [System.Drawing.Color]::Red }[$msg.Severity]
                $logBox.AppendText($msg.Text + "`r`n")
                $logBox.ScrollToCaret()
            }
            'Item'      { Set-ItemRow $msg }
            'RemoveRow' { Set-RemoveRowStatus $msg }
            'Inventory' { Update-RemoveList; Update-Buttons }
            'Progress'  { $progress.Value = [Math]::Min(100, $msg.Value); $lblStatus.Text = $msg.Text }
            'LoadDone' {
                $Sync.Busy = $false
                $progress.Style = 'Continuous'; $progress.Value = 0
                $lblStatus.Text = 'Ready. Check packages to install or remove, then click Apply selected.'
                Update-Buttons
            }
            'ApplyDone' {
                foreach ($k in $Sync.Results.Keys) { $script:AllResults[$k] = $Sync.Results[$k] }
                $Sync.Selected = $null
                $Sync.Busy = $false
                foreach ($li in @($lvInstall.CheckedItems)) { $li.Checked = $false }
                foreach ($li in @($lvRemove.CheckedItems))  { $li.Checked = $false }
                foreach ($item in $Sync.Items.Values) { Set-ItemRow @{ Id = $item.Id; Status = $item.Status } }
                $btnClose.Enabled = $true
                Update-Buttons
                $code = Get-OverallExitCode $Sync.Results
                $summary = ($Sync.Results.GetEnumerator() | ForEach-Object {
                    $kind = if ($_.Key -like 'remove:*') { 'Remove' } else { 'Install' }
                    '  {0}: {1}' -f $Sync.Labels[$_.Key], (Get-FriendlyResult $_.Value $kind) }) -join "`r`n"
                Write-Log "Batch finished (exit code $code). Rescanning installed .NET versions..."
                $lblStatus.Text = 'Finished.'
                Start-Worker $RescanWorker
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
