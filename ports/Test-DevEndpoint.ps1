#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test Dev Endpoint - Northstar DevKit
.DESCRIPTION
    HTTP health check for local development endpoints. With -Url, sends a HEAD
    request (falling back to GET when the server answers 405/501) and reports
    the status code, latency, and final URL after redirects; for https URLs it
    additionally inspects the TLS certificate and reports days until expiry.
    Without -Url, probes http://localhost:<port> for every common dev port
    that is actually listening and prints a compact table.

    Read-only: only makes network requests to localhost or the URL you give
    it; every request failure is reported as a clean "not responding" result,
    never a crash.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Url
    The endpoint to test, e.g. http://localhost:3000 or https://localhost:5001/api/health.
    When omitted, all listening common dev ports are probed instead.
.EXAMPLE
    .\Test-DevEndpoint.ps1
    .\Test-DevEndpoint.ps1 -Url "http://localhost:3000"
#>
[CmdletBinding()]
param(
    [string]$Url
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

# Same list Scan-Ports.ps1 scans.
$CommonPorts = @(3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017)

function Invoke-DevKitEndpointProbe {
    <#
    .SYNOPSIS
        Sends one HTTP request (HEAD, retried as GET on 405/501) and reports
        the outcome. Any HTTP status code - even 404/500 - counts as
        "responding"; only connection-level failures count as not responding.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetUrl,
        [int]$TimeoutSec = 10
    )

    $result = [PSCustomObject]@{
        Responding = $false
        StatusCode = $null
        Method     = 'HEAD'
        LatencyMs  = $null
        FinalUrl   = $null
        Error      = $null
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    foreach ($method in @('Head', 'Get')) {
        $result.Method = $method.ToUpper()
        try {
            $response = Invoke-WebRequest -Uri $TargetUrl -Method $method -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop
        } catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
            }
            if ($method -eq 'Head' -and ($statusCode -eq 405 -or $statusCode -eq 501)) {
                continue  # server refuses HEAD - retry once with GET
            }
            $stopwatch.Stop()
            if ($null -ne $statusCode) {
                $result.Responding = $true
                $result.StatusCode = $statusCode
                $result.LatencyMs = $stopwatch.ElapsedMilliseconds
            } else {
                $result.Error = $_.Exception.Message
            }
            return $result
        }
        break
    }
    $stopwatch.Stop()

    $result.Responding = $true
    $result.StatusCode = [int]$response.StatusCode
    $result.LatencyMs = $stopwatch.ElapsedMilliseconds
    # Final URL after redirects: HttpWebResponse.ResponseUri on PS 5.1,
    # HttpResponseMessage.RequestMessage.RequestUri on PS 7+.
    try {
        if ($response.BaseResponse.ResponseUri) {
            $result.FinalUrl = $response.BaseResponse.ResponseUri.AbsoluteUri
        } elseif ($response.BaseResponse.RequestMessage -and $response.BaseResponse.RequestMessage.RequestUri) {
            $result.FinalUrl = $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
        }
    } catch { $result.FinalUrl = $null }
    return $result
}

function Get-DevKitCertificateInfo {
    <#
    .SYNOPSIS
        Opens a TLS handshake against HostName:Port and reports the server
        certificate's expiry. Inspection only: certificate validation is
        disabled so self-signed dev certs can still be read, and no data is
        ever sent over the stream.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 5000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return [PSCustomObject]@{ Ok = $false; Error = "connect timed out"; NotAfter = $null; DaysRemaining = $null }
        }
        $client.EndConnect($connect)

        $acceptAnyCert = [System.Net.Security.RemoteCertificateValidationCallback]{
            param($sender, $certificate, $chain, $sslPolicyErrors)
            $true
        }
        $sslStream = New-Object System.Net.Security.SslStream -ArgumentList $client.GetStream(), $false, $acceptAnyCert
        try {
            # Bound an otherwise infinite wait on a stalled handshake.
            $sslStream.ReadTimeout = $TimeoutMs
            $sslStream.WriteTimeout = $TimeoutMs
            $sslStream.AuthenticateAsClient($HostName)
            if (-not $sslStream.RemoteCertificate) {
                return [PSCustomObject]@{ Ok = $false; Error = "no certificate presented"; NotAfter = $null; DaysRemaining = $null }
            }
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
            $days = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
            return [PSCustomObject]@{ Ok = $true; Error = $null; NotAfter = $cert.NotAfter; DaysRemaining = $days }
        } finally {
            $sslStream.Dispose()
        }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message; NotAfter = $null; DaysRemaining = $null }
    } finally {
        $client.Close()
    }
}

