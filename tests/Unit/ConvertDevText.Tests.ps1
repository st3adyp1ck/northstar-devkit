#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the pure converters in workflow/Convert-DevText.ps1
.DESCRIPTION
    Exercises every conversion function in isolation - no interactive
    picker, clipboard, or console input is involved. Covers Base64 and URL
    round-trips plus known vectors, the seconds-vs-milliseconds timestamp
    heuristic, now-to-timestamp freshness, GUID format, the SHA-256 "abc"
    test vector, and JWT header/payload decoding of a handcrafted token
    (including base64url padding restoration and rejection of garbage).

    Dot-sourcing Convert-DevText.ps1 here is safe: the script detects
    when it is being dot-sourced (`$MyInvocation.InvocationName -eq '.'`)
    and returns immediately after defining the conversion functions,
    without showing a menu or touching the clipboard.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\ConvertDevText.Tests.ps1
#>

Describe "Convert-DevText pure converters" {

    BeforeAll {
        $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "tools\workflow\Convert-DevText.ps1"
        . $script:ScriptPath

        # base64url-encode helper for handcrafting JWT segments in tests.
        function ConvertTo-TestBase64Url([string]$Text) {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
            return $b64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
        }
    }

    Context "Base64" {

        It "encodes a known vector" {
            ConvertTo-DevKitBase64 -Text "hello" | Should -Be "aGVsbG8="
        }

        It "round-trips text with spaces and symbols" {
            $original = "hello world & goodbye/at=once"
            ConvertFrom-DevKitBase64 -Base64 (ConvertTo-DevKitBase64 -Text $original) | Should -Be $original
        }

        It "round-trips non-ASCII text as UTF-8" {
            $original = "héllo ünïcode"
            ConvertFrom-DevKitBase64 -Base64 (ConvertTo-DevKitBase64 -Text $original) | Should -Be $original
        }

        It "throws on malformed Base64" {
            { ConvertFrom-DevKitBase64 -Base64 "!!!not-base64!!!" } | Should -Throw
        }
    }

    Context "URL encoding" {

        It "encodes a known vector" {
            ConvertTo-DevKitUrlEncoded -Text "a b&c=d" | Should -Be "a%20b%26c%3Dd"
        }

        It "round-trips a query string's worth of special characters" {
            $original = "q=a b&lang=c#&r=100%"
            ConvertFrom-DevKitUrlEncoded -Text (ConvertTo-DevKitUrlEncoded -Text $original) | Should -Be $original
        }
    }

    Context "Unix timestamps" {

        It "treats a 10-digit value as seconds" {
            $result = ConvertFrom-DevKitUnixTime -Timestamp 1700000000
            $result | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1700000000).LocalDateTime)
        }

        It "treats a 13-digit value as milliseconds" {
            $result = ConvertFrom-DevKitUnixTime -Timestamp 1700000000000
            $result | Should -Be ([DateTimeOffset]::FromUnixTimeMilliseconds(1700000000000).LocalDateTime)
        }

        It "maps a seconds value and its milliseconds twin to the same instant" {
            ConvertFrom-DevKitUnixTime -Timestamp 1700000000 | Should -Be (ConvertFrom-DevKitUnixTime -Timestamp 1700000000000)
        }

        It "returns a current timestamp within a few seconds of now" {
            $result = Get-DevKitCurrentUnixTime
            [math]::Abs($result.Seconds - [DateTimeOffset]::Now.ToUnixTimeSeconds()) | Should -BeLessThan 10
            $result.Milliseconds | Should -BeGreaterThan 1000000000000
        }
    }

    Context "GUID" {

        It "returns a standard dashed lowercase GUID" {
            New-DevKitGuid | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        }

        It "returns a different GUID each time" {
            New-DevKitGuid | Should -Not -Be (New-DevKitGuid)
        }
    }

    Context "SHA-256" {

        It "matches the published 'abc' test vector" {
            Get-DevKitSha256Hash -Text "abc" |
                Should -Be "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        }

        It "matches the published empty-string test vector" {
            Get-DevKitSha256Hash -Text "" |
                Should -Be "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        }
    }

    Context "JWT decode (signature never verified)" {

        It "decodes a handcrafted token's header and payload" {
            $header = ConvertTo-TestBase64Url '{"alg":"none","typ":"JWT"}'
            $payload = ConvertTo-TestBase64Url '{"sub":"42","name":"Test User"}'
            $token = "$header.$payload.ignoredsignature"

            $decoded = ConvertFrom-DevKitJwt -Token $token
            $decoded.Header.alg | Should -Be "none"
            $decoded.Payload.sub | Should -Be "42"
            $decoded.Payload.name | Should -Be "Test User"
        }

        It "restores missing base64url padding" {
            # '{"a":"b"}' base64s to a 12-char string, so the unpadded form
            # exercises the %4 == 0 path; the payload below hits %4 == 2.
            $header = ConvertTo-TestBase64Url '{"a":"b"}'
            $payload = ConvertTo-TestBase64Url '{"x":1}'
            $decoded = ConvertFrom-DevKitJwt -Token "$header.$payload.sig"
            $decoded.Header.a | Should -Be "b"
            $decoded.Payload.x | Should -Be 1
        }

        It "rejects a string with no segment separator" {
            { ConvertFrom-DevKitJwt -Token "not-a-jwt" } | Should -Throw
        }

        It "rejects a token whose segments are not valid base64url/JSON" {
            { ConvertFrom-DevKitJwt -Token "%%%.###.___" } | Should -Throw
        }
    }
}
