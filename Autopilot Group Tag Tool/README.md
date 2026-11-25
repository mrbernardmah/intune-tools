# Autopilot Group Tag Manager

A Windows GUI (PowerShell + WPF) for viewing and bulk-changing **Windows Autopilot group tags** in any tenant through Microsoft Graph.

## Run it
Download `AutopilotGroupTagTool.ps1`, open PowerShell in its folder and run:

```powershell
powershell -STA -ExecutionPolicy Bypass -File .\AutopilotGroupTagTool.ps1
```

If Windows blocks it because it was downloaded: right-click the .ps1 → Properties → **Unblock**.

## Sign in (two options)
| Option | How |
|---|---|
| **Interactive login** | Enter a tenant ID or domain (or pick a saved tenant), click **Connect**, sign in with an Intune admin account. Uses the `Microsoft.Graph.Authentication` module (the tool offers to install it). Tick *use device code* for GDAP/partner logins or if the browser popup is blocked. |
| **Bearer token** | Select *Bearer token*, paste a Microsoft Graph access token (`Bearer ` prefix optional), click **Connect**. The tool reads the token's tenant, user and expiry, and warns if it isn't a Graph token or lacks permissions. |

To get a token from the Intune portal: open intune.microsoft.com → F12 → Network → filter `graph.microsoft.com` → click any request → copy the `Authorization` request header value. These tokens last about an hour.

Permission needed: **DeviceManagementServiceConfig.ReadWrite.All** (Read.All is enough to browse only).

## Use it
1. **Load devices**: lists every Autopilot device (serial, current tag, model, user, enrollment state, last contact).
2. Filter by search text or current group tag, then tick the devices (or highlight them).
3. Type a **New group tag** → **Stage for checked rows** (or **Stage clear tag**). Staged rows turn yellow.
   - Bulk option: **Save CSV template…**, edit the `GroupTag` column, then **Import CSV…** (columns `SerialNumber,GroupTag`).
4. Review, optionally tick **Dry run**, then **Apply staged changes**. A confirmation shows the tenant and counts.
5. Optional: **Sync Autopilot service**. New tags can take a few minutes to show in Intune, and dynamic groups update after that.

## Safety
- Switching tenants clears the device list, and Apply refuses to run if the list was loaded from a different tenant.
- Each change is logged with tenant, serial, old → new tag and who made it, in `%APPDATA%\AutopilotGroupTagTool\logs\yyyyMMdd.log`.
- Saved tenants are kept in `%APPDATA%\AutopilotGroupTagTool\tenants.json`. Tokens are never saved.
- Throttling (HTTP 429 or 5xx) is retried automatically, using Graph's `Retry-After` header.
