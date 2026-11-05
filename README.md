# Double Commander as the Windows 11 file manager

[DoubleCommanderDefault.ps1](DoubleCommanderDefault.ps1) is the complete tool. Copy that one file anywhere and run it from a normal PowerShell session as your Windows account. Supports built-in Windows PowerShell 5.1 and PowerShell 7. Double Commander must already be installed; portable installations work too.

```powershell
# Preview enabling folder/drive opening and Win+E.
.\DoubleCommanderDefault.ps1 -Action Enable -WhatIf

# Enable both.
.\DoubleCommanderDefault.ps1 -Action Enable

# Inspect settings (also the default when run without arguments).
.\DoubleCommanderDefault.ps1 -Action Status

# Restore the previous settings for both.
.\DoubleCommanderDefault.ps1 -Action Disable
```

Manage either feature independently:

```powershell
.\DoubleCommanderDefault.ps1 -Action Enable -Feature Folders
.\DoubleCommanderDefault.ps1 -Action Disable -Feature Hotkey

# Specify an executable for a portable or nonstandard installation.
.\DoubleCommanderDefault.ps1 -Action Enable `
    -DoubleCommanderPath 'D:\Portable Apps\Double Commander\doublecmd.exe'
```

`Folders` covers filesystem directories and drives. `Hotkey` covers Win+E through Explorer's launch CLSID. `All` is the default. Automatic executable discovery checks App Paths, conventional installation directories, and PATH. Once enabled, omitting the executable keeps the feature's saved path; a newly enabled feature inherits an existing feature's path. Paths with spaces, apostrophes, and Unicode are supported. Paths containing `%` are rejected because the Windows shell interprets percent placeholders in association commands.

The script calls `doublecmd.exe` directly: no console window, launcher, resident process, PowerShell installation, administrator rights, or extra runtime files. Double Commander's `-C` activates an existing instance; folder requests also use `-T` to open a new tab in the active panel. Its executable path is stored in the registry, so moving this script afterwards is fine. If you move or uninstall Double Commander, disable first or enable again with its new path.

## Restoration and recovery

Before changing registry values, the script saves a rollback journal in `%LOCALAPPDATA%\DoubleCommanderDefault\pending.json`. The active backup is `state.json` in the same directory. Keep these files while integration is enabled. Backups preserve each previous per-user value's data and type, distinguish missing from empty values, and track newly created registry keys.

`Disable` restores the configuration from before `Enable`. On a stock installation that restores Explorer; if a different file manager was already configured, that configuration returns. Existing machine-wide settings are never modified. Repeated enabling preserves the original backup, including when you change Double Commander's path.

Registry writes are verified. Ordinary errors trigger rollback. After an interrupted operation, new enable/disable operations are blocked until you run:

```powershell
.\DoubleCommanderDefault.ps1 -Action Recover -WhatIf
.\DoubleCommanderDefault.ps1 -Action Recover
```

Recovery rolls back the **entire pending operation**, including both features if that operation changed both. It also works if the current state file is damaged, provided the journal is intact. A damaged or missing backup cannot be reconstructed automatically; validation failures stop the script instead of guessing earlier settings.

If another tool changes a managed value, `Status` reports `ChangedExternally`, and enable/disable stops before writing. After reviewing the change, explicitly overwrite it with `-Force`:

```powershell
# Restore the original backup despite intervening registry changes.
.\DoubleCommanderDefault.ps1 -Action Disable -Force

# Repair the enabled configuration, retaining the original backup.
.\DoubleCommanderDefault.ps1 -Action Enable -Force

# Resolve an intervening change during recovery.
.\DoubleCommanderDefault.ps1 -Action Recover -Force
```

`-Force` never bypasses backup validation. An account-specific mutex prevents concurrent instances of this script. Other applications can still write the registry; the script detects conflicts and verifies its own writes, but this is not a Windows registry transaction across competing applications or a guarantee against storage failure.

`Status` returns PowerShell objects with the feature state, executable availability, changed values, backup path, and pending recovery flag. `NotManaged` means this script has no active backup for that feature; it does not assert that nobody else has customized it. Errors terminate the script and produce a nonzero exit code when invoked with `powershell.exe -File` or `pwsh -File`.

## Windows behavior and limits

Windows 11 has no general Default Apps setting for replacing every Explorer entry point. This script sets per-user `Directory`/`Drive` shell `open` commands and their default verb, plus an optional Explorer launch CLSID override. It sends the shell association-change notification after a successful change. If Windows has cached the old behavior, sign out and back in; the script does not forcibly restart Explorer.

The Win+E hook uses `{52205fd8-5dfb-447d-801a-d0b52f2e83e1}\shell\opennewwindow\command`. This is **undocumented Windows behavior**, inherited conceptually from the reference project's registry approach. Windows updates may change it. It can also redirect Explorer's other new-window launch entry points. Keyboard remappers such as PowerToys can intercept Win+E independently and take precedence.

The desktop/taskbar shell, file open/save dialogs, virtual folders such as Recycle Bin and This PC, Explorer's internal navigation, and applications explicitly launching Explorer can continue to use Explorer. This script intentionally targets filesystem directories and drives rather than the broad `Folder` class that also includes virtual objects. It does not modify Winlogon, use image-execution interception, or bypass Windows default-app protections.

For directory arguments, the registered command uses `"%1\."`: the final dot keeps drive roots and other paths ending in `\` from escaping their closing command-line quote. `.` resolves to the same directory. No requested path is evaluated as PowerShell or passed through `cmd.exe`.

If local execution policy blocks a downloaded script, inspect it and use `Unblock-File -LiteralPath .\DoubleCommanderDefault.ps1` if appropriate for your environment. The tool does not change execution policy or bypass organization policy. Built-in help is available with `Get-Help .\DoubleCommanderDefault.ps1 -Full`.

## Development verification

```powershell
.\tests\DoubleCommanderDefault.Tests.ps1
powershell.exe -NoProfile -NonInteractive -File .\tests\DoubleCommanderDefault.Tests.ps1
```

The dependency-free integration suite loads the production functions into an isolated registry subtree and temporary directory. It exercises feature independence, dry runs, idempotency, all supported registry value types, backup validation, external conflicts, unrelated-data preservation, failed writes, failed state-file saves, and interrupted-operation recovery. It launches no applications and does not modify real shell associations. Interactive Explorer/Win+E behavior still needs checking on the intended Windows build after enabling.

Verified on Windows build 26200 with **103 assertions passing in each of PowerShell 7.6.5 and Windows PowerShell 5.1.26100.9711**. The standalone script's Status and Enable `-WhatIf` entry points were also checked; discovery found the installed `C:\Program Files\Double Commander\doublecmd.exe`.

## Design references

Implementation written from scratch. Requested functionality was informed by [domportera/doublecmd-default-on-windows](https://github.com/domportera/doublecmd-default-on-windows).

- [Double Commander command-line options](https://doublecmd.github.io/doc/en/commandline.html): native instance activation and new tabs.
- [Microsoft: extending shell shortcut menus](https://learn.microsoft.com/en-us/windows/win32/shell/context): verbs and quoted association commands.
- [Microsoft: merged HKEY_CLASSES_ROOT view](https://learn.microsoft.com/en-us/windows/win32/sysinfo/merged-view-of-hkey-classes-root): per-user versus machine registrations.
- [Microsoft: SHChangeNotify](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shchangenotify): association-change notifications.
