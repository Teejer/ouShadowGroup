#Requires -Version 7
<#
    Mock test harness for New-OuShadowGroup.ps1.
    Stubs the ActiveDirectory cmdlets with in-memory fakes and verifies the
    script's logic: CSV/single-OU modes, group creation path, idempotency,
    EnabledOnly filtering, -WhatIf, and split success/failure logging.
    Run: pwsh -NoProfile -File test-mocks.ps1
#>
$ErrorActionPreference = 'Stop'

$global:ADState = @{
    ous         = [System.Collections.Generic.HashSet[string]]::new()
    groups      = @{}
    usersByOU   = @{}
}

function Add-MockOU([string]$Dn) { [void]$global:ADState.ous.Add($Dn) }

function Add-MockUser([string]$Ou, [string]$Sam, [bool]$Enabled = $true) {
    if (-not $global:ADState.usersByOU.ContainsKey($Ou)) { $global:ADState.usersByOU[$Ou] = @() }
    $global:ADState.usersByOU[$Ou] += [pscustomobject]@{
        SamAccountName     = $Sam
        DistinguishedName  = "CN=$Sam,$Ou"
        Enabled            = $Enabled
    }
}

# --- Mock AD cmdlets (shadow the real ones; the AD module doesn't exist in test) ---

function Get-ADOrganizationalUnit {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Identity)
    if ($global:ADState.ous.Contains($Identity)) {
        return [pscustomobject]@{
            DistinguishedName = $Identity
            Name              = ($Identity -split ',')[0] -replace '^OU=', ''
        }
    }
    throw "Cannot find an organizational unit with: $Identity"
}

function Get-ADUser {
    [CmdletBinding()]
    param($Filter, [string]$SearchBase, [string]$SearchScope, [string[]]$Properties)
    $result = @()
    foreach ($ouDn in $global:ADState.usersByOU.Keys) {
        $inScope = ($ouDn -eq $SearchBase) -or
                   ($SearchScope -eq 'Subtree' -and $ouDn.EndsWith(",$SearchBase"))
        if ($inScope) { $result += $global:ADState.usersByOU[$ouDn] }
    }
    $filterText = if ($Filter -is [scriptblock]) { $Filter.ToString() } else { "$Filter" }
    if ($filterText -match 'Enabled') { $result = @($result | Where-Object Enabled) }
    return $result
}

function Get-ADGroup {
    [CmdletBinding()]
    param([string]$Filter)
    if ($Filter -match "Name -eq '([^']+)'") {
        $n = $Matches[1]
        return @($global:ADState.groups.Values | Where-Object Name -eq $n)
    }
}

function New-ADGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$GroupScope,
        [string]$GroupCategory,
        [string]$Description,
        [Parameter(Mandatory)][string]$Path,
        [switch]$PassThru
    )
    if (-not $global:ADState.ous.Contains($Path)) { throw "Cannot find an organizational unit with: $Path" }
    if (@($global:ADState.groups.Values | Where-Object Name -eq $Name).Count -gt 0) { throw "Group '$Name' already exists" }
    $dn = "CN=$Name,$Path"
    $global:ADState.groups[$dn] = [pscustomobject]@{
        Name              = $Name
        DistinguishedName = $dn
        Path              = $Path
        Scope             = $GroupScope
        Category          = $GroupCategory
        members           = [System.Collections.Generic.List[string]]::new()
    }
    if ($PassThru) { return $global:ADState.groups[$dn] }
}

function Get-ADGroupMember {
    [CmdletBinding()]
    param($Identity, [bool]$Recursive)
    $dn = if ($Identity -is [string]) { $Identity } else { $Identity.DistinguishedName }
    if (-not $global:ADState.groups.ContainsKey($dn)) { return @() }
    return @($global:ADState.groups[$dn].members | ForEach-Object {
        [pscustomobject]@{ objectClass = 'user'; distinguishedName = $_; name = ($_ -split ',')[0] -replace '^CN=', '' }
    })
}

function Add-ADGroupMember {
    [CmdletBinding()]
    param($Identity, $Members)
    $g = $global:ADState.groups[$Identity.DistinguishedName]
    foreach ($m in $Members) { $g.members.Add($m.DistinguishedName) }
}

