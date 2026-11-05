#Requires -Version 5.1
<#
.SYNOPSIS
Enables or restores Double Commander folder/drive associations and Win+E for this user.
.DESCRIPTION
Windows 11; Windows PowerShell 5.1 or PowerShell 7. No elevation, downloads,
resident process, execution-policy changes, or helper scripts are required.
The default action is Status. Folders and Hotkey can be managed independently.

Before writing the registry, saves a durable rollback journal under
%LOCALAPPDATA%\DoubleCommanderDefault. Disable restores the exact previous
per-user values, including their types and absence. Do not delete this backup
while enabled. If interrupted, use Recover to roll back the pending operation.

This changes filesystem directory/drive shell opening, not the desktop shell,
file dialogs, virtual folders, or every application that explicitly runs Explorer.
The Win+E CLSID hook is undocumented and can change in future Windows updates;
it can also affect File Explorer's "new window" entry points.
.PARAMETER Action
Enable, Disable, Status (default), or Recover (roll back an interrupted operation).
.PARAMETER Feature
All (default), Folders (directories and drives), or Hotkey (Win+E).
.PARAMETER DoubleCommanderPath
Full path to doublecmd.exe, including a portable installation. Otherwise searches
    App Paths, standard installation locations, and PATH. An already managed
    feature keeps its saved executable path when this parameter is omitted.
    Used only by Enable.
.PARAMETER Force
Overwrite values changed since Enable, or conflicts during Recover. The original
backup is retained when repairing with Enable. Never bypasses backup validation.
.EXAMPLE
.\DoubleCommanderDefault.ps1 -Action Enable -WhatIf
.EXAMPLE
.\DoubleCommanderDefault.ps1 -Action Enable
.EXAMPLE
.\DoubleCommanderDefault.ps1 -Action Enable -Feature Hotkey -DoubleCommanderPath 'D:\Apps\Double Commander\doublecmd.exe'
.EXAMPLE
.\DoubleCommanderDefault.ps1 -Action Disable
.EXAMPLE
.\DoubleCommanderDefault.ps1 -Action Recover
.NOTES
Run as your normal Windows account. Disable restores the configuration from
before Enable; if another file manager was already the default, it is restored.
Exit: terminating error on failure; Status returns structured objects.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Enable', 'Disable', 'Status', 'Recover')]
    [string] $Action = 'Status',
    [ValidateSet('All', 'Folders', 'Hotkey')]
    [string] $Feature = 'All',
    [string] $DoubleCommanderPath,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-Context {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This script requires Windows.'
    }
    if ([Environment]::OSVersion.Version.Build -lt 22000) {
        throw 'This script targets Windows 11 (build 22000 or later).'
    }
    $script:OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:View = if ([Environment]::Is64BitOperatingSystem) { 'Registry64' } else { 'Registry32' }
    $script:UserRegistry = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', $script:View)
    $script:ClassesPrefix = 'Software\Classes'
    $script:DataDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DoubleCommanderDefault'
    $script:StateFile = Join-Path $script:DataDirectory 'state.json'
    $script:JournalFile = Join-Path $script:DataDirectory 'pending.json'
}

function Get-Specifications {
    param([string] $Name)
    if ($Name -eq 'Folders') {
        foreach ($class in 'Directory', 'Drive') {
            [pscustomobject]@{ Key = "$script:ClassesPrefix\$class\shell"; Name = ''; Role = 'Verb' }
            [pscustomobject]@{ Key = "$script:ClassesPrefix\$class\shell\open\command"; Name = ''; Role = 'FolderCommand' }
            # An empty override suppresses a machine-level COM delegate.
            [pscustomobject]@{ Key = "$script:ClassesPrefix\$class\shell\open\command"; Name = 'DelegateExecute'; Role = 'Delegate' }
        }
    } else {
        $key = "$script:ClassesPrefix\CLSID\{52205fd8-5dfb-447d-801a-d0b52f2e83e1}\shell\opennewwindow\command"
        [pscustomobject]@{ Key = $key; Name = ''; Role = 'HotkeyCommand' }
        [pscustomobject]@{ Key = $key; Name = 'DelegateExecute'; Role = 'Delegate' }
    }
}

