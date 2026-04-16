<#
.SYNOPSIS
    Registers the local device with Windows Autopilot via Microsoft Graph.

.DESCRIPTION
    Installs prerequisites, connects to Microsoft Graph interactively, collects
    the local device's hardware hash, and uploads it to the Autopilot import
    service. Optionally applies a group tag and/or assigns a device name.

.PARAMETER GroupTag
    Optional group tag to apply to the Autopilot device record.
    Must contain 'DP' followed by 3 or 4 uppercase letters and must not
    start or end with a dash.

.PARAMETER OverrideGroupTag
    Bypasses the standard GroupTag validation. Use for rare but valid
    group tag formats that don't follow the DP naming convention.

.PARAMETER AssignedComputerName
    Optional computer name to assign to the device after Autopilot import
    completes. Must be 15 characters or fewer, alphanumeric with hyphens
    allowed (not at start or end). If not specified, no name is assigned.
    Cannot be used with -AssignedPrefix.

.PARAMETER AssignedPrefix
    Optional prefix for auto-generating a computer name. The script will
    append "-<SerialNumber>" to the prefix, truncated to fit the 15
    character Windows limit. For example, -AssignedPrefix "DPINFT" on a
    device with serial ABC12345 produces "DPINFT-ABC12345".
    Cannot be used with -AssignedComputerName.

.PARAMETER UseWAM
    Re-enables the new method of signing in, which allows for use of
    security keys, but shows that bothersome all apps page that messes
    with enrollment.

.PARAMETER Reboot
    Reboots the computer after completion. Defaults to 5 second delay
    unless RebootDelay is set.

.PARAMETER Shutdown
    Shuts down the computer after completion. Defaults to 5 second delay
    unless ShutdownDelay is set. Cannot be used with -Reboot.

.PARAMETER RebootDelay
    Delay in seconds before reboot (only applies if -Reboot is specified).

.PARAMETER ShutdownDelay
    Delay in seconds before shutdown (only applies if -Shutdown is specified).

.PARAMETER AutoRemove
    Removes the script file after successful upload (done regardless if
    -Reboot or -Shutdown is specified).

.EXAMPLE
    .\usuap.ps1 -GroupTag "DPINFT"
    .\usuap.ps1 -GroupTag "Lab-DPINFT"
    .\usuap.ps1 -GroupTag "Shared-DPINFT" -AssignedComputerName "DPINFT-Lab-01"
    .\usuap.ps1 -GroupTag "DPINFT" -AssignedPrefix "DPINFT"
    .\usuap.ps1 -GroupTag "DPINFT" -AssignedPrefix "LAB"
    .\usuap.ps1 -GroupTag "DPINFT" -Reboot -RebootDelay 5
    .\usuap.ps1 -GroupTag "DPINFT" -Shutdown
    .\usuap.ps1 -GroupTag "SomeDifferentTag" -OverrideGroupTag
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GroupTag = "",
    [switch]$OverrideGroupTag,
    [Parameter(Mandatory = $false)]
    [string]$AssignedComputerName = "",
    [Parameter(Mandatory = $false)]
    [string]$AssignedPrefix = "",
    [Parameter(Mandatory = $false)]
    [switch]$UseWAM,
    [switch]$Reboot,
    [switch]$Shutdown,
    [Parameter(Mandatory = $false)]
    [int]$RebootDelay,
    [Parameter(Mandatory = $false)]
    [int]$ShutdownDelay,
    [switch]$AutoRemove,
    [Alias("1888")]
    [switch]$GoAggies
)
$CLIENT_ID = "87d8aa30-7d13-4f37-8914-ebe8c7097789"
$TENANT_ID = "ac352f9b-eb63-4ca2-9cf9-f4c40047ceff"

# --- Easter egg: USU themed output -------------------------------------------
$script:MockIndex = 0
function Write-USU {
    param(
        [string]$Text,
        [string]$ForegroundColor = "White"
    )
    if ($GoAggies) {
        $usuColors = @("DarkBlue", "Blue", "DarkCyan", "Cyan", "White")
        $mocked = -join ($Text.ToCharArray() | ForEach-Object {
            $script:MockIndex++
            if ($_ -match '[a-zA-Z]') {
                if ($script:MockIndex % 2 -eq 0) { $_.ToString().ToUpper() }
                else { $_.ToString().ToLower() }
            } else { $_ }
        })
        $color = $usuColors[$script:MockIndex % $usuColors.Count]
        Write-Host $mocked -ForegroundColor $color
    } else {
        Write-Host $Text -ForegroundColor $ForegroundColor
    }
}

# --- Validation ---------------------------------------------------------------
if ($GroupTag -and -not $OverrideGroupTag) {
    if ($GroupTag -notmatch 'DP[A-Z]{3,4}') {
        Write-Error "GroupTag must contain 'DP' followed by 3 or 4 uppercase letters (e.g. DPINFT, Lab-DPINFT, Shared-DPINFT)."
        exit 1
    }
    if ($GroupTag -match '^-' -or $GroupTag -match '-$') {
        Write-Error "GroupTag must not start or end with a dash."
        exit 1
    }
}

