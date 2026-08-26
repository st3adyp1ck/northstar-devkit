#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the RPC layer's pure helpers (core/RpcMethods.ps1)
.DESCRIPTION
    The RPC layer had zero coverage. This file covers the parts that are
    pure functions of their inputs, with an emphasis on the two invariants
    that have actually broken things in production:

      - The $DevKitRpcArrayMethods registry. A method whose top-level result
        is an array MUST be listed there or PowerShell's function-boundary
        unrolling turns a one-element result into a bare object and an empty
        one into $null - which the typed consumers (the CLI's Vec<> parses,
        the widget's .map calls) then crash on, precisely on the
        fresh-install states no dev machine exhibits.
      - Add-DevKitForceArgument / Test-DevKitScriptDeclaresParameter, the
        fix for destructive tools dying under -NonInteractive because
        Confirm-DevKitDestructiveAction's Read-Host throws there.

    Dot-sources RpcMethods.ps1 directly - it defines functions and the
    registry at load time and needs neither DevKit.Core nor a live sidecar.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitRpcMethodsLoaded = $false
    . (Join-Path $script:RepoRoot 'core\RpcMethods.ps1')

    function New-TestScript {
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Body)
        $path = Join-Path $TestDrive $Name
        Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
        return $path
    }
}

Describe "Test-DevKitRpcArrayMethod" {

    It "knows the array-returning methods" {
        Test-DevKitRpcArrayMethod -Method 'projects.list' | Should -BeTrue
        Test-DevKitRpcArrayMethod -Method 'notes.get' | Should -BeTrue
        Test-DevKitRpcArrayMethod -Method 'ondeck.get' | Should -BeTrue
    }

    It "registers the error-center collectors, whose results are arrays" {
        Test-DevKitRpcArrayMethod -Method 'errors.system' | Should -BeTrue
        Test-DevKitRpcArrayMethod -Method 'errors.app' | Should -BeTrue
    }

    It "does NOT register errors.clearAppLogs, whose result is an object" {
        Test-DevKitRpcArrayMethod -Method 'errors.clearAppLogs' | Should -BeFalse
    }

    It "is false for scalar/object methods and for unknown ones" {
        Test-DevKitRpcArrayMethod -Method 'settings.get' | Should -BeFalse
        Test-DevKitRpcArrayMethod -Method 'metrics.system' | Should -BeFalse
        Test-DevKitRpcArrayMethod -Method 'no.such.method' | Should -BeFalse
    }
}

Describe "Get-DevKitRpcParam" {

    It "reads a present property" {
        Get-DevKitRpcParam ([PSCustomObject]@{ hours = 6 }) 'hours' 24 | Should -Be 6
    }

    It "falls back to the default for a missing property" {
        Get-DevKitRpcParam ([PSCustomObject]@{ other = 1 }) 'hours' 24 | Should -Be 24
    }

    It "falls back to the default for a null-valued property" {
        Get-DevKitRpcParam ([PSCustomObject]@{ hours = $null }) 'hours' 24 | Should -Be 24
    }

    It "falls back to the default when params itself is null" {
        Get-DevKitRpcParam $null 'hours' 24 | Should -Be 24
    }

    It "returns `$false rather than the default for an explicit false" {
        # The tool.run 'confirmed' flag depends on this: an explicit false
        # must not be mistaken for "absent".
        Get-DevKitRpcParam ([PSCustomObject]@{ confirmed = $false }) 'confirmed' $false | Should -BeFalse
    }
}

Describe "Test-DevKitRpcConfirmedFlag" {

    It "is true only for a real boolean true" {
        Test-DevKitRpcConfirmedFlag $true | Should -BeTrue
        Test-DevKitRpcConfirmedFlag $false | Should -BeFalse
    }

    It "is false for a missing/null value" {
        Test-DevKitRpcConfirmedFlag $null | Should -BeFalse
    }

    It "does NOT treat the string 'false' as true" {
        # A plain [bool] cast would: PowerShell casts any non-empty string
        # to $true, which on this flag means silently forcing a destructive
        # tool the user never confirmed.
        Test-DevKitRpcConfirmedFlag 'false' | Should -BeFalse
        Test-DevKitRpcConfirmedFlag 'no' | Should -BeFalse
        Test-DevKitRpcConfirmedFlag 0 | Should -BeFalse
        Test-DevKitRpcConfirmedFlag 1 | Should -BeFalse
    }

    It "accepts the exact string 'true' (case-insensitive) for a stringly-typed caller" {
        Test-DevKitRpcConfirmedFlag 'true' | Should -BeTrue
        Test-DevKitRpcConfirmedFlag 'True' | Should -BeTrue
    }
}

