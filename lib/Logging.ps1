# Monthly success/failure log files.

function Initialize-RunLogs {
    <#
        Prepares the log directory and the two monthly log paths.
        Files are only created once something is actually written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyy-MM'
    [pscustomobject]@{
        SuccessLog = Join-Path $Directory "ou-shadow-group-success_$stamp.log"
        FailureLog = Join-Path $Directory "ou-shadow-group-failure_$stamp.log"
        MemberLog  = Join-Path $Directory "ou-shadow-group-members_$stamp.log"
        Header     = '=== ouShadowGroup log, created {0} ===' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
}

function Write-LogEntry {
    <#
        Appends one timestamped line. A single header line is written at the
        top of a file only when that file is first created.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Logs,
        [Parameter(Mandatory)][ValidateSet('Success', 'Failure', 'Member')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )

    $path = switch ($Kind) {
        'Success' { $Logs.SuccessLog }
        'Failure' { $Logs.FailureLog }
        'Member'  { $Logs.MemberLog  }
    }

    if (-not (Test-Path -LiteralPath $path)) {
        $Logs.Header | Out-File -FilePath $path -Append -Encoding utf8
    }
    ('{0} | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) |
        Out-File -FilePath $path -Append -Encoding utf8
}

function Write-SuccessLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Logs,
        [Parameter(Mandatory)][pscustomobject]$Result
    )

    $state = if ($Result.Created) { 'created' } else { 'synced' }
    Write-LogEntry -Logs $Logs -Kind Success -Message (
        '{0} | {1} | {2}; added {3}, removed {4}, failed {5}, {6} OU user(s) total' -f
            $Result.OU, $Result.GroupName, $state, $Result.Added, $Result.Removed,
            $Result.Failed, $Result.Total)
}

function Write-MemberLogEntry {
    <#
        One line per user add/remove attempt in the members log:
        timestamp | group | action | member DN [ | reason]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Logs,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][ValidateSet('ADDED', 'REMOVED', 'ADD-FAILED', 'REMOVE-FAILED')][string]$Action,
        [Parameter(Mandatory)][string]$Member,
        [AllowEmptyString()][string]$Reason = ''
    )

    $line = '{0} | {1} | {2}' -f $GroupName, $Action, $Member
    if ($Reason) { $line += " | $Reason" }
    Write-LogEntry -Logs $Logs -Kind Member -Message $line
}

function Write-FailureLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Logs,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason
    )

    Write-LogEntry -Logs $Logs -Kind Failure -Message (
        '{0} | {1} | {2}' -f $Config.OU, $Config.GroupName, $Reason)
}
