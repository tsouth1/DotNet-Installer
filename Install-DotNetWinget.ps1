<#
.SYNOPSIS
    GUI wrapper that installs/upgrades .NET 6, 8, 9 and 10 packages using winget (winget source only).

.DESCRIPTION
    Shows a checklist of .NET Runtime, Desktop Runtime, ASP.NET Core Runtime, Hosting Bundle and SDK
    for .NET 6.x / 8.x / 9.x / 10.x, with the latest version available in the winget repository and the
    version currently installed. Checked packages are installed one at a time, silently:

        winget install --id <Id> --exact --source winget --silent
               --accept-package-agreements --accept-source-agreements --disable-interactivity

    For the .NET "burn" installers winget passes "/quiet /norestart" through to the installer.
    "winget install" on a package that is already installed upgrades it to the latest version.

    Designed to run as SYSTEM from a ConfigMgr (SCCM) application with
    "Allow users to view and interact with the program installation" enabled.

    Exit codes:  0 = success / nothing to do,  3010 = success, reboot required,
                 1603 = one or more packages failed,  1 = winget not usable.

.PARAMETER PackageId
    Optional. Skip the GUI and install the given winget IDs (testing / unattended use), e.g.
    -PackageId Microsoft.DotNet.Runtime.8,Microsoft.DotNet.DesktopRuntime.8

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install-DotNetWinget.ps1
#>
[CmdletBinding()]
param(
    [string[]]$PackageId
)

$ErrorActionPreference = 'Stop'

# "powershell.exe -File" passes "-PackageId A,B" as one string: split on commas / semicolons / spaces.
$PackageId = @($PackageId -split '[,;\s]+' | Where-Object { $_ })

#region ---------------- Configuration ----------------
$Majors   = @('10', '9', '8', '6')                  # display order (newest first)
$Products = [ordered]@{                             # winget ID segment = display name
    'Runtime'        = '.NET Runtime'
    'DesktopRuntime' = '.NET Desktop Runtime'
    'AspNetCore'     = 'ASP.NET Core Runtime'
    'HostingBundle'  = 'ASP.NET Core Hosting Bundle'
    'SDK'            = '.NET SDK'
}
$OutOfSupport = @('6')                              # majors labelled "out of support" in the GUI
$LogFileName  = 'DotNetWingetInstaller.log'
$MarkerKey    = 'HKLM:\SOFTWARE\DotNetWingetInstaller'   # written on success; used by Detect-DotNetWinget.ps1
#endregion

#region ---------------- Shared state ----------------
$Sync = [hashtable]::Synchronized(@{
    Queue    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    LogLock  = New-Object object
    LogDir   = $null
    LogFile  = $null
    Winget   = $null
    Console  = $false
    Busy     = $false
    Items    = [ordered]@{}     # Id -> @{ Id; Name; Major; Latest; Installed; Status }
    Selected = @()
    Results  = @{}
})

foreach ($major in $Majors) {
    foreach ($p in $Products.Keys) {
        $id = "Microsoft.DotNet.$p.$major"
        $Sync.Items[$id] = @{ Id = $id; Name = "$($Products[$p]) $major"; Major = $major; Latest = $null; Installed = $null; Status = $null }
    }
}
#endregion