function Get-ValueSnapshot {
    param([string] $Key, [string] $Name)
    $handle = $script:UserRegistry.OpenSubKey($Key)
    try {
        if ($null -eq $handle -or $handle.GetValueNames() -notcontains $Name) {
            return [pscustomobject]@{ Exists = $false; Kind = $null; Data = $null }
        }
        $kind = $handle.GetValueKind($Name).ToString()
        $data = $handle.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        switch ($kind) {
            { $_ -in 'Binary', 'None' } { $data = [Convert]::ToBase64String([byte[]]$data) }
            { $_ -in 'DWord', 'QWord' } { $data = $data.ToString([Globalization.CultureInfo]::InvariantCulture) }
            'MultiString' { $data = @($data) }
        }
        return [pscustomobject]@{ Exists = $true; Kind = $kind; Data = $data }
    } finally { if ($null -ne $handle) { $handle.Dispose() } }
}

function Set-ValueSnapshot {
    param([string] $Key, [string] $Name, $Snapshot)
    if (-not $Snapshot.Exists) {
        $handle = $script:UserRegistry.OpenSubKey($Key, $true)
        try { if ($null -ne $handle) { $handle.DeleteValue($Name, $false); $handle.Flush() } }
        finally { if ($null -ne $handle) { $handle.Dispose() } }
        return
    }
    $data = $Snapshot.Data
    switch ($Snapshot.Kind) {
        { $_ -in 'Binary', 'None' } { $data = [Convert]::FromBase64String($data) }
        'DWord' { $data = [int]::Parse($data, [Globalization.CultureInfo]::InvariantCulture) }
        'QWord' { $data = [long]::Parse($data, [Globalization.CultureInfo]::InvariantCulture) }
        'MultiString' { $data = [string[]]@($data) }
    }
    $handle = $script:UserRegistry.CreateSubKey($Key)
    try { $handle.SetValue($Name, $data, [Microsoft.Win32.RegistryValueKind]$Snapshot.Kind); $handle.Flush() }
    finally { $handle.Dispose() }
}

function Test-SnapshotEqual {
    param($Left, $Right)
    # Ordered properties and normalized data make comparison independent of JSON formatting.
    $a = [ordered]@{ Exists = $Left.Exists; Kind = $Left.Kind; Data = $Left.Data }
    $b = [ordered]@{ Exists = $Right.Exists; Kind = $Right.Kind; Data = $Right.Data }
    return (ConvertTo-Json -InputObject $a -Depth 5 -Compress) -ceq (ConvertTo-Json -InputObject $b -Depth 5 -Compress)
}

function Assert-Snapshot {
    param($Snapshot)
    if ($Snapshot.Exists -isnot [bool]) { throw 'Invalid backup: snapshot presence flag.' }
    if (-not $Snapshot.Exists) {
        if ($null -ne $Snapshot.Kind -or $null -ne $Snapshot.Data) { throw 'Invalid absent snapshot.' }
        return
    }
    switch -Exact ($Snapshot.Kind) {
        { $_ -in 'String', 'ExpandString' } {
            if ($Snapshot.Data -isnot [string]) { throw 'Invalid string snapshot.' }
        }
        'MultiString' {
            if ($Snapshot.Data -isnot [array]) { throw 'Invalid multi-string snapshot.' }
            foreach ($item in $Snapshot.Data) { if ($item -isnot [string]) { throw 'Invalid multi-string item.' } }
        }
        { $_ -in 'Binary', 'None' } { $null = [Convert]::FromBase64String($Snapshot.Data) }
        'DWord' { $null = [int]::Parse($Snapshot.Data, [Globalization.CultureInfo]::InvariantCulture) }
        'QWord' { $null = [long]::Parse($Snapshot.Data, [Globalization.CultureInfo]::InvariantCulture) }
        default { throw 'Invalid backup: unsupported registry value kind.' }
    }
}

