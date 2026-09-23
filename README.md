# RunOnSleep

A native macOS 26+ menu-bar app for long-running agents. Built for Apple Silicon with SwiftUI, IOKit, and a small administrator-installed helper. No dependencies or network services.

- **Background agents:** idle-sleep prevention; optional experimental closed-lid support on charger and battery.
- **Computer use:** system and display stay awake with an open lid and unlocked desktop.
- Helper-owned 45-second leases, battery cutoff, thermal stops, and conservative recovery.
- Independent indicators for app session, global `SleepDisabled`, and hardware verification.

Closed-lid support uses undocumented `pmset disablesleep`. It is **untested until physical trials pass on your exact configuration**. A successful write is not verification. Another power-management utility can interfere; same-value external writes cannot be detected.

## Build and run

Requires macOS 26+, Apple Silicon, and Command Line Tools with Swift 6.

```sh
./Scripts/test.sh
./Scripts/build.sh
open dist/RunOnSleep.app
```

The build produces `dist/RunOnSleep.app`, `dist/RunOnSleepHelper.pkg`, `dist/RunOnSleep.zip`, and an uninstall command. The app and helper are ad-hoc signed for local use, not notarized for public distribution.

Move the app to `/Applications` before enabling launch at login. Open it and use its robot icon in the menu bar. Ordinary keep-awake needs no administrator access. Choose **Install administrator helper…** for closed-lid operation; the native Installer requests authorization. Installation starts the helper but **does not disable sleep**. The helper is restricted to the user at the console during installation.

See [the user, recovery, and hardware-testing guide](docs/USER_GUIDE.md) and [architecture](docs/ARCHITECTURE.md).

## Software validation versus physical verification

Tests inject power state, thermal state, time, client identities, and journal failures. They never run `pmset` mutations. Hardware trials require you to close the lid, disconnect/reconnect power, and inspect a real task; they are intentionally not marked complete by unit tests.

The app prevents sleep-related interruptions. Screen savers, security policy, network loss, agent crashes, and explicit lock actions can still interrupt computer use. It never unlocks your Mac or changes password requirements.
