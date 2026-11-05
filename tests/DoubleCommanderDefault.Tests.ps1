#Requires -Version 5.1
# Dependency-free integration tests. No real shell associations are changed and no apps are launched.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Assertions = 0
$script:TestId = [Guid]::NewGuid().ToString('N')
$script:TestRegistryPath = "Software\DoubleCommanderDefault.Tests\$script:TestId"
$script:Sandbox = Join-Path $PSScriptRoot ".sandbox.$script:TestId"
$script:FixtureData = Join-Path $script:Sandbox 'backup'
$script:FixtureExe = Join-Path $script:Sandbox "Double Commander O'Brien unicode-$([char]0x00FC)\doublecmd.exe"
$script:ActualRegistry = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64')

# Load only function declarations, never the production entry point.
$tokens = $null
$errors = $null
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'DoubleCommanderDefault.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($node.Extent.Text))
    }
}

# Redirect the same production code to a disposable registry subtree and filesystem directory.
function Initialize-Context {
    $script:OwnerSid = "Test.$script:TestId"
    $script:View = 'Registry64'
    $script:ClassesPrefix = 'Classes'
    $script:UserRegistry = $script:ActualRegistry.CreateSubKey($script:TestRegistryPath)
    $script:DataDirectory = $script:FixtureData
    $script:StateFile = Join-Path $script:DataDirectory 'state.json'
    $script:JournalFile = Join-Path $script:DataDirectory 'pending.json'
}
function Send-AssociationNotification { }

