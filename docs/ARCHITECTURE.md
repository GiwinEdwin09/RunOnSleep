# Architecture and invariants

`RunOnSleepCore` contains a serial session state machine, bounded version-1 JSON-lines socket transport, macOS power backend, and hardware-verification record validation. `RunOnSleep` is the SwiftUI client. `RunOnSleepHelper` is a root LaunchDaemon restricted to the installing user's UID.

## Protocol

- One JSON object and newline per connection; maximum 8,192 bytes, bounded read/write time.
- `start` accepts only a typed mode, experimental flag, duration (none/3600/14400/28800), and battery floor (5–50). It returns a random 32-byte token only on success.
- `renew` and `stop` require that token, the same kernel audit identity (including process incarnation), and a strictly increasing sequence. Tokens are memory-only. PID alone is insufficient.
- `status` accepts no token and never returns one. Responses contain helper instance/version, session state, power observations, and recovery status.
- Peers are checked with `getpeereid` and `LOCAL_PEERTOKEN`. The GUI verifies the server is root before sending credentials. Socket directory is root-owned and non-writable; socket mode is 0600 for the configured UID.
- Only one session is permitted. Duplicate starts are rejected. A lost start response can leave a session until its 45-second lease expires; it is not retried automatically.
- This is a same-user trust boundary, not app code-signature authorization: another process of the installing UID can start its own bounded session while idle, but cannot take over a different process's session. Other users have no socket access.

The helper's serial queue owns all assertions, power mutations, journal changes, and safety decisions. Network reads occur outside that queue. Tokens expire against continuous monotonic time, including system sleep. The selected deadline never changes on renewal. The GUI is kept out of App Nap while renewing, without adding an app-owned sleep assertion. Ordinary fallback mode uses the same engine in-process and prohibits global writes.

## Durable state

The root-owned journal follows `intent → confirmed → restoring → removed`. Each write is atomically renamed and fsynced. An observed external change marks it `conflicted`. Ambiguous phases and different-boot records never authorize a true-to-false restoration. A currently false flag needs no mutation and permits clearing stale journal state.

Restoration writes are also journaled before execution. A crash between restoration and journal removal therefore cannot cause a later blind retry. The helper takes an exclusive file lock before reading/recovering the journal, including `--recover-only` invocations.

There is an unavoidable race between observation and `pmset`; this system has no atomic ownership API. Identical external writes and brief changes between checks are invisible. Filesystem failure can also prevent durable conflict recording. These limitations preclude a guarantee of coexistence with other sleep managers. UI and docs explicitly state this.

## Safety and compatibility

IOKit assertions are public API; `pmset disablesleep`, global readback, lid registry properties, and distributed lock notifications need compatibility testing. Closed-lid control is always experimental. Power read failures fail closed for experimental starts; ordinary assertions remain available. Thermal notifications are supplemented by five-second polling. Unavailable battery level while on battery stops protection; macOS may report nominal when thermal sensing is unsupported.

No arbitrary command execution, network listener, analytics, screen capture, synthetic input, Accessibility permission, auto-unlock, kernel extension, or SIP modification is used. Local artifacts are ad-hoc signed. Signing for external distribution and automatic updates are outside this build.
