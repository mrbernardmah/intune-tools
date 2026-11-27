# Autopilot Group Tag Manager (AutopilotGroupTagTool.ps1)

A Windows GUI to **view and bulk-update Windows Autopilot group tags** across tenants through Microsoft Graph. Changes are staged and reviewed in a grid, and nothing is written until you confirm.

| | |
|---|---|
| **Script** | `AutopilotGroupTagTool.ps1` |
| **Category** | Operational / Autopilot / GUI |
| **Runs on** | Windows PowerShell 5.1 or PowerShell 7+ (Windows only, WPF) |
| **Graph API** | `https://graph.microsoft.com/beta` |

> **Warning:** Group tags often drive dynamic device groups, and through them deployment profiles, apps and policies. Try a **Dry run** and a small batch first.

---

## Features

- Interactive Microsoft sign-in (browser or device code) or a pasted bearer token.
- Saved tenant list for switching between tenants.
- Search by serial number, model, manufacturer, display name, user or tag, and filter by group tag.
- Set or clear tags on checked rows, or from a CSV / TXT file.
- Serial numbers in a file that aren't in the tenant are listed in grey and can be saved to CSV.
- Dry run, confirmation summary, per-device status and a daily audit log.
- Export the current view to CSV and request an Autopilot service sync.

---

## Requirements

- Windows. If not already in an STA thread, the script relaunches itself with `-STA -NoProfile -ExecutionPolicy Bypass`.
- For interactive sign-in, the `Microsoft.Graph.Authentication` module. The tool offers to install it for the current user if it is missing.
- An account allowed to manage Autopilot devices (for example Intune Administrator).

| Graph permission | Allows |
|---|---|
| `DeviceManagementServiceConfig.ReadWrite.All` | Browse and update group tags |
| `DeviceManagementServiceConfig.Read.All` | Browse only (pasted token) |

Interactive sign-in always requests the `ReadWrite.All` permission.

---

## Quick start

1. Run the script:

   ```powershell
   .\AutopilotGroupTagTool.ps1
   ```

2. Enter a tenant ID or domain (blank uses your home tenant), choose a sign-in method and click **Connect**.
3. Click **Load devices**.
4. Check the rows to change, type the **New group tag** and click **Stage for checked rows** (or **Stage clear tag**). With no rows checked, highlighted rows are used.
5. Review the **New group tag** column.
6. Optionally tick **Dry run (no writes)**, then click **Apply staged changes** and confirm.

---

## Sign-in options

| Option | Notes |
|---|---|
| **Interactive login** | Uses `Connect-MgGraph`. Tick **use device code** to get a code in the PowerShell console. |
| **Bearer token** | A Microsoft Graph access token, with or without the `Bearer ` prefix. Audience and expiry are checked. It cannot be renewed: paste a new one and reconnect when it expires. |

Connecting to a tenant clears the loaded device list, including staged changes.

---

## Importing from a file

| Button | Behaviour |
|---|---|
| **Import serials...** | Applies one tag (from the **New group tag** box) to every serial in the file. Type `CLEAR` to remove tags. If the file has a tag column, you are asked which to use. |
| **Import CSV (serial + tag)...** | Applies each row's own tag. Without a tag column, the **New group tag** box is used. |

Accepted files:

- A header row with `SerialNumber`, `Serial` or `Device Serial Number`, and optionally `GroupTag`, `Group Tag`, `Tag` or `OrderID`. Comma, semicolon and tab delimiters work.
- No header: one serial per line.

```csv
SerialNumber,GroupTag
ABC1234567,EXAMPLE-TAG
```

> **Note:** When the tags from a file are used, an **empty tag cell clears** that device's tag.

> **Note:** Name the serial column as shown above. A file with an unrecognised header may be read as a headerless list.

**Save CSV template...** writes the serials and current tags of the checked or highlighted rows (otherwise the visible rows).

---

## Applying changes

- Tag comparison is **case-sensitive**.
- **Apply staged changes** applies **every** staged row, including rows hidden by a filter. Check the confirmation summary.
- **Load devices** reloads the list and discards staged changes.
- HTTP 429 and 5xx responses are retried, up to 6 attempts.
- Intune can take a few minutes to show new tags; dynamic groups re-evaluate afterwards.
- **Sync Autopilot service** is limited by Intune to about one sync every 10 minutes.

| Row status | Meaning |
|---|---|
| `Staged` | Waiting to be applied |
| `Already correct` | File tag matches the current tag |
| `Not found in tenant` | Serial in the file has no Autopilot record |
| `Dry run OK` | Simulated only |
| `Updated` | Graph accepted the change |
| `Failed` | See the log pane |

---

## Files and logging

Stored under `%APPDATA%\AutopilotGroupTagTool`:

- `tenants.json`: saved tenant names and IDs.
- `logs\<yyyyMMdd>.log`: activity and audit log. Each applied change records tenant, serial, device ID, old tag, new tag and signed-in identity.

The script does not write access tokens to these files.

---

## Troubleshooting

| Symptom | What to check |
|---|---|
| Token rejected | It must be issued for `https://graph.microsoft.com` and not expired. |
| Read-only warning or updates fail | The sign-in lacks `DeviceManagementServiceConfig.ReadWrite.All`. |
| No device code visible | Look in the PowerShell console window. |
| Serial column not found | Rename the column to `SerialNumber`. |
