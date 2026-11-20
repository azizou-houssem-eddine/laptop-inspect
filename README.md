# LaptopInspect

Fast, zero-dependency, single-file Windows pre-purchase laptop diagnostic, **corporate lock audit**, and interactive hardware verification suite for laptop buyers and refurbishers.

Run it straight from PowerShell on any Windows 10/11 laptop you are inspecting before buying — no installer, no database, and no external binaries required.

## Instant One-Liner Usage

Run in **PowerShell** (right-click Start -> Terminal / PowerShell):

```powershell
irm https://github.com/azizou-houssem-eddine/laptop-inspect/releases/latest/download/inspect.ps1 | iex
```

Alternative direct `main` branch raw URL:

```powershell
irm https://raw.githubusercontent.com/azizou-houssem-eddine/laptop-inspect/main/inspect.ps1 | iex
```

> When started from a standard user prompt, LaptopInspect offers optional UAC elevation (`[Y/n]`) so it can read Vendor BIOS WMI, BitLocker, MDM CIM, and SSD SMART wear. If you decline UAC, it continues cleanly in Standard mode and clearly labels unavailable telemetry instead of guessing.

### Quick / Headless One-Liner Flags (via Environment Variables)

```powershell
# Fast 6-second hardware + corporate lock audit without opening browser or stress tests:
$env:LI_QUICK='1'; $env:LI_NO_BROWSER='1'; irm https://github.com/azizou-houssem-eddine/laptop-inspect/releases/latest/download/inspect.ps1 | iex
```

Supported environment overrides: `LI_QUICK=1`, `LI_SKIP_STRESS=1`, `LI_STRESS_SECONDS=10`, `LI_NO_ELEVATE=1`, `LI_NO_BROWSER=1`, `LI_NO_SERVER=1`, `LI_JSON_ONLY=1`, `LI_OUTDIR="C:\Reports"`.

### Offline USB Usage