# --- Test framework ---

$script:failures = 0
function Assert([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "PASS: $Name" }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:failures++ }
}
function Get-LogFile([string]$dir, [string]$kind) {
    Get-ChildItem $dir -Filter "ou-shadow-group-$kind-*.log" | Select-Object -First 1
}
function Get-LogEntries($file) { @(Get-Content $file.FullName | Where-Object { $_ -notmatch '^===' }) }

# Build a testable copy of the script (strip #Requires since the AD module is absent)
$out = 'test-output'
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $out | Out-Null
$tmpScript = Join-Path (Resolve-Path $out).Path 'script-under-test.ps1'
(Get-Content 'New-OuShadowGroup.ps1') | Where-Object { $_ -notmatch '^#Requires' } | Set-Content $tmpScript

# Directory / user fixtures
Add-MockOU 'OU=Sales,DC=contoso,DC=com'
Add-MockOU 'OU=Marketing,DC=contoso,DC=com'
Add-MockOU 'OU=Groups,DC=contoso,DC=com'
Add-MockUser 'OU=Sales,DC=contoso,DC=com' 'sales1'
Add-MockUser 'OU=Sales,DC=contoso,DC=com' 'sales2'
Add-MockUser 'OU=Sales,DC=contoso,DC=com' 'sales3' $false
Add-MockUser 'OU=Marketing,DC=contoso,DC=com' 'mkt1'
Add-MockUser 'OU=Marketing,DC=contoso,DC=com' 'mkt2'

# --- T1: CSV mode with mixed success/failure ---
Write-Host "`n=== T1: CSV mixed results ==="
$rows = @(
    [pscustomobject]@{ OU = 'OU=Sales,DC=contoso,DC=com'; GroupName = 'GG-Sales-AllUsers'; GroupPath = 'OU=Groups,DC=contoso,DC=com' }
    [pscustomobject]@{ OU = 'OU=Bad,DC=contoso,DC=com';   GroupName = 'GG-Bad';             GroupPath = '' }
    [pscustomobject]@{ OU = 'OU=Sales,DC=contoso,DC=com'; GroupName = '';                   GroupPath = '' }
)
$csv1 = Join-Path (Resolve-Path $out).Path 't1.csv'
$rows | Export-Csv $csv1 -NoTypeInformation
$t1log = Join-Path (Get-Item $out).FullName 't1'
& $tmpScript -CsvPath $csv1 -LogDirectory $t1log *> (Join-Path (Resolve-Path $out).Path 't1.out')

Assert ($LASTEXITCODE -eq 1) 'T1 exit code is 1 (failures present)'
$g = $global:ADState.groups.Values | Where-Object Name -eq 'GG-Sales-AllUsers'
Assert ($g -and $g.members.Count -eq 3) 'T1 group created with all 3 members'
Assert ($g.Path -eq 'OU=Groups,DC=contoso,DC=com') 'T1 group created in GroupPath'
Assert (Get-LogEntries (Get-LogFile $t1log success)).Count -eq 1 'T1 success log has 1 entry'
$t1failures = Get-LogEntries (Get-LogFile $t1log failure)
Assert ($t1failures.Count -eq 2) 'T1 failure log has 2 entries'
Assert (($t1failures -join "`n") -match 'Could not find OU') 'T1 failure log names the bad OU reason'
Assert (($t1failures -join "`n") -match 'empty OU or GroupName') 'T1 failure log records blank row'

# --- T2: idempotent re-run ---
Write-Host "`n=== T2: re-run is a no-op ==="
$rows2 = @([pscustomobject]@{ OU = 'OU=Sales,DC=contoso,DC=com'; GroupName = 'GG-Sales-AllUsers'; GroupPath = 'OU=Groups,DC=contoso,DC=com' })
$csv2 = Join-Path (Resolve-Path $out).Path 't2.csv'
$rows2 | Export-Csv $csv2 -NoTypeInformation
$t2log = Join-Path (Get-Item $out).FullName 't2'
& $tmpScript -CsvPath $csv2 -LogDirectory $t2log *> (Join-Path (Resolve-Path $out).Path 't2.out')

