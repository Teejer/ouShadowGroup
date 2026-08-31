#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Creates AD groups containing every user account in given OUs.

.DESCRIPTION
    Runs against a single OU (-OU/-GroupName), a CSV file (-CsvPath), or the
    default ./groups.csv in the current directory when no OU or CSV is given.
    Required CSV columns: OU, GroupName. Optional columns:
    GroupPath, GroupScope, GroupCategory, Description. Blank optional cells
    fall back to the script-level parameters/defaults.

    Example CSV:
        OU,GroupName,GroupPath
        "OU=Sales,DC=contoso,DC=com","GG-Sales-AllUsers","OU=Groups,DC=contoso,DC=com"
        "OU=IT,DC=contoso,DC=com","GG-IT-AllUsers","OU=Groups,DC=contoso,DC=com"

    Every run writes timestamped log files to -LogDirectory:
        ou-shadow-group-success-<timestamp>.log
        ou-shadow-group-failure-<timestamp>.log
    The failure log is deleted again if nothing failed.

.EXAMPLE
    .\New-OuShadowGroup.ps1 -OU "OU=Sales,DC=contoso,DC=com" -GroupName "GG-Sales-AllUsers"

.EXAMPLE
    .\New-OuShadowGroup.ps1 -OU "OU=Sales,DC=contoso,DC=com" -GroupName "GG-Sales-AllUsers" -GroupPath "OU=Groups,DC=contoso,DC=com" -IncludeSubOUs -EnabledOnly -Verbose

.EXAMPLE
    .\New-OuShadowGroup.ps1 -CsvPath .\ous.csv -LogDirectory C:\Logs -WhatIf

.EXAMPLE
    .\New-OuShadowGroup.ps1   # uses .\groups.csv if present
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'SingleOU')]
param(
    # Source OU. With -GroupName (and -GroupPath) runs single-OU mode;
    # without anything, falls back to .\groups.csv.
    [Parameter(ParameterSetName = 'SingleOU')]
    [string]$OU,

    [Parameter(ParameterSetName = 'SingleOU')]
    [ValidateNotNullOrEmpty()]
    [string]$GroupName,

    # OU where the new group object will be created. Defaults to -OU.
    [Parameter(ParameterSetName = 'SingleOU')]
    [string]$GroupPath,

    # CSV with columns: OU, GroupName, [GroupPath], [GroupScope], [GroupCategory], [Description].
    # Defaults to .\groups.csv when neither -OU nor -CsvPath is given.
    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

    # Where the success/failure log files are written. Created if missing.
    [string]$LogDirectory = '.',

    [ValidateSet('Global', 'DomainLocal', 'Universal')]
    [string]$GroupScope = 'Global',

    [ValidateSet('Security', 'Distribution')]
    [string]$GroupCategory = 'Security',

    # Default description; per-row 'Description' column overrides.
    [string]$GroupDescription,

    [switch]$IncludeSubOUs,

    [switch]$EnabledOnly
)