function Assert {
    param([bool] $Condition, [string] $Message)
    $script:Assertions++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws {
    param([scriptblock] $Code, [string] $Pattern)
    $caught = $null
    try { & $Code | Out-Null } catch { $caught = $_ }
    Assert ($null -ne $caught) "Expected failure matching '$Pattern'"
    Assert ($caught.Exception.Message -match $Pattern) "Unexpected failure: $caught"
}
function Invoke-TestAction {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Action, [string] $Feature = 'All', [switch] $Force, [string] $DoubleCommanderPath = $script:FixtureExe)
    if ($Action -ne 'Enable') { $DoubleCommanderPath = $null }
    Invoke-Main
}
function With-Context {
    param([scriptblock] $Code)
    Initialize-Context
    try { & $Code } finally { $script:UserRegistry.Dispose() }
}
function Reset-Fixture {
    $script:ActualRegistry.DeleteSubKeyTree($script:TestRegistryPath, $false)
    if (Test-Path -LiteralPath $script:FixtureData) {
        $full = [IO.Path]::GetFullPath($script:FixtureData)
        if (-not $full.StartsWith($script:Sandbox + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup.' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
function Get-AllSnapshots {
    With-Context {
        foreach ($spec in @((Get-Specifications 'Folders')) + @((Get-Specifications 'Hotkey'))) {
            Get-ValueSnapshot $spec.Key $spec.Name
        }
    }
}

try {
    $null = [IO.Directory]::CreateDirectory((Split-Path $script:FixtureExe -Parent))
    [IO.File]::WriteAllText($script:FixtureExe, 'Test fixture only; never execute.')
    Reset-Fixture

    $result = @(Invoke-TestAction Status)
    Assert ($result.Count -eq 2 -and @($result | Where-Object State -ne 'NotManaged').Count -eq 0) 'Fresh status'
    Assert (-not [IO.Directory]::Exists($script:FixtureData)) 'Status does not create backup files'
    Invoke-TestAction Enable -WhatIf | Out-Null
    Assert (-not [IO.Directory]::Exists($script:FixtureData)) 'WhatIf does not create backup files'
    Assert (@((Get-AllSnapshots) | Where-Object Exists).Count -eq 0) 'WhatIf does not write registry values'

    $result = @(Invoke-TestAction Enable)
    Assert (@($result | Where-Object State -eq 'Enabled').Count -eq 2) 'Both features enabled'
    $firstBackup = [IO.File]::ReadAllText($script:StateFile)
    Invoke-TestAction Enable | Out-Null
    Assert ([IO.File]::ReadAllText($script:StateFile) -ceq $firstBackup) 'Repeated enable keeps original backup'
    Invoke-TestAction Enable -DoubleCommanderPath '' | Out-Null
    Assert ([IO.File]::ReadAllText($script:StateFile) -ceq $firstBackup) 'Omitted executable preserves saved portable path'
    Invoke-TestAction Disable -WhatIf | Out-Null
    Assert (@((Invoke-TestAction Status) | Where-Object State -eq 'Enabled').Count -eq 2) 'Disable WhatIf is read-only'
    Invoke-TestAction Disable -Feature Hotkey | Out-Null
    $result = @(Invoke-TestAction Status)
    Assert ($result[0].State -eq 'Enabled' -and $result[1].State -eq 'NotManaged') 'Independent hotkey disable'
    Invoke-TestAction Disable | Out-Null
    Assert (@((Get-AllSnapshots) | Where-Object Exists).Count -eq 0) 'Originally absent values removed'
    With-Context {
        Assert ($script:UserRegistry.GetSubKeyNames().Count -eq 1) 'Only synthetic Classes root remains'
        $root = $script:UserRegistry.OpenSubKey('Classes')
        try { Assert ($root.SubKeyCount -eq 0) 'All created descendants removed, including equal-length keys' }
        finally { $root.Dispose() }
    }
    Invoke-TestAction Disable | Out-Null
    Assert (-not [IO.File]::Exists($script:JournalFile)) 'Repeated disable leaves no journal'

    # Every supported value kind, including empty string versus missing and 64-bit precision.
    Reset-Fixture
    $originals = @(
        [pscustomobject]@{ Exists = $true; Kind = 'String'; Data = '' },
        [pscustomobject]@{ Exists = $true; Kind = 'ExpandString'; Data = '%TEMP%\original' },
        [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Data = '-1' },
        [pscustomobject]@{ Exists = $true; Kind = 'QWord'; Data = '9223372036854775807' },
        [pscustomobject]@{ Exists = $true; Kind = 'MultiString'; Data = @('one', "two-$([char]0x00FC)") },
        [pscustomobject]@{ Exists = $true; Kind = 'Binary'; Data = 'AAEC/w==' },
        [pscustomobject]@{ Exists = $true; Kind = 'None'; Data = 'AP8=' },
        [pscustomobject]@{ Exists = $false; Kind = $null; Data = $null }
    )
    With-Context {
        $specs = @(Get-Specifications 'Folders') + @(Get-Specifications 'Hotkey')
        for ($i = 0; $i -lt $specs.Count; $i++) { Set-ValueSnapshot $specs[$i].Key $specs[$i].Name $originals[$i] }
    }
    Invoke-TestAction Enable | Out-Null
    Invoke-TestAction Disable | Out-Null
    $restored = @(Get-AllSnapshots)
    for ($i = 0; $i -lt $originals.Count; $i++) { Assert (Test-SnapshotEqual $restored[$i] $originals[$i]) "Exact type restoration $i" }

    Reset-Fixture
    Invoke-TestAction Enable -Feature Folders | Out-Null
    With-Context {
        $key = $script:UserRegistry.CreateSubKey('Classes\Directory\shell\open\command')
        try { $key.SetValue('Unrelated', 'keep me') } finally { $key.Dispose() }
        $key = $script:UserRegistry.CreateSubKey('Classes\Drive\shell\open\command\OtherApp')
        $key.Dispose()
    }
    Invoke-TestAction Disable | Out-Null
    With-Context {
        $key = $script:UserRegistry.OpenSubKey('Classes\Directory\shell\open\command')
        try { Assert ($key.GetValue('Unrelated') -eq 'keep me') 'Preserve unrelated values' } finally { $key.Dispose() }
        $key = $script:UserRegistry.OpenSubKey('Classes\Drive\shell\open\command\OtherApp')
        try { Assert ($null -ne $key) 'Preserve unrelated subkeys' } finally { if ($key) { $key.Dispose() } }
    }

    Reset-Fixture
    Invoke-TestAction Enable | Out-Null
    $foreign = [pscustomobject]@{ Exists = $true; Kind = 'String'; Data = 'another program' }
    With-Context { Set-ValueSnapshot 'Classes\Directory\shell' '' $foreign }
    $result = @(Invoke-TestAction Status)
    Assert ($result[0].State -eq 'ChangedExternally' -and $result[0].ChangedValues.Count -eq 1) 'Detect external changes'
    Assert-Throws { Invoke-TestAction Disable } 'changed outside'
    Assert-Throws { Invoke-TestAction Enable } 'changed outside'
    Invoke-TestAction Enable -Force | Out-Null
    Invoke-TestAction Disable | Out-Null
    Assert (@((Get-AllSnapshots) | Where-Object Exists).Count -eq 0) 'Force repair preserves original baseline'

    Reset-Fixture
    Invoke-TestAction Enable -Feature Hotkey | Out-Null
    Invoke-TestAction Enable -Feature Folders -DoubleCommanderPath '' | Out-Null
    Assert (@((Invoke-TestAction Status) | Where-Object DoubleCommanderPath -eq $script:FixtureExe).Count -eq 2) 'New feature inherits configured executable'
    [IO.File]::Delete($script:FixtureExe)
    Assert (@((Invoke-TestAction Status) | Where-Object ExecutableExists -eq $false).Count -eq 2) 'Missing executable reported'
    Assert-Throws { Invoke-TestAction Enable -DoubleCommanderPath '' } 'was not found'
    Invoke-TestAction Disable | Out-Null
    Assert (@((Get-AllSnapshots) | Where-Object Exists).Count -eq 0) 'Disable works after executable removal'
    [IO.File]::WriteAllText($script:FixtureExe, 'Test fixture only; never execute.')

    # Fault after one write: production rollback must restore everything.
    Reset-Fixture
    $originalSetter = ${function:Set-ValueSnapshot}
    $script:Writes = 0
    function Set-ValueSnapshot {
        param($Key, $Name, $Snapshot)
        $script:Writes++
        if ($script:Writes -eq 2) { throw 'simulated registry failure' }
        & $originalSetter $Key $Name $Snapshot
    }
    Assert-Throws { Invoke-TestAction Enable } 'was rolled back.*simulated registry failure'
    Set-Item Function:Set-ValueSnapshot $originalSetter
    Assert (@((Get-AllSnapshots) | Where-Object Exists).Count -eq 0) 'Failed enable restored all values'
    Assert (-not [IO.File]::Exists($script:JournalFile)) 'Successful rollback clears journal'

    # Failure saving final state, after registry writes, also rolls back.
    Reset-Fixture
    $originalWriter = ${function:Write-AtomicJson}
    $script:FailStateOnce = $true
    function Write-AtomicJson {
        param($Path, $Value)
        if ($Path -eq $script:StateFile -and $script:FailStateOnce) {
            $script:FailStateOnce = $false
            throw 'simulated disk failure'
        }
        & $originalWriter $Path $Value
    }
    Assert-Throws { Invoke-TestAction Enable } 'was rolled back.*simulated disk failure'
    Set-Item Function:Write-AtomicJson $originalWriter
    Assert (@((Get-AllSnapshots) | Where-Object Exists).Count -eq 0) 'Disk failure restored all values'

    # A failure after Disable prunes keys must recreate the enabled configuration.
    Reset-Fixture
    Invoke-TestAction Enable | Out-Null
    $beforeFailedDisable = @(Get-AllSnapshots)
    $script:FailStateOnce = $true
    function Write-AtomicJson {
        param($Path, $Value)
        if ($Path -eq $script:StateFile -and $script:FailStateOnce) {
            $script:FailStateOnce = $false
            throw 'simulated disk failure during disable'
        }
        & $originalWriter $Path $Value
    }
    Assert-Throws { Invoke-TestAction Disable } 'was rolled back.*simulated disk failure during disable'
    Set-Item Function:Write-AtomicJson $originalWriter
    $afterFailedDisable = @(Get-AllSnapshots)
    for ($i = 0; $i -lt $beforeFailedDisable.Count; $i++) {
        Assert (Test-SnapshotEqual $beforeFailedDisable[$i] $afterFailedDisable[$i]) "Failed disable rollback $i"
    }

    # Failed rollback keeps its journal; a later Recover can finish idempotently.
    Reset-Fixture
    $script:Writes = 0
    function Set-ValueSnapshot {
        param($Key, $Name, $Snapshot)
        $script:Writes++
        if ($script:Writes -in 2, 3) { throw 'simulated persistent write failure' }
        & $originalSetter $Key $Name $Snapshot
    }
    Assert-Throws { Invoke-TestAction Enable } 'Rollback incomplete'
    Set-Item Function:Set-ValueSnapshot $originalSetter
    Assert ([IO.File]::Exists($script:JournalFile)) 'Failed rollback retains journal'
    Invoke-TestAction Recover | Out-Null
    Assert (@((Get-AllSnapshots) | Where-Object Exists).Count -eq 0) 'Recovery completes failed rollback'

    # Simulate abrupt termination by leaving a valid journal and a partially applied registry.
    Reset-Fixture
    $originalTransaction = ${function:Invoke-Transaction}
    function Invoke-Transaction {
        param($BeforeState, $AfterState, $Entries, $CreatedKeys, $CleanupKeys)
        $journal = [pscustomobject]@{
            Schema = 1; BeforeState = $BeforeState; AfterState = $AfterState
            Entries = @($Entries); CreatedKeys = @($CreatedKeys); CleanupKeys = @($CleanupKeys)
        }
        Write-AtomicJson $script:JournalFile $journal
        Set-ValueSnapshot $Entries[0].Key $Entries[0].Name $Entries[0].After
        throw 'simulated termination'
    }
    Assert-Throws { Invoke-TestAction Enable } 'simulated termination'
    Set-Item Function:Invoke-Transaction $originalTransaction
    Assert (@((Invoke-TestAction Status) | Where-Object RecoveryPending).Count -eq 2) 'Pending recovery reported'
    Assert-Throws { Invoke-TestAction Enable } 'needs recovery'
    Invoke-TestAction Recover -WhatIf | Out-Null
    Assert ([IO.File]::Exists($script:JournalFile)) 'Recover WhatIf preserves journal'
    With-Context { Set-ValueSnapshot 'Classes\Directory\shell' '' $foreign }
    Assert-Throws { Invoke-TestAction Recover } 'Recovery conflict'
    # Recovery must not depend on the possibly damaged current state file.
    [IO.File]::WriteAllText($script:StateFile, '{broken')
    Invoke-TestAction Recover -Force | Out-Null
    Assert (@((Get-AllSnapshots) | Where-Object Exists).Count -eq 0) 'Force recovery restores original values'
    Assert (-not [IO.File]::Exists($script:JournalFile)) 'Recovery clears journal'
    Invoke-TestAction Recover | Out-Null

    # The same crash recovery must also undo a partially completed Disable.
    Reset-Fixture
    Invoke-TestAction Enable | Out-Null
    $enabledSnapshots = @(Get-AllSnapshots)
    function Invoke-Transaction {
        param($BeforeState, $AfterState, $Entries, $CreatedKeys, $CleanupKeys)
        $journal = [pscustomobject]@{
            Schema = 1; BeforeState = $BeforeState; AfterState = $AfterState
            Entries = @($Entries); CreatedKeys = @($CreatedKeys); CleanupKeys = @($CleanupKeys)
        }
        Write-AtomicJson $script:JournalFile $journal
        Set-ValueSnapshot $Entries[0].Key $Entries[0].Name $Entries[0].After
        throw 'simulated termination during disable'
    }
    Assert-Throws { Invoke-TestAction Disable } 'simulated termination during disable'
    Set-Item Function:Invoke-Transaction $originalTransaction
    Invoke-TestAction Recover | Out-Null
    $recovered = @(Get-AllSnapshots)
    for ($i = 0; $i -lt $recovered.Count; $i++) { Assert (Test-SnapshotEqual $recovered[$i] $enabledSnapshots[$i]) "Disable crash recovery $i" }
    Assert (@((Invoke-TestAction Status) | Where-Object State -eq 'Enabled').Count -eq 2) 'Disable crash restores enabled state'

    Reset-Fixture
    Invoke-TestAction Enable | Out-Null
    $state = Read-Json $script:StateFile
    $state.Features[0].Values[0].Key = 'Software\Unrelated'
    Write-AtomicJson $script:StateFile $state
    Assert-Throws { Invoke-TestAction Disable -Force } 'Invalid backup registry target'

    # Empty arrays and empty binary values must survive JSON without becoming null.
    Reset-Fixture
    With-Context {
        $emptyMulti = [pscustomobject]@{ Exists = $true; Kind = 'MultiString'; Data = @() }
        $emptyBinary = [pscustomobject]@{ Exists = $true; Kind = 'Binary'; Data = '' }
        Set-ValueSnapshot 'Classes\Directory\shell' '' $emptyMulti
        Set-ValueSnapshot 'Classes\Drive\shell' '' $emptyBinary
    }
    $emptyBefore = @(Get-AllSnapshots)
    Invoke-TestAction Enable | Out-Null
    Invoke-TestAction Disable | Out-Null
    $emptyAfter = @(Get-AllSnapshots)
    for ($i = 0; $i -lt $emptyBefore.Count; $i++) { Assert (Test-SnapshotEqual $emptyBefore[$i] $emptyAfter[$i]) "Empty-data roundtrip $i" }

    Reset-Fixture
    Assert-Throws { Invoke-TestAction Enable -DoubleCommanderPath (Join-Path $script:Sandbox 'missing.exe') } 'was not found'
    $unsafe = Join-Path $script:Sandbox '%1\doublecmd.exe'
    $null = [IO.Directory]::CreateDirectory((Split-Path $unsafe -Parent))
    [IO.File]::WriteAllText($unsafe, 'never execute')
    Assert-Throws { Invoke-TestAction Enable -DoubleCommanderPath $unsafe } 'percent signs'
    With-Context {
        $command = New-AppliedSnapshot 'FolderCommand' $script:FixtureExe
        Assert ($command.Data -ceq ('"{0}" -C -T "%1\."' -f $script:FixtureExe)) 'Quoted command without shell interpolation'
    }

    if (-not ('DoubleCommanderDefaultTests.Arguments' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DoubleCommanderDefaultTests {
    public static class Arguments {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(string line, out int count);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);
        public static string[] Parse(string line) {
            int count;
            IntPtr memory = CommandLineToArgvW(line, out count);
            if (memory == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try {
                string[] result = new string[count];
                for (int i = 0; i < count; i++)
                    result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
                return result;
            } finally { LocalFree(memory); }
        }
    }
}
'@
    }
    $template = New-AppliedSnapshot 'FolderCommand' $script:FixtureExe
    foreach ($directory in @('C:\', 'C:\space & apostrophe''s\', '\\server\share\', 'C:\literal $(test); %PATH%')) {
        $parsed = [DoubleCommanderDefaultTests.Arguments]::Parse($template.Data.Replace('%1', $directory))
        Assert ($parsed.Count -eq 4) "Windows argument count for $directory"
        Assert ($parsed[0] -ceq $script:FixtureExe -and $parsed[1] -ceq '-C' -and $parsed[2] -ceq '-T') 'Windows executable and switches'
        Assert ([IO.Path]::GetFullPath($parsed[3]).TrimEnd('\') -ceq [IO.Path]::GetFullPath($directory).TrimEnd('\')) "Directory argument roundtrip for $directory"
    }

    Write-Output "PASS: $script:Assertions assertions on PowerShell $($PSVersionTable.PSVersion). Real associations unchanged."
} finally {
    $script:ActualRegistry.DeleteSubKeyTree($script:TestRegistryPath, $false)
    $script:ActualRegistry.Dispose()
    $full = [IO.Path]::GetFullPath($script:Sandbox)
    $expected = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".sandbox.$script:TestId"))
    if ($full -ne $expected -or (Split-Path $full -Parent) -ne $PSScriptRoot) { throw 'Unsafe test cleanup.' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
