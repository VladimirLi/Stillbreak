# Stillbreak

Stillbreak is a native, menu-bar-only macOS utility that reminds you to take
breaks based on actual keyboard, mouse, scroll, or tablet activity. Its current
countdown is shown directly in the menu bar.

It uses macOS's aggregate HID idle-time API. It does not record keys, pointer
positions, app names, window titles, or raw input events, and it does not need
Accessibility or Input Monitoring permission.

## Screenshots

The countdown sits in the menu bar: <picture><source media="(prefers-color-scheme: dark)" srcset="docs/brand/screenshots/menubar-countdown-dark.png"><img alt="Menu bar status item showing a countdown of minutes and seconds" src="docs/brand/screenshots/menubar-countdown-light.png" height="20"></picture> and runs below zero in overtime: <picture><source media="(prefers-color-scheme: dark)" srcset="docs/brand/screenshots/menubar-overtime-dark.png"><img alt="Menu bar status item showing a negative countdown in overtime" src="docs/brand/screenshots/menubar-overtime-light.png" height="20"></picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/screenshots/dashboard-dark.png">
  <img alt="Stillbreak Dashboard showing seven days of work blocks in blue with overtime in red" src="docs/brand/screenshots/dashboard-light.png">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/screenshots/settings-dark.png">
  <img alt="Stillbreak Settings window with work threshold, dead time and notification options" src="docs/brand/screenshots/settings-light.png" width="282">
</picture>

## How timing works

The default work threshold is 25 minutes and the default dead time is 5
minutes. Both are configurable. Setting changes apply to the next interval.

Stillbreak uses a provisional "Model A" timeline:

```text
activity ----- provisional work gap ----- activity
0:00                                      4:59
```

If activity returns strictly before 5:00, the whole 4:59 gap remains work. If
no activity returns and the gap reaches 5:00, Stillbreak retroactively removes
that unresolved gap from active time, records it as a break, closes the
interval, and returns to idle. The menu countdown can therefore jump back when
dead time is reached.

The permissionless aggregate HID API exposes only the latest event seen at each
one-second poll. If that event is first observed no more than one polling
interval after the dead-time boundary, Stillbreak conservatively counts the
gap as work because an earlier event may have occurred between polls. Events
later than that one-second grace close the old interval normally. Each
reconstructed event is compared with the immediately previous observation so
drift from a stale physical event cannot accumulate into activity, while real
millisecond-scale activity remains observable. Stale events outside the polling
window cannot restart an idle timer.

At zero, Stillbreak sends one notification. Notification banners and sound can
be disabled independently. The timer continues below zero until dead time,
Pause, sleep (including while the app is closed), reboot, or a sufficiently
long app shutdown closes the interval.

Pause closes the current interval using validated work only. Resume waits for
new activity. History is retained locally until **Delete All History** is
confirmed. Each interval has one stable identifier, and applying the same
closure more than once cannot create a second history record.

## Install

Requires macOS 14 (Sonoma) or newer on Apple Silicon or Intel.

### Install with Homebrew (build from source)

Homebrew builds Stillbreak on your Mac from the latest `main`. The build takes a
few minutes and needs the Xcode or Command Line Tools with Swift 6.3+. Because
the app is built locally, macOS does not quarantine it and the first-launch
warning described below does not appear.

```sh
brew tap VladimirLi/tap
brew install --HEAD VladimirLi/tap/stillbreak
stillbreak-app install
```

