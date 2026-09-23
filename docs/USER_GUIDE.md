# RunOnSleep: use, testing, and recovery

## Starting a session

1. Open RunOnSleep to see its controls and current protection status. The first launch also explains where to find the robot icon in the menu bar.
2. Choose Background agents or Computer use, a duration, and a battery cutoff.
3. For closed-lid background work, install the helper using the app's button, then select Closed lid · experimental. Read the first-use heat notice.
4. Click Start protection. An ACTIVE session, the observed global flag, and experimental capability are three different indicators.
5. Stop protection when finished. Quit also asks the helper to stop. If the app disappears, the helper expires its lease within 45 seconds plus at most one five-second polling interval.

Keep the Mac on a hard, ventilated surface. Never run it closed in a bag, sleeve, drawer, or enclosure. A coarse OS thermal signal cannot guarantee safe temperatures. RunOnSleep ends protection at serious heat with a closed or unknown lid, or critical heat with any lid state. It cannot stop an agent's CPU work directly.

Opening the app does not start protection. Closing the controls window leaves the app and any active session running; use Stop protection or Quit to end the session. Click the menu-bar robot for quick access, or open the app again to bring back the window. Optional launch at login stays quiet and starts inactive.

Battery warning starts at 20% (or five points above a higher cutoff). Default cutoff is 15%, adjustable from 5–50%. Unknown battery level while unplugged also ends protection. Thermal/battery stops never automatically restart.

Computer use requires an open lid and an unlocked desktop. macOS display assertions prevent display idle sleep, but do not promise to prevent screen savers or managed security policies. Configure your workflow accordingly. Lock detection uses best-effort macOS notifications and never bypasses authentication.

## What the global indicator means

`SleepDisabled` is shared, global state with no ownership metadata. Enabled does not prove that this app changed it. When already enabled, RunOnSleep borrows that condition and never clears it on Stop. The UI says so.

When RunOnSleep observes false, journals its intent, writes true, verifies the result, and persists confirmation, it can conditionally restore false at the end of that session. It only does so within the same boot, without an observed conflict, and with a readable current true value. It does not reapply settings changed externally.

Another tool writing true while true is already set cannot be distinguished from no change. Polling also cannot detect every transient change. Do not run multiple global sleep-management utilities together. There is no atomic compare-and-set API and the app does not claim exclusive ownership.

If Stop or a safety cutoff leaves global sleep disable enabled, the UI reports that normal sleep is not assured. This can be intentional external state. Releasing app assertions cannot guarantee sleep when other assertions exist either.

## Recovery

Open Diagnostics & settings, copy diagnostics, and inspect the recorded error first. Tokens are never included. Helper state lives in `/Library/Application Support/RunOnSleep`; journals are root-owned and contain no tokens.

**Review before changing anything:** close other sleep-management tools and establish whether the enabled flag is still wanted. Do not reset unrelated power settings or use `pmset restoredefaults`.

To inspect after stopping RunOnSleep:

```sh
pmset -g
pmset -g assertions
sudo cat '/Library/Application Support/RunOnSleep/journal.json'
```

If you have explicitly decided that global sleep disable should be cleared, the following is a manual recovery procedure. It can allow the Mac to sleep and interrupt running tasks:

```sh
# Stop the daemon first so it cannot race with manual recovery.
sudo launchctl bootout system/com.runonsleep.helper
sudo /usr/bin/pmset -a disablesleep 0
sudo /Library/PrivilegedHelperTools/com.runonsleep.helper --recover-only
sudo launchctl bootstrap system /Library/LaunchDaemons/com.runonsleep.helper.plist
```

The recovery command reads back the setting and removes the journal only when resolved. If the flag remains true or unreadable, stop here and inspect the problem; do not delete the journal to suppress the warning. Recovery never blindly restores a journal from a different boot. Helper updates also stop if recovery is unresolved.

## Closed-lid hardware verification

Initial status is **Untested**. A `pmset` write or unit test never changes that. Conduct both trials on this exact Mac and OS build, with no external monitor:

1. Start a real, observable background task, enable experimental protection, and run `Scripts/capture-trial.sh charger` in Terminal.
2. Close the lid for at least 30 minutes on charger. Open it afterward and confirm the actual task progressed throughout, not just after waking.
3. Repeat with `Scripts/capture-trial.sh battery`, keeping charge well above the cutoff. Stay nearby and stop if it becomes unusually hot.
4. In additional closed-lid checks, disconnect and reconnect power. Confirm progress continues through both transitions. The baseline charger/battery trials must each contain at least 30 minutes on the named source.
5. Review the captured heartbeat, battery-source history, and sleep/wake logs against your real task's log. Record gaps, wakes, thermal events, and actual trial duration. A heartbeat alone does not verify network access or agent success.
6. Record charger and battery results in a copy of `docs/verification-template.json`. Use configuration values from Copy diagnostics. Keep evidence paths/notes in each trial. Dates use ISO 8601.
7. Import the record in Diagnostics & settings. Both trials need at least 1,800 seconds, task progress, reviewed sleep logs, no unexpected sleep, successful transitions, and evidence notes. A failure produces Failed verification. A different hardware identifier, OS build, app version, or helper version invalidates verification.

This is user-attested evidence, not an automatic certification. Never mark fields true for an unperformed check. Experimental status remains even after verification; OS updates can change undocumented behavior.

Separately test computer use: with the lid open and desktop unlocked, run a real mouse/keyboard/screenshot task beyond your normal idle interval. Confirm screenshots remain useful and input reaches the intended app. Test stopping and quitting. Verify a forced GUI termination releases helper protection after lease expiry. Test helper restart and uninstall when no valuable task is running. Do not induce actual overheating or exhaust the battery; automated tests inject those states.

## Uninstall

Disable Launch at login, Stop protection, and Quit. Double-click `Uninstall RunOnSleep.command`, or run `sudo /bin/bash Scripts/uninstall.sh` from this project. The utility stops the daemon and applies the same conditional recovery rules. It retains recovery files and exits with an error if global state remains unresolved.

After successful recovery it removes the helper, launch daemon, installer receipt, and the app in `/Applications`. Other copies of the app and user verification records are retained. Remove a stale login item in System Settings → General → Login Items if needed. An externally enabled global flag is preserved and reported; uninstall cannot promise normal sleep.