function Get-KeyAncestors {
    param([string] $Key)
    while ($Key.StartsWith("$script:ClassesPrefix\", [StringComparison]::OrdinalIgnoreCase)) {
        $Key
        $Key = $Key.Substring(0, $Key.LastIndexOf('\'))
    }
}

function Get-MissingKeys {
    param($Specifications)
    @($Specifications | ForEach-Object {
        foreach ($key in (Get-KeyAncestors $_.Key)) {
            $handle = $script:UserRegistry.OpenSubKey($key)
            if ($null -eq $handle) { $key } else { $handle.Dispose() }
        }
    } | Sort-Object -Unique)
}

function Remove-EmptyCreatedKeys {
    param([object[]] $Keys)
    foreach ($key in @($Keys | Sort-Object -Unique | Sort-Object { $_.Length } -Descending)) {
        $handle = $script:UserRegistry.OpenSubKey($key)
        if ($null -eq $handle) { continue }
        try { $empty = $handle.ValueCount -eq 0 -and $handle.SubKeyCount -eq 0 }
        finally { $handle.Dispose() }
        if ($empty) {
            # Non-recursive: unrelated values/subkeys are never removed.
            $script:UserRegistry.DeleteSubKey($key, $false)
        }
    }
    $script:UserRegistry.Flush()
}

function New-State {
    [pscustomobject]@{ Schema = 1; OwnerSid = $script:OwnerSid; RegistryView = $script:View; Features = @() }
}

function Assert-State {
    param($State)
    if ($State.Schema -ne 1 -or $State.OwnerSid -cne $script:OwnerSid -or $State.RegistryView -cne $script:View) {
        throw 'Backup schema, Windows account, or registry view does not match. No changes made.'
    }
    if ($State.Features -isnot [array]) { throw 'Invalid backup: feature list.' }
    $seen = @()
    foreach ($saved in $State.Features) {
        if ($saved.Name -notin 'Folders', 'Hotkey' -or $saved.Name -in $seen) { throw 'Invalid backup feature.' }
        $seen += $saved.Name
        $specs = @(Get-Specifications $saved.Name)
        if ($saved.Values -isnot [array] -or $saved.Values.Count -ne $specs.Count) { throw 'Invalid backup value list.' }
        for ($i = 0; $i -lt $specs.Count; $i++) {
            $value = $saved.Values[$i]
            if ($value.Key -cne $specs[$i].Key -or $value.Name -cne $specs[$i].Name) { throw 'Invalid backup registry target.' }
            Assert-Snapshot $value.Original
            Assert-Snapshot $value.Applied
        }
        $allowed = @($specs | ForEach-Object { Get-KeyAncestors $_.Key })
        if ($saved.CreatedKeys -isnot [array]) { throw 'Invalid backup key list.' }
        foreach ($key in $saved.CreatedKeys) {
            if ($key -cnotin $allowed) { throw 'Invalid backup cleanup target.' }
        }
    }
}

function Read-Json {
    param([string] $Path)
    try { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -ErrorAction Stop }
    catch { throw "Cannot read backup '$Path': $($_.Exception.Message). Preserve the file for recovery." }
}

function Write-AtomicJson {
    param([string] $Path, $Value)
    $null = [IO.Directory]::CreateDirectory($script:DataDirectory)
    $temporary = Join-Path $script:DataDirectory ([IO.Path]::GetRandomFileName())
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 30))
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) {
            # PowerShell otherwise converts $null to an empty string for this .NET overload.
            [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value)
        }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Assert-Journal {
    param($Journal)
    if ($Journal.Schema -ne 1) { throw 'Invalid recovery journal schema.' }
    Assert-State $Journal.BeforeState
    Assert-State $Journal.AfterState
    $allowed = @(Get-Specifications 'Folders') + @(Get-Specifications 'Hotkey')
    if ($Journal.Entries -isnot [array] -or $Journal.Entries.Count -gt $allowed.Count) { throw 'Invalid journal entries.' }
    $seen = @()
    foreach ($entry in $Journal.Entries) {
        $id = "$($entry.Key)|$($entry.Name)"
        if ($id -in $seen -or -not @($allowed | Where-Object { $_.Key -ceq $entry.Key -and $_.Name -ceq $entry.Name }).Count) {
            throw 'Invalid recovery registry target.'
        }
        $seen += $id
        Assert-Snapshot $entry.Before
        Assert-Snapshot $entry.After
    }
    $keys = @($allowed | ForEach-Object { Get-KeyAncestors $_.Key })
    if ($Journal.CreatedKeys -isnot [array] -or $Journal.CleanupKeys -isnot [array]) { throw 'Invalid recovery cleanup list.' }
    foreach ($key in @($Journal.CreatedKeys) + @($Journal.CleanupKeys)) {
        if ($key -cnotin $keys) { throw 'Invalid recovery cleanup target.' }
    }
}

function Restore-Journal {
    param($Journal, [switch] $OverwriteConflicts)
    Assert-Journal $Journal
    foreach ($entry in $Journal.Entries) {
        $current = Get-ValueSnapshot $entry.Key $entry.Name
        if (-not (Test-SnapshotEqual $current $entry.Before) -and
            -not (Test-SnapshotEqual $current $entry.After) -and -not $OverwriteConflicts) {
            throw "Recovery conflict at HKCU\$($entry.Key) [$($entry.Name)]. Review it, then use Recover -Force to overwrite it."
        }
    }
    foreach ($entry in $Journal.Entries) { Set-ValueSnapshot $entry.Key $entry.Name $entry.Before }
    Remove-EmptyCreatedKeys $Journal.CreatedKeys
    Write-AtomicJson $script:StateFile $Journal.BeforeState
    [IO.File]::Delete($script:JournalFile)
}

function Invoke-Transaction {
    param($BeforeState, $AfterState, [object[]] $Entries, [object[]] $CreatedKeys, [object[]] $CleanupKeys)
    $journal = [pscustomobject]@{
        Schema = 1; BeforeState = $BeforeState; AfterState = $AfterState
        Entries = @($Entries); CreatedKeys = @($CreatedKeys); CleanupKeys = @($CleanupKeys)
    }
    Assert-Journal $journal
    Write-AtomicJson $script:JournalFile $journal
    try {
        foreach ($entry in $Entries) {
            # Catch a competing writer between planning and applying this value.
            if (-not (Test-SnapshotEqual (Get-ValueSnapshot $entry.Key $entry.Name) $entry.Before)) {
                throw "Registry changed during the operation: HKCU\$($entry.Key)."
            }
            Set-ValueSnapshot $entry.Key $entry.Name $entry.After
        }
        foreach ($entry in $Entries) {
            if (-not (Test-SnapshotEqual (Get-ValueSnapshot $entry.Key $entry.Name) $entry.After)) {
                throw "Registry verification failed: HKCU\$($entry.Key)."
            }
        }
        Remove-EmptyCreatedKeys $CleanupKeys
        Write-AtomicJson $script:StateFile $AfterState
        [IO.File]::Delete($script:JournalFile)
    } catch {
        $failure = $_
        try { Restore-Journal $journal }
        catch { throw "Operation failed: $($failure.Exception.Message) Rollback incomplete: $($_.Exception.Message) Journal retained at '$script:JournalFile'. Run -Action Recover." }
        throw "Operation failed and was rolled back: $($failure.Exception.Message)"
    }
}

function Resolve-DoubleCommander {
    param([string] $ExplicitPath)
    if ($ExplicitPath) { $candidates = @([Environment]::ExpandEnvironmentVariables($ExplicitPath)) }
    else {
        $candidates = @(
            foreach ($hive in 'CurrentUser', 'LocalMachine') {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $script:View)
                try {
                    $key = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\App Paths\doublecmd.exe')
                    if ($null -ne $key) {
                        try { $key.GetValue('') } finally { $key.Dispose() }
                    }
                } finally { $base.Dispose() }
            }
            foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
                if ($root) { Join-Path $root 'Double Commander\doublecmd.exe' }
            }
            if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Double Commander\doublecmd.exe' }
            Get-Command doublecmd.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        )
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $file = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
        if ($null -ne $file -and $file -is [IO.FileInfo] -and $file.Name -ieq 'doublecmd.exe') {
            $path = $file.FullName
            # Shell placeholders (%1, %L, ...) must never occur inside the executable path.
            if ($path.Contains('%') -or $path.Contains('"') -or $path -match '[\r\n]') {
                throw 'The executable path cannot contain percent signs, quotes, or line breaks.'
            }
            return $path
        }
    }
    throw 'doublecmd.exe was not found. Supply -DoubleCommanderPath with its full executable path.'
}