The formula builds the app into Homebrew's own folder and does not manage
`/Applications`; the `stillbreak-app` helper it installs copies the app there
(launch at login can fail from other locations), so quit Stillbreak first if it
is running, then open it from `/Applications`. The helper verifies the copy
before swapping it in and moves any existing `/Applications/Stillbreak.app` to
the Trash instead of deleting it. It refuses to touch an app that is not
Stillbreak. Use the full `VladimirLi/tap/stillbreak` name: Homebrew 7 refuses
the short name from an untrusted tap. To upgrade, run
`brew reinstall VladimirLi/tap/stillbreak` and then `stillbreak-app install`. To
uninstall, quit Stillbreak, turn off Launch at login in Settings, run
`stillbreak-app uninstall` (moves the app to the Trash), then
`brew uninstall VladimirLi/tap/stillbreak` and check System Settings > General >
Login Items & Extensions for a leftover entry. See the
[tap](https://github.com/VladimirLi/homebrew-tap) for details.

### Install from the DMG

1. Download the `.dmg` (named `<app name>-<version>.dmg`) from the
   [latest release](https://github.com/VladimirLi/Stillbreak/releases/latest).
   A `.zip` of the same app is attached too.
2. Open the DMG and drag the app onto the **Applications** shortcut. Install it
   in `/Applications` before the first launch; running it from the DMG or
   Downloads can make launch at login fail.
3. Open it from Applications. The first launch is blocked by macOS because the
   app is not notarized (see below). Use the steps for your macOS version.

The app lives in the menu bar only and has no Dock icon.

The name (app bundle, DMG and release file names) is set in one place,
`APP_NAME` in `scripts/release-config.sh`; the install steps above only spell it
out in the `APP_NAME=` line of the Terminal alternative.

### Upgrading from ActiveBreak

Stillbreak was called ActiveBreak before its first public release. The first
time Stillbreak launches and finds no data of its own, it copies your history and
settings from `~/Library/Application Support/ActiveBreak/state.json` to
`~/Library/Application Support/Stillbreak/state.json`. The old file is left in
place untouched, so it doubles as a backup.

Quit ActiveBreak from its menu **before** opening Stillbreak for the first time.
While ActiveBreak is running, Stillbreak refuses that first import (the copy
would be stale immediately), shows a storage error, and saves nothing; quit
ActiveBreak and relaunch Stillbreak to retry. The same happens if the copy
itself fails.

If ActiveBreak runs again later (for example from its old Login Items entry) and
records more history, nothing is lost: every Stillbreak launch compares
ActiveBreak's file with the copy it last imported (kept as
`legacy-import-base.json` next to Stillbreak's `state.json`) and adds the new
history records. If ActiveBreak saved more recently than Stillbreak, its
settings and timer state win too. Changes made while both apps run at the same
time are picked up on the next Stillbreak launch. If ActiveBreak's file cannot
be read, Stillbreak shows a storage error and saves nothing rather than risk
overwriting it.

The bundle identifier changed (`com.vladimirli.Stillbreak`), so macOS treats it
as a new app and asks for notification permission again. Your "Launch at login"
choice is carried over, but Stillbreak will not register itself as a login item
while `ActiveBreak.app` is still installed, so the two never start together;
Settings says so. Delete `ActiveBreak.app` (its old Login Items entry goes with
it), then relaunch Stillbreak once and it registers itself. Past diagnostics
stay under the old `com.vladimirli.ActiveBreak` log subsystem.

### First launch on macOS 15 Sequoia and macOS 26 Tahoe

Control-click > Open no longer bypasses the warning on these versions.

1. Open the app once and dismiss the warning ("Done" or "OK"; do not move it to
   the Trash).
2. Open **System Settings > Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway** next to the message about the app and authenticate with
   your password or Touch ID.
4. Click **Open** when the warning appears again.

The Open Anyway button appears only after a blocked launch attempt, and only
for a limited time. If it is missing, open the app again first.

### First launch on macOS 14 Sonoma

Control-click (or right-click) the app in Applications, choose **Open**, then
click **Open** in the dialog. The Open Anyway steps above also work.

### Terminal alternative (any version)

```sh
APP_NAME=Stillbreak
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app"
```

This removes the download quarantine flag from the app so macOS stops asking.
Do it only for a download you trust. You can compare the download against the
SHA-256 checksums in the release notes with `shasum -a 256 <file>`.

### Why the warning appears

Stillbreak is free and open source, and releases are only ad-hoc signed, not
signed with an Apple Developer ID or notarized. Notarization requires a paid
Apple Developer Program membership, which the project does not have yet. The
warning means Apple has not scanned the build; it does not mean the app is
harmful. The full source is here, and you can build it yourself below.

## Build from source

### Requirements

- macOS 14 or newer
- Swift 6.3 or newer
- Command Line Tools or Xcode

### Build and test

With Command Line Tools:

```sh
mkdir -p .build/module-cache
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox

# Swift 6.3.3 CLT workaround that also executes the registered test bundle:
./scripts/test.sh

CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift build -c release --disable-sandbox

./scripts/package-app.sh
./scripts/smoke-test.sh
```

The cache variables and `--disable-sandbox` are needed only in restricted
shells. In a normal terminal, `swift test` and `swift build -c release` are
sufficient.

With Xcode, open `Package.swift`, select the `Stillbreak` executable scheme,
and Run. Use Product > Test to run the package tests. To create the standalone
ad-hoc signed bundle, run `./scripts/package-app.sh` in Terminal. To also
produce the `.dmg`, `.zip` and checksums in `dist/`, first install the pinned
DMG builder with
`python3 -m pip install --require-hashes -r scripts/dmgbuild-requirements.txt`
(a virtual environment is recommended), then run
`VERSION=1.0.0 ./scripts/package-release.sh` (`VERSION` defaults to
`0.0.0-dev`; add `ARCHS="arm64 x86_64"` for a universal binary).

## Dashboard and exports

Dashboard shows a 3, 7, or 14 day activity timeline, defaulting to 7 days.
Days are aligned left to right on one shared vertical local-time scale, and
the columns widen to fill the window; they scroll sideways only when the window
is too narrow for readable columns (typically 14 days at small sizes). Empty
hours before and after all visible activity are compressed, while unusual-hour
activity expands the shared scale for every day. Blue blocks are validated
work, red blocks are overtime, dashed outlines identify the current ongoing
interval, and breaks remain empty. The ongoing interval includes validated
segments only; unresolved provisional time is excluded until later activity
validates it. Select a block to see its exact start, end, duration, work type,
and completion status.

Each day column ends with its exact active time and overtime. Click a day's
header, column, or daily total (the cursor becomes a pointing hand) to show
that day in the side panel: active time, overtime, the longest completed
stretch within the day, and its most active hour. Ongoing work is labeled and
never counts as a completed stretch. The panel starts on today, or the last
visible day, and follows range changes. Ranges with no activity keep the
full timeline and panel with zero totals and a short "No activity" note. Left and right arrow keys move the
selection when the timeline has keyboard focus.

The summary reports exact visible active time and overtime, the longest visible
completed interval, and the local hour containing the most active time. Ongoing
validated work contributes to active and overtime totals but not the completed
interval metric. Duration summaries retain seconds using compact adaptive
labels. Ties for most active hour choose the earlier hour. Previous, Today, and
next controls navigate by the selected range, and next never moves beyond
today. The time geometry uses exact elapsed time from each local midnight, so
daylight-saving transitions retain their real duration and order.
The pinned axis identifies its reference day and shows that day's actual local
times with UTC offsets. If the range contains a daylight-saving transition,
that transition day is the reference; its 23-hour or 25-hour header remains
visible above the corresponding column. Popover timestamps also include UTC
offsets so repeated local times are unambiguous.

CSV and JSON exports use the visible calendar-day range, represented as a
half-open interval ending at the next local midnight. Absolute timestamps are
stored; grouping is recomputed in the Mac's current local timezone. Export rows
are clipped to the selected range and split at local midnight. JSON records
include exact `workSegments`, each marked as regular or overtime.

CSV columns are:

```text
id,interval_start,interval_end,active_seconds,overtime_seconds,break_start,break_end,break_seconds
```

JSON is an array of records with `id`, `intervalStart`, `intervalEnd`,
`activeDuration`, `overtimeDuration`, `breakStart`, `breakEnd`,
`breakDuration`, and `workSegments`. Older state files without timeline
segments are decoded into the closest equivalent contiguous timeline.

## Data and privacy

All settings, timer state, and history are stored as JSON in:

```text
~/Library/Application Support/Stillbreak/state.json
```

Data from the earlier ActiveBreak name is migrated once; see
[Upgrading from ActiveBreak](#upgrading-from-activebreak). There is no network
service, telemetry, account, cloud sync, or app-level tracking.

Stillbreak writes bounded local diagnostics to Apple's unified log under the
`com.vladimirli.Stillbreak` subsystem, with `timer`, `lifecycle`,
`persistence`, and `login-item` categories:

```sh
log show --last 1h --predicate 'subsystem == "com.vladimirli.Stillbreak"'
```

Diagnostics include timing decisions, state transitions, effect kinds,
persistence outcomes, lifecycle handling, and login-item outcomes. They never
include keys, pointer coordinates, app names, window titles, screenshots, or
raw input events. Relaunch and wake logs identify the actual closure or
preservation cause, and login-item status failures name the status. Timer
transitions and successful writes are emitted at info level; unchanged samples
and skipped writes remain debug-only.

State is saved when it changes, at lifecycle boundaries, and at most every 60
seconds as a checkpoint. An abrupt process loss can therefore lose at most the
current provisional interval since the latest checkpoint.

The smoke script runs the non-GUI `StillbreakSmoke` executable with an
isolated `STILLBREAK_STATE_FILE`, exits normally, verifies that live state is
unchanged, and fails if a `Stillbreak` crash report was added or modified.

## History repair

Build the tools, then preview a state file without modifying it:

```sh
swift build -c release --disable-sandbox
.build/release/StillbreakRepair \
  --state "$HOME/Library/Application Support/Stillbreak/state.json" \
  --manifest .build/history-repair-preview.json
```

Add `--candidate .build/repaired-state.json` to write a separate repaired copy
for review or a second idempotency preview. `--apply` is deliberately explicit:
it creates a timestamped backup beside the original, atomically replaces the
state, and validates the result. State, candidate, and manifest paths must not
refer to the same file through direct, normalized, symbolic-link, or hard-link
paths. Keep the backup until the repaired history has been reviewed.

## Architecture

- `StillbreakCore`: pure reducer, persistence, aggregation, and export logic
- `Stillbreak`: SwiftUI menu bar, settings, dashboard, notifications, and
  `SMAppService` integration
- `StillbreakRepair`: preview/apply history repair command
- `StillbreakSmoke`: isolated non-GUI persistence and lifecycle harness
- `scripts/package-app.sh`: release build and ad-hoc signed `.app` assembly
- `scripts/package-release.sh`: `.dmg`, `.zip` and checksums in `dist/`
- `scripts/release-config.sh`: app name, bundle ID, artifact prefix, signing
  identity and version defaults used by the scripts above

The normative behavior is in [`docs/SPEC.md`](docs/SPEC.md).

## Limitations

- The packaged app uses only an ad-hoc signature and is not Developer ID
  signed or notarized, so macOS asks for confirmation on first launch (see
  [Install](#install)).
- Launch at login can fail for an unsigned or translocated bundle; the Settings
  window reports the macOS error without changing the timer.
- macOS controls whether notification banners and menu-bar text colors are
  shown exactly as requested.
- History is a local JSON file with no sync. Repair apply mode creates a local
  timestamped backup, but ordinary saves do not.

## License

MIT. See [LICENSE](LICENSE).
