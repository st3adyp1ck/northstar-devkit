#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for ConvertTo-DevKitBrowsableUrl (workflow/Open-Repo.ps1)
.DESCRIPTION
    Exercises the Git-remote-to-browsable-HTTPS-URL conversion in isolation
    against fake remote-URL strings - no real repo, git process, or
    Start-Process call is involved. Covers GitHub/GitLab/Bitbucket https
    remotes, git@ SSH shorthand (with and without a .git suffix), Azure
    DevOps SSH remotes (both the current and legacy host forms), ssh://
    URI-style remotes, and confirms that a bare non-URL string is now
    REJECTED (returns $null) instead of being passed through unchanged.

    Dot-sourcing Open-Repo.ps1 here is safe: the script detects when it is
    being dot-sourced (`$MyInvocation.InvocationName -eq '.'`) and returns
    immediately after defining ConvertTo-DevKitBrowsableUrl, without
    touching the current directory, running git, or launching a browser.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\OpenRepo-UrlConversion.Tests.ps1
#>

Describe "ConvertTo-DevKitBrowsableUrl" {

    BeforeAll {
        $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "workflow\Open-Repo.ps1"
        . $script:ScriptPath
    }

    Context "GitHub / GitLab / Bitbucket https remotes" {

        It "strips a trailing .git suffix from an https GitHub remote" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "https://github.com/user/repo.git" | Should -Be "https://github.com/user/repo"
        }

        It "leaves an https remote without a .git suffix untouched" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "https://gitlab.com/group/repo" | Should -Be "https://gitlab.com/group/repo"
        }

        It "converts an https Bitbucket remote" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "https://bitbucket.org/user/repo.git" | Should -Be "https://bitbucket.org/user/repo"
        }
    }

    Context "git@ scp-style SSH remotes" {

        It "converts a git@ SSH remote with a .git suffix" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "git@github.com:user/repo.git" | Should -Be "https://github.com/user/repo"
        }

        It "converts a git@ SSH remote without a .git suffix" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "git@gitlab.com:group/sub/repo" | Should -Be "https://gitlab.com/group/sub/repo"
        }
    }

    Context "Azure DevOps SSH remotes" {

        It "converts the current ssh.dev.azure.com/v3 form to a real dev.azure.com URL" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "git@ssh.dev.azure.com:v3/myorg/myproject/myrepo" |
                Should -Be "https://dev.azure.com/myorg/myproject/_git/myrepo"
        }

        It "converts the legacy vs-ssh.visualstudio.com form to a real dev.azure.com URL" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "git@vs-ssh.visualstudio.com:v3/myorg/myproject/myrepo" |
                Should -Be "https://dev.azure.com/myorg/myproject/_git/myrepo"
        }

        It "does not fall through to the generic git@ handler (which would build a broken URL)" {
            $result = ConvertTo-DevKitBrowsableUrl -RemoteUrl "git@ssh.dev.azure.com:v3/myorg/myproject/myrepo"
            $result | Should -Not -Match "ssh\.dev\.azure\.com"
        }
    }

    Context "ssh:// URI-style remotes" {

        It "converts an ssh:// remote with an explicit port" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "ssh://git@github.com:22/user/repo.git" | Should -Be "https://github.com/user/repo"
        }

        It "converts a self-hosted ssh:// remote with a custom port" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "ssh://git@gitlab.mycompany.com:2222/group/repo.git" |
                Should -Be "https://gitlab.mycompany.com/group/repo"
        }

        It "converts an ssh:// remote with no explicit port" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "ssh://git@bitbucket.example.com/scm/proj/repo.git" |
                Should -Be "https://bitbucket.example.com/scm/proj/repo"
        }
    }

    Context "Unsafe / non-URL input is rejected, never passed through" {

        It "rejects a bare command name instead of returning it unchanged" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "calc.exe" | Should -BeNullOrEmpty
        }

        It "rejects an arbitrary unrecognized scheme" {
            ConvertTo-DevKitBrowsableUrl -RemoteUrl "file:///C:/Windows/System32/calc.exe" | Should -BeNullOrEmpty
        }
    }
}

Describe "Open-Repo Start-Process safety gate regex" {
    # This mirrors the literal validation Open-Repo.ps1 runs immediately
    # before Start-Process, guarding against a bare/garbage value ever
    # reaching it even if URL conversion above were somehow bypassed.
    #
    # $gatePattern must be set inside BeforeAll, not directly in the Describe
    # body: Pester 5 runs Describe/Context bodies once at discovery time and
    # again (without side effects re-applied) at run time, so a plain
    # variable assignment made directly in the Describe body is invisible to
    # the It blocks when they actually execute - $gatePattern would be $null
    # there, and "$x -match $null" matches every string (empty pattern),
    # which is exactly why both "rejects ..." tests below false-passed as
    # $true until this was moved into BeforeAll.
    BeforeAll {
        $script:gatePattern = '^https?://[A-Za-z0-9.-]+/'
    }

    It "accepts a well-formed https URL with a path" {
        ("https://github.com/user/repo/tree/main" -match $gatePattern) | Should -Be $true
    }

    It "rejects a bare executable name" {
        ("calc.exe" -match $gatePattern) | Should -Be $false
    }

    It "rejects a scheme-less host" {
        ("github.com/user/repo" -match $gatePattern) | Should -Be $false
    }
}
