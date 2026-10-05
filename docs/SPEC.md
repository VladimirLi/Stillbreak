# Stillbreak normative specification

## Platform and privacy

Stillbreak MUST run on macOS 14 or newer as a menu-bar-only app with no normal
Dock presence. It MUST use aggregate HID idle time, poll approximately once per
second, treat all HID input equally, and MUST NOT request Accessibility or Input
Monitoring permission or capture raw input.

## Timer model

The default work threshold is 25 minutes. The default dead time is 5 minutes.
Both are configurable and MUST be captured when an interval starts; later
changes apply only to the next interval.

The first activity while idle MUST start an interval silently. Time after the
last activity is provisional work:

- Activity strictly before dead time validates the entire gap as work.
- Reaching dead time reclassifies the entire unresolved gap as break time,
  closes and logs the interval, and returns to idle.
- The displayed countdown MUST include provisional time and MAY jump back when
  dead time is reached.

The permissionless aggregate HID API reports only the latest event at each
nominal one-second poll, so exact ordering around the dead-time boundary is not
observable. A newly observed event strictly after dead time and no more than one
poll interval after it MUST conservatively validate the unresolved gap as work.
An event later than dead time plus that grace MUST close the prior interval.
Pure timer operations MUST remain strict unless this grace is explicitly
supplied. Each reconstructed event observation MUST be compared with the
immediately previous observation so drift from a stale physical event cannot
accumulate while newer millisecond-scale events remain observable. An inferred
event older than the initial polling window MUST NOT restart an idle timer.
Continued idle samples after closure MUST emit no additional history records.

Remaining time below one hour MUST use `MM:SS`. One hour or more MUST use hours
and minutes. At zero, exactly one threshold event MUST occur. Notification and
sound MUST be independently configurable and default on. Overtime MUST continue
indefinitely with a conspicuous urgent menu-bar presentation.

## Controls and lifecycle

The menu MUST contain only Pause/Resume, Settings, Dashboard, and Quit.

Pause MUST immediately log the interval using validated work only, discard the
unresolved provisional gap, and enter paused state. Resume MUST enter idle and
wait for activity.

State MUST persist across termination and restart. Relaunch downtime shorter
than the interval's captured dead time MUST preserve state without counting
app-off wall time as work. Downtime equal to or longer than dead time MUST count
as a break and clear the interval. Sleep or reboot while the app is closed MUST
also count as a break and clear active state. Sleep while running MUST clear
state on wake. Lock MUST follow the ordinary dead-time rule.

Launch at login MUST default on and use `SMAppService`. Failures MUST be shown
without damaging timer or history state.

Every active interval MUST have one stable identity that survives persistence.
Closing an interval MUST consume its active state, and applying a repeated
closure effect with that identity MUST NOT append another history record.
Samples, wake, relaunch reconciliation, pause, or quit handling after closure
MUST therefore leave history unchanged.

The one-second HID sample clock MUST NOT itself be a published SwiftUI value.
Visible status state MUST publish only when its rendered text or urgency
changes. Persistence MUST occur for material state changes, explicit lifecycle
flushes, and a checkpoint no more than 60 seconds after the prior successful
save; unchanged one-second samples MUST NOT write the state file.

## History and reporting

History MUST remain until one confirmed Delete All History action. Each record
MUST include absolute interval start/end timestamps, validated active duration,
overtime, break duration, and exact validated work segments with their
regular/overtime classification. Pause-closed intervals MUST be retained.

Intervals and breaks MUST be split at local midnight for aggregation. Stored
timestamps remain absolute and MUST be regrouped using the current local
timezone.

Dashboard MUST provide exactly 3, 7, and 14 day ranges and default to 7 days.
Visible days MUST be arranged left to right as aligned vertical timelines with
local time flowing top to bottom. Every visible day MUST use one shared scale
derived from all visible work. Universally empty leading and trailing hours MAY
be compressed with an explicit marker; any hour containing visible work MUST
remain expanded for every day.

Validated work MUST be blue, overtime MUST use a distinct warm/red treatment,
and breaks MUST remain empty. Selecting a work block MUST show a compact
popover with its exact start, end, duration, and overtime status. Summary
metrics MUST report exact visible active time and overtime, the longest visible
completed interval contribution, and the local hour containing the greatest
active duration. Most-active-hour ties MUST choose the earlier hour and an
empty selection MUST show no hour. Duration summaries MUST retain whole seconds
with a compact format appropriate to their magnitude.

The dashboard MUST include validated segments from the current active interval
without appending them to history or duplicating a record after closure. Those
segments MUST be identified as ongoing. Unresolved provisional time MUST remain
excluded until later activity validates it. Ongoing validated work contributes
to active and overtime totals but MUST NOT contribute to the longest completed
interval metric.