Describe "Test-DevKitScriptDeclaresParameter" {

    It "finds a switch declared in a [CmdletBinding()] param block" {
        $p = New-TestScript -Name 'has-force.ps1' -Body @'
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)
Write-Host "ran"
'@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeTrue
    }

    It "matches case-insensitively" {
        $p = New-TestScript -Name 'case.ps1' -Body "param([switch]`$Force)"
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'force' | Should -BeTrue
    }

    It "finds a parameter even when the comment-based help runs straight into [CmdletBinding()]" {
        # Docker-Nuke.ps1 really is written as `#>[CmdletBinding()]` on one
        # line - a text search would be fine, but this proves the AST is.
        $p = New-TestScript -Name 'jammed.ps1' -Body @'
<#
.SYNOPSIS
    Test
#>[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepVolumes
)
'@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeTrue
    }

    It "is false for a script with no -Force" {
        $p = New-TestScript -Name 'no-force.ps1' -Body @'
[CmdletBinding()]
param(
    [int]$Hours = 24,
    [int]$MaxEvents = 50
)
'@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeFalse
    }

    It "is false for a script with no param block at all" {
        $p = New-TestScript -Name 'no-params.ps1' -Body 'Write-Host "just a script"'
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeFalse
    }

    It "is false (not a crash) for a missing file" {
        Test-DevKitScriptDeclaresParameter -ScriptPath (Join-Path $TestDrive 'nope.ps1') -Name 'Force' | Should -BeFalse
    }

    It "does not match a -Force mentioned only in the help text or the body" {
        $p = New-TestScript -Name 'mentions-force.ps1' -Body @'
<#
.PARAMETER Force
    Documented but never declared.
#>
param([switch]$Apply)
Write-Host "pass -Force to skip"
'@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeFalse
    }

    It "does not EXECUTE the script it inspects" {
        $marker = Join-Path $TestDrive 'side-effect.txt'
        $p = New-TestScript -Name 'side-effect.ps1' -Body @"
param([switch]`$Force)
Set-Content -LiteralPath '$marker' -Value 'ran'
"@
        Test-DevKitScriptDeclaresParameter -ScriptPath $p -Name 'Force' | Should -BeTrue
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
}

Describe "Add-DevKitForceArgument" {

    BeforeAll {
        $script:ForceScript = New-TestScript -Name 'forceable.ps1' -Body @'
[CmdletBinding()]
param(
    [string]$SetStartType,
    [switch]$Force
)
'@
        $script:PlainScript = New-TestScript -Name 'plain.ps1' -Body @'
[CmdletBinding()]
param([int]$Hours = 24)
'@
    }

    It "appends -Force when the script declares it" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @())
        $r.Count | Should -Be 1
        $r[0] | Should -Be '-Force'
    }

    It "keeps the caller's existing arguments and appends -Force last" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @('-SetStartType', 'Spooler'))
        $r.Count | Should -Be 3
        $r[0] | Should -Be '-SetStartType'
        $r[1] | Should -Be 'Spooler'
        $r[2] | Should -Be '-Force'
    }

    It "leaves a script that declares no -Force completely alone" {
        # Passing an undeclared parameter to `pwsh -File` is a hard binding
        # error, so this would turn the fix into a new breakage for the
        # non-destructive half of the catalog.
        $r = @(Add-DevKitForceArgument -ScriptPath $script:PlainScript -Arguments @('-Hours', '6'))
        $r.Count | Should -Be 2
        $r | Should -Not -Contain '-Force'
    }

    It "does not add a second -Force when the caller already passed one" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @('-Force'))
        $r.Count | Should -Be 1
    }

    It "recognizes an already-present -Force case-insensitively" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @('-force'))
        $r.Count | Should -Be 1
        $r[0] | Should -Be '-force'
    }

    It "does not mistake a VALUE that happens to read like -Force for a passed switch" {
        $r = @(Add-DevKitForceArgument -ScriptPath $script:ForceScript -Arguments @('-SetStartType', '-Force-ish'))
        $r.Count | Should -Be 3
        $r[2] | Should -Be '-Force'
    }

    It "leaves a missing script alone rather than throwing" {
        $r = @(Add-DevKitForceArgument -ScriptPath (Join-Path $TestDrive 'gone.ps1') -Arguments @('-A'))
        $r.Count | Should -Be 1
    }
}

Describe "ConvertTo-DevKitQuotedArgument" {

    It "leaves a simple token unquoted" {
        ConvertTo-DevKitQuotedArgument -Value '-Force' | Should -Be '-Force'
    }

    It "quotes a value containing spaces" {
        ConvertTo-DevKitQuotedArgument -Value 'C:\Program Files\App' | Should -Be '"C:\Program Files\App"'
    }

    It "escapes an embedded quote per the C runtime's rules" {
        ConvertTo-DevKitQuotedArgument -Value 'say "hi"' | Should -Be '"say \"hi\""'
    }

    It "doubles a trailing backslash run inside the quotes" {
        ConvertTo-DevKitQuotedArgument -Value 'C:\Some Dir\' | Should -Be '"C:\Some Dir\\"'
    }

    It "quotes an empty string" {
        ConvertTo-DevKitQuotedArgument -Value '' | Should -Be '""'
    }
}