#region ---------------- Core functions (used by GUI thread and background runspaces) ----------------
$CoreScript = {
    function Write-Log {
        param([string]$Message, [ValidateSet('Info', 'Warning', 'Error')][string]$Severity = 'Info')
        $now  = Get-Date
        $type = @{ Info = 1; Warning = 2; Error = 3 }[$Severity]
        # CMTrace format
        $line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="DotNetWinget" context="{3}" type="{4}" thread="{5}" file="">' -f `
            $Message, $now.ToString('HH:mm:ss.fff+000'), $now.ToString('MM-dd-yyyy'), $env:USERNAME, $type, [Threading.Thread]::CurrentThread.ManagedThreadId
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
        param([string]$Result)
        switch ($Result) {
            'Success'  { 'Installed' }
            'UpToDate' { 'Already up to date' }
            'Reboot'   { 'Installed (reboot required)' }
            default    { 'FAILED - see log' }
        }
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
    param([hashtable]$Results)
    $vals = @($Results.Values)
    if ($vals -contains 'Failed') { return 1603 }
    if ($vals -contains 'Reboot') { return 3010 }
    0
}

function Set-Marker {
    param([int]$ExitCode, [hashtable]$Results)
    if ($ExitCode -ne 0 -and $ExitCode -ne 3010) { return }
    try {
        if (-not (Test-Path $MarkerKey)) { New-Item -Path $MarkerKey -Force | Out-Null }
        Set-ItemProperty -Path $MarkerKey -Name 'LastRunUtc'   -Value ((Get-Date).ToUniversalTime().ToString('o'))
        Set-ItemProperty -Path $MarkerKey -Name 'LastExitCode' -Value $ExitCode -Type DWord
        Set-ItemProperty -Path $MarkerKey -Name 'LastPackages' -Value (($Results.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';')
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
Write-Log ('===== Start: running as {0} (admin={1}), PS {2}, {3}-bit =====' -f $runAs, $isAdmin, $PSVersionTable.PSVersion, ([IntPtr]::Size * 8))
if (-not $isAdmin) { Write-Log 'Not running elevated: each install will prompt for UAC.' Warning }
#endregion

#region ---------------- Headless mode ----------------
if ($PackageId) {
    $Sync.Console = $true
    $err = Test-Winget
    if ($err) { Write-Log $err Error; exit 1 }
    $results = @{}
    foreach ($id in $PackageId) {
        if (-not $Sync.Items.Contains($id)) { Write-Log "$id is not in the supported list; installing anyway." Warning }
        try { $results[$id] = Install-DotNetPackage -Id $id } catch { Write-Log "${id}: $_" Error; $results[$id] = 'Failed' }
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
    [void][System.Windows.Forms.MessageBox]::Show("$wingetError`r`n`r`nLog: $($Sync.LogFile)", '.NET Installer', 'OK', 'Error')
    exit 1
}

$script:AllResults = @{}

$form = New-Object System.Windows.Forms.Form
$form.Text          = ".NET Installer (winget)  -  running as $runAs"
$form.Size          = New-Object System.Drawing.Size(940, 720)
$form.MinimumSize   = New-Object System.Drawing.Size(780, 560)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock        = 'Fill'
$layout.Padding     = New-Object System.Windows.Forms.Padding(10)
$layout.ColumnCount = 1
$layout.RowCount    = 5
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 62)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 38)))
$form.Controls.Add($layout)

$header = New-Object System.Windows.Forms.Label
$header.AutoSize    = $true
$header.MaximumSize = New-Object System.Drawing.Size(880, 0)
$header.Margin      = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$header.Text        = "Check the .NET packages to install. Each one installs the latest version from the winget repository " +
                      "(packages already installed are upgraded). Installs run silently, one at a time."
$layout.Controls.Add($header, 0, 0)

$lv = New-Object System.Windows.Forms.ListView
$lv.View          = 'Details'
$lv.CheckBoxes    = $true
$lv.FullRowSelect = $true
$lv.HideSelection = $true
$lv.MultiSelect   = $false
$lv.Dock          = 'Fill'
[void]$lv.Columns.Add('Package', 230)
[void]$lv.Columns.Add('Winget ID', 260)
[void]$lv.Columns.Add('Latest', 90)
[void]$lv.Columns.Add('Installed', 90)
[void]$lv.Columns.Add('Status', 190)
foreach ($major in $Majors) {
    $title = ".NET $major"; if ($OutOfSupport -contains $major) { $title += '  (out of support)' }
    $grp = New-Object System.Windows.Forms.ListViewGroup($major, $title)
    [void]$lv.Groups.Add($grp)
    foreach ($item in ($Sync.Items.Values | Where-Object { $_.Major -eq $major })) {
        $li = New-Object System.Windows.Forms.ListViewItem($item.Name)
        $li.Name  = $item.Id
        $li.Group = $grp
        [void]$li.SubItems.Add($item.Id)
        [void]$li.SubItems.Add('...')
        [void]$li.SubItems.Add('...')
        [void]$li.SubItems.Add('Checking...')
        $li.UseItemStyleForSubItems = $false
        [void]$lv.Items.Add($li)
    }
}
$layout.Controls.Add($lv, 0, 1)

$btnRow = New-Object System.Windows.Forms.FlowLayoutPanel
$btnRow.Dock          = 'Fill'
$btnRow.AutoSize      = $true
$btnRow.FlowDirection = 'RightToLeft'
$btnRow.Margin        = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
$btnClose   = New-Object System.Windows.Forms.Button; $btnClose.Text   = 'Close';           $btnClose.Size   = New-Object System.Drawing.Size(100, 30)
$btnInstall = New-Object System.Windows.Forms.Button; $btnInstall.Text = 'Install selected'; $btnInstall.Size = New-Object System.Drawing.Size(130, 30)
$btnClear   = New-Object System.Windows.Forms.Button; $btnClear.Text   = 'Clear selection'; $btnClear.Size   = New-Object System.Drawing.Size(120, 30)
$lblStatus  = New-Object System.Windows.Forms.Label;  $lblStatus.AutoSize = $true; $lblStatus.Margin = New-Object System.Windows.Forms.Padding(0, 8, 20, 0)
$lblStatus.Text = 'Reading installed and latest versions from winget...'
$btnInstall.Enabled = $false
$btnRow.Controls.AddRange(@($btnClose, $btnInstall, $btnClear, $lblStatus))
$layout.Controls.Add($btnRow, 0, 2)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock   = 'Fill'
$progress.Height = 18
$progress.Style  = 'Marquee'
$progress.MarqueeAnimationSpeed = 30
$layout.Controls.Add($progress, 0, 3)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock       = 'Fill'
$logBox.ReadOnly   = $true
$logBox.BackColor  = [System.Drawing.Color]::White
$logBox.Font       = New-Object System.Drawing.Font('Consolas', 9)
$logBox.WordWrap   = $false
$layout.Controls.Add($logBox, 0, 4)

function Update-Buttons {
    $btnInstall.Enabled = (-not $Sync.Busy) -and ($lv.CheckedItems.Count -gt 0)
    $btnClear.Enabled   = (-not $Sync.Busy)
}

function Set-ItemRow {
    param($Msg)
    $li = $lv.Items[$Msg.Id]
    if (-not $li) { return }
    if ($Msg.ContainsKey('Latest'))    { $v = $Msg.Latest;    if (-not $v) { $v = '-' }; $li.SubItems[2].Text = $v }
    if ($Msg.ContainsKey('Installed')) { $v = $Msg.Installed; if (-not $v) { $v = '-' }; $li.SubItems[3].Text = $v }
    if ($Msg.ContainsKey('Status')) {
        $s = $li.SubItems[4]
        $s.Text = $Msg.Status
        $s.ForeColor = switch -Wildcard ($Msg.Status) {
            'Up to date'          { [System.Drawing.Color]::Green }
            'Already up to date'  { [System.Drawing.Color]::Green }
            'Installed*'          { [System.Drawing.Color]::Green }
            'Update available'    { [System.Drawing.Color]::DarkOrange }
            'FAILED*'             { [System.Drawing.Color]::Red }
            'Not found in winget' { [System.Drawing.Color]::Red }
            'Installing*'         { [System.Drawing.Color]::Blue }
            default               { [System.Drawing.Color]::Black }
        }
    }
}

$LoadWorker = {
    try {
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

$InstallWorker = {
    $results = @{}
    try {
        $ids   = @($Sync.Selected)
        $total = $ids.Count
        for ($i = 0; $i -lt $total; $i++) {
            $id   = $ids[$i]
            $item = $Sync.Items[$id]
            $Sync.Queue.Enqueue(@{ Type = 'Progress'; Value = [int](100 * $i / $total); Text = ('Installing {0} of {1}: {2}' -f ($i + 1), $total, $item.Name) })
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $id; Status = 'Installing...' })
            Write-Log "----- [$($i + 1)/$total] $($item.Name) ($id) -----"
            try { $res = Install-DotNetPackage -Id $id } catch { Write-Log "${id}: $_" Error; $res = 'Failed' }
            $results[$id] = $res
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $id; Status = (Get-FriendlyResult $res) })
        }
        $Sync.Queue.Enqueue(@{ Type = 'Progress'; Value = 100; Text = 'Refreshing installed versions...' })
        $installed = Get-InstalledPackages
        foreach ($item in $Sync.Items.Values) {
            $item.Installed = $installed[$item.Id]
            $Sync.Queue.Enqueue(@{ Type = 'Item'; Id = $item.Id; Installed = $item.Installed })
        }
    }
    catch { Write-Log "Unexpected error during install: $_" Error }
    finally {
        $Sync.Results = $results
        $Sync.Queue.Enqueue(@{ Type = 'InstallDone' })
    }
}