if ($AssignedComputerName -and $AssignedPrefix) {
    Write-Error "Cannot specify both -AssignedComputerName and -AssignedPrefix. Use one or the other."
    exit 1
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

if ($AssignedPrefix) {
    # Prefix + "-" must leave at least 1 character for the serial
    if (($AssignedPrefix.Length + 1) -ge 15) {
        Write-Error "AssignedPrefix is too long. Prefix plus '-' must leave room for the serial number (15 char max)."
        exit 1
    }
    if ($AssignedPrefix -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$' -and $AssignedPrefix.Length -gt 1) {
        Write-Error "AssignedPrefix must be alphanumeric (hyphens allowed, not at start or end)."
        exit 1
    }
}

if ($Reboot -and $Shutdown) {
    Write-Error "Cannot specify both -Reboot and -Shutdown."
    exit 1
}

# --- Prerequisites ------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null

if (-not (Get-Module -Name Microsoft.Graph.Authentication -ListAvailable)) {
    Write-USU "Installing Microsoft.Graph.Authentication module..." -ForegroundColor Cyan
    Install-Module Microsoft.Graph.Authentication -Force -Scope CurrentUser
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# --- Connect to Graph ---------------------------------------------------------
Write-USU "Connecting to Microsoft Graph..." -ForegroundColor Cyan
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

# --- Collect hardware info ----------------------------------------------------
Write-USU "Collecting hardware information from this device..." -ForegroundColor Cyan

try {
    $bios   = Get-WmiObject -Class Win32_BIOS -ErrorAction Stop
    $serial = $bios.SerialNumber.Trim()
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

# --- Auto-generate computer name from prefix if provided ----------------------
if ($AssignedPrefix) {
    $fullPrefix = "$AssignedPrefix-"
    $maxSerial  = 15 - $fullPrefix.Length
    $truncatedSerial = $serial.Substring(0, [Math]::Min($serial.Length, $maxSerial))
    $AssignedComputerName = "$fullPrefix$truncatedSerial"
    Write-USU "  Auto-generated computer name: $AssignedComputerName" -ForegroundColor Cyan
}

# --- Display device info ------------------------------------------------------
Write-USU "  Serial number : $serial" -ForegroundColor Gray
if ($GroupTag)             { Write-USU "  Group tag     : $GroupTag"             -ForegroundColor Gray }
if ($AssignedComputerName) { Write-USU "  Computer name : $AssignedComputerName" -ForegroundColor Gray }

# --- Upload to Autopilot ------------------------------------------------------
$importUri = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities"

$importBody = @{
    serialNumber       = $serial
    hardwareIdentifier = $hardwareHash
    groupTag           = $GroupTag
    "@odata.type"      = "#microsoft.graph.importedWindowsAutopilotDeviceIdentity"
} | ConvertTo-Json

Write-USU "Uploading device to Autopilot..." -ForegroundColor Cyan

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
Write-USU "  Import record ID: $importedId" -ForegroundColor Gray

# --- Wait for import to complete ----------------------------------------------
Write-USU "Waiting for import to complete..." -ForegroundColor Cyan

$statusUri    = "$importUri/$importedId"
$startTime    = [datetime]::UtcNow
$timeout      = $startTime.AddMinutes(10)
$importStatus = "unknown"
$extraMessage = ">"

while ([datetime]::UtcNow -lt $timeout) {
    Start-Sleep -Seconds 1
    $elapsed = [int]([datetime]::UtcNow - $startTime).TotalSeconds
    Write-Host "`r  Elapsed: ${elapsed}s ${extraMessage}" -NoNewline

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

# --- Handle result ------------------------------------------------------------
switch ($importStatus) {
    "complete" {
        Write-USU "Device successfully registered with Autopilot." -ForegroundColor Green

        if ($GoAggies) {
            Write-Host ""
            Write-Host "  gO aGgIeS!!!" -ForegroundColor Blue
            Write-Host ""
        }

        # --- Set computer name if provided ------------------------------------
        if ($AssignedComputerName) {
            Write-USU "Setting assigned computer name to '$AssignedComputerName'..." -ForegroundColor Cyan

            $autopilotUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities"
            $filterUri    = "${autopilotUri}?`$filter=contains(serialNumber,'$serial')"

            $device      = $null
            $nameTimeout = [datetime]::UtcNow.AddMinutes(5)

            while (-not $device -and [datetime]::UtcNow -lt $nameTimeout) {
                try {
                    $device = (Invoke-MgGraphRequest -Method GET -Uri $filterUri -ErrorAction Stop).value | Select-Object -First 1
                }
                catch {
                    Write-Warning "Failed to query Autopilot device: $_"
                }

                if (-not $device) {
                    $remaining = [int]($nameTimeout - [datetime]::UtcNow).TotalSeconds
                    Write-USU "  Waiting for device to appear in Autopilot... (${remaining}s remaining)" -ForegroundColor Gray
                    Start-Sleep -Seconds 5
                }
            }

            if ($device) {
                $updateUri  = "$autopilotUri/$($device.id)/updateDeviceProperties"
                $updateBody = @{ displayName = $AssignedComputerName } | ConvertTo-Json

                try {
                    Invoke-MgGraphRequest -Method POST -Uri $updateUri -Body $updateBody -ContentType "application/json" -ErrorAction Stop
                    Write-USU "  Computer name set successfully." -ForegroundColor Green
                }
                catch {
                    Write-Warning "Failed to set computer name: $_`nYou may need to set it manually in Intune."
                }
            } else {
                Write-Warning "Timed out waiting for device '$serial' to appear in Autopilot. You may need to set the name manually in Intune."
            }
        }

        # --- Cleanup and reboot/shutdown --------------------------------------
        if ($AutoRemove -or $Reboot -or $Shutdown) {
            Remove-Item $PSCommandPath
        }
        if ($Reboot) {
            if (!$RebootDelay) { $RebootDelay = 5 }
            Write-USU "Rebooting in $RebootDelay seconds..."
            Start-Sleep $RebootDelay
            Restart-Computer
        }
        if ($Shutdown) {
            if (!$ShutdownDelay) { $ShutdownDelay = 5 }
            Write-USU "Shutting down in $ShutdownDelay seconds..."
            Start-Sleep $ShutdownDelay
            Stop-Computer
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
