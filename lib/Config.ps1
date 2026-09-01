# CSV configuration loading and validation.

function Get-TrimmedValue {
    <#
        Returns a trimmed string for a CSV column, or '' when the column
        doesn't exist or the cell is empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Row,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Row.PSObject.Properties[$Name]) { "$($Row.$Name)".Trim() } else { '' }
}

function Import-GroupConfig {
    <#
        Reads the groups CSV and returns validated rows with defaults applied.
        Required columns : OU, GroupName
        Optional columns : GroupPath, GroupScope, GroupCategory, Description
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) {
        throw "Config file '$Path' contains no rows."
    }

    $missing = 'OU', 'GroupName' | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
    if ($missing) {
        throw "Config file is missing required column(s): $($missing -join ', ')."
    }

    $validScopes    = 'Global', 'DomainLocal', 'Universal'
    $validCategories = 'Security', 'Distribution'
    $config = @()

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row      = $rows[$i]
        $lineNo   = $i + 2   # +1 for header, +1 for 1-based numbering
        $ou       = Get-TrimmedValue -Row $row -Name 'OU'
        $group    = Get-TrimmedValue -Row $row -Name 'GroupName'
        $scope    = Get-TrimmedValue -Row $row -Name 'GroupScope'
        $category = Get-TrimmedValue -Row $row -Name 'GroupCategory'

        if (-not $ou -or -not $group) {
            Write-Warning "Line $lineNo`: skipped; OU and GroupName are both required."
            continue
        }
        if ($scope    -and $scope    -notin $validScopes)    { throw "Line $lineNo`: invalid GroupScope '$scope'. Allowed: $($validScopes -join ', ')" }
        if ($category -and $category -notin $validCategories) { throw "Line $lineNo`: invalid GroupCategory '$category'. Allowed: $($validCategories -join ', ')" }

        $config += [pscustomobject]@{
            OU          = $ou
            GroupName   = $group
            GroupPath   = Get-TrimmedValue -Row $row -Name 'GroupPath'
            GroupScope  = if ($scope) { $scope } else { 'Global' }
            GroupCategory = if ($category) { $category } else { 'Security' }
            Description = Get-TrimmedValue -Row $row -Name 'Description'
        }
    }

    if ($config.Count -eq 0) {
        throw "Config file '$Path' has no usable rows."
    }

    $config
}
