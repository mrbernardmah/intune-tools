# Get App Assignments using token

Lists every Microsoft Intune app assignment in a tenant as one row per assignment, using a Microsoft Graph bearer token (for example one copied from the Authorization header of a `graph.microsoft.com` request in the Intune admin center's browser DevTools).

`Get-IntuneAppAssignments.ps1` decodes the token, pages through all mobile apps with their assignments, resolves group IDs and assignment filter IDs to display names, and can export the results to CSV or JSON.

## Quick start

```powershell
# Prompts for the token (not echoed), shows a table, then asks where to save
.\Get-IntuneAppAssignments.ps1

# Only apps matching a name, exported straight to CSV
.\Get-IntuneAppAssignments.ps1 -AppName "*Adobe*" -CsvPath .\adobe-assignments.csv

# Use the results in the pipeline
$rows = .\Get-IntuneAppAssignments.ps1 -Token $tok -PassThru
$rows | Where-Object Intent -eq 'required' | Group-Object GroupName
```

## Getting a token

1. Open the Intune admin center and press **F12** to open DevTools, then go to the **Network** tab.
2. Refresh the page and filter requests by `graph.microsoft.com` (for example `mobileApps`).
3. Copy the `Authorization` request header value. The script accepts it with or without the leading `Bearer `.

Portal tokens usually live for 60-90 minutes. **Treat the token like a password**: don't share it, commit it, or leave it in script history. The script prompts for it as a secure string when `-Token` is omitted, which is preferable to passing it on the command line.

## Parameters

| Parameter | Description |
| --- | --- |
| `-Token` | The bearer token. If omitted you are prompted for it. |
| `-AppName` | Wildcard filter on app display name, for example `*Chrome*`. Default `*`. |
| `-IncludeUnassigned` | Also list apps with no assignments (TargetType `Unassigned`). |
| `-CsvPath` | Export the results to CSV. |
| `-JsonPath` | Export the results to JSON. |
| `-NoExport` | Don't prompt for an export location. |
| `-PassThru` | Return the result objects to the pipeline instead of printing a table. |

With no `-CsvPath` or `-JsonPath` (and no `-NoExport`), the script asks where to save: a Save As dialog on Windows, a typed path elsewhere. The format follows the file extension.

## Output columns

`AppName`, `AppType`, `Publisher`, `Version`, `Intent`, `TargetType` (Include group, Exclude group, All users, All devices, Unassigned), `GroupName`, `GroupId`, `Filter`, `FilterMode`, `Notifications`, `AvailableFrom`, `Deadline`, `DeliveryOptimization`, `AppId`.

## Required permissions

| Permission | Needed for |
| --- | --- |
| `DeviceManagementApps.Read.All` | Required: apps and assignments |
| `Group.Read.All` or `Directory.Read.All` | Group names (otherwise the group ID is shown) |
| `DeviceManagementConfiguration.Read.All` | Assignment filter names (otherwise the filter ID is shown) |

The script prints the token's tenant, identity, audience, scopes and expiry before it starts, and stops if the token has expired.

## Things to know

- **Read-only.** It only issues GET requests, plus one POST to `directoryObjects/getByIds` to look up group names.
- **Uses the Graph beta endpoint** for apps and assignment filters, so property names may change over time.
- Requests that hit throttling (429) or server errors (5xx) are retried automatically.
- Works in Windows PowerShell 5.1 and PowerShell 7.
