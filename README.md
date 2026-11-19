# DotNet-Installer

A PowerShell GUI that installs or upgrades Microsoft .NET 6, 8, 9 and 10 packages with **winget**. It is built to be deployed as a Configuration Manager (SCCM/MECM) application that runs as SYSTEM, while the logged-on user picks which packages to install.

![.NET Installer GUI](docs/gui-screenshot.png)

## Files

| File | Purpose |
| --- | --- |
| `Install-DotNetWinget.ps1` | The original installer: a Windows Forms GUI, or a headless mode for unattended installs. It can install .NET 6, 8, 9 and 10. |
| `Detect-DotNetWinget.ps1` | ConfigMgr detection script that reads the registry marker the installer writes. |
| `Install-DotNet10Winget.ps1` | **.NET 10 edition.** Installs, upgrades and uninstalls .NET 10 only. See [.NET 10 / .NET 11 editions](#net-10--net-11-editions). |
| `Detect-DotNet10Winget.ps1` | Detection script for the .NET 10 edition. |
| `Install-DotNet11Winget.ps1` | **.NET 11 edition.** Installs, upgrades and uninstalls .NET 11 only. |
| `Detect-DotNet11Winget.ps1` | Detection script for the .NET 11 edition. |

## Supported packages

For each .NET major version (**10, 9, 8, 6**), the GUI lists five winget packages:

| Product | Winget ID pattern |
| --- | --- |
| .NET Runtime | `Microsoft.DotNet.Runtime.<major>` |
| .NET Desktop Runtime | `Microsoft.DotNet.DesktopRuntime.<major>` |
| ASP.NET Core Runtime | `Microsoft.DotNet.AspNetCore.<major>` |
| ASP.NET Core Hosting Bundle | `Microsoft.DotNet.HostingBundle.<major>` |
| .NET SDK | `Microsoft.DotNet.SDK.<major>` |

.NET 6 is labelled *out of support* in the GUI. To change the versions or products, edit the `$Majors`, `$Products` and `$OutOfSupport` values in the **Configuration** region at the top of the script.

## How it works

1. **Startup and logging**
   - The script opens a log file in CMTrace format, `DotNetWingetInstaller.log`. It uses the first folder it can write to: `%windir%\CCM\Logs`, then `%ProgramData%\DotNetWingetInstaller\Logs`, then `%TEMP%`.
   - It records who the script runs as and whether it is elevated. When it is not elevated, each install shows a UAC prompt.

2. **Finding winget**
   - The SYSTEM account has no `winget` alias on its PATH. So the script searches `Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe`, uses the newest version it finds, and only falls back to `winget.exe` on PATH if that search finds nothing.
   - It then runs `winget --version` to check that winget starts. If winget is missing or cannot start (often because a dependency such as VCLibs or UI.Xaml is missing for SYSTEM), the script shows an error and exits with code `1`.

3. **Reading versions (background thread)**
   - The installed versions come from `winget export --include-versions`. This returns clean JSON and avoids the column truncation in `winget list`.
   - The latest available version of each package comes from `winget show --id <Id> --exact --source winget`.
   - Each row then gets a status: **Up to date**, **Update available**, **Not installed** or **Not found in winget**.

4. **Selecting and installing**
   - The user checks the packages they want and clicks **Install selected**, then confirms.
   - The packages install one at a time, silently:
     ```
     winget install --id <Id> --exact --source winget --silent
            --accept-package-agreements --accept-source-agreements
            --disable-interactivity --log <LogDir>\winget_<Id>_<timestamp>.log
     ```
   - If a package is already installed, `winget install` upgrades it to the latest version.
   - While packages install, the progress bar, the status column and the log pane update live. The window cannot be closed until the batch finishes.
   - When the batch finishes, the script reads the installed versions again and shows a summary.

5. **Result mapping**
   - Each winget exit code is mapped to one of these results:

     | Winget exit code | Result |
     | --- | --- |
     | `0` | Installed |
     | `0x8A15002B`, `0x8A150061`, `0x8A15010D` | Already up to date |
     | `0x8A150109`, `0x8A15010A`, `3010`, `1641` | Installed, reboot required |
     | anything else | Failed |

6. **Exit code and detection marker**
   - When the window closes, the script exits with the overall result:

     | Exit code | Meaning |
     | --- | --- |
     | `0` | Success, or nothing to do |
     | `3010` | Success, reboot required |
     | `1603` | One or more packages failed |
     | `1` | winget could not be used |

   - On `0` or `3010`, the script writes `LastRunUtc`, `LastExitCode` and `LastPackages` to `HKLM\SOFTWARE\DotNetWingetInstaller`.

### Threading model

WinForms runs on the main thread. The two slow jobs, reading versions and installing packages, run in separate STA runspaces, so the window stays responsive. The background threads share state with the window through a synchronized hashtable and send their log lines and row updates through a `ConcurrentQueue`. A 200 ms UI timer takes items off that queue and applies them to the window.

## Usage

### Interactive (GUI)

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install-DotNetWinget.ps1
```

### Headless / unattended

Pass one or more winget IDs to skip the GUI. Log output goes to the console and to the log file.

```powershell
.\Install-DotNetWinget.ps1 -PackageId Microsoft.DotNet.Runtime.8,Microsoft.DotNet.DesktopRuntime.8
```

## ConfigMgr deployment

1. Create an application with a **Script Installer** deployment type.
2. **Install program:** `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install-DotNetWinget.ps1`
3. **User experience:** *Install for system*, *Whether or not a user is logged on* (or *Only when a user is logged on*), and enable **Allow users to view and interact with the program installation**.
4. **Return codes:** keep the defaults (`0` success, `3010` soft reboot, `1603` failure) and add `1` as a failure.
5. **Detection method:** use the custom script `Detect-DotNetWinget.ps1`.

### How detection works

`Detect-DotNetWinget.ps1` reports the application as **installed** only for 60 minutes after a successful run, based on `LastRunUtc`. That window is set by `$WindowMinutes`. Because of this, Software Center shows the app as installed right after a run, and users can launch it again later to install more packages or pick up updates.

## .NET 10 / .NET 11 editions

`Install-DotNet10Winget.ps1` and `Install-DotNet11Winget.ps1` are the same script. They differ only in `$TargetMajor`, at the top of the file. Each edition works with **only its own .NET version**. Other .NET versions cannot be installed, and they are not listed.

The window has a single list with two groups:

- **Install .NET 10 (or 11):** the five winget packages (Runtime, Desktop Runtime, ASP.NET Core Runtime, Hosting Bundle, SDK). Each row shows the latest version in winget and the installed version. Check one or more packages and click **Install**. Packages that are already installed are upgraded to the latest version.
- **Installed .NET 10 (or 11) on this device:** every 10.x (or 11.x) runtime, Hosting Bundle and SDK already on the device. Checking an installed entry shows the red **Uninstall** button.

![.NET 10 edition with an installed runtime checked](docs/gui-net10.png)

<details><summary>.NET 11 edition</summary>

![.NET 11 edition](docs/gui-net11.png)

</details>

### How installed versions are found

1. **Add/Remove Programs:** The script reads the uninstall registry keys, both 64-bit and `WOW6432Node`. It keeps only the visible .NET bundle entries of the target version and skips the hidden `SystemComponent` MSI parts.
2. **Files on disk:** The script lists `Program Files\dotnet\shared\*` and `\sdk`, plus the `(x86)` folders. A runtime or SDK of the target version that no uninstall entry accounts for is shown as **No uninstaller (part of VS or an SDK)**.

| Installed entry | Checkbox |
| --- | --- |
| Standalone install (Runtime, Desktop Runtime, ASP.NET Core, Hosting Bundle, SDK) | ✅ Can be uninstalled |
| SDK installed by Visual Studio ("from Visual Studio") | ⬜ Information only. Remove it with the Visual Studio Installer. |
| Files on disk with no uninstall entry | ⬜ Information only. Remove it with the product that installed it. |

Uninstalling runs the entry's registered `QuietUninstallString` with `/norestart /log <LogDir>\uninstall_*.log`. For an MSI entry it runs `msiexec /x {GUID} /qn /norestart`. Exit codes `1605`/`1614` (product not installed) count as *already uninstalled*. After each batch, the list is scanned again.

### Colour scheme

The window uses a light body, a pale blue package list with dark text, and dark buttons with white text: navy for **Install**, red for **Uninstall** and slate for **Clear selection** and **Close**. All colours are hex values in the `$Theme` table at the top of the script.

### Usage

```powershell
# GUI
powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install-DotNet10Winget.ps1

# Headless install (only .NET 10 IDs are accepted)
.\Install-DotNet10Winget.ps1 -PackageId Microsoft.DotNet.Runtime.10,Microsoft.DotNet.DesktopRuntime.10
```

Each edition writes its own log (`DotNet10WingetInstaller.log` / `DotNet11WingetInstaller.log`) and its own detection marker (`HKLM\SOFTWARE\DotNetWingetInstaller\NET10` / `NET11`). Use the matching `Detect-DotNet10Winget.ps1` / `Detect-DotNet11Winget.ps1` as the ConfigMgr detection script. The exit codes are the same as in the original script.

## Requirements

- Windows 10/11 with **App Installer (winget)** provisioned for the device.
- Windows PowerShell 5.1.
- Administrator rights or SYSTEM context to install without UAC prompts.

## License

See [LICENSE](LICENSE).
