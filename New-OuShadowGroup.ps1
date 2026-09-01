#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Creates and keeps in sync "shadow groups" mirroring the users of an OU
    and all of its sub-OUs.

.DESCRIPTION
    All parameters come from groups.csv, located in the same folder as this
    script. Each row defines one group:

        OU            (required) source OU; members are every enabled user
                                in it and every sub-OU (disabled accounts
                                are not added, and are removed if they were
                                a member before being disabled)
        GroupName     (required) group to create and maintain
        GroupPath     (optional) OU where the group object is created;
                                defaults to the source OU
        GroupScope    (optional) Global (default), DomainLocal, Universal
        GroupCategory (optional) Security (default), Distribution
        Description   (optional) group description

    First run creates the group and adds all OU users. Every later run
    diffs the group against current OU users: enabled users who joined the
    OU are added, users who left, were deleted, or were disabled are
    removed. Nested groups or computers already in the group are left
    untouched.

    Results are also appended to monthly log files in a logs\ folder next
    to this script (created on first use in a given month):
        ou-shadow-group-success_yyyy-MM.log
        ou-shadow-group-failure_yyyy-MM.log
        ou-shadow-group-members_yyyy-MM.log   per-user ADDED / REMOVED /
                                              ADD-FAILED / REMOVE-FAILED

.EXAMPLE
    .\New-OuShadowGroup.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' |
    Sort-Object Name |
    ForEach-Object { . $_.FullName }

function Sync-ShadowGroup {
    <#
        One CSV row -> a group whose direct user members exactly match the
        users of the source OU subtree. Returns a result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Logs
    )

    $users = Get-OuUser -OU $Config.OU
    if ($users.Count -eq 0) {
        throw "No user accounts found in '$($Config.OU)' or its sub-OUs."
    }
    Write-Verbose "Found $($users.Count) user(s) in the OU subtree."

    $groupPath = if ($Config.GroupPath) { $Config.GroupPath } else { $Config.OU }
    $description = if ($Config.Description) { $Config.Description } else { "Auto-generated: all user accounts in $($Config.OU) and its sub-OUs" }
    $created = $false

    $group = Find-ADGroup -Name $Config.GroupName
    if (-not $group) {
        Write-Verbose "Creating group '$($Config.GroupName)' in '$groupPath'..."
        $group = New-ShadowGroup -Name $Config.GroupName `
                                 -Path $groupPath `
                                 -Scope $Config.GroupScope `
                                 -Category $Config.GroupCategory `
                                 -Description $description
        $created = $true
        Write-Verbose 'Waiting 10 seconds for the new group to replicate before adding members...'
        Start-Sleep -Seconds 10
    }
    else {
        Write-Verbose "Group '$($Config.GroupName)' exists; syncing members."
    }

    $diff = Get-MembershipDiff `
                -Expected $users.DistinguishedName `
                -Current  (Get-GroupUserMemberDn -Group $group)

    $applied = Update-GroupMembership -Group $group -Logs $Logs -ToAdd $diff.ToAdd -ToRemove $diff.ToRemove

    [pscustomobject]@{
        GroupName = $Config.GroupName
        OU        = $Config.OU
        Created   = $created
        Added     = $applied.Added
        Removed   = $applied.Removed
        Failed    = $applied.Failed
        Total     = $users.Count
    }
}

# --- Main ---

$configPath = Join-Path $PSScriptRoot 'groups.csv'
Write-Host "Using config: $configPath"
$config = Import-GroupConfig -Path $configPath

$logs = Initialize-RunLogs -Directory (Join-Path $PSScriptRoot 'logs')
Write-Verbose "Success log: $($logs.SuccessLog)"
Write-Verbose "Failure log: $($logs.FailureLog) (only created once something fails)"

$succeeded = 0
$failed    = 0

foreach ($row in $config) {
    Write-Host "--- $($row.OU) -> $($row.GroupName) ---"
    try {
        $result = Sync-ShadowGroup -Config $row -Logs $logs
        $succeeded++
        Write-SuccessLog -Logs $logs -Result $result

        $state = if ($result.Created) { 'created' } else { 'synced' }
        Write-Host ("    OK: {0}; added {1}, removed {2}, failed {3}, {4} OU user(s) total." -f
            $state, $result.Added, $result.Removed, $result.Failed, $result.Total)
        if ($result.Failed -gt 0) {
            Write-Warning "    See the members log for the $($result.Failed) user(s) that failed."
        }
    }
    catch {
        $failed++
        Write-Warning "    FAILED: $($_.Exception.Message)"
        Write-Verbose $_.ScriptStackTrace
        Write-FailureLog -Logs $logs -Config $row -Reason (
            '{0} [line {1}]' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
    }
}

Write-Host "Completed: $succeeded succeeded, $failed failed (of $($config.Count))."
if (Test-Path -LiteralPath $logs.SuccessLog) { Write-Host "Success log: $($logs.SuccessLog)" }
if ($failed -gt 0) { Write-Host "Failure log: $($logs.FailureLog)"; exit 1 } else { exit 0 }
