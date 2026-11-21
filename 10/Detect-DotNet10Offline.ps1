# ConfigMgr detection script for Install-DotNet10Offline.ps1 (GUI deployment)
# Install-DotNet10Offline.ps1 writes HKLM:\SOFTWARE\DotNetOfflineInstaller\NET10\LastRunUtc after a successful run (exit 0 or 3010).
# The app reports "installed" only for $WindowMinutes after that run, so it shows as Installed right after the run
# but can be launched again from Software Center later.
# For per-package (headless) deployment types, use a registry detection on the package ProductCode instead (see README).
# ConfigMgr treats any STDOUT output as "detected"; no output means "not detected".
$WindowMinutes = 60
try {
    $v = Get-ItemProperty -Path 'HKLM:\SOFTWARE\DotNetOfflineInstaller\NET10' -Name LastRunUtc -ErrorAction Stop
    $last = [datetime]::Parse($v.LastRunUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    if (((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalMinutes -le $WindowMinutes) { 'Detected' }
}
catch { }