$lv.Add_ItemCheck({ param($s, $e) if ($Sync.Busy) { $e.NewValue = $e.CurrentValue } })
$lv.Add_ItemChecked({ Update-Buttons })

$btnClear.Add_Click({ foreach ($li in @($lv.CheckedItems)) { $li.Checked = $false } })

$btnInstall.Add_Click({
    $ids = @($lv.CheckedItems | ForEach-Object { $_.Name })
    if ($ids.Count -eq 0) { return }
    $names = ($ids | ForEach-Object { '  - ' + $Sync.Items[$_].Name }) -join "`r`n"
    $answer = [System.Windows.Forms.MessageBox]::Show("Install the following packages?`r`n`r`n$names", '.NET Installer', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $Sync.Selected = $ids
    $Sync.Busy     = $true
    Update-Buttons
    $btnClose.Enabled = $false
    $progress.Style   = 'Continuous'
    $progress.Value   = 0
    Write-Log "Selected: $($ids -join ', ')"
    Start-Worker $InstallWorker
})

$btnClose.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    param($s, $e)
    if ($Sync.Busy -and $Sync.Selected.Count -gt 0 -and -not $btnClose.Enabled) {
        [void][System.Windows.Forms.MessageBox]::Show('Please wait until the current installation finishes.', '.NET Installer', 'OK', 'Information')
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
            'Item'     { Set-ItemRow $msg }
            'Progress' { $progress.Value = [Math]::Min(100, $msg.Value); $lblStatus.Text = $msg.Text }
            'LoadDone' {
                $Sync.Busy = $false
                $progress.Style = 'Continuous'; $progress.Value = 0
                $lblStatus.Text = 'Ready. Check packages and click Install selected.'
                Update-Buttons
            }
            'InstallDone' {
                foreach ($k in $Sync.Results.Keys) { $script:AllResults[$k] = $Sync.Results[$k] }
                $Sync.Selected = @()
                $Sync.Busy = $false
                foreach ($li in @($lv.CheckedItems)) { $li.Checked = $false }
                $btnClose.Enabled = $true
                Update-Buttons
                $code = Get-OverallExitCode $Sync.Results
                $summary = ($Sync.Results.GetEnumerator() | Sort-Object Key | ForEach-Object { '  {0}: {1}' -f $Sync.Items[$_.Key].Name, (Get-FriendlyResult $_.Value) }) -join "`r`n"
                Write-Log "Batch finished (exit code $code)."
                $lblStatus.Text = 'Finished.'
                $icon = 'Information'; $extra = ''
                if ($code -eq 1603) { $icon = 'Error'; $extra = "`r`n`r`nLog: $($Sync.LogFile)" }
                if ($code -eq 3010) { $icon = 'Warning'; $extra = "`r`n`r`nA restart is required to complete the installation." }
                [void][System.Windows.Forms.MessageBox]::Show("Installation finished.`r`n`r`n$summary$extra", '.NET Installer', 'OK', $icon)
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
if ($script:AllResults.Count -eq 0) { Write-Log 'Closed without installing anything.' }
Set-Marker -ExitCode $exitCode -Results $script:AllResults
Write-Log "===== Finished: exit code $exitCode ====="
exit $exitCode
#endregion
