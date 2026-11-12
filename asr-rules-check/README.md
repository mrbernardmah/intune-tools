# ASR Rules Check

Checks that each Microsoft Defender **attack surface reduction (ASR)** rule is set to **Audit** or **Block** on a Windows device, and reports every rule that is Disabled, Not configured or in Warn mode.

`Check-ASRRules.ps1` reads the *effective* configuration with `Get-MpPreference`. That is the merged result of Intune, Group Policy, Configuration Manager and local settings, so it shows what the device is actually enforcing, not what one policy says.

## Quick start

```powershell
# Run on the device (elevated is recommended)
.\Check-ASRRules.ps1

# Treat only Block as compliant
.\Check-ASRRules.ps1 -AcceptedModes Block

# Accept Warn as well, and export the results
.\Check-ASRRules.ps1 -AcceptedModes Block,Audit,Warn -CsvPath C:\Temp\asr.csv
```

Example output:

```
Status       State          Rule                                               Guid
------       -----          ----                                               ----
NonCompliant Not configured Block Adobe Reader from creating child processes   7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c
Compliant    Block          Block rebooting machine in Safe Mode               33ddedf1-c6e0-47cb-833e-de6133960387
Skipped      Exchange ...   Block Webshell creation for Servers                a8f5898e-1dc8-49a9-9878-85004b8a61e6
```

## Parameters

| Parameter | Description |
| --- | --- |
| `-AcceptedModes` | Actions counted as compliant: `Block`, `Audit`, `Warn`. Default `Block,Audit`. |
| `-ExcludeRuleId` | One or more rule GUIDs to skip, for example rules your OS versions don't support. |
| `-IncludeExchangeServerRule` | Also check *Block Webshell creation for Servers*. It applies to Exchange servers only, so it is skipped by default. |
| `-CsvPath` | Export the per-rule results to CSV. |
| `-Detection` | Intune Remediations mode: one status line, exit `0` or `1`. |
| `-PassThru` | Return the result objects to the pipeline. |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every checked rule is Compliant |
| `1` | At least one checked rule is NonCompliant |
| `2` | The check could not run (for example Defender isn't available). With `-Detection`, this returns `1` instead. |

## Use as an Intune Remediation detection script

In the Intune admin center go to **Devices > Scripts and remediations > Remediations > Create**, and upload a copy of `Check-ASRRules.ps1` as the detection script. Intune can't pass parameters to a detection script, so in that copy change `[switch]$Detection` to `[switch]$Detection = $true` (and adjust `-AcceptedModes` or `-ExcludeRuleId` defaults the same way if needed). A device with any non-compliant rule shows as "With issues", and the output line (up to about 2000 characters) names the rules. Run it with the logged-on credentials set to **No** (SYSTEM) and in 64-bit PowerShell.

This tool only detects. Fixing a rule means changing your ASR policy (Endpoint security > Attack surface reduction > Attack Surface Reduction Rules), and starting in Audit mode before moving rules to Block is Microsoft's recommended approach.

## Rules checked

Names and GUIDs come from the Microsoft Defender for Endpoint [ASR rules reference](https://learn.microsoft.com/en-us/defender-endpoint/attack-surface-reduction-rules-reference) (page last updated 2026-09-09), which is the page the [Intune attack surface reduction documentation](https://learn.microsoft.com/en-us/intune/device-configuration/endpoint-security/attack-surface-reduction) links to for rule details. The Intune page itself doesn't list GUIDs.

| Rule | GUID |
| --- | --- |
| Block abuse of exploited vulnerable signed drivers (Device) | `56a863a9-875e-4185-98a7-b882c64b5ce5` |
| Block credential stealing from the Windows local security authority subsystem | `9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2` |
| Block persistence through WMI event subscription | `e6db77e5-3df2-4cf1-b95a-636979351e5b` |
| Block Adobe Reader from creating child processes | `7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c` |
| Block all Office applications from creating child processes | `d4f940ab-401b-4efc-aadc-ad5f3c50688a` |
| Block executable content from email client and webmail | `be9ba2d9-53ea-4cdc-84e5-9b1eeee46550` |
| Block executable files from running unless they meet a prevalence, age, or trusted list criterion | `01443614-cd74-433a-b99e-2ecdc07bfc25` |
| Block execution of potentially obfuscated scripts | `5beb7efe-fd9a-4556-801d-275e5ffc04cc` |
| Block JavaScript or VBScript from launching downloaded executable content | `d3e037e1-3eb8-44c8-a917-57927947596d` |
| Block Office applications from creating executable content | `3b576869-a4ec-4529-8536-b80a7769e899` |
| Block Office applications from injecting code into other processes | `75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84` |
| Block Office communication application from creating child processes | `26190899-1602-49e8-8b27-eb1d0a1ce869` |
| Block process creations originating from PSExec and WMI commands | `d1e49aac-8f56-4280-b9ba-993a6d77406c` |
| Block rebooting machine in Safe Mode | `33ddedf1-c6e0-47cb-833e-de6133960387` |
| Block untrusted and unsigned processes that run from USB | `b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4` |
| Block use of copied or impersonated system tools | `c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb` |
| Block Webshell creation for Servers (Exchange servers only) | `a8f5898e-1dc8-49a9-9878-85004b8a61e6` |
| Block Win32 API calls from Office macros | `92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b` |
| Use advanced protection against ransomware | `c1db55ab-c21a-4637-bb3f-a12568109d35` |

Microsoft adds and changes rules over time. Any GUID configured on the device that isn't in this table is listed separately in the output so it isn't silently ignored. To pick up a new rule, add it to the `$AsrRules` table at the top of the script.

## Things to know

- **Not configured counts as non-compliant.** A rule that no policy sets doesn't appear in `Get-MpPreference`, so it is reported as `Not configured`.
- **Rules not supported on some OS versions** (for example some rules on Windows Server 2012 R2 and 2016, or Windows 10 builds before the rule's minimum version) will show as non-compliant. Use `-ExcludeRuleId` for those. See the OS support table in the Microsoft reference.
- **LSASS rule and LSA protection.** Microsoft notes that if Local Security Authority (LSA) protection is enabled, the credential stealing rule isn't required. Exclude it with `-ExcludeRuleId 9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2` if you rely on LSA protection instead.
- **Warn mode.** Warn (action `6`) isn't Audit or Block, so it is non-compliant unless you pass `-AcceptedModes ...,Warn`. The LSASS and Office code injection rules don't support Warn.
- Requires Windows with Microsoft Defender Antivirus as the primary antivirus.
- The script is read-only and changes nothing on the device.
