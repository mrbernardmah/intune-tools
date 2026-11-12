# Windows Update Error Remediation Builder

Pick the Windows Update error codes your devices report and get a ready-to-import **Intune Remediation** pair:
a read-only detection script and a matching remediation script. No API key, no backend: everything is generated in
the browser from fixed, tested templates.

The code list covers Microsoft's
[Windows Update error reference](https://learn.microsoft.com/en-us/windows/deployment/update/windows-update-error-reference)
(259 codes across 16 components). Descriptions are short paraphrases; follow the link for Microsoft's wording.

## Use it

Open `dist/index.html` (single self-contained file) or `index.html` in a browser.

1. **Pick codes.** Search by hex (`0x8024402C`, `8024402C`), decimal HRESULT (`-2147023838`), symbolic name or keyword,
   or filter by component or fix type. Codes not in the reference (for example `0x800F0922`) can be added by typing
   them and pressing Enter. The selection is kept in the page URL (`#codes=...`) so you can share it.
2. **Review the fix plan.** Each code maps to one or more playbooks; suggested ones are ticked and you can add or
   remove any. Set the organisation folder, look-back window and what triggers detection.
3. **Download** `Detect-WUError-<id>.ps1` and `Remediate-WUError-<id>.ps1` and follow the **Intune setup** tab:
   Devices > Scripts and remediations > Remediations > Create; run as SYSTEM; 64-bit PowerShell.

## Fix playbooks

| Playbook | Remediation does | Detection flags (state) |
| --- | --- | --- |
| Clear blocking policy | Exports a `.reg` backup, removes leftover WSUS values (`WUServer`, `WUStatusServer`, `UpdateServiceUrlAlternate`, `UseWUServer`) and access blocks (`DisableWindowsUpdateAccess`, `DoNotConnectToWindowsUpdateInternetLocations`, `SetDisableUXWUAccess`, `NoAutoUpdate`). WSUS values are left alone on Configuration Manager clients by default. | Any of those values present |
| Repair update services | Re-enables disabled `wuauserv`, `BITS`, `CryptSvc`, `UsoSvc`, `TrustedInstaller`, `msiserver`; starts the core ones | A service is Disabled |
| Clear failed BITS jobs | Removes BITS jobs in `Error`/`TransientError` for all users, restarts BITS | - |
| Reset components | Stops services, renames `SoftwareDistribution` (and optionally `catroot2`) to `.bak-<timestamp>`, removes older backups, restarts services | - |
| Network check | Flushes DNS, optionally resets the WinHTTP proxy, tests Microsoft or WSUS endpoints and reports failures | - |
| Repair component store | `DISM /RestoreHealth`, optionally `sfc /scannow` | Image not Healthy (optional) |
| Pending restart | Schedules a restart with a user warning, only if you enable it | Restart pending |
| Scan | Starts a Windows Update scan at the end (`UsoClient StartScan` or `DetectNow`) | - |

### How detection decides

Detection looks for the selected codes in Windows Update Agent history (`HResult` and `UnmappedResultCode`) and in
the `WindowsUpdateClient/Operational` event log, within the look-back window. After a successful remediation the
time is stored under `HKLM\SOFTWARE\<Org>\WUErrorRemediation\<id>`, and detection only counts errors after it, so a
fixed device turns compliant instead of looping on old errors. Depending on the trigger setting it also checks the
device state listed above. Each script writes one status line (shown in Intune's output columns) and logs to
`%ProgramData%\<Org>\Logs\`.

### Cautions

- Removing WSUS policy is the wrong fix for devices that should scan WSUS or Configuration Manager; Group Policy
  also re-applies the values if the GPO is still linked.
- The component reset clears the update history list shown in Settings.
- DISM can run long; Intune ends a remediation after 60 minutes.
- Pilot on a small group first.

## Develop

No dependencies. `wu-codes.js` holds the data, `generator.js` the script templates, `index.html` the page.

```
node --test wu-error-remediation/test/*.test.js   # generator tests; PowerShell tests run when pwsh is on PATH
node wu-error-remediation/build.js                 # rebuild dist/index.html (a test fails if it is stale)
```

`test/scripts.test.js` parses every generated script with the PowerShell parser and runs detection and remediation
against mocked Windows commands (`test/mocks.ps1`): disabled services, WSUS leftovers, Configuration Manager clients,
pending restarts, old vs new history entries, the remediation marker, and file renames on disk. The scripts target
Windows PowerShell 5.1 and are ASCII only.