Every visible day MUST show a compact daily summary below its timeline column
with exact active time and overtime, including zero-duration days. Daily
metrics MUST derive from the same midnight- and range-clipped segments the
timeline draws. The day header, whole column background, and daily summary
MUST act as one selection target with a pointing-hand cursor, hover and
selected treatment, and accessibility text naming the date and exact seconds.
Selecting a day, or a work block in it, MUST open or update a side detail panel
with the date, active time, overtime, longest completed record contribution
within that day, and the actual local hour with the most active time. Ongoing
work MUST be identified in the panel and MUST NOT count as a completed stretch.
The detail panel MUST initially show today when visible, otherwise the final
visible day. Changing range or navigating MUST keep the selected day when it
remains visible and otherwise fall back the same way. A range with no activity
MUST still render every day column, zero daily summary, and the detail panel;
its empty-state cue MUST be passive and MUST NOT replace or block day selection.

Timeline geometry MUST use exact elapsed time from each local midnight rather
than hour/minute components. Spring-forward and repeated fall-back hours MUST
retain exact duration and chronological order. Day headers MUST identify
non-24-hour days, block details and accessibility text MUST use explicit local
timestamps, and the shared time axis MUST remain pinned while only day columns
scroll horizontally. Day columns MUST share the width beside the pinned axis
and fixed detail panel, expanding with the window with no trailing gap, and
MUST scroll only when that width falls below a readable per-range minimum.
Three- and seven-day ranges MUST fit at the minimum window width. Every
block's accessibility text MUST include date,
start, end, duration, work type, and ongoing/completed status.

The pinned axis MUST identify one reference day and derive each displayed local
time from that day's midnight plus the exact elapsed offset. A visible
daylight-saving transition day MUST be preferred as the reference day. Axis and
popover timestamps MUST include UTC offsets so repeated local times remain
distinguishable.

Date navigation MUST provide previous, Today, and next controls. Navigation
MUST move by the selected range and MUST NOT advance beyond today. Changing
range MUST preserve the visible end date where possible. Export and confirmed
Delete All History actions MUST remain available but secondary to the timeline.

CSV and JSON export MUST use the selected visible calendar-day range, ending
exclusively at the next local midnight, and a native save panel. Exported
records MUST be clipped to that range and split at current-local-midnight
boundaries; exported timestamps and durations MUST NOT extend outside the
selected range.

## Diagnostics

Stillbreak MUST use Apple's unified log with subsystem
`com.vladimirli.Stillbreak` and bounded `timer`, `lifecycle`, `persistence`,
and `login-item` categories. Diagnostics MUST include enough structured fields
to reconstruct sampled idle duration, inferred activity time, timer state
before and after, closure reason, configured threshold and dead time,
validated/provisional/overtime duration, emitted effect kinds and record ID,
persistence outcome, sleep/wake/relaunch/quit handling, and login-item failure
type.

Relaunch diagnostics MUST distinguish preserved state, dead-time closure, sleep
closure, and reboot closure. Wake diagnostics MUST report closure only when a
history effect was emitted. Non-throwing login-item status failures MUST report
the status type and an explicit non-success outcome.

Timer state transitions, including effect-free idle-to-active starts, and
successful persisted writes MUST be emitted at info level. Unchanged samples
and skipped writes MUST be debug-only. Blocked and failed writes MUST be errors.

Diagnostics MUST NOT include raw keys, pointer coordinates, application names,
window titles, screenshots, raw input events, or unbounded error dumps.

## Repair and smoke safety

History repair preview MUST leave its input unchanged and report before/after
counts, removed and retained IDs, and active/overtime duration deltas. Duplicate
closure artifacts MUST be matched by exact interval identity and zero-work
shape; a unique legitimate zero-work interval and near-duplicates MUST remain.
Apply mode MUST require an explicit flag, create a timestamped backup beside
the state file, atomically replace it, validate the decoded result and
aggregates, and be idempotent. Preview and apply MUST reject state, candidate,
and manifest paths that alias through direct, normalized, symbolic-link, or
hard-link identity before writing any output.

Smoke verification MUST use the non-GUI core harness with an isolated state
path, finish through normal process return, prove the live state fingerprint is
unchanged, and prove no existing or new `Stillbreak` crash report changed.

## Distribution

The project MUST build and test with Swift Package Manager and Command Line
Tools. `scripts/package-app.sh` MUST produce an unsigned `Stillbreak.app`
containing an executable and an `Info.plist` with `LSUIElement` enabled.
