#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for Test-DevKitAiCliVersionMismatch (agents/Update-AiClis.ps1)
.DESCRIPTION
    Exercises the "installed major version is wildly higher than this
    channel's own latest -- probably a different tool sharing the same
    command name, not a real update" heuristic in isolation. This logic
    used to be inline in the COMPARE loop; it was extracted into its own
    function (Test-DevKitAiCliVersionMismatch) this sprint specifically so
    it could be unit tested directly, with no behavior change versus the
    original inline block.

    Dot-sourcing agents/Update-AiClis.ps1 here is safe: it detects when it
    is being dot-sourced (`$MyInvocation.InvocationName -eq '.'`) and
    returns immediately after defining its helper functions (including
    Test-DevKitAiCliVersionMismatch), before the DETECT/COMPARE/UPDATE
    block that enumerates real installed CLIs and shells out to
    npm/GitHub/scoop (same guard pattern as wifi/WiFi-Scan.ps1 and
    workflow/Open-Repo.ps1).
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\UpdateAiClis-VersionCompare.Tests.ps1
#>

BeforeAll {
    $script:UpdateAiClisScript = (Resolve-Path (Join-Path $PSScriptRoot "..\..\agents\Update-AiClis.ps1")).Path

    # lib/DevKit-Common.ps1 guards itself with a $global:DevKitCommonLoaded
    # "load once per process" flag; Update-AiClis.ps1 dot-sources it near
    # its own top. Reset the flag so a real load happens (defensive - this
    # script's helper functions don't depend on DevKit-Common.ps1's
    # functions, but a fresh load keeps this file self-contained regardless
    # of run order, matching the rest of this suite's convention).
    $global:DevKitCommonLoaded = $false
    . $script:UpdateAiClisScript
}

Describe "Test-DevKitAiCliVersionMismatch" {

    It "does NOT flag a real one-major-version bump (current=2.0.0, latest=1.9.0, diff 1)" {
        Test-DevKitAiCliVersionMismatch -Current "2.0.0" -Latest "1.9.0" | Should -Be $false
    }

    It "does NOT flag current=1.44.0 vs latest=0.23.6 (major diff 1, below the +2 threshold)" {
        # This is the exact pairing named in this sprint's follow-up: local
        # major (1) is only 1 higher than latest's major (0), so it must NOT
        # be flagged even though it looks like a big version gap at a
        # glance -- the threshold is major-version count, not numeric size.
        Test-DevKitAiCliVersionMismatch -Current "1.44.0" -Latest "0.23.6" | Should -Be $false
    }

    It "does NOT flag current=1.0.0 vs latest=0.9.0 (major diff 1)" {
        Test-DevKitAiCliVersionMismatch -Current "1.0.0" -Latest "0.9.0" | Should -Be $false
    }

    It "flags current=3.0.0 vs latest=0.5.0 (major diff 3)" {
        Test-DevKitAiCliVersionMismatch -Current "3.0.0" -Latest "0.5.0" | Should -Be $true
    }

    It "flags exactly at the +2 threshold (current=2.0.0, latest=0.9.0, diff 2)" {
        Test-DevKitAiCliVersionMismatch -Current "2.0.0" -Latest "0.9.0" | Should -Be $true
    }

    It "does NOT flag equal major versions (current=1.5.0, latest=1.0.0)" {
        Test-DevKitAiCliVersionMismatch -Current "1.5.0" -Latest "1.0.0" | Should -Be $false
    }

    It "does NOT flag when the installed version is older (current=0.9.0, latest=1.0.0)" {
        Test-DevKitAiCliVersionMismatch -Current "0.9.0" -Latest "1.0.0" | Should -Be $false
    }

    It "returns `$false when a version string has no leading numeric major component" {
        Test-DevKitAiCliVersionMismatch -Current "unknown" -Latest "1.0.0" | Should -Be $false
        Test-DevKitAiCliVersionMismatch -Current "1.0.0" -Latest "unavailable (network?)" | Should -Be $false
    }
}
