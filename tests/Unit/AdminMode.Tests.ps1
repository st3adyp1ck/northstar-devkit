#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for tools/system/Set-DevKitAdminMode.ps1's pure helpers.
.DESCRIPTION
    Covers the pieces of Admin Mode that can go wrong without ever touching
    the real system: exe candidate ordering and resolution, the WSH launcher
    shim's quoting, the shortcut plan, the Run-key autostart matcher, and
    the elevated-child argument list. The script guards its run section with
    the InvocationName check, so dot-sourcing it here registers nothing,
    deletes nothing, and never prompts.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why this flag reset matters
    # when several test files run in one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path (Join-Path (Join-Path $script:RepoRoot 'tools') 'system') 'Set-DevKitAdminMode.ps1')
}

Describe "Get-DevKitAppExeCandidates" {

    It "prefers the per-user install over a repo release build" {
        $candidates = @(Get-DevKitAppExeCandidates -LocalAppData 'C:\Users\u\AppData\Local' -RepoRoot 'D:\repo')
        $candidates.Count | Should -Be 2
        $candidates[0] | Should -Be 'C:\Users\u\AppData\Local\Programs\DevKit\DevKit.exe'
        $candidates[1] | Should -Be 'D:\repo\target\release\devkit-app.exe'
    }

    It "skips blank roots instead of emitting rooted half-paths" {
        @(Get-DevKitAppExeCandidates -LocalAppData '' -RepoRoot 'D:\repo').Count | Should -Be 1
        # With both blank it falls back to the real LOCALAPPDATA for the
        # install candidate only - nothing repo-shaped may appear.
        $candidates = @(Get-DevKitAppExeCandidates -LocalAppData 'C:\Users\u\AppData\Local' -RepoRoot '')
        $candidates.Count | Should -Be 1
        $candidates[0] | Should -Not -Match 'target'
    }
}

Describe "Resolve-DevKitAppExe" {

    It "returns the explicit path when it exists" {
        $exe = Join-Path $TestDrive 'DevKit.exe'
        Set-Content -LiteralPath $exe -Value 'x'
        Resolve-DevKitAppExe -Explicit $exe -Candidates @() | Should -Be $exe
    }

    It "throws for an explicit path that does not exist" {
        { Resolve-DevKitAppExe -Explicit (Join-Path $TestDrive 'nope.exe') -Candidates @() } | Should -Throw '*does not exist*'
    }

    It "picks the first candidate that exists" {
        $missing = Join-Path $TestDrive 'missing.exe'
        $real = Join-Path $TestDrive 'real.exe'
        Set-Content -LiteralPath $real -Value 'x'
        Resolve-DevKitAppExe -Candidates @($missing, $real) | Should -Be $real
    }

    It "throws listing the candidates when none exist" {
        { Resolve-DevKitAppExe -Candidates @('C:\a.exe', 'C:\b.exe') } | Should -Throw '*C:\a.exe*'
    }
}

Describe "Get-DevKitAdminLauncherVbs" {

    It "runs the task hidden via wscript's 0 window style" {
        $vbs = Get-DevKitAdminLauncherVbs -TaskName 'NorthstarDevKit-Admin'
        $vbs | Should -BeLike 'CreateObject("Wscript.Shell").Run *'
        $vbs | Should -BeLike '*, 0, False'
    }

    It "doubles quotes around the task name for VBScript" {
        $vbs = Get-DevKitAdminLauncherVbs -TaskName 'NorthstarDevKit-Admin'
        $vbs | Should -BeLike '*schtasks /run /tn ""NorthstarDevKit-Admin""*'
    }
}

