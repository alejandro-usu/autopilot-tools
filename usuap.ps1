<#
.SYNOPSIS
    Registers the local device with Windows Autopilot via Microsoft Graph.

.DESCRIPTION
    Installs prerequisites, connects to Microsoft Graph interactively, collects
    the local device's hardware hash, and uploads it to the Autopilot import
    service. Optionally applies a group tag and/or assigns a device name.

.PARAMETER GroupTag
    Optional group tag to apply to the Autopilot device record.

.PARAMETER AssignedComputerName
    Optional computer name to assign to the device after Autopilot import completes.
    Must be 15 characters or fewer, alphanumeric with hyphens allowed (not at start or end).

.PARAMETER UseWAM
    Re-enables the new method of signing in, which allows for use of security keys, but shows that bothersome all apps page that messes with enrollment.

.PARAMETER Reboot
    Reboots the computer after completion. Defaults to 10 second delay unless RebootDelay is set

.PARAMETER RebootDelay
    Optional for reboot in seconds after successful upload (only applies if -Reboot is specified)

.PARAMETER AutoRemove
    Autoremove the script after successful upload (done regardless if -Reboot is specified)

.EXAMPLE
    .\get-usuap.ps1
    .\get-usuap.ps1 -GroupTag "DPINFT"
    .\get-usuap.ps1 -GroupTag "DPINFT" -AssignedComputerName "LAB-PC-042"
    .\get-usuap.ps1 -GroupTag "DPINFT" -AssignedComputerName "LAB-PC-042" -AutoRemove
    .\get-usuap.ps1 -GroupTag "DPINFT" -Reboot -RebootDelay 5
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GroupTag = "",
    [Parameter(Mandatory = $false)]
    [string]$AssignedComputerName = "",
    [Parameter(Mandatory = $false)]
    [switch]$UseWAM,
    [switch]$Reboot,
    [Parameter(Mandatory = $false)]
    [int]$RebootDelay,
    [switch]$AutoRemove
)
$CLIENT_ID = "87d8aa30-7d13-4f37-8914-ebe8c7097789"
$TENANT_ID = "ac352f9b-eb63-4ca2-9cf9-f4c40047ceff"


if ($GroupTag) {
    if ($GroupTag -notmatch 'DP[A-Z]{3,4}') {
        Write-Error "GroupTag must contain 'DP' followed by 3 or 4 uppercase letters (e.g. DPABC, Finance-DPABCD)."
        exit 1
    }
    if ($GroupTag -match '^-' -or $GroupTag -match '-$') {
        Write-Error "GroupTag must not start or end with a dash."
        exit 1
    }
}

if (-not $AssignedComputerName) {
    $AssignedComputerName = Read-Host "Enter computer name (leave blank to skip)"
}

if ($AssignedComputerName) {
    if ($AssignedComputerName.Length -gt 15) {
        Write-Error "Computer name must be 15 characters or fewer."
        exit 1
    }
    if ($AssignedComputerName.Length -eq 1) {
        if ($AssignedComputerName -notmatch '^[a-zA-Z0-9]$') {
            Write-Error "Computer name must be alphanumeric (hyphens allowed, not at start or end)."
            exit 1
        }
    } else {
        if ($AssignedComputerName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,13}[a-zA-Z0-9]$') {
            Write-Error "Computer name must be alphanumeric (hyphens allowed, not at start or end)."
            exit 1
        }
    }
}

if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Host "Installing NuGet package provider..." -ForegroundColor Cyan
    Find-PackageProvider -Name NuGet -ForceBootstrap -IncludeDependencies | Out-Null
}

