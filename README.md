# ouShadowGroup

Creates and keeps in sync "shadow groups" that mirror all enabled users of an Active Directory OU and its sub-OUs.

Each row in `groups.csv` defines one group. On first run the script creates the group and adds every enabled user in the OU subtree. Every later run diffs the group against current OU users:

- enabled users who joined the OU are **added**
- users who left, were deleted, or were disabled are **removed**
- nested groups or computers already in the group are left untouched

## Requirements

- Windows with PowerShell 5+
- [RSAT Active Directory module](https://learn.microsoft.com/en-us/windows-server/remote/rsat/) (`ActiveDirectory`), run as a user that can read AD and create/modify groups

## Usage

1. Edit `groups.csv` (see table below).
2. Run:

   ```powershell
   .\New-OuShadowGroup.ps1
   ```

Use `-Verbose` for progress details. The script exits with code `1` if any row failed, `0` otherwise — useful for scheduled tasks.

## Configuration (`groups.csv`)

| Column        | Required | Description |
|---------------|----------|-------------|
| `OU`          | yes      | Source OU distinguished name; members are every enabled user in it and all sub-OUs |
| `GroupName`   | yes      | Group to create and maintain |
| `GroupPath`   | no       | OU where the group object is created; defaults to the source OU |
| `GroupScope`  | no       | `Global` (default), `DomainLocal`, `Universal` |
| `GroupCategory` | no     | `Security` (default), `Distribution` |
| `Description` | no       | Group description; defaults to an auto-generated text |

Example:

```csv
OU,GroupName,GroupPath,GroupScope,GroupCategory,Description
"OU=Sales,DC=contoso,DC=com","GG-Sales-AllUsers","OU=Groups,DC=contoso,DC=com"
"OU=IT,DC=contoso,DC=com","GG-IT-AllUsers"
```

## Logging

Results are appended to monthly log files in a `logs\` folder next to the script (created on first use in a given month):

| File | Content |
|------|---------|
| `ou-shadow-group-success_yyyy-MM.log` | one line per synced group |
| `ou-shadow-group-failure_yyyy-MM.log` | failed rows with reason and line number (only created once something fails) |
| `ou-shadow-group-members_yyyy-MM.log` | per-user `ADDED` / `REMOVED` / `ADD-FAILED` / `REMOVE-FAILED` events |

## Repository layout

```
New-OuShadowGroup.ps1   Entry point: reads groups.csv, syncs each row
groups.csv              Configuration (one row per shadow group)
lib/
  AdGroups.ps1          Group lookup, creation, membership diff/apply
  AdUsers.ps1           OU validation and enabled-user queries
  Config.ps1            CSV loading and validation
  Logging.ps1           Monthly log helpers
```

## Scheduling

To keep groups in sync automatically, register a scheduled task, e.g.:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\scripts\ouShadowGroup\New-OuShadowGroup.ps1'
Register-ScheduledTask -TaskName 'OuShadowGroup' -Action $action -User 'CONTOSO\admin' -RunLevel Limited `
    -Trigger (New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 1) -Once -At (Get-Date))
```
