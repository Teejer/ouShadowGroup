# Active Directory group creation and membership sync.

function Find-ADGroup {
    <#
        Looks up a group by exact name anywhere in the domain.
        Returns the group object or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $escaped = $Name.Replace("'", "''")
    @(Get-ADGroup -Filter "Name -eq '$escaped'" -ErrorAction SilentlyContinue) |
        Select-Object -First 1
}

function New-ShadowGroup {
    <#
        Creates the shadow group. -Path must be an existing OU's DN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Category,
        [string]$Description
    )

    $null = Test-AdOuExists -OU $Path

    $params = @{
        Name          = $Name
        GroupScope    = $Scope
        GroupCategory = $Category
        Path          = $Path
        PassThru      = $true
    }
    if ($Description) { $params.Description = $Description }

    New-ADGroup @params
}

function Get-GroupUserMemberDn {
    <#
        Distinguished names of the *direct* user members of the group.
        Nested groups/computers are intentionally ignored so the sync never
        removes objects the script didn't manage to add itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Group
    )

    @(Get-ADGroupMember -Identity $Group -Recursive:$false |
        Where-Object { $_.objectClass -eq 'user' } |
        Select-Object -ExpandProperty distinguishedName |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-MembershipDiff {
    <#
        Compares expected member DNs against current member DNs
        (case-insensitive, DN-safe) and returns what to add/remove.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Expected,
        [AllowEmptyCollection()][string[]]$Current
    )

    $Expected = @($Expected | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $Current  = @($Current  | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $expectedSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $currentSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($dn in $Expected) { $null = $expectedSet.Add($dn) }
    foreach ($dn in $Current)  { $null = $currentSet.Add($dn)  }

    [pscustomobject]@{
        ToAdd    = @($Expected | Where-Object { -not $currentSet.Contains($_) })
        ToRemove = @($Current  | Where-Object { -not $expectedSet.Contains($_) })
    }
}

function Update-GroupMembership {
    <#
        Applies the diff in batches of 100 (the recommended per-operation
        maximum for Add/Remove-ADGroupMember). When a batch fails, its
        members are retried one at a time so the members log can name the
        specific user(s) that failed. Returns success/failure counts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Group,
        [Parameter(Mandatory)][pscustomobject]$Logs,
        [AllowEmptyCollection()][string[]]$ToAdd = @(),
        [AllowEmptyCollection()][string[]]$ToRemove = @()
    )

    $added = 0; $removed = 0; $failed = 0

    for ($i = 0; $i -lt $ToAdd.Count; $i += 100) {
        $batch = $ToAdd[$i..([Math]::Min($i + 99, $ToAdd.Count - 1))]
        try {
            Add-ADGroupMember -Identity $Group -Members $batch
            foreach ($dn in $batch) {
                $added++
                Write-MemberLogEntry -Logs $Logs -GroupName $Group.Name -Action 'ADDED' -Member $dn
            }
        }
        catch {
            Write-Verbose "Batch add failed ($($_.Exception.Message)); retrying one at a time."
            foreach ($dn in $batch) {
                try {
                    Add-ADGroupMember -Identity $Group -Members $dn
                    $added++
                    Write-MemberLogEntry -Logs $Logs -GroupName $Group.Name -Action 'ADDED' -Member $dn
                }
                catch {
                    $failed++
                    Write-MemberLogEntry -Logs $Logs -GroupName $Group.Name -Action 'ADD-FAILED' -Member $dn -Reason $_.Exception.Message
                }
            }
        }
    }

    for ($i = 0; $i -lt $ToRemove.Count; $i += 100) {
        $batch = $ToRemove[$i..([Math]::Min($i + 99, $ToRemove.Count - 1))]
        try {
            Remove-ADGroupMember -Identity $Group -Members $batch -Confirm:$false
            foreach ($dn in $batch) {
                $removed++
                Write-MemberLogEntry -Logs $Logs -GroupName $Group.Name -Action 'REMOVED' -Member $dn
            }
        }
        catch {
            Write-Verbose "Batch remove failed ($($_.Exception.Message)); retrying one at a time."
            foreach ($dn in $batch) {
                try {
                    Remove-ADGroupMember -Identity $Group -Members $dn -Confirm:$false
                    $removed++
                    Write-MemberLogEntry -Logs $Logs -GroupName $Group.Name -Action 'REMOVED' -Member $dn
                }
                catch {
                    $failed++
                    Write-MemberLogEntry -Logs $Logs -GroupName $Group.Name -Action 'REMOVE-FAILED' -Member $dn -Reason $_.Exception.Message
                }
            }
        }
    }

    [pscustomobject]@{ Added = $added; Removed = $removed; Failed = $failed }
}
