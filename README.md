Tools for Microsoft Intune - ASR GUID rules checker, Windows Update Rings, Windows Update Error Remediation, Intune Wipe Tool GUI

## Autopilot Group Tag Manager

A Windows GUI (PowerShell + WPF) to view and bulk-change **Windows Autopilot group tags** in any tenant through Microsoft Graph.

- Sign in interactively or paste a Graph bearer token
- Search and filter devices by serial, model, user or group tag
- Stage changes for selected devices, or import a serial list or CSV
- Review before applying, with a dry run option and a daily audit log

**Requires:** Windows, PowerShell 5.1 or 7+, and `DeviceManagementServiceConfig.ReadWrite.All` (`Read.All` to browse only).

```powershell
powershell -STA -ExecutionPolicy Bypass -File ".\Autopilot Group Tag Tool\AutopilotGroupTagTool.ps1"
```

[Full instructions](Autopilot%20Group%20Tag%20Tool/README.md)