1. Download `LaptopInspect-v1.0.0.zip` from [Releases](https://github.com/azizou-houssem-eddine/laptop-inspect/releases).
2. Extract to a USB flash drive.
3. Double-click `RUN.bat` (auto-requests Admin elevation) or run `.\inspect.ps1` in PowerShell.

---

## What It Checks

### 1. Corporate Lock & Ownership Audit (Critical for Used Buyers)
- **Windows Autopilot:** Checks local Autopilot registry policies (`AutopilotSettings`, `Diagnostics\AutoPilot`, `AutopilotPolicyCache`), offline `AutopilotConfigurationFile.json`, CloudStore cache, and MDM `MDM_DevDetail_Ext01` hardware hash availability.
- **Entra ID / Active Directory (`dsregcmd /status`):** Flags `AzureAdJoined`, `EnterpriseJoined`, `DomainJoined`, `WorkplaceJoined`, and tenant details.
- **Intune / MDM Enrollment:** Scans `HKLM:\SOFTWARE\Microsoft\Enrollments\*`, `MDM_EnterpriseModernManagement_Enrollment01`, and `.ppkg` provisioning packages.
- **Absolute Persistence / Computrace:** Checks OS services/files/registry (`rpcnet`, `rpcnetp`, `ctesdursvc`) plus **Vendor BIOS WMI** on HP (`root\HP\InstrumentedBIOS`), Lenovo (`root\wmi` `Lenovo_BiosSetting` / `Lenovo_BiosPasswordSettings`), and Dell (`root\dcim\sysman` `DCIM_BIOSEnumeration`).
- **BIOS Password, Secure Boot, TPM & Intel AMT/vPro:** Flags BIOS/Supervisor password status where exposed by vendor WMI (`UNAVAILABLE` never masquerades as `PASS`), checks Secure Boot, TPM readiness, and AMT/LMS services.
- **BitLocker Encryption:** Reports protected/encrypted volumes via `Get-BitLockerVolume` / `Win32_EncryptableVolume`.
- **Corporate RMM / EDR Agents:** Scans services & processes for 17 enterprise tools (SCCM, CrowdStrike, SentinelOne, NinjaRMM, ScreenConnect, ConnectWise Automate, Tanium, Carbon Black, Cortex XDR, Huntress, Datto, Atera, Pulseway, MeshAgent, ManageEngine, Sophos, Deep Freeze).
- **Windows OEM License Check:** Verifies BIOS embedded OA3 product key presence (masked last 5 chars only) and flags unlicensed or `VOLUME_KMSCLIENT` builds.

### 2. Automated Hardware & Thermal Telemetry
- **Battery & Power Load Stability:** Parses `powercfg /batteryreport` XML + WMI `BatteryStatus`/`BatteryCycleCount` (supports dual-battery ThinkPads). Detects AC adapter flicker or >12% voltage droop while the CPU is under load.
- **CPU Verified Workload + Thermal Load:** Runs parallel multi-core **verified SHA-256 integer AND floating-point checksum workloads** across all logical threads (detects calculation faults + thermal throttling).
- **GPU & True >4GB VRAM:** Reads 64-bit `HardwareInformation.qwMemorySize` from Display Class registry (avoids the 4 GB `Win32_VideoController.AdapterRAM` uint32 cap bug), checks for Code 43 errors, and reads `nvidia-smi` VBIOS/temps/power/PCIe link when present.
- **RAM & Upgradeability:** Reads total physical slots, used vs free slots, DDR/LPDDR type, SODIMM vs soldered detection, plus a verified 128 MB allocation pattern check.
- **Storage SMART & Speed Test:** Reads internal drive health, wear %, temperature, power-on hours, uncorrected errors (isolates USB flash drives so your inspection USB never triggers false alerts), optional `smartctl.exe` enrichment if installed, and a 64 MB `WriteThrough` sequential read/write test.
- **Display EDID, Wi-Fi & Device Errors:** Decodes panel manufacturer (`AUO`, `BOE`, `LGD`, `SDC`, etc.) & diagonal inches, Wi-Fi 4/5/6/7 capability, **local gateway ping**, cameras/Hello IR/fingerprint devices, and Device Manager error codes.

### 3. Guided 10-Step Interactive Verification (Served on Loopback Secure Context)
Because browsers restrict camera/microphone access on `file://`, LaptopInspect saves an offline `.html` report to your Desktop **and** serves the interactive wizard over `http://127.0.0.1:<freeport>/`:
1. **Keyboard & Backlight:** Full QWERTY + F-keys + Nav + Numpad live matrix with key chatter (`<15ms`) detector.
2. **Touchpad & Touchscreen:** Interactive canvas testing Move, Left/Right/Middle clicks, Scroll, Drag, and Touch/Pen.
3. **Screen Inspection:** Fullscreen 10-mode tester (Black, White, R, G, B, 50% Gray, Gradient, Checkerboard, Grid, Motion/Hz test).
4. **Speakers & Audio:** Web Audio left/right/stereo channel test + `120Hz -> 6000Hz` rattle sweep + 3.5mm jack status.
5. **Webcam:** Live preview & resolution readout (auto-stops stream when switching steps).
6. **Microphone:** Live waveform/dB meter + 3s recording playback + local `.wav` download (never stored in the report).
7. **Live Hot-Plug Port Watcher:** Polls `/api/ports` every 1.5s to log newly plugged/unplugged USB drives, chargers, monitors, and Ethernet cables in real time.
8. **GPU 3D WebGL2 Stress:** Selectable Normal/Heavy/Extreme 3D load with live FPS, frame time, and 30s artifact timer.
9. **BIOS / UEFI Manual Lock Checklist:** Prompts manual boot-menu check when vendor BIOS WMI is unavailable.
10. **Cosmetic Grade & Purchase Certificate:** Chassis/screen/hinge/charger grades, seller/price notes, Save to Desktop HTML, Copy Text/WhatsApp Summary, Export `.TXT`/`.JSON`, and Print/PDF certificate.

---

## CLI Parameters

| Parameter | Description |
| :--- | :--- |
| `-Quick` | Skips CPU stress, RAM allocation test, and disk benchmark (~6-8s audit) |
| `-SkipStress` | Skips stress/disk benchmarks while running full telemetry |
| `-StressSeconds <0..60>` | CPU thermal + verified math load duration (default `10`) |
| `-NoBrowser` | Saves report and prints console summary without starting localhost UI |
| `-NoServer` | Opens static Desktop HTML directly without starting `127.0.0.1` server |
| `-NoElevate` | Runs immediately in current privilege level without UAC prompt |
| `-JsonOnly` | Writes raw JSON report only |
| `-OutDir <path>` | Custom output directory (defaults to Desktop) |

---

## Honest Diagnostic Scope & Limitations
- **Clean local Autopilot != guaranteed cloud-free:** If a seller performed an offline Windows wipe and never connected to the internet, cloud-only Autopilot hardware-hash assignments only surface once the machine reaches network during Windows Setup (OOBE).
- **UNAVAILABLE != PASS:** When vendor BIOS WMI, ACPI temperature sensors, or SMART wear counters are restricted or absent, LaptopInspect explicitly reports `UNAVAILABLE` rather than `PASS`.
- **Short load scope:** Verified CPU, RAM, and WebGL workloads test allocation and short-duration stability; they do not guarantee multi-hour longevity.

## License
MIT License — see [LICENSE](LICENSE).
