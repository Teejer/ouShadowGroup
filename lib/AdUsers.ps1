# Active Directory user queries.

function Test-AdOuExists {
    <#
        Returns the resolved OU object, or throws a friendly error when the
        distinguished name can't be found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OU
    )

    try {
        Get-ADOrganizationalUnit -Identity $OU -ErrorAction Stop
    }
    catch {
        throw "Could not find OU '$($OU)'. Verify the distinguished name. Error: $($_.Exception.Message)"
    }
}

function Get-OuUser {
    <#
        Every enabled user account in the OU and all sub-OUs.
        Disabled accounts are excluded. Returns user objects with
        DistinguishedName and SamAccountName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OU
    )

    $null = Test-AdOuExists -OU $OU

    Write-Verbose "Searching '$($OU)' (Subtree) for enabled users..."
    @(Get-ADUser -Filter { Enabled -eq $true } -SearchBase $OU -SearchScope Subtree -Properties DistinguishedName, SamAccountName)
}
