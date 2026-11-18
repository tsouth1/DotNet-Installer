# ConfigMgr detection script for Install-DotNet10Winget.ps1
# Install-DotNet10Winget.ps1 writes HKLM:\SOFTWARE\DotNetWingetInstaller\NET10\LastRunUtc after a successful run (exit 0 or 3010).
# The app reports "installed" only for $WindowMinutes after that run, so it shows as Installed right after the run
# but can be launched again from Software Center later.
# ConfigMgr treats any STDOUT output as "detected"; no output means "not detected".
$WindowMinutes = 60
try {
    $v = Get-ItemProperty -Path 'HKLM:\SOFTWARE\DotNetWingetInstaller\NET10' -Name LastRunUtc -ErrorAction Stop
    $last = [datetime]::Parse($v.LastRunUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    if (((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalMinutes -le $WindowMinutes) { 'Detected' }
}
catch { }
