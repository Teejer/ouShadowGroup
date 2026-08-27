#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Creates AD groups containing every user account in given OUs.

.DESCRIPTION
    Runs against a single OU (-OU/-GroupName) or a CSV file (-CsvPath) with one
    OU per row. Required CSV columns: OU, GroupName. Optional columns:
    GroupPath, GroupScope, GroupCategory, Description. Blank optional cells
    fall back to the script-level parameters/defaults.

    Example CSV:
        OU,GroupName,GroupPath
        "OU=Sales,DC=contoso,DC=com","GG-Sales-AllUsers","OU=Groups,DC=contoso,DC=com"
        "OU=IT,DC=contoso,DC=com","GG-IT-AllUsers","OU=Groups,DC=contoso,DC=com"

.EXAMPLE
    .\New-OuShadowGroup.ps1 -OU "OU=Sales,DC=contoso,DC=com" -GroupName "GG-Sales-AllUsers"

.EXAMPLE
    .\New-OuShadowGroup.ps1 -OU "OU=Sales,DC=contoso,DC=com" -GroupName "GG-Sales-AllUsers" -GroupPath "OU=Groups,DC=contoso,DC=com" -IncludeSubOUs -EnabledOnly -Verbose

.EXAMPLE
    .\New-OuShadowGroup.ps1 -CsvPath .\ous.csv -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'SingleOU')]
param(
    [Parameter(Mandatory, ParameterSetName = 'SingleOU')]
    [string]$OU,

    [Parameter(Mandatory, ParameterSetName = 'SingleOU')]
    [ValidateNotNullOrEmpty()]
    [string]$GroupName,

    # OU where the new group object will be created. Defaults to -OU.
    [Parameter(ParameterSetName = 'SingleOU')]
    [string]$GroupPath,

    # CSV with columns: OU, GroupName, [GroupPath], [GroupScope], [GroupCategory], [Description]
    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

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
        Write-Warning "No user accounts found in '$OU'. Skipping."
        return
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

    # Create the group or reuse the existing one
    $existingGroup = Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue

    if ($existingGroup) {
        Write-Warning "Group '$GroupName' already exists; adding members to it."
        $group = $existingGroup
    }
    elseif ($PSCmdlet.ShouldProcess("$GroupName in $GroupPath", 'Create AD group')) {
        $group = New-ADGroup -Name $GroupName `
                             -GroupScope $GroupScope `
                             -GroupCategory $GroupCategory `
                             -Description $GroupDescription `
                             -Path $GroupPath `
                             -PassThru
        Write-Verbose "Created group $($group.DistinguishedName)."
    }

    # Only add users who aren't already members
    $currentMembers = Get-ADGroupMember -Identity $group -Recursive:$false |
        Where-Object { $_.objectClass -eq 'user' } |
        Select-Object -ExpandProperty distinguishedName

    $toAdd = $users | Where-Object { $currentMembers -notcontains $_.DistinguishedName }

    if (-not $toAdd) {
        Write-Output "Group '$GroupName' is already up to date ($($currentMembers.Count) members)."
        return
    }

    Write-Verbose "Adding $($toAdd.Count) member(s) to '$GroupName'..."

    # Add in batches of 100 (recommended max per operation)
    for ($i = 0; $i -lt $toAdd.Count; $i += 100) {
        $batch = $toAdd | Select-Object -Skip $i -First 100
        if ($PSCmdlet.ShouldProcess("$($batch.Count) user(s)", 'Add to group')) {
            Add-ADGroupMember -Identity $group -Members $batch
        }
    }

    $finalCount = (Get-ADGroupMember -Identity $group -Recursive:$false).Count
    Write-Output "Done. '$GroupName' now has $finalCount member(s)."
}

Begin {
    $ErrorActionPreference = 'Stop'
}

Process {
    if ($PSCmdlet.ParameterSetName -eq 'SingleOU') {
        $params = @{
            OU               = $OU
            GroupName        = $GroupName
            GroupScope       = $GroupScope
            GroupCategory    = $GroupCategory
            IncludeSubOUs    = $IncludeSubOUs
            EnabledOnly      = $EnabledOnly
        }
        if ($GroupPath)       { $params.GroupPath = $GroupPath }
        if ($GroupDescription) { $params.GroupDescription = $GroupDescription }

        New-OuShadowGroup @params
        return
    }

    # --- CSV mode ---
    $rows = @(Import-Csv -LiteralPath $CsvPath)

    if ($rows.Count -eq 0) {
        Write-Warning "CSV file '$CsvPath' contains no rows. Nothing to do."
        return
    }

    $required = @('OU', 'GroupName')
    $headers = $rows[0].PSObject.Properties.Name
    $missing = $required | Where-Object { $_ -notin $headers }
    if ($missing) {
        throw "CSV is missing required column(s): $($missing -join ', '). Expected headers: OU, GroupName [, GroupPath] [, GroupScope] [, GroupCategory] [, Description]"
    }

    $succeeded = 0
    $failed = 0

    foreach ($row in $rows) {
        $rowOU = if ($row.PSObject.Properties['OU']) { $row.OU.Trim() } else { '' }
        $rowGroup = if ($row.PSObject.Properties['GroupName']) { $row.GroupName.Trim() } else { '' }

        if ([string]::IsNullOrWhiteSpace($rowOU) -or [string]::IsNullOrWhiteSpace($rowGroup)) {
            Write-Warning "Skipping row with empty OU or GroupName: '$($row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1)'"
            $failed++
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
            New-OuShadowGroup @params
            $succeeded++
        }
        catch {
            $failed++
            Write-Error "Failed on row '$rowOU' / '$rowGroup': $_" -ErrorAction Continue
        }
    }

    Write-Output "Completed: $succeeded succeeded, $failed failed/skipped (of $($rows.Count) rows)."
    if ($failed -gt 0) { exit 1 }
}
