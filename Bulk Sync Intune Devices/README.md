# Bulk Sync Intune Devices

A Windows GUI for sending the Intune **Sync** action to many managed devices at once. Load devices, filter them, tick the ones you want and send.

| | |
|---|---|
| **Script** | `Bulk-SyncIntuneDevices.ps1` |
| **Runs on** | Windows PowerShell 5.1 or PowerShell 7 (Windows only, WinForms) |
| **Graph API** | `https://graph.microsoft.com/v1.0` |

## Features

- Three sign-in options: interactive, bearer token, or app registration with a client secret.
- Filter by device name (wildcard), operating system and last check-in age.
- Tick or untick individual devices, or use **Select all** / **Select none**.
- Confirmation prompt before anything is sent.
- Retries throttled or unavailable responses (429, 503, 504), honouring `Retry-After`.
- **Stop** button, per-device status, live log and CSV export.

## Requirements

- Windows with Windows PowerShell 5.1 or PowerShell 7.
- Outbound access to `login.microsoftonline.com` and `graph.microsoft.com`.
- For interactive sign-in only: the `Microsoft.Graph.Authentication` module. If it is missing, the tool offers to install it for the current user from the PowerShell Gallery.

## Permissions

| Microsoft Graph permission | Used for |
|---|---|
| `DeviceManagementManagedDevices.Read.All` | Listing managed devices |
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | Sending the sync request |

Use **delegated** permissions for interactive sign-in and **application** permissions (with admin consent) for an app registration. A signed-in user also needs an Intune role that allows syncing devices, such as Intune Administrator.

## Quick start

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Bulk-SyncIntuneDevices.ps1"
```

If you downloaded the file and Windows blocks it, run `Unblock-File ".\Bulk-SyncIntuneDevices.ps1"` first.

1. Choose a sign-in method and click **Connect**.
2. Set any filters and click **Load devices**.
3. Review the list. **Every matching device is ticked by default**, so untick any you want to leave out.
4. Click **Sync selected** and confirm.
5. Optionally click **Export CSV** to keep a record.

## Sign-in options

| Option | What you enter | Notes |
|---|---|---|
| **Sign in to Intune (interactive)** | Tenant (optional) | Default. Opens a Microsoft sign-in window. |
| **Bearer token** | An access token for `https://graph.microsoft.com` | A leading `Bearer ` is accepted. The tool warns if the token is close to expiry or lacks the sync permission. |
| **App registration** | Tenant ID, Client ID, Client secret | Client-credentials flow. |

Tokens are not renewed automatically in bearer token or app registration mode. When one expires, click **Connect** again.

## Filters

| Filter | Behaviour |
|---|---|
| **Name (wildcard)** | Matches the device name, for example `LAPTOP-*`. Without a wildcard the name must match exactly. Default `*`. |
| **OS** | `All`, `Windows`, `macOS`, `iOS`, `Android` or `Linux`. Matches the reported OS name exactly, so devices reported as `iPadOS` appear only under `All`. |
| **Last check-in older than (hours)** | `0` means any. Otherwise lists devices that have not checked in within that many hours, including those with no check-in date. |

All managed devices are downloaded first and then filtered, so loading a large tenant can take a while.

## Results and CSV export

A status of **Sent** means Microsoft Graph accepted the request. It does not confirm that the device has checked in. To verify, reload the list later and look at **Last check-in**.

A **Failed** status shows the error as a tooltip. A 401 error stops the run; other failures are logged and the run continues with the next device.

The CSV contains: `Selected`, `DeviceName`, `OS`, `User`, `LastSync`, `Status`, `Error`, `DeviceId`.

## Troubleshooting

| Problem | What to check |
|---|---|
| **401 Unauthorized** | The token is invalid or expired. Connect again. |
| **403 Forbidden** | The Graph permissions, admin consent and your Intune role. Activate PIM first if you use it. |
| Frequent **throttled** messages | Expected on large runs. The tool waits and retries up to 5 times per request. |
| No devices listed | Check the name, OS and check-in filters. |

## Security notes

- Treat access tokens and client secrets like passwords. Don't commit them or share screenshots that show them.
- The script does not write tokens or secrets to disk. **Disconnect** clears the token and secret boxes.
- CSV exports contain device names and user principal names, so store them appropriately.
