# Intune Device Wipe (Wipe-IntuneDevices-GUI.ps1)

A Windows GUI for sending **remote wipe / retire** actions to Microsoft Intune managed devices at scale. Targets are found by **Entra ID group** or by **hostname / serial number**, previewed in a grid, ticked or unticked individually, then wiped only after an explicit confirmation.

| | |
|---|---|
| **Script** | `Wipe-IntuneDevices-GUI.ps1` |
| **Version** | 1.6 |
| **Category** | Operational / Devices / GUI |
| **Minimum role** | Intune Administrator |
| **Runs on** | Windows PowerShell 5.1 or PowerShell 7 (Windows only, WinForms) |
| **Graph API** | `https://graph.microsoft.com/beta` |

> **Warning:** A full wipe resets devices to factory settings. Wipe and retire operations **cannot be undone**. Test on a small, non-production group first.

---

## Contents

1. [Why this tool exists](#why-this-tool-exists)
2. [Features at a glance](#features-at-a-glance)
3. [Requirements](#requirements)
4. [Permissions](#permissions)
5. [Quick start](#quick-start)
6. [Parameters](#parameters)
7. [The window, section by section](#the-window-section-by-section)
8. [Sign-in options](#sign-in-options)
9. [Finding devices](#finding-devices)
10. [Wipe options](#wipe-options)
11. [Safety checks and confirmation](#safety-checks-and-confirmation)
12. [Long-running runs: token handling and resilience](#long-running-runs-token-handling-and-resilience)
13. [Output: CSV and log files](#output-csv-and-log-files)
14. [Stopping and exiting safely](#stopping-and-exiting-safely)
15. [Troubleshooting](#troubleshooting)
16. [Security notes](#security-notes)
17. [Version history](#version-history)

---

## Why this tool exists

Wiping many devices from the Intune portal is slow and error-prone, and scripted wipes of large groups commonly fail part-way through with **401 Unauthorized** when the access token expires. This tool puts a guarded front end on the Graph wipe calls and is designed around three ideas:

- **See before you send.** Every target device is listed in a grid first. Nothing is sent until you confirm.
- **Survive long runs.** Tokens are tracked, renewed before expiry, and retried on 401. Throttling (429) and server errors (5xx) are retried with back-off.
- **Be resumable and auditable.** A per-device CSV and a log are written continuously, and devices that were not processed stay ticked so you can press Wipe again to resume.

---

## Features at a glance

- Search for an **Entra ID group** by the start of its name, or by group ID, and pick the exact group from a drop-down (no ambiguity when two groups share a name).
- Search by **hostname or serial number**, several at once, with `*` and `?` wildcards. Matches are added to the list, so lists can be built up across several searches.
- Optional **nested group** expansion (transitive members).
- Group members are matched to Intune records by **Entra device ID** (the most recently synced record wins); **user members** add all of their managed devices.
- Device list grid with per-device tick boxes, **Tick all / Untick all / Clear list**.
- Devices already in a pending wipe or retire state are **unticked** automatically.
- Group members with no Intune record are shown in **grey** and cannot be ticked.
- Four wipe options that use the same wording as the Intune portal, plus an optional **macOS unlock PIN**.
- Configurable **delay between wipes**.
- Five sign-in methods, including browser sign-in with silent renewal.
- Pre-flight check that the **wipe permission** is actually accepted by Graph before the first device is touched.
- Authorisation **circuit breaker**: stops the run if authorisation keeps failing instead of failing every remaining device.
- Stop button, safe Exit, and a colour-coded live log.

---

## Requirements

- Windows with **Windows PowerShell 5.1** or **PowerShell 7**.
- An **STA** thread. If the script is not already running in STA it relaunches itself with `-STA -NoProfile -ExecutionPolicy Bypass`.
- Module **`Microsoft.Graph.Authentication`**. All sign-in options hand their token to it. If it is missing, the tool offers to install it from the PowerShell Gallery (`AllUsers` scope if you are an administrator, otherwise `CurrentUser`).
- Module **`MgGraphCommunity`**, only if you choose that sign-in option.
- An account holding the **Intune Administrator** role (activate PIM first if you use it).
- Outbound access to `login.microsoftonline.com` and `graph.microsoft.com`.

---

## Permissions

The tool requests these delegated Microsoft Graph permissions:

| Permission | Used for |
|---|---|
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | Sending wipe / retire actions |
| `DeviceManagementManagedDevices.Read.All` | Reading Intune managed devices |
| `GroupMember.Read.All` | Reading group members (including nested) |
| `Device.Read.All` | Reading Entra device objects |

Browser and device code sign-in use the **Microsoft Graph Command Line Tools** public client by default. It needs consent for the four permissions above, which an administrator can grant at first sign-in.

---

## Quick start

1. Open PowerShell on a Windows machine and run:

   ```powershell
   .\Wipe-IntuneDevices-GUI.ps1
   ```

2. Pick a **sign-in method**, confirm the **tenant** box, and click **Connect**.
3. Choose **Search by** (Entra ID group, or hostname / serial number), type your search and press **Search**.
4. For a group, pick it from the drop-down, optionally tick **Nested**, then click **Load devices (preview)**.
5. Review the grid. Tick or untick devices.
6. Choose a **Wipe option** (and a macOS PIN if needed). Set the **delay** and **export folder**.
7. Click **Wipe...**, read the prompt, tick **I understand**, type the required confirmation, and proceed.

The status line at the bottom of the window summarises the same steps: *1) Connect 2) Search and pick a group 3) Load devices (preview) 4) Review ticks 5) Wipe.*

---

## Parameters

```powershell
.\Wipe-IntuneDevices-GUI.ps1 [-ExportPath <string>] [-TenantId <string>] [-ClientId <string>]
```

| Parameter | Default | Description |
|---|---|---|
| `-ExportPath` | `C:\ProgramData\Devicie\logs` | Folder where the CSV and log are written. Can also be changed in the window (Export folder / Browse). |
| `-TenantId` | `organizations` | Tenant for browser and device code sign-in: `organizations`, a tenant ID, or a domain such as `contoso.onmicrosoft.com`. Also editable in the **Tenant** box. |
| `-ClientId` | `14d82eec-204b-4c2f-b7e8-296a70dab67e` | Public client used for browser and device code sign-in (Microsoft Graph Command Line Tools, the app `Connect-MgGraph` uses). |

---

## The window, section by section

**Connection bar (top)**
- Sign-in method drop-down, **Tenant** box, **Connect** button.
- A status label shows the signed-in account, approximate minutes of token life remaining, how the token renews, and wipe-permission status (shown in green normally and amber when the token is nearly due for renewal or Graph refused the wipe permission).
- **Exit** button (top right).

**Wipe by group tab**
- **Search by** drop-down: *Entra ID group* or *hostname / serial number*.
- Search box and **Search** button. For groups, type the start of a group name (or a group ID), press Search, then pick the group from the drop-down next to it.
- **Nested** tick box: include members of nested groups.
- **Load devices (preview)**: populate the grid from the selected group.

**Wipe option box**
- Drop-down with the four wipe options, a description of the selected option, and the **macOS unlock PIN (6 digits)** field.

**Run settings box**
- **Delay between wipes (s)**: pause between devices, 0 to 60 seconds (default 3).
- **Export folder** and **Browse**.

**Device list box**
- **Tick all**, **Untick all**, **Clear list**.

**Device grid** columns: `Wipe` (tick box), `Device`, `Serial`, `Primary user`, `OS`, `Model`, `Last sync`, `Intune state`, `Source`, `Result`, `Error`.

**Bottom bar**
- Large red **Wipe...** button (its label updates to show the count, for example *Wipe 12 device(s)...*, or *Retire 12 device(s)...* when Retire is selected), **Stop**, **Open export folder**, a progress bar, and a count label (*N device(s) found, M ticked*).
- A live, colour-coded **log pane** (info, OK, warning, error) mirrored to the log file.

---

## Sign-in options

Choose in the connection bar. All options end with a Microsoft Graph token handed to the Graph PowerShell SDK.

| Option | How it works | Renewal |
|---|---|---|
| **Browser sign-in** (default) | Opens the Microsoft login page in your default browser using the authorization code flow with **PKCE** and a localhost redirect (5 minute limit). | Refresh token held in memory; the access token **renews silently** during long runs. |
| **Device code** | Shows a code (copied to the clipboard) and opens `microsoft.com/devicelogin`. Useful when the browser is on another machine. | Silent refresh-token renewal. |
| **Paste bearer token** | Paste a token, for example the `Authorization` header copied from the Intune portal (F12, Network tab, filter `graph.microsoft.com`). The `Bearer ` prefix is optional. | **Cannot be renewed.** The run pauses and asks for a new token before expiry. |
| **MgGraphCommunity** | Uses `Connect-MgGraphCommunity`. | Renews by signing in again. |
| **Graph SDK** | Uses `Connect-MgGraph`. | Renews silently. |

**Pasted-token validation:** the token must look like a JWT, be issued for the Graph audience, and have at least **6 minutes** left. The tool asks for a replacement when a pasted token has under **5 minutes** left. Scopes listed inside a pasted token are not used to reject it, because portal tokens may not list the wipe scope yet still be permitted; Graph decides (see the pre-flight check below).

After sign-in the tool reads the token's **expiry, scopes, account and tenant** and shows them in the connection bar.

---

## Finding devices

### By Entra ID group
1. Set **Search by** to *Entra ID group*.
2. Type the start of the group name (or paste a group ID) and press **Search**. Up to 100 matches are returned, sorted by name.
3. Pick the exact group, optionally tick **Nested**, and click **Load devices (preview)**.

How members are resolved:
- **Device members** are matched to Intune managed devices by **Entra device ID**. If several Intune records exist, the **most recently synced** one wins.
- **User members** add **all of that user's managed devices**.
- With **Nested** ticked, transitive membership is used instead of direct membership.
- Members that have **no Intune record** are listed in grey and cannot be ticked. If a group has no Intune devices at all, a clear message is shown.

### By hostname or serial number
Set **Search by** to hostname / serial number.

- Enter **one or more** hostnames or serial numbers, separated by commas or spaces (for example `DD-0392*`).
- `*` and `?` work as **wildcards**. Without a wildcard, a term must match a device name or serial number **exactly**.
- Matching devices are **added** to the existing list, so you can build a list across multiple searches. Use **Clear list** to start again.
- If the same physical device has several Intune records, the **most recently synced** one is used and the others are skipped (noted in the log).
- The **Source** column shows how each device got into the list (`Device member`, `User: <name>`, or `Search: <term>`).

### Pre-ticking rules
Devices whose Intune state is already a pending operation (`wipePending`, `retirePending`, `wipeIssued`, `retireIssued`, `deletePending`) are **unticked** and marked **Already pending - skipped** so they are not sent a second action. **Tick all** never ticks rows that are already initiated or that have no Intune record.

---

## Wipe options

The wording matches the Intune portal. The option is chosen in the main window and the confirmation prompt opens with it pre-selected.

| Option | Graph call | Notes |
|---|---|---|
| **Reset device and remove all data** | `POST .../managedDevices('{id}')/wipe` with `keepEnrollmentData` and `keepUserData` both `false` | Restores factory settings and deletes all data and management settings. If interrupted, the device might not recover. |
| **Reset device, but keep user data** | `wipe` with `keepEnrollmentData` and `keepUserData` both `true` | Keeps user files and accounts; management settings are removed but the device stays enrolled. **Windows only.** |
| **Securely erase device (high security)** | `wipe` with `useProtectedWipe: true` | Removes all data and settings, prevents recovery, and completes even if the device loses power. Can leave some devices (for example BitLocker-encrypted ones) unable to start. **Windows only.** |
| **Retire: remove company data only** | `POST .../managedDevices('{id}')/retire` (no request body) | Removes company apps, data, email profiles and management, and unenrolls the device. Personal data and the OS are left in place. |

**macOS unlock PIN:** an optional 6-digit PIN can be entered in the main window or the wipe prompt. It is sent as `macOsUnlockCode` **only to devices whose OS is macOS**.

---

## Safety checks and confirmation

Before any device is touched:

1. **Preview first.** Nothing is sent until you click Wipe.
2. **Portal-style wipe prompt.** Opens with the option chosen in the main window (you can change it here) and shows its description, with:
   - an **"I understand"** tick box that must be ticked,
   - typing the **number of devices** to confirm, when more than one device is selected,
   - an optional **macOS unlock PIN** field,
   - a warning when you pick a **Windows-only option** and some selected devices are not Windows (Intune may reject those, and they will show as Failed),
   - a warning about the **500 wipe actions per tenant per day** limit when more than 500 devices are selected.

   Cancelling the prompt sends nothing.
3. **Permission pre-check.** The wipe permission is not judged from the token's scope list. If the scope is not listed, a harmless **`syncDevice`** request is sent first to check with Graph. The run stops only if Graph **refuses (403)**, so a missing permission is caught before any device is wiped.

---

## Long-running runs: token handling and resilience

This tool specifically addresses the *"Unauthorized (401)"* failures that appear part-way through large runs.

- **Proactive refresh.** Before every wipe call the token is checked. With under **4 minutes** left (5 for pasted tokens) the tool renews it: silently with the Graph SDK or a refresh token, otherwise by signing in again, or by prompting for a new pasted token.
- **401 retry.** A 401 on any call triggers **one** token renewal and a retry of that same device.
- **Authorisation circuit breaker.** If authorisation (HTTP 401 or 403) fails for **3 devices in a row**, the run stops rather than failing every remaining device.
- **Failure pause.** After **5 failures in a row** (of any kind) the tool asks whether to continue.
- **Throttling and server errors.** 429 and 5xx responses honour **Retry-After** and are retried with back-off (up to 4 attempts per request).
- **Resumable.** Each successful device is **unticked** after it is sent. Failed and unprocessed devices stay **ticked**, so pressing **Wipe** again resumes with only those.
- **Stale token guard.** If renewal returns a token with under 2 minutes of life, the run stops with an explanatory message instead of continuing on a stale cached token.

---

## Output: CSV and log files

Files are written to the **Export folder** with the same naming as the earlier V3 script:

- `Wipe-Devices_<yyyyMMdd-HHmmss>_<Option>.csv`: one row per device, **rewritten after every device** so it is never lost if the run is interrupted. `<Option>` is the option key (`Wipe`, `WipeKeepUserData`, `ProtectedWipe`, `Retire`).
- A matching `.log` file with the same content as the on-screen log.
- Clicking **Load devices (preview)** also writes a **preview** CSV (`..._Preview.csv`), the equivalent of a dry run, before anything is sent.

**CSV columns:** `Timestamp`, `DeviceName`, `SerialNumber`, `UserPrincipalName`, `OperatingSystem`, `Model`, `LastSync`, `ManagementState`, `IntuneDeviceId`, `EntraDeviceId`, `Source`, `Ticked`, `WipeOption`, `Target`, `Result`, `Error`.

**Result values:** `Not processed`, `In progress`, `Wipe initiated`, `Retire initiated`, `Failed` (with `HTTP <status> - <message>` in `Error`), `Already pending - skipped`, and rows for members that are `Not in Intune`.

`Wipe initiated` means Intune **accepted** the request. The device itself carries it out the next time it checks in.

Use **Open export folder** to jump straight to the location. Tokens are **never** written to the log or the CSV.

---

## Stopping and exiting safely

- **Stop** halts the run after the current device or step. It also cancels a sign-in that is waiting.
- **Exit** (and closing the window) is safe: if work is running, you are asked to confirm, the run stops after the current step, and the window closes once everything has unwound. Unprocessed devices are recorded as *Not processed* in the CSV and stay ticked.
- **Ctrl+C** in the console is treated as a key press and does not stop the script mid-run.
- Every event handler catches its own errors. If PowerShell is stopped anyway (for example Stop in VS Code or ISE), the window closes instead of showing *"Unhandled exception ... The pipeline has been stopped"*.

---

## Troubleshooting

| Symptom | What to check |
|---|---|
| **401 Unauthorized** mid-run | Normally handled automatically. If sign-in cannot renew (for example a pasted token), paste a new one when prompted. |
| **403 reading devices** | Confirm the **Intune Administrator** role is active (PIM) and the token includes `DeviceManagementManagedDevices.Read.All`. |
| **Wipe permission REFUSED by Graph** | The account or app lacks `DeviceManagementManagedDevices.PrivilegedOperations.All`. Ask an admin to grant consent, then reconnect. |
| Browser sign-in never completes | Finish within 5 minutes. Check that a local firewall is not blocking the loopback redirect, or use **Device code** instead. |
| Pasted token rejected | It must be for `graph.microsoft.com`, start with `eyJ`, and have at least 6 minutes left. |
| Module missing | Accept the install prompt for `Microsoft.Graph.Authentication`, or install it manually. |
| Group members greyed out | They have no Intune record (not enrolled, or only an Entra device object). They cannot be wiped here. |
| Windows-only option on Mac/mobile | *Keep user data* and *Securely erase* are Windows-only. Use *Reset device and remove all data* or *Retire*. |
| Hit the daily limit | Intune accepts up to **500 wipe actions per tenant per day** (portal and API combined). Untick some devices and run the rest the next day. |
| Some devices show **Failed** | Read the `Error` column (HTTP status and Graph message). Fix the cause and press **Wipe** again; only failed and unprocessed devices are still ticked. |

---

## Security notes

- Tokens live **in memory only** and are never logged or exported.
- The default public client is Microsoft's own *Graph Command Line Tools* app; use `-ClientId` to point at your own app registration if your organisation requires it.
- Restrict who can run this tool. Anyone who can sign in with the required permissions can factory-reset devices.
- Keep the export folder (default `C:\ProgramData\Devicie\logs`) appropriately protected: it contains device names, serial numbers and user principal names.

---

## Version history

| Version | Highlights |
|---|---|
| **1.6** | Wipe option drop-down in its own box (with description and macOS PIN). Search by hostname / serial number (multiple, `*` wildcard) alongside Entra ID group; hostname matches are added to the list; **Clear list** button. Fixed the Exit button being pushed off-screen. |
| **1.5** | Portal-style wipe prompt: four wipe options, optional macOS PIN, "I understand" tick box, device-count typing for multiple devices; warnings for Windows-only options and the 500/day limit. |
| **1.4** | Wipe permission no longer judged from the token scope list; a harmless `syncDevice` request checks with Graph before the first wipe. |
| **1.3** | Fixed "property 'Visible' cannot be found" / null-valued expression when loading a group; explicit grid columns; grey, untickable rows for members with no Intune record; clear message when a group has no Intune devices. |
| **1.2** | Exit button with safe shutdown; Ctrl+C no longer stops the script; Stop cancels a waiting sign-in; every handler catches its own errors. |
| **1.1** | Browser (auth code + PKCE) and device code sign-in with silent renewal; paste-bearer-token option with validation and pause-and-prompt before expiry; tenant box; `-TenantId` and `-ClientId` parameters. |
| **1.0** | Initial GUI release: Wipe by group, token expiry tracking and proactive refresh, 401 re-auth and retry, authorisation circuit breaker, resumable runs, per-device CSV written after every device. |