function Get-DevKitStatusColor {
    param([int]$StatusCode)
    if ($StatusCode -lt 400) { return 'Green' }
    if ($StatusCode -lt 500) { return 'Yellow' }
    return 'Red'
}

Write-DevKitHeader "Test Dev Endpoint"

if (-not [string]::IsNullOrWhiteSpace($Url)) {
    $uri = $null
    try { $uri = [System.Uri]$Url } catch { $uri = $null }
    if (-not $uri -or ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https')) {
        Write-DevKitError "Invalid URL '$Url' - expected an absolute http:// or https:// URL."
        exit 1
    }

    Write-DevKitStep "Probing $Url"
    $probe = Invoke-DevKitEndpointProbe -TargetUrl $Url -TimeoutSec 10
    if (-not $probe.Responding) {
        Write-Host ""
        Write-Host "  NOT RESPONDING" -ForegroundColor Red
        if ($probe.Error) { Write-DevKitInfo $probe.Error }
        Write-Host ""
        exit 1
    }
    Write-DevKitDone

    Write-Host ("  Status:   {0} ({1})" -f $probe.StatusCode, $probe.Method) -ForegroundColor (Get-DevKitStatusColor $probe.StatusCode)
    Write-Host ("  Latency:  {0} ms" -f $probe.LatencyMs) -ForegroundColor Cyan
    if ($probe.FinalUrl -and $probe.FinalUrl.TrimEnd('/') -ne $Url.TrimEnd('/')) {
        Write-Host "  Redirect: $($probe.FinalUrl)" -ForegroundColor Gray
    }

    if ($uri.Scheme -eq 'https') {
        $cert = Get-DevKitCertificateInfo -HostName $uri.Host -Port $uri.Port
        if ($cert.Ok) {
            $certColor = 'Green'
            if ($cert.DaysRemaining -lt 7) { $certColor = 'Red' }
            elseif ($cert.DaysRemaining -lt 30) { $certColor = 'Yellow' }
            Write-Host ("  TLS cert: expires {0} ({1} day(s) remaining)" -f $cert.NotAfter.ToString('yyyy-MM-dd'), $cert.DaysRemaining) -ForegroundColor $certColor
        } else {
            Write-DevKitInfo "TLS cert: could not inspect ($($cert.Error))"
        }
    }
    Write-Host ""
    exit 0
}

# No -Url: probe http://localhost:<port> for each common dev port that is
# actually listening right now.
Write-DevKitStep "Checking which common dev ports are listening"
$listeningPorts = @()
try {
    $listeningPorts = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Select-Object -ExpandProperty LocalPort -Unique)
} catch {
    Write-Host ""
    Write-DevKitError "Could not query TCP connections: $_"
    exit 1
}
Write-DevKitDone

$activePorts = @()
foreach ($p in $CommonPorts) {
    if ($listeningPorts -contains $p) { $activePorts += $p }
}

if ($activePorts.Count -eq 0) {
    Write-Host "  No common dev ports are currently listening - nothing to probe." -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host ""
Write-Host ("  {0,-7}{1,-9}{2,-11}{3}" -f 'PORT', 'STATUS', 'LATENCY', 'NOTE') -ForegroundColor Cyan
foreach ($p in $activePorts) {
    $probe = Invoke-DevKitEndpointProbe -TargetUrl "http://localhost:$p" -TimeoutSec 2
    if ($probe.Responding) {
        Write-Host ("  {0,-7}{1,-9}{2,-11}" -f $p, $probe.StatusCode, "$($probe.LatencyMs) ms") -ForegroundColor (Get-DevKitStatusColor $probe.StatusCode)
    } else {
        Write-Host ("  {0,-7}{1,-9}{2,-11}{3}" -f $p, '-', '-', 'not responding (no HTTP)') -ForegroundColor DarkGray
    }
}
Write-Host ""
exit 0
