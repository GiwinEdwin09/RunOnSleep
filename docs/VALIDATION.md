# Validation record — 2026-09-22

Configuration: Mac14,2 (M2 MacBook Air), macOS 26.5.2 / 25F84, Swift 6.3.3, RunOnSleep 0.1.0.

## Completed

- `Scripts/test.sh`: **37 tests passed** in three suites.
- Session-engine coverage: pre-existing global state, conditional restoration, observed external changes, unknown readback, failed writes, failed confirmation persistence, ambiguous journals, reboot boundaries, stale/wrong tokens, peer identity, sequence replay, competing starts, lease expiry, fixed deadlines, battery/thermal transitions, and logout.
- Transport coverage: real kernel peer audit identity, malformed/oversized framing, multiple frames, and disconnected peers.
- Native backend checks: real power/lid readback, 256-bit random tokens, acquiring and releasing a real idle-sleep assertion, and atomic journal round trips. Global `SleepDisabled` remained unchanged.
- Verification records require both trials and matching hardware/OS/app/helper configuration.
- Production app and helper compiled; app and helper ad-hoc code signatures verified. Installer payload and shell/plist syntax checked.
- The packaged app was launched through Finder and its process was observed running. The native UI inspection tool could not attach to the menu-bar-only app, so visual/control interaction testing is not claimed.

## Not performed

- Administrator helper installation and end-to-end privileged IPC/installer/uninstaller runs.
- Thirty-minute closed-lid charger and battery trials, actual power transitions, or sustained computer-use task testing.
- Physical thermal stress or battery depletion (these are simulated in unit tests).

No hardware verification result was generated or imported. Closed-lid capability remains **untested**. The helper installer is ready for user authorization. See USER_GUIDE.md for the physical test and recovery procedures.