function New-AppliedSnapshot {
    param([string] $Role, [string] $Executable)
    $data = switch ($Role) {
        'Verb' { 'open' }
        # Appending \. avoids a quoted drive-root argument ending in a backslash.
        'FolderCommand' { '"{0}" -C -T "%1\."' -f $Executable }
        'HotkeyCommand' { '"{0}" -C' -f $Executable }
        'Delegate' { '' }
    }
    [pscustomobject]@{ Exists = $true; Kind = 'String'; Data = $data }
}

function Send-AssociationNotification {
    try {
        if (-not ('DoubleCommanderDefault.NativeShell' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DoubleCommanderDefault {
    public static class NativeShell {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
    }
}
'@
        }
        [DoubleCommanderDefault.NativeShell]::SHChangeNotify(0x08000000, 0x3000, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { Write-Warning "Settings saved, but shell refresh failed: $($_.Exception.Message). Sign out and back in to refresh." }
}

function Get-Status {
    param($State, [string[]] $Names)
    foreach ($name in $Names) {
        $saved = @($State.Features | Where-Object { $_.Name -eq $name })
        $drift = @()
        $executable = $null
        if ($saved.Count) {
            $drift = @($saved[0].Values | Where-Object {
                -not (Test-SnapshotEqual (Get-ValueSnapshot $_.Key $_.Name) $_.Applied)
            })
            $executable = $saved[0].Executable
        }
        [pscustomobject]@{
            Feature = $name
            State = if (-not $saved.Count) { 'NotManaged' } elseif ($drift.Count) { 'ChangedExternally' } else { 'Enabled' }
            DoubleCommanderPath = $executable
            ExecutableExists = if ($executable) { [IO.File]::Exists($executable) } else { $null }
            ChangedValues = @($drift | ForEach-Object { "HKCU\$($_.Key) [$($_.Name)]" })
            RecoveryPending = [IO.File]::Exists($script:JournalFile)
            BackupFile = $script:StateFile
        }
    }
}

function Invoke-Main {
    Initialize-Context
    $mutex = $null
    $locked = $false
    try {
        $mutex = [Threading.Mutex]::new($false, "Global\DoubleCommanderDefault.$script:OwnerSid")
        try { $locked = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another DoubleCommanderDefault operation is running for this Windows account.' }
        if ($Action -ne 'Enable' -and $DoubleCommanderPath) { throw '-DoubleCommanderPath is only valid with Enable.' }
        if ($Action -eq 'Recover') {
            if (-not [IO.File]::Exists($script:JournalFile)) { Write-Verbose 'No pending operation to recover.'; return }
            $journal = Read-Json $script:JournalFile
            Assert-Journal $journal
            if ($PSCmdlet.ShouldProcess('current-user registry and backup', 'Roll back the entire pending operation')) {
                Restore-Journal $journal -OverwriteConflicts:$Force
                Send-AssociationNotification
                Get-Status $journal.BeforeState @('Folders', 'Hotkey')
            }
            return
        }
        $state = if ([IO.File]::Exists($script:StateFile)) { Read-Json $script:StateFile } else { New-State }
        Assert-State $state
        $names = if ($Feature -eq 'All') { @('Folders', 'Hotkey') } else { @($Feature) }
        if ($Action -eq 'Status') { Get-Status $state $names; return }
        if ([IO.File]::Exists($script:JournalFile)) {
            throw "An interrupted operation needs recovery. Run -Action Recover first. Journal: '$script:JournalFile'."
        }
        $requestedExecutable = if ($Action -eq 'Enable' -and $DoubleCommanderPath) {
            Resolve-DoubleCommander $DoubleCommanderPath
        } else { $null }
        # Clone so the durable journal retains an unmodified BeforeState.
        $after = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $state -Depth 30)
        $entries = @()
        $createdKeys = @()
        $cleanupKeys = @()
        foreach ($name in $names) {
            $saved = @($state.Features | Where-Object { $_.Name -eq $name })
            if ($Action -eq 'Disable' -and -not $saved.Count) { continue }
            $executable = $null
            if ($Action -eq 'Enable') {
                $executable = if ($requestedExecutable) { $requestedExecutable }
                elseif ($saved.Count) { Resolve-DoubleCommander $saved[0].Executable }
                elseif ($state.Features.Count) { Resolve-DoubleCommander $state.Features[0].Executable }
                else { Resolve-DoubleCommander }
            }
            if ($saved.Count) {
                foreach ($value in $saved[0].Values) {
                    $current = Get-ValueSnapshot $value.Key $value.Name
                    if (-not (Test-SnapshotEqual $current $value.Applied) -and -not $Force) {
                        throw "Settings changed outside this script: HKCU\$($value.Key) [$($value.Name)]. Review Status, then use -Force to overwrite the change."
                    }
                }
            }
            $specs = @(Get-Specifications $name)
            $createdKeys += @(Get-MissingKeys $specs)
            $values = @()
            for ($i = 0; $i -lt $specs.Count; $i++) {
                $spec = $specs[$i]
                $current = Get-ValueSnapshot $spec.Key $spec.Name
                $original = if ($saved.Count) { $saved[0].Values[$i].Original } else { $current }
                $desired = if ($Action -eq 'Enable') { New-AppliedSnapshot $spec.Role $executable } else { $original }
                if (-not (Test-SnapshotEqual $current $desired)) {
                    $entries += [pscustomobject]@{ Key = $spec.Key; Name = $spec.Name; Before = $current; After = $desired }
                }
                $values += [pscustomobject]@{ Key = $spec.Key; Name = $spec.Name; Original = $original; Applied = $desired }
            }
            $after.Features = @($after.Features | Where-Object { $_.Name -ne $name })
            if ($Action -eq 'Enable') {
                $featureKeys = @(if ($saved.Count) { $saved[0].CreatedKeys } else { Get-MissingKeys $specs })
                $after.Features += [pscustomobject]@{ Name = $name; Executable = $executable; Values = $values; CreatedKeys = $featureKeys }
            } else { $cleanupKeys += @($saved[0].CreatedKeys) }
        }
        $after.Features = @($after.Features | Sort-Object Name)
        $stateChanged = (ConvertTo-Json -InputObject $state -Depth 30 -Compress) -cne (ConvertTo-Json -InputObject $after -Depth 30 -Compress)
        if ($entries.Count -eq 0 -and -not $stateChanged) { Get-Status $state $names; return }
        $description = "$Action Double Commander integration ($($entries.Count) registry values)"
        if ($Action -eq 'Enable') {
            $paths = @($after.Features | Where-Object { $_.Name -in $names } | Select-Object -ExpandProperty Executable -Unique)
            $description += ": $($paths -join '; ')"
        }
        if ($PSCmdlet.ShouldProcess("current user: $($names -join ', ')", $description)) {
            Invoke-Transaction $state $after $entries @($createdKeys | Sort-Object -Unique) @($cleanupKeys | Sort-Object -Unique)
            Send-AssociationNotification
            Get-Status $after $names
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
        $script:UserRegistry.Dispose()
    }
}

Invoke-Main