function New-OuShadowGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$OU,
        [Parameter(Mandatory)][string]$GroupName,
        [string]$GroupPath,
        [ValidateSet('Global', 'DomainLocal', 'Universal')][string]$GroupScope = 'Global',
        [ValidateSet('Security', 'Distribution')][string]$GroupCategory = 'Security',
        [string]$GroupDescription,
        [switch]$IncludeSubOUs,
        [switch]$EnabledOnly
    )

    if ([string]::IsNullOrWhiteSpace($GroupDescription)) {
        $GroupDescription = "Auto-generated: all user accounts in $OU"
    }

    # Validate the source OU exists
    try {
        $ouObj = Get-ADOrganizationalUnit -Identity $OU -ErrorAction Stop
    }
    catch {
        throw "Could not find OU '$OU'. Verify the distinguished name is correct. Error: $_"
    }

    # Build the user filter
    $userFilter = if ($EnabledOnly) { { $_.Enabled -eq $true } } else { { $_.ObjectClass -eq 'user' } }

    $searchScope = if ($IncludeSubOUs) { 'Subtree' } else { 'OneLevel' }

    Write-Verbose "Searching $OU (scope: $searchScope) for users..."
    $users = @(Get-ADUser -Filter $userFilter -SearchBase $OU -SearchScope $searchScope -Properties Enabled)

    if ($users.Count -eq 0) {
        throw "No user accounts found in '$OU'."
    }

    Write-Verbose "Found $($users.Count) user(s)."

    # Resolve where the group object will live
    if ([string]::IsNullOrWhiteSpace($GroupPath)) {
        $GroupPath = $ouObj.DistinguishedName
    }
    else {
        try {
            $GroupPath = (Get-ADOrganizationalUnit -Identity $GroupPath -ErrorAction Stop).DistinguishedName
        }
        catch {
            throw "Could not find the group destination OU '$GroupPath'. Error: $_"
        }
    }

    # Existing group? Compute who still needs to be added.
    $group = $null
    $currentMembers = @()
    $toAdd = $users

    $existingGroup = Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue
    if ($existingGroup) {
        Write-Warning "Group '$GroupName' already exists; adding members to it."
        $group = $existingGroup
        $currentMembers = @(Get-ADGroupMember -Identity $group -Recursive:$false |
            Where-Object { $_.objectClass -eq 'user' } |
            Select-Object -ExpandProperty distinguishedName)
        $toAdd = @($users | Where-Object { $currentMembers -notcontains $_.DistinguishedName })
    }

    # -WhatIf: show intentions and return a preview without changing anything
    if ($WhatIfPreference) {
        if (-not $existingGroup) {
            $null = $PSCmdlet.ShouldProcess("$GroupName in $GroupPath", 'Create AD group')
        }
        if ($toAdd.Count -gt 0) {
            $null = $PSCmdlet.ShouldProcess("$($toAdd.Count) user(s) into $GroupName", 'Add to group')
        }
        else {
            Write-Verbose "'$GroupName' is up to date; nothing to add."
        }
        return [pscustomobject]@{
            OU        = $OU
            GroupName = $GroupName
            GroupDN   = if ($existingGroup) { $existingGroup.DistinguishedName } else { $null }
            Added     = $toAdd.Count
            Total     = $null
            UpToDate  = ($toAdd.Count -eq 0)
            WhatIf    = $true
        }
    }

    # Create the group if it doesn't exist
    if (-not $group) {
        if (-not $PSCmdlet.ShouldProcess("$GroupName in $GroupPath", 'Create AD group')) {
            return $null    # user declined via -Confirm
        }
        $group = New-ADGroup -Name $GroupName `
                             -GroupScope $GroupScope `
                             -GroupCategory $GroupCategory `
                             -Description $GroupDescription `
                             -Path $GroupPath `
                             -PassThru
        Write-Verbose "Created group $($group.DistinguishedName)."
    }

    if ($toAdd.Count -eq 0) {
        Write-Verbose "'$GroupName' is already up to date."
        return [pscustomobject]@{
            OU = $OU; GroupName = $GroupName; GroupDN = $group.DistinguishedName
            Added = 0; Total = $currentMembers.Count; UpToDate = $true; WhatIf = $false
        }
    }

    Write-Verbose "Adding $($toAdd.Count) member(s) to '$GroupName'..."

    # Add in batches of 100 (recommended max per operation)
    for ($i = 0; $i -lt $toAdd.Count; $i += 100) {
        $batch = $toAdd | Select-Object -Skip $i -First 100
        Add-ADGroupMember -Identity $group -Members $batch
    }

    $finalCount = @(Get-ADGroupMember -Identity $group -Recursive:$false).Count
    return [pscustomobject]@{
        OU = $OU; GroupName = $GroupName; GroupDN = $group.DistinguishedName
        Added = $toAdd.Count; Total = $finalCount; UpToDate = $false; WhatIf = $false
    }
}

function Write-RunLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    ('{0} | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) |
        Out-File -FilePath $Path -Append -Encoding utf8 -WhatIf:$false
}

function Convert-ResultToMessage {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    if ($Result.WhatIf) {
        if ($Result.UpToDate) { "WhatIf: already up to date; nothing to add" }
        else { "WhatIf: would add $($Result.Added) user(s)" }
    }
    elseif ($Result.UpToDate) { "Up to date ($($Result.Total) members)" }
    else { "Added $($Result.Added) user(s), total members now $($Result.Total)" }
}

$ErrorActionPreference = 'Stop'

# --- Determine mode (default to .\groups.csv when nothing is passed) ---
$mode = if ($OU) { 'SingleOU' } else { 'Csv' }

if (-not $OU -and -not $CsvPath) {
    $defaultCsv = Join-Path (Get-Location).Path 'groups.csv'
    if (Test-Path -LiteralPath $defaultCsv -PathType Leaf) {
        $CsvPath = $defaultCsv
        Write-Verbose "No -OU/-CsvPath given; using default '$defaultCsv'."
    }
    else {
        throw "Pass -OU and -GroupName (or -CsvPath), or place a groups.csv in the current directory."
    }
}
elseif ($OU -and -not $GroupName) {
    throw "-GroupName is required when -OU is used."
}
elseif (-not $OU -and $GroupName) {
    throw "-OU is required when -GroupName is used."
}

# --- Set up split success/failure log files ---
if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force -WhatIf:$false | Out-Null
}
$logRoot = (Resolve-Path -LiteralPath $LogDirectory).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$SuccessLog = Join-Path $logRoot "ou-shadow-group-success-$stamp.log"
$FailureLog = Join-Path $logRoot "ou-shadow-group-failure-$stamp.log"

$header = "=== ouShadowGroup run {0} | mode: {1} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mode
$header | Out-File -FilePath $SuccessLog -Encoding utf8 -WhatIf:$false
$header | Out-File -FilePath $FailureLog -Encoding utf8 -WhatIf:$false

$succeeded = 0
$failed = 0
$total = 0

Write-Verbose "Success log: $SuccessLog"
Write-Verbose "Failure log: $FailureLog (deleted again if nothing fails)"

if ($mode -eq 'SingleOU') {
    # --- Single OU mode ---
    $total = 1
    $params = @{
        OU            = $OU
        GroupName     = $GroupName
        GroupScope    = $GroupScope
        GroupCategory = $GroupCategory
        IncludeSubOUs = $IncludeSubOUs
        EnabledOnly   = $EnabledOnly
    }
    if ($GroupPath)        { $params.GroupPath = $GroupPath }
    if ($GroupDescription) { $params.GroupDescription = $GroupDescription }

    try {
        $result = New-OuShadowGroup @params
        if ($result) {
            $succeeded = 1
            Write-RunLog -Path $SuccessLog -Message ("{0} | {1} | {2}" -f $result.OU, $result.GroupName, (Convert-ResultToMessage $result))
        }
        else {
            $failed = 1
            Write-RunLog -Path $FailureLog -Message ("{0} | {1} | operation skipped (declined)" -f $OU, $GroupName)
        }
    }
    catch {
        $failed = 1
        Write-RunLog -Path $FailureLog -Message ("{0} | {1} | {2}" -f $OU, $GroupName, $_.Exception.Message)
        Write-Error "Failure logged to $FailureLog" -ErrorAction Continue
        throw
    }
}
else {
    # --- CSV mode ---
    $rows = @(Import-Csv -LiteralPath $CsvPath)

    if ($rows.Count -eq 0) {
        Write-Warning "CSV file '$CsvPath' contains no rows. Nothing to do."
    }
    else {
        $required = @('OU', 'GroupName')
        $headers = $rows[0].PSObject.Properties.Name
        $missing = $required | Where-Object { $_ -notin $headers }
        if ($missing) {
            throw "CSV is missing required column(s): $($missing -join ', '). Expected headers: OU, GroupName [, GroupPath] [, GroupScope] [, GroupCategory] [, Description]"
        }

        $total = $rows.Count

        foreach ($row in $rows) {
            $rowOU = if ($row.PSObject.Properties['OU']) { $row.OU.Trim() } else { '' }
            $rowGroup = if ($row.PSObject.Properties['GroupName']) { $row.GroupName.Trim() } else { '' }

            if ([string]::IsNullOrWhiteSpace($rowOU) -or [string]::IsNullOrWhiteSpace($rowGroup)) {
                $failed++
                Write-RunLog -Path $FailureLog -Message ("(blank) | (blank) | row has empty OU or GroupName: {0}" -f ($row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Out-String).Trim())
                Write-Warning "Skipping row with empty OU or GroupName."
                continue
            }

            $params = @{
                OU            = $rowOU
                GroupName     = $rowGroup
                IncludeSubOUs = $IncludeSubOUs
                EnabledOnly   = $EnabledOnly
            }

            # Per-row optional overrides, falling back to script-level parameters
            foreach ($col in 'GroupPath', 'GroupScope', 'GroupCategory', 'Description') {
                $val = if ($row.PSObject.Properties[$col]) { "$($row.$col)".Trim() } else { '' }
                switch ($col) {
                    'GroupPath'     { if ($val) { $params.GroupPath = $val } }
                    'GroupScope'    { $params.GroupScope = if ($val) { $val } else { $GroupScope } }
                    'GroupCategory' { $params.GroupCategory = if ($val) { $val } else { $GroupCategory } }
                    'Description'   { $params.GroupDescription = if ($val) { $val } else { $GroupDescription } }
                }
            }

            Write-Host "--- Processing: $rowOU -> $rowGroup ---"
            try {
                $result = New-OuShadowGroup @params
                if ($result) {
                    $succeeded++
                    $msg = Convert-ResultToMessage $result
                    Write-Host "    OK: $msg"
                    Write-RunLog -Path $SuccessLog -Message ("{0} | {1} | {2}" -f $result.OU, $result.GroupName, $msg)
                }
                else {
                    $failed++
                    Write-RunLog -Path $FailureLog -Message ("{0} | {1} | operation skipped (declined)" -f $rowOU, $rowGroup)
                }
            }
            catch {
                $failed++
                Write-Host "    FAILED: $_"
                Write-RunLog -Path $FailureLog -Message ("{0} | {1} | {2}" -f $rowOU, $rowGroup, $_.Exception.Message)
            }
        }
    }
}

# --- Summary ---
Write-Output "Completed: $succeeded succeeded, $failed failed (of $total)."
Write-Output "Success log: $SuccessLog"
if ($failed -gt 0) {
    Write-Output "Failure log: $FailureLog"
    exit 1
}
Remove-Item -LiteralPath $FailureLog -ErrorAction SilentlyContinue -WhatIf:$false
exit 0
