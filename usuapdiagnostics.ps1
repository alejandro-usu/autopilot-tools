<#
.SYNOPSIS
    Runs Get-AutopilotDiagnosticsCommunity and saves output to a USB drive or prompted path.

.DESCRIPTION
    Installs prerequisites, detects a plugged-in USB flash drive, runs
    Get-AutopilotDiagnosticsCommunity with -Online, and saves the output.
    If no USB drive is found, prompts for a file path.

.EXAMPLE
    .\usuap-diag.ps1
#>

[CmdletBinding()]
param()

# --- Find output location ---------------------------------------------------
$usbDrive = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } | Select-Object -First 1
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

if ($usbDrive) {
    $driveLetter = $usbDrive.DriveLetter
    $outPath = "${driveLetter}:\AutopilotDiag_${timestamp}.txt"

    Write-Host ""
    Write-Host "Found USB drive: ${driveLetter}:\ ($($usbDrive.FileSystemLabel))" -ForegroundColor Green
    Write-Host "Output file:     $outPath" -ForegroundColor Gray
    Write-Host ""
    $response = Read-Host "Save here? (Y = yes, N = cancel, or enter a custom file path)"

    switch -Regex ($response.Trim()) {
        '^[Yy]$' {
            # keep $outPath as-is
            break
        }
        '^[Nn]$' {
            Write-Host "Cancelled." -ForegroundColor Yellow
            exit 0
        }
        '.+' {
            $outPath = $response.Trim()
            break
        }
        default {
            Write-Error "No input provided. Exiting."
            exit 1
        }
    }
} else {
    Write-Warning "No removable USB drive detected."
    $outPath = Read-Host "Enter full output file path (e.g. C:\AutopilotDiag.txt)"
    if (-not $outPath) {
        Write-Error "No path provided. Exiting."
        exit 1
    }
}

Write-Host "Output will be saved to: $outPath" -ForegroundColor Cyan

# --- Install prerequisites ---------------------------------------------------
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Host "Installing NuGet package provider..." -ForegroundColor Cyan
    Find-PackageProvider -Name NuGet -ForceBootstrap -IncludeDependencies | Out-Null
}

$scriptName = "Get-AutopilotDiagnosticsCommunity"
if (-not (Get-InstalledScript -Name $scriptName -ErrorAction SilentlyContinue)) {
    Write-Host "Installing $scriptName..." -ForegroundColor Cyan
    Install-Script -Name $scriptName -Force
}

# --- Run diagnostics ---------------------------------------------------------
Write-Host "Running Autopilot diagnostics (this may take a minute)..." -ForegroundColor Cyan

try {
    & $scriptName -Online | Out-File -FilePath $outPath -Encoding UTF8
    Write-Host "Diagnostics saved to: $outPath" -ForegroundColor Green
}
catch {
    Write-Error "Failed to run diagnostics: $_"
    exit 1
}