Assert ($LASTEXITCODE -eq 0) 'T2 exit code is 0'
Assert ($g.members.Count -eq 3) 'T2 no duplicate members added'
Assert (((Get-LogEntries (Get-LogFile $t2log success)) -join "`n") -match 'Up to date') 'T2 success log says up to date'
Assert (-not (Get-LogFile $t2log failure)) 'T2 failure log removed (nothing failed)'

# --- T3: single-OU mode with GroupPath + EnabledOnly ---
Write-Host "`n=== T3: single-OU, GroupPath, EnabledOnly ==="
$t3log = Join-Path (Get-Item $out).FullName 't3'
& $tmpScript -OU 'OU=Sales,DC=contoso,DC=com' -GroupName 'GG-Sales-Enabled' -GroupPath 'OU=Groups,DC=contoso,DC=com' -EnabledOnly -LogDirectory $t3log

$g3 = $global:ADState.groups['CN=GG-Sales-Enabled,OU=Groups,DC=contoso,DC=com']
Assert ($g3 -and $g3.members.Count -eq 2) 'T3 only the 2 enabled users added'
Assert ($LASTEXITCODE -eq 0) 'T3 exit code is 0'

# --- T4: -WhatIf makes no changes ---
Write-Host "`n=== T4: WhatIf preview ==="
$t4log = Join-Path (Get-Item $out).FullName 't4'
& $tmpScript -OU 'OU=Marketing,DC=contoso,DC=com' -GroupName 'GG-Marketing' -LogDirectory $t4log -WhatIf

Assert (-not $global:ADState.groups.ContainsKey('CN=GG-Marketing,OU=Marketing,DC=contoso,DC=com')) 'T4 group NOT created under WhatIf'
Assert (((Get-LogEntries (Get-LogFile $t4log success)) -join "`n") -match 'WhatIf: would add 2') 'T4 success log records preview'

# --- T5: single-OU mode failure ---
Write-Host "`n=== T5: single-OU bad OU ==="
$t5log = Join-Path (Get-Item $out).FullName 't5'
$err = $null
try { & $tmpScript -OU 'OU=Nope,DC=contoso,DC=com' -GroupName 'GG-Nope' -LogDirectory $t5log -ErrorAction Stop } catch { $err = $_ }
Assert ($null -ne $err) 'T5 throws on bad OU'
Assert (((Get-LogEntries (Get-LogFile $t5log failure)) -join "`n") -match 'Could not find OU') 'T5 failure logged to failure file'

# --- T6: default groups.csv used when no args ---
Write-Host "`n=== T6: default groups.csv ==="
$defaultDir = Join-Path (Resolve-Path $out).Path 't6'
New-Item -ItemType Directory $defaultDir | Out-Null
@([pscustomobject]@{ OU = 'OU=Marketing,DC=contoso,DC=com'; GroupName = 'GG-Marketing'; GroupPath = 'OU=Groups,DC=contoso,DC=com' }) |
    Export-Csv (Join-Path $defaultDir 'groups.csv') -NoTypeInformation
$t6log = Join-Path (Get-Item $out).FullName 't6'
Push-Location $defaultDir
try { & $tmpScript -LogDirectory $t6log *> (Join-Path $defaultDir 't6.out') }
finally { Pop-Location }
$g6 = $script:ADState.groups['CN=GG-Marketing,OU=Groups,DC=contoso,DC=com']
Assert ($LASTEXITCODE -eq 0) 'T6 exit code is 0'
Assert ($g6 -and $g6.members.Count -eq 2) 'T6 default groups.csv processed'

# --- T7: no args and no groups.csv -> clear error ---
Write-Host "`n=== T7: no args, no groups.csv ==="
$emptyDir = Join-Path (Resolve-Path $out).Path 't7'
New-Item -ItemType Directory $emptyDir | Out-Null
Push-Location $emptyDir
$err = $null
try { & $tmpScript -ErrorAction Stop } catch { $err = $_ }
finally { Pop-Location }
Assert ($null -ne $err) 'T7 throws when nothing to do'
Assert ($err -match 'groups.csv') 'T7 error mentions groups.csv'

# --- Summary ---
Write-Host "`n=============================="
if ($script:failures -gt 0) { Write-Host "$($script:failures) test(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed'