if (-not (Get-Module -Name Microsoft.Graph.Authentication -ListAvailable)) {
    Write-Host "Installing Microsoft.Graph.Authentication module..." -ForegroundColor Cyan
    Install-Module Microsoft.Graph.Authentication -Force -Scope CurrentUser
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
if (!$UseWAM) {
    Set-MgGraphOption -DisableLoginByWAM $true
}
try {
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All" -NoWelcome -TenantId $TENANT_ID -ClientId $CLIENT_ID
} catch {
    exit 1
}

$context = Get-MgContext
if (-not $context) {
    exit 1
}

Write-Host "Collecting hardware information from this device..." -ForegroundColor Cyan

try {
    $bios      = Get-WmiObject -Class Win32_BIOS -ErrorAction Stop
    $serial    = $bios.SerialNumber.Trim()
}
catch {
    Write-Error "Failed to retrieve serial number via WMI: $_"
    exit 1
}

try {
    $devDetail    = Get-WmiObject -Namespace root/cimv2/mdm/dmmap `
                        -Class MDM_DevDetail_Ext01 `
                        -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" `
                        -ErrorAction Stop
    $hardwareHash = $devDetail.DeviceHardwareData
}
catch {
    Write-Error "Failed to retrieve hardware hash via WMI. Ensure the script is running as Administrator: $_"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($hardwareHash)) {
    Write-Error "Hardware hash is empty. Cannot register device."
    exit 1
}

Write-Host "  Serial number : $serial" -ForegroundColor Gray
if ($GroupTag)            { Write-Host "  Group tag     : $GroupTag"            -ForegroundColor Gray }
if ($AssignedComputerName) { Write-Host "  Computer name : $AssignedComputerName" -ForegroundColor Gray }

$importUri = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities"

$importBody = @{
    serialNumber       = $serial
    hardwareIdentifier = $hardwareHash
    groupTag           = $GroupTag
    "@odata.type"      = "#microsoft.graph.importedWindowsAutopilotDeviceIdentity"

} | ConvertTo-Json

Write-Host "Uploading device to Autopilot..." -ForegroundColor Cyan

try {
    $importResult = Invoke-MgGraphRequest -Method POST -Uri $importUri `
                        -Body $importBody -ContentType "application/json" -ErrorAction Stop
}
catch {
    Write-Error "Failed to submit device import: $_"
    exit 1
}

$importedId = $importResult.id
if (-not $importedId) {
    Write-Error "Import request succeeded but returned no record ID. Cannot poll for status."
    exit 1
}
Write-Host "  Import record ID: $importedId" -ForegroundColor Gray

Write-Host "Waiting for import to complete..." -ForegroundColor Cyan

$statusUri = "$importUri/$importedId"
$startTime = [datetime]::UtcNow
$timeout   = $startTime.AddMinutes(10)
$importStatus = "unknown"
$extraMessage = ">"

while ([datetime]::UtcNow -lt $timeout) {
    Start-Sleep -Seconds 1
    $elapsed = [int]([datetime]::UtcNow - $startTime).TotalSeconds
    Write-Host "`r  Elapsed: ${elapsed}s ${extraMessage}" -NoNewline


    # Poll the API every 5 seconds because the default 15 is awful
    if ($elapsed % 5 -eq 0) {
        $extraMessage = ("-" * $extraMessage.Length) + ">"
        try {
            $statusResult = Invoke-MgGraphRequest -Method GET -Uri $statusUri -ErrorAction Stop
        }
        catch {
            Write-Warning "`nStatus check failed: $_"
            continue
        }

        $importStatus = $statusResult.state.deviceImportStatus
        if ($importStatus -ne "unknown") { break }
    }
}

Write-Host ""

switch ($importStatus) {
    "complete" {
        Write-Host "Device successfully registered with Autopilot." -ForegroundColor Green

        if ($AssignedComputerName) {
            Write-Host "Setting assigned computer name to '$AssignedComputerName'..." -ForegroundColor Cyan

            $autopilotUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities"
            $filterUri    = "${autopilotUri}?`$filter=contains(serialNumber,'$serial')"

            $retryCount = 0
            $maxRetries = 3
            $device     = $null

            while ($retryCount -lt $maxRetries -and -not $device) {
                try {
                    $device = (Invoke-MgGraphRequest -Method GET -Uri $filterUri -ErrorAction Stop).value | Select-Object -First 1
                }
                catch {
                    Write-Warning "Failed to query Autopilot device: $_"
                }

                if (-not $device) {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Write-Host "  Waiting for device to appear in Autopilot (attempt $retryCount of $maxRetries)..." -ForegroundColor Gray
                        Start-Sleep -Seconds 5
                    }
                }
            }

            if ($device) {
                $updateUri  = "$autopilotUri/$($device.id)/updateDeviceProperties"
                $updateBody = @{ displayName = $AssignedComputerName } | ConvertTo-Json

                try {
                    Invoke-MgGraphRequest -Method POST -Uri $updateUri -Body $updateBody -ContentType "application/json" -ErrorAction Stop
                    Write-Host "  Computer name set successfully." -ForegroundColor Green
                }
                catch {
                    Write-Warning "Failed to set computer name: $_`nYou may need to set it manually in Intune."
                }
            } else {
                Write-Warning "Could not find Autopilot device with serial '$serial' to set computer name. You may need to set it manually in Intune."
            }
        }

        if ($AutoRemove -or $Reboot) {
            Remove-Item $PSCommandPath
        }
        if ($Reboot) {
            if (!$RebootDelay) {
                $RebootDelay = 10
            }
            Write-Host "Rebooting in $RebootDelay seconds..."
            Start-Sleep $RebootDelay
            Restart-Computer
        }
    }
    "error" {
        $errorCode = $statusResult.state.deviceErrorCode
        $errorName = $statusResult.state.deviceErrorName
        Write-Error "Import failed. Error $errorCode : $errorName"
        exit 1
    }
    "completedWithErrors" {
        Write-Warning "Import completed with errors: $($statusResult.state.deviceErrorName)"
    }
    default {
        Write-Warning "Import timed out or returned unexpected status: $importStatus"
    }
}