Describe "Get-DevKitAdminShortcutPlan" {

    It "plans Desktop and Start Menu shortcuts pointing wscript at the launcher" {
        $specs = @(Get-DevKitAdminShortcutPlan -VbsPath 'C:\app\DevKit-Admin.vbs' -IconExePath 'C:\app\DevKit.exe' `
            -ShortcutFileName 'DevKit (Admin).lnk' -DesktopDir 'C:\Users\u\Desktop' -ProgramsDir 'C:\Users\u\Programs')
        $specs.Count | Should -Be 2
        $specs[0].Path | Should -Be 'C:\Users\u\Desktop\DevKit (Admin).lnk'
        $specs[1].Path | Should -Be 'C:\Users\u\Programs\DevKit (Admin).lnk'
        foreach ($spec in $specs) {
            $spec.Target | Should -Be 'wscript.exe'
            $spec.Arguments | Should -Be '"C:\app\DevKit-Admin.vbs"'
            $spec.IconLocation | Should -Be 'C:\app\DevKit.exe'
        }
    }

    It "skips blank folders so a redirected Desktop still leaves the Start Menu one" {
        $specs = @(Get-DevKitAdminShortcutPlan -VbsPath 'C:\app\DevKit-Admin.vbs' -IconExePath 'C:\app\DevKit.exe' `
            -ShortcutFileName 'DevKit (Admin).lnk' -DesktopDir '' -ProgramsDir 'C:\Users\u\Programs')
        $specs.Count | Should -Be 1
        $specs[0].Path | Should -Be 'C:\Users\u\Programs\DevKit (Admin).lnk'
    }
}

Describe "Find-DevKitAutostartRunValue" {

    It "matches an unquoted value" {
        $name = Find-DevKitAutostartRunValue -RunValues @{ DevKit = 'C:\Apps\DevKit\DevKit.exe' } -ExePath 'C:\Apps\DevKit\DevKit.exe'
        $name | Should -Be 'DevKit'
    }

    It "matches a quoted value, case-insensitively, with trailing arguments" {
        $name = Find-DevKitAutostartRunValue -RunValues @{ DevKit = '"c:\apps\devkit\devkit.exe" --minimized' } -ExePath 'C:\Apps\DevKit\DevKit.exe'
        $name | Should -Be 'DevKit'
    }

    It "ignores unrelated autostart values" {
        $name = Find-DevKitAutostartRunValue -RunValues @{ OneDrive = 'C:\Apps\OneDrive.exe'; Other = 'C:\Apps\DevKit\NotDevKit.exe' } -ExePath 'C:\Apps\DevKit\DevKit.exe'
        $name | Should -BeNullOrEmpty
    }
}

Describe "ConvertTo-DevKitAdminChildArgs" {

    It "carries the script, the result path, and -Force" {
        $childArgs = @(ConvertTo-DevKitAdminChildArgs -ScriptPath 'C:\tools\Set-DevKitAdminMode.ps1' -ResultPath 'C:\t\r.json')
        $childArgs | Should -Contain '-File'
        $childArgs | Should -Contain 'C:\tools\Set-DevKitAdminMode.ps1'
        $childArgs | Should -Contain '-ElevatedChildResultPath'
        $childArgs | Should -Contain 'C:\t\r.json'
        $childArgs | Should -Contain '-Force'
        $childArgs | Should -Not -Contain '-Off'
    }

    It "adds -Off and -ExePath only when set" {
        $offArgs = @(ConvertTo-DevKitAdminChildArgs -ScriptPath 'C:\s.ps1' -ResultPath 'C:\r.json' -Off -ExePath 'C:\app\DevKit.exe')
        $offArgs | Should -Contain '-Off'
        $offArgs | Should -Contain '-ExePath'
        $offArgs | Should -Contain 'C:\app\DevKit.exe'
    }

    It "quotes elements containing whitespace (Start-Process joins without quoting)" {
        $childArgs = @(ConvertTo-DevKitAdminChildArgs -ScriptPath 'C:\My Tools\Set-DevKitAdminMode.ps1' -ResultPath 'C:\t\r.json')
        $childArgs | Should -Contain '"C:\My Tools\Set-DevKitAdminMode.ps1"'
        $childArgs | Should -Not -Contain 'C:\My Tools\Set-DevKitAdminMode.ps1'
    }
}
