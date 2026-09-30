# Liddy roadmap

Scope: **the proposition** — what makes Liddy worth existing next to `caffeinate`, LidRun ($9, closed) and
[Lidless](https://github.com/nghialuong/Lidless) (MIT, free), all three of which flip the same `pmset disablesleep`
flag behind the same style of root helper.

Edited honestly — gaps are gaps, not opportunities. Every row names a **surface** (the thing that will exist)
and a **benchmark** (how you'd know it worked). A row with no benchmark belongs in Triage, not here.

Tier legend: **T1** runnable fixture+scorer+baseline · **T2** live observation procedure · **T3** written acceptance test.

---

## P0 — Proving and unblocking

Nothing below this line matters until these are settled. The first is broken; the second is the load-bearing
assumption the entire product rests on and it has never been tested.

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| The tree compiles and tests pass | `swift test` failed to build — `Doctor.swift:64` used `Bool?` as `Bool`, `Doctor.swift:79` called undefined `sleepAssertionHolder()`. `swift build` misreported success from cache. | `swift build && swift test` | S | **T3** — `swift build && swift test`; PASS iff both exit 0. | **done** 2026-07-31 — green, 29 tests, 0 failures |
| `liddy doctor` reports whether the clamshell lever actually works | The README asserts `pmset disablesleep` is one of "exactly two public ways" to survive a lid close. On Apple Silicon that is contested: several sources say the lid magnet forces sleep in hardware since Ventura, while Amphetamine claims a public API that works "under any circumstance". If `disablesleep` is inert on M-series, `LiddyHelper` is a root daemon holding a lever that does nothing. | `liddy doctor` prints `clamshell lever: effective \| ineffective` | M | **T2** — read `AppleClamshellCausesSleep` from `IOPMrootDomain` (`ioreg -r -c IOPMrootDomain -d 1`) with `disablesleep` off, then on; PASS iff the value flips `Yes`→`No`. Confirm once by physically closing the lid on battery, no external display, and checking `Last Sleep Reason` is unchanged. | open |
| Honest Claude Code interaction | `Hook.swift:12` claims "the Mac is awake exactly while Claude is producing output, and sleeps when it stops". False today: Claude Code self-spawns and **respawns** `caffeinate -i -t 300` per session and defeats external decaffeinate ([claude-code#64522](https://github.com/anthropics/claude-code/issues/64522), closed not-planned). Releasing Liddy's lease does not let the Mac sleep. Verified live: 3 `caffeinate` holds parented to `claude` on this machine. | `liddy doctor` warns when a foreign sleep assertion outlives Liddy's lease; corrected claim in `Hook.swift` + README | S | **T3** — with a Claude Code session open, run `liddy hook release`, then `pmset -g assertions`; PASS iff either no `PreventUserIdleSystemSleep` remains **or** `liddy doctor` names the process still holding it. Currently fails silently. | open |

## P1 — The differentiator

The lease API is the only thing in this repo that LidRun and Lidless do not have. It is currently an internal
detail of one binary. Making it a contract other tools can target is the difference between "third `pmset`
wrapper" and "the thing agents call".

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| A documented lease protocol third parties can implement | `claim`/`renew`/`release` are real (`WorkLease.swift:86-133`, keyed leases at `:95` so per-turn hooks don't stack) but undocumented outside `--help`. Nobody can integrate without reading Swift. | `docs/lease-protocol.md` + stable line-JSON schema on `LiddyPath.appSocket` | M | **T3** — hand the doc to a fresh reader; PASS iff they can claim and release a lease from `nc`/Python without opening a `.swift` file. | **done** 2026-09-11 — drafted by a free sub-CLI worker, then every JSON string in it replayed against the running app and one section corrected (the worker read HEAD, which still had the decode fallback). Both worked examples — `nc -U` and stdlib Python — were run. Not yet handed to a fresh human reader, which is the half of the benchmark a machine cannot stand in for. |
| Hooks for agents beyond Claude Code | `Hook.swift` hardcodes Claude Code's event names and payload (`session_id`, `cwd`). Cursor, Codex and Amp are named as target workloads by competitors but get only process-matching here — the guess Liddy's own README argues against. | `liddy hook install --agent cursor\|codex\|amp` | M | **T3** — run the installer for each supported agent, drive one turn, `liddy lease`; PASS iff a keyed lease appears during the turn and is gone within TTL after. | open |
| Wrapped commands get the safety floors | `main.swift:122` — when the app is not running, `liddy -- <cmd>` falls back to a bare assertion with **no battery or thermal floor** and only warns on stderr. The README's safety table implies the floors are unconditional. | `liddy -- <cmd>` enforces floors in-process when the app is absent | M | **T3** — stop the app, run `liddy -- sleep 600` on battery below the soft floor; PASS iff the hold releases at the floor. Currently holds indefinitely. | open |

## P2 — Adoption

Liddy is MIT and free. So is Lidless. Price is not a wedge; friction is. Every item here is
already listed in the README's "Not yet built" — this just attaches acceptance tests.

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| Helper installs without a sudo shell script | `Script/install-helper.sh` asks for sudo and hand-rolls a LaunchDaemon. Lidless registers the same daemon via `SMAppService`, which gives a system approval UI and a supported uninstall path. | `Liddy.app` registers the helper on first use of Closed-Lid | M | **T3** — fresh user account, enable lid mode; PASS iff the helper registers via the system prompt with no Terminal step. | **partial** 2026-07-31 — `build-app.sh` bundles the helper into `Contents/Helpers`, and the menu's Closed-lid row installs it via one system authorisation prompt, no Terminal. Still **not** `SMAppService`: that needs a Developer ID signature and a matching `Contents/Library/LaunchDaemons` plist, and this build is ad-hoc signed, so it would fail on exactly the machines that need it. Blocked behind the notarisation row below; the benchmark's "no Terminal step" clause passes today, the supported-uninstall clause does not. |
| Developer ID signature + notarised DMG | README: "ad-hoc signed. Replace with a Developer ID signature before distributing." Gatekeeper blocks the current build for anyone who didn't compile it. | notarised `Liddy.dmg` release artifact | M | **T3** — download the DMG on a Mac that never built Liddy; PASS iff it opens with no Gatekeeper override. | open |
| Homebrew tap | No install path for the CLI that isn't `git clone` + a script. `build-app.sh` now links `~/.local/bin/liddy` as a side effect of a source build; that is not a tap. | `brew install <tap>/liddy` | S | **T3** — `brew install` on a clean machine; PASS iff `liddy status` runs. | open |
| Local `build-app.sh` lands in `/Applications` | A menu-bar-only (`LSUIElement`) app left in `dist/` disappears after logout — no Dock icon, nothing to reopen. Direct user report: the app was unusable because it was not in Applications. | `./Script/build-app.sh` copies to `/Applications/Liddy.app` and links the bundled CLI | S | **T3** — run the script locally (not `CI=true`); PASS iff `/Applications/Liddy.app` exists and `liddy --version` matches the bundle. CI skips the copy. Health check `liddy.install` and `liddy doctor` name a copy running from anywhere else. | **done** 2026-08-13 — `AppInstallTest` locks the health verdicts (`/Applications` ok, `dist/` degraded, `.build/` off) |
| Battery percent on the status item | The panel already drew a battery ring, but the number that can end a hold lived behind a click. Direct user report: the battery should be *there*. | status-item title `N%` next to the glyph | S | **T1** — `MenuBarIconTest`; PASS iff a 67% snapshot yields title `"67%"` and a desktop (nil percent) yields nil. | **done** 2026-08-13 |
| Open at login | Same LSUIElement gap: after a reboot there is nothing to launch. Direct user report: better integrated if it has open and login. | Settings toggle via `SMAppService.mainApp`; disabled until the app is in `/Applications` | S | **T3** — from `/Applications/Liddy.app`, enable the toggle; PASS iff System Settings → Login Items lists Liddy, or status is `.requiresApproval`. | **done** 2026-08-13 — toggle ships. Ad-hoc rebuilds can drop the item (same identity problem as quarantine). `LoginItem` lives in `LiddyApp`, which has no test target. |

---

## What we are NOT going to do

| Idea | Why not |
|---|---|
| Fan control to survive closed-lid heat | Third-party fan control is restricted on Apple silicon, and direct SMC reads misfire. Already rejected in the README's Honest Limits, correctly. Back off on thermal state instead. |
| A kernel extension for lid handling | No public path; kexts are effectively dead on Apple silicon. There is no third lever. |
| CPU-threshold workload detection | Deliberately rejected: an agent waiting on an API sits near 0% CPU, so a CPU floor drops the Mac mid-task. Existence-based matching is the correct call (`README` §Agent awareness). |
| Webhooks, alert routing, weekly reports | Listed as "not yet built" but ungrounded — no user, issue or telemetry asks for them. Pure added surface on a tool whose pitch is a small guarded wrapper. Fails the deletion test. |
| ~~Dashboard~~ — **partially overturned 2026-07-31** | Rejected above as ungrounded, then grounded by a direct user request for menu-bar visualisation and service verification. Built as an **in-menu health panel**, not a dashboard: gauges only for quantities that can end a hold, and reachability-only service probes. Still rejected in the shape originally named — no separate window, no charts of CPU/memory/throughput, no history beyond a 15-minute ring. The line held is that Activity Monitor already draws the machine; this panel draws only what decides whether the Mac stays awake. |
| Competing on price | Lidless is MIT and free with the same architecture. There is no price below free. |

---

# Whole-project sweep — 2026-07-31

Scope: **every area** — `LiddyKit` (Ipc · Work · Safety · Runtime · Model · Power), `LiddyApp`, `LiddyCli`,
`LiddyHelper`, `Script`, `Tests`, packaging. The section above covered the proposition only; this covers
the code under it. Deduped against `docs/roadmap-rejected.md`.

The headline: **`liddy doctor` currently turns off the protection it is diagnosing.**

## P0 — Safety invariants

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| `liddy doctor` no longer disarms closed-lid mode | `LineSocketServer.serve()` fires `onClose?()` when **any** connection closes (`UnixSocket.swift:138`). The helper wires that straight to `guardian.connectionLost()` (`LiddyHelper/main.swift:177`), which reverts `disablesleep` without checking *which* connection dropped. `Doctor.run()` opens a second connection to the helper socket (`Doctor.swift:51-53`) and lets it close — so running `liddy doctor` during an active closed-lid session silently ends it. Checking whether lid mode works breaks lid mode. | `liddy doctor` | M | **T3** — enable lid mode, run `liddy doctor`, then `pmset -g \| grep disablesleep`; PASS iff still `1` and `liddy status` shows clamshell on. Currently fails. | **done** 2026-09-11 — `LineSocketServer` now names each connection (`ConnectionId`) and the guard reverts only for the connection that armed the toggle. `ClamshellGuardTest.testForeignConnectionClosingDoesNotRevert` locks it; the live T3 still wants one run on a real Mac. |
| The deadman switch is covered by tests | The 29 tests cover `LeaseRegistry`, `ProcessWatcher`, `SafetyGovernor` and keyed claims. Nothing covers `Ipc`, `Runtime`, or the helper. The single most safety-critical component — revert-on-disconnect, heartbeat timeout, `reconcileOnLaunch` — has **zero** tests, which is exactly why the row above could break silently. `ClamshellGuard` lives in the `LiddyHelper` executable target, so a test cannot import it. | `LiddyKit.ClamshellGuard` + `Tests/LiddyKitTest/ClamshellGuardTest.swift` | M | **T1** — earned: this is the safety invariant the whole product rests on, and it has already regressed undetected. Fixture = scripted connect/disconnect/heartbeat-gap sequences against a fake pmset; scorer = asserted `disablesleep` state per step. Quarantine: none needed — it tests existing behavior, so it goes straight into the live suite and must be green. | **done** 2026-09-11 — `ClamshellGuard` moved into `LiddyKit` behind `PmsetRunning` / `ClamshellStateStoring` / `DelayScheduling`; 12 tests cover set/revert, ownership, deadman, heartbeat re-arm and launch reconcile. |
| CI runs the gate on every push | `.github/workflows/release.yml` runs `swift test` on tags only. A broken push to `main` is still silent, and `swift build` can exit 0 from cache while `swift test` fails to compile — so a broken tree looks green, and `Script/build-app.sh` would happily ship an app whose CLI does not build. | `.github/workflows/ci.yml` | S | **T3** — push a commit that breaks a CLI target; PASS iff CI goes red. Gate command must be `swift build && swift test`, never `swift build` alone. | **done** 2026-09-11 — runs on every branch push and PR; separate Build and Test steps, so a cached build cannot mask a test-compile failure. Unproven until the first red push. |

## P1 — Correctness

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| Processes at paths containing spaces match correctly | `ProcessWatcher.executableName(from:)` (`:67`) splits the `ps` row on the first space to strip arguments — but `ps -Ao comm=` returns full paths, so `/Applications/Visual Studio Code.app/Contents/MacOS/Electron` reduces to `Visual`, and `/Applications/My App.app/…` to `My`. Any watched tool installed at a spaced path silently never matches. | `liddy watch <name>` for app-bundle tools | S | **T1** — earned: pure function, gnarly edge cases, and `ProcessWatcherTest` already exists as the bench home (it locked down the `appplaceholdersyncd`/`UVCAssistant` class of bug). Add spaced-path cases there. | **done** 2026-09-11 — `comm=` returns two shapes (absolute path, spaces and no arguments; or a bare command with its argument), measured on macOS 15: 166 spaced rows, zero absolute rows carrying a flag. The leading `/` decides which rule applies, so `npm run dev …` → `npm` still holds. |
| Malformed requests get an error, not a silent status | `AppModel.swift:77` — `(try? Wire.decode(AppRequest.self, from: line)) ?? .status`. A typo'd or version-skewed request returns a snapshot instead of failing, which masks protocol bugs. Actively harmful once the lease protocol is public (P1 above): a third-party client that gets the schema wrong sees a plausible reply and no error. | line-JSON error response on `LiddyPath.appSocket` | S | **T3** — `echo '{"bogus":1}' \| nc -U <app socket>`; PASS iff the reply is a `failed` response naming the decode error. Currently returns a full status snapshot. | **done** 2026-09-11 — **PASS, run live**: `{"bogus":1}` → `{"failed":{"_0":"bad request: DecodingError.typeMismatch: … Invalid number of keys found, expected one."}}`, and raw non-JSON → `dataCorrupted`. |
| Charging-only release reports the real reason | `SafetyGovernor.swift:69` returns `.release(.userStopped)` for the charging-only rule. `liddy log` then reports "user stopped" for a session the policy ended. The README sells "every session records why it ended" as a feature; this row is a lie in that log. | `liddy log` | S | **T3** — enable `--charging-only on`, unplug, wait for release, run `liddy log`; PASS iff the reason names charging-only, not user-stopped. | **done** 2026-09-11 — new `StopReason.chargingOnly` ("Unplugged in charging-only mode"); `SafetyGovernorTest` asserts it. |

## P2 — Robustness

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| A failed socket bind is visible | `AppModel.swift:81` — `try? server.start(mode: 0o600)` discards the error. If the bind fails the app runs with no CLI socket and every command reports "Liddy is not running", with no way to tell that apart from the app genuinely being closed. | menu-bar warning + `liddy doctor` line | S | **T3** — pre-create an unwritable file at the socket path, launch the app; PASS iff the UI or `doctor` names the bind failure. Currently silent. | **done** 2026-07-31 — the bind error surfaces as a menu-bar alert, an activity-log line, and the `CLI socket` health check; `HealthProbeLocalTest.testUnboundSocketIsDown` locks the verdict |
| Bounded reads on the root helper socket | `UnixSocket.readLine` (`:33-45`) grows `buffer` without limit until a newline arrives. A client that never sends one grows a **root** daemon's memory unbounded. Mode `0600` + `chown` limits this to one local user, so it is hardening rather than a live exploit — but it is a root process with no input bound. | — (internal; `LiddyKit.UnixSocket`) | S | **T3** — send 100 MB with no newline to the helper socket; PASS iff the connection is dropped after a fixed cap and the helper's RSS is flat. | **done** 2026-09-11 — `UnixSocket.maxLineByte` caps accumulation at 1 MiB and the connection is dropped like an EOF. Live 100 MB run still pending. |
| README matches the tree | README says "21 tests"; the suite runs 29. Small, but the README is the product's only sales surface and the number is checkable in one command. | `README.md` | S | **T3** — `swift test` count equals the README's number. | **done** 2026-07-31 — still the contract; README says 272, `swift test` runs 272 (2026-09-30) |

## What we are NOT going to do — 2026-07-31 sweep

| Idea | Why not |
|---|---|
| Replace the Unix socket IPC with XPC (as Lidless does) | The line-JSON socket is precisely what makes the CLI, the Claude Code hooks, and any third-party lease client trivial to write. XPC locks the protocol to Apple frameworks and would kill the public lease API — the one differentiator. Rejecting the sibling's choice deliberately. |
| Replace `ps` with `sysctl(KERN_PROC)` | `ProcessWatcher.swift:95` already justifies `ps`: stable across releases, needs no entitlement, runs once per 10s. Cargo-cult optimisation of a cold path. |
| Multi-user helper support | `install-helper.sh` binds the helper to the installing uid on purpose, so another local account cannot toggle power settings. A documented security tradeoff, not a defect. |

---

# Menu bar — 2026-09-11

Direct user report, with screenshots: the dropdown "doesn't work on full screen apps",
"doesn't follow the rest of the mac apps", and wanted "more compact UI" with the status
dot removed.

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| The panel opens over a full-screen app | `show()` called `NSApp.activate(ignoringOtherApps:)`. Activating an accessory app while a full-screen app owns the space makes macOS leave that space, so the panel opened on the desktop behind the user. `.fullScreenAuxiliary` was already set — activation was undoing it. | `MenuPanel.show` | S | **T2** — enter full screen in any app, pull the menu bar down, click Liddy; PASS iff the panel appears over the full-screen window and the space does not change. | **done** 2026-09-11 — activation dropped; the `.nonactivatingPanel` takes key on its own. Dismissal moved to `NSWorkspace.didActivateApplicationNotification`, and Escape now closes. **Unverified live** — needs one click in a full-screen app. |
| The dropdown reads as a Mac menu, not a dashboard | Seven `Divider()` rules in a 300pt column, a bordered "Quit" push button in the corner (dialog furniture), and a status dot restating what the title already said. | `MenuView` | S | **T3** — open the panel; PASS iff there are ≤3 rules, the last row is a plain "Quit Liddy", and no coloured dot precedes the status title. | **done** 2026-09-11 |
| A second instance cannot clobber the first's socket | `LineSocketServer.start` opens with `unlink(path)` — right for a stale socket left by a crash, catastrophic for a live one. A second Liddy deleted the running app's socket and bound its own; the first kept a listener on an unnamed inode, so every `liddy` command reported "Liddy is not running" while the menu bar still showed it running. Hit for real on 2026-09-11 by running a second copy to measure the panel. | `AppModel.startServer` | S | **T3** — with Liddy running, launch a second copy, then talk to the socket; PASS iff the original still answers. | **done** 2026-09-11 — `isAnotherInstanceListening()` probes before binding and the second instance stands down with a named reason instead of taking the socket. |
| The panel is short enough to read at a glance | Measured before: 340pt wide, 62pt rings, a 66pt lease block, a 26pt sparkline, and the collapsed health section drew four group pills restating its own headline. | `MenuView`, `Gauge`, `HealthSection` | S | **T1** — `LIDDY_MEASURE_PANEL=1 dist/Liddy.app/Contents/MacOS/Liddy` prints the content's `fittingSize` and exits; PASS iff the height shrinks by ≥15% against the same command run on the previous commit. | **done** 2026-09-11 — **340x694 → 300x538**: height −156pt (**−22.5%**), width −40pt, area −34%. Both measured on an idle snapshot through the env-guarded seam the benchmark names, so the comparison is repeatable rather than an impression. |

---

# Requested features — 2026-09-11

Direct user request, three items. Each reaches for something outside Liddy's own
process, so each row names what it gives back and when.

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| Screen off while the lid is shut | A closed panel that is still lit is watts and heat spent on a display nobody can see. No public API exists for the built-in backlight on Apple silicon. | `DisplayBrightness`, `DimmingPlan`, `DisplayDimmer`, a Settings toggle, `liddy set --lid-brightness-off` | M | **T1** — `DisplayBrightnessTest` + `DisplayDimmerTest`: the ioreg parse against a row captured from this Mac, and the policy truth table including the one that matters (a second tick must not re-save the zero it just wrote). **T2** — close the lid on a live session; PASS iff the panel goes dark and comes back at the same level. | **done** 2026-09-11 — 17 tests. Read, write and lid-state verified live (`canChange=true`, read `0.492`, write returned true against an unchanged level). The T2 lid-close run is **not** done — it needs a physical lid. |
| See what is hampering performance | The panel drew every quantity that can *end* a hold and nothing about what was *costing* one. "Battery crossed the floor" never said Chrome had been at 95% for an hour. | `ProcessLoad`, the "Using the most" card, `liddy top`, and a heaviest-at-stop line in the log | S | **T1** — `ProcessLoadTest`: spaced app-bundle paths, helper collapsing (Chrome's renderers summing to one row), the CPU floor, limit, and a stable tie-break so the list holds still between samples. | **done** 2026-09-11 — 9 tests. Verified live: `liddy top` names CodexBar at 97.6% and Chrome at 30.1%/26.6% mem. Partially **overturns** the sweep's "no CPU metrics" line — it is visibility only, and the rejection of CPU-threshold *detection* stands unchanged. |
| Background chosen apps during a hold | Chrome and Discord cost CPU and heat through a run nobody is watching. | `ResourcePlan`, `AppBackgrounding`, `WorkspaceBackgrounder`, a Settings toggle, `liddy set --resource-saver/--background-app` | M | **T1** — `ResourcePlanTest` (10) + `ResourceSaverRuntimeTest` (6): hide once not every tick, never the frontmost app, never unhide something Liddy did not hide, and give everything back on release, on a safety stop and on quit. | **done** 2026-09-11 — off by default, because it moves windows that belong to someone else's app. `SIGSTOP` and `renice` both rejected: the first corrupts a browser session, the second cannot be undone without root. |

---

# Tab Warden and the text cut — 2026-09-12

Direct user report, relayed from their friends: "too much text in Liddy", the Agents
row "somehow wasn't fully accurate most of the time — even if it was running, it was
saying that it was not working", and a request for per-session visibility across Claude,
Codex, Cursor and Grok with a colour per state.

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| Agent state stops lying | `AgentStatus.isWorking` was `!leaseLabel.isEmpty` — true only if the Claude Code hook had claimed a lease, or the watcher matched a name in `watchPattern` while auto-watch was on **and** a hold was live. Grok is not in the default pattern, so it could never read as working. | `AgentStatus.build(session:)` | S | **T3** — run an agent with no Liddy hold; PASS iff the panel calls it working. Previously failed by construction. | **done** 2026-09-12 — state now comes from session activity, which does not depend on Liddy being involved at all. |
| Tab Warden: live sessions per CLI | No way to see which of six Claude sessions is waiting for input. Process-level detection cannot answer it — one `claude` process looks like any other. | `AgentSession`, `SessionScanner`, `SessionSection`, `liddy session` | L | **T1** — `SessionStateTest` + `SessionScannerTest` (20): the state machine including a dead process with a fresh transcript, clock skew, partial-JSON heads, `lsof -Fn` pairing, and both file-naming schemes. | **done** 2026-09-12 — verified live: 6 Claude sessions with project + branch + age, 1 Grok session, correct working/your-turn/idle split. Cursor and Codex sources are implemented and parse their real formats; neither had a session inside the 6h horizon at the time of the run, so **both are unverified against live data**. |
| Less text on the panel | "Why awake" listed up to three lease labels plus a "+N more" line, restating what the third ring counts and what Tab Warden now names. Health drew every passing check. | `MenuView`, `Setting.isHealthPanelOn` | M | **T1** — `LIDDY_MEASURE_PANEL=1`; PASS iff the resting height drops again against the 2026-09-11 measurement of 300x547. | **done** 2026-09-12 — **300x405**, down 142pt (−26%) on top of yesterday's cut, and **−42% against the original 340x694**. Health is off by default; a *failing* check still shows as one tappable line, because a problem hidden behind a setting is worse than the text. |

---

# Panel redesign round 2 — 2026-09-12

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| Sessions as icon pills | A list of text rows per session was the thing the panel was being criticised for. | `SessionSection`, `PillFlow`, `AgentTool.bundleIdentifier` | M | **T3** — open the panel with 8 sessions; PASS iff they occupy ≤2 lines and each shows the agent's real app icon. | **done** 2026-09-12 — real icons resolved from the installed app (measured bundle ids: Cursor is `com.todesktop.230313mzl4w4u92`, the Grok desktop app is `com.anysphere.sand` — neither is derivable from the vendor name). Tool, branch, age and directory moved to the hover tooltip. |
| The temperature is a temperature | The ring drew `ProcessInfo.thermalState` — a four-step *throttling-pressure* signal, not a temperature. It sits at "fair" on a Mac whose die is at 38°C, which is the "not accurate most of the time" report. | `TemperatureReader`, `ThermalReading.celsius` | M | **T1** — `TemperatureSelectionTest`; and **T2** — compare against any other sensor tool. | **done** 2026-09-12 — real die temperature via `IOHIDEventSystemClient` (no root, no entitlement, `dlsym`ed like `DisplayBrightness`). 45 sensors exposed; picking the wrong one is the whole risk — the first cut matched `PMU tcal`, a **calibration reference**, and reported 52°C while `PMU tdie*` read 68°C. Now die-only, max not mean. The governor still acts on the pressure state, unchanged. |
| A fourth indicator | Three rings could not answer "is something pinning this machine". | `MenuView.cpuGauge`, `ProcessLoad.systemCpuPercent` | S | **T1** — `SystemCpuTest`: `ps` reports %cpu per *core*, so the raw sum is not a system load until it is divided by the core count. | **done** 2026-09-12 — battery · temperature · CPU · leases. |
| Opening Health no longer jitters | The panel resized from `objectWillChange` one runloop pass *after* SwiftUI drew the new content, so there was always one frame where the window was the old size and the content was the new one. | `MeasuringHostingView` | M | **T2** — expand Health; PASS iff nothing moves except the bottom edge. | **done** 2026-09-12 — the window now follows from the hosting view's own `layout()`, in the same pass, with implicit animation disabled. **Unverified live** — needs a human eye on the expand. |
| A failing check has a way out | The panel diagnosed and then left the user stuck: "not in /Applications" with no next step. | `HealthRemedy`, `HealthRow.onFix`, `AppModel.apply` | M | **T3** — every check that can fail offers a button; PASS iff each one either performs the fix or opens the exact place it is performed, and none prints a command to retype. | **done** 2026-09-12 — Install…, Show in Finder, Open Settings, Install hook, Clear it, Re-check. The hook button runs the **bundled CLI**, not a second copy of the JSON merge, so the button and the documented command cannot drift. |

| The panel's top is hard set | The panel could be clipped at the top — rings and mode selector cut off — and could run past the screen bottom. Three separate mechanisms, all of which made the *top* the thing that moved. | `MenuPanel` | M | **T1** — `LIDDY_PANEL_CEILING=300 LIDDY_MEASURE_PANEL=open`; PASS iff the window clamps while the content keeps its full height and the scroll position stays at 0, i.e. the top is what you see. | **done** 2026-09-12 — measured `window=300 content=691 hostH=691 scrollY=0 top=1129`. Three fixes: `constrainFrameRect` now returns the rect unchanged (AppKit was relocating a too-tall window upward, behind the menu bar); the ceiling is the room **below the anchor** rather than the screen height; and the content lives in a scroll view, because both Auto Layout arrangements tried before compressed the hosting view and made SwiftUI centre-and-clip a `VStack` that no longer fit. |
| Closed-lid backgrounding | The resource saver only ever hid a fixed list. With the lid shut, every app that is not hosting live work is drawing nothing anyone can see while costing battery and heat with no airflow. | `ResourcePlan.plan(isLidClosed:sessionApp:)` | S | **T1** — `ClosedLidResourceTest` (7): the wider scope, and everything that must survive it. | **done** 2026-09-12 — keyed on the **lid**, not the mode: closed-lid mode can be armed with the lid open on an external display, and that is still a desktop the user is looking at. Terminals are the load-bearing exclusion — every Tab Warden session runs inside one. |

| The panel stops filling the screen | Still resizing wrongly after three geometry fixes, because the geometry was not the whole problem: with the model running and Health expanded the **content is 1330pt**. Clamping only to the screen produced a 1121pt panel covering the display. | `MenuPanel.maxHeight`, scroll reset, row caps | M | **T1** — `LIDDY_MEASURE_PANEL=open` with the model started; PASS iff the window is ≤640 in every configuration and `scrollY=0`. | **done** 2026-09-12 — resting **621** (fits, no scroller), everything expanded **640 with 1305 of content** behind a scroller, top pinned at 1129 across 40 passes. The earlier harness measured 369 because it never called `model.start()` — no sessions, no health, no load — so it was measuring a panel nobody would ever see. |

| The panel stops resizing at all | Four separate bugs — the one-frame jump on expand, the measurement feedback loop, content clipped off the top, the screen-filling panel — all had the same cause: a height that was a function of the content. Patching the geometry four times did not remove the cause. | `PanelTab`, `PanelTabBar`, fixed `pageHeight` | M | **T1** — `LIDDY_TAB=<page> LIDDY_MEASURE_PANEL=open`; PASS iff the window height is identical on every page and unchanged across 40 layout passes with the model running. | **done** 2026-09-12 — the iStat Menus shape, at the user's suggestion: pages behind an icon bar instead of disclosures. **429 on every page** — one shape, always. Per-page heights were tried in between and removed: they stopped the dead space but made the panel change shape as you clicked between pages, which is its own kind of moving around. The height is what the tallest page needs, and the shorter pages were given more to show rather than padding — six processes instead of three, nine session pills instead of six. The window changes only when a different page is clicked — never on a tick, a health sweep or a data update, which is the property that closed the bug class. |

---

# Cost against iStat Menus — 2026-09-30

Goal: beat iStat Menus on resource cost while keeping the features. Everything below is
measured on this Mac with `Script/cpuwatch` (CPU-seconds consumed over a fixed window,
which is what `ps` bills) and `LIDDY_PROFILE=1` for the per-phase breakdown.

**Where it started and where it is**

| | Liddy before | Liddy now | iStat Menus (Menubar + Helper) |
|---|---|---|---|
| CPU, idle | 3.45% | **0.04%** | 0.11% |
| CPU, holding a run | 3.45% | 0.32% | — (no equivalent feature) |
| Resident memory | 71 MB | 69 MB | 31 + 11 MB |

**What actually cost what.** Three rounds of this were spent optimising the wrong thing,
because the cost was never where it looked:

| Assumed cost | Real cost | Fix | Result |
|---|---|---|---|
| Rebuilding the HID client per read | ~1.1ms of driver IPC **per sensor**, 45 of them | filter to the 36 that are die/package sensors, cache the value for 10s (120s while shut) | 44ms → 0ms amortised |
| `ProcessInfo.thermalState` is a field read | **13-15ms**, it crosses to `powerd` | cache it, refresh on `thermalStateDidChangeNotification` | 15ms → 0.00ms |
| Reading the lid is cheap | **34ms**, it forks `ioreg` and parses the dump | `IORegistryEntryCreateCFProperty` on `IOPMrootDomain` | 0.749ms → 0.014ms, 53× |
| Session scan is slow because of transcript reads | enumerating **8390 files / 7.1 GB** every 15s | only sample while the panel is open | removed from the idle path |
| — | the panel's data was rebuilt 18×/min with the panel **shut** | `refreshPanelData()` only while visible | 96 MB → 64 MB at the time |

**The measurement itself was wrong twice, and that is the durable lesson.** `TickProfile`
first timed with `Date()`, which on a machine already at 100% CPU counts the time a
thread spends *waiting for a core* — it reported a cached in-memory field read at 15ms
and made two real improvements look like regressions. It now uses
`CLOCK_THREAD_CPUTIME_ID`, which is what `ps` bills and therefore what the comparison is
in.

**Not met: memory.** 69 MB against iStat's 42 MB combined. Two attempts moved it zero —
building the panel lazily instead of at launch, and holding the `URLSession` only for the
duration of a sweep. The remainder is the SwiftUI runtime against iStat's pure AppKit,
which is a rewrite rather than an optimisation. Recorded as open, not as done.

| Item | Surface | Benchmark | Status |
|---|---|---|---|
| Idle CPU below iStat | whole runtime | **T1** — `cpuwatch 150` with no hold; PASS iff Liddy's share is below iStat's. | **done** 2026-09-30 — 0.04% vs 0.11%. |
| Per-phase profile that does not lie | `TickProfile` | **T3** — `LIDDY_PROFILE=1`; PASS iff phases sum to something near the process's billed CPU. | **done** 2026-09-30 |
| Resident memory below iStat | — | **T1** — `ps -o rss` after a 45s settle; PASS iff under 42 MB. | **open** — 69 MB. Lazy panel and per-sweep session both measured zero effect. |

---

## Not covered by a test — 2026-09-30

Recorded rather than fixed, so the next session starts from what is actually true.

| Gap | Why it matters | Why it is not covered |
|---|---|---|
| The whole `LiddyApp` target | The panel is where every UI bug of the last two days lived: the resize loop, the clipped top, the screen-filling window. | `Package.swift` has one test target and it depends on `LiddyKit`. The pure pieces that *could* move — `PanelGeometry`, `MenuBarIcon`, `AppInstall` — already did, and are tested. The rest needs a window server, so it is covered by the `LIDDY_MEASURE_PANEL` harness instead: repeatable, but not run by `swift test`. |
| Cursor and Codex session sources | Two of Tab Warden's four tools. | Both parse their real formats and neither had a session inside the six-hour horizon while it was being built, so only Claude and Grok have been seen live. The parsers are unit-tested against captured fixtures; the end-to-end path is not. |
| Lid-close brightness (T2) | The feature's whole point. | Needs a physical lid close. `DimmingPlan` is tested exhaustively and the read/write path was verified live, but nobody has shut the lid on a running session and watched it come back. |
| The full-screen panel fix | Reported by the user, fixed, never confirmed. | Needs one click from inside a full-screen app. |
| Resident memory against iStat | The one half of the optimisation goal not met. | 69 MB vs 42 MB. No test, because there is no fix yet — the remainder is the SwiftUI runtime. |

---

## Triage — needs a decision, not a benchmark

| Item | What's blocking |
|---|---|
| Swift 6 sendability annotation | `Package.swift` pins Swift 5 mode deliberately (IOKit/launchd layers are callback-shaped). Not user-visible; no failure attributed to it. Needs a reason to move beyond tidiness. |
| Whether Cursor / Codex / Amp expose turn-level hooks at all | The P1 multi-agent row assumes they do. Claude Code's `UserPromptSubmit`/`Stop` may have no equivalent — unverified. If they don't, that row collapses to process-matching and should be re-scoped. |
| Whether to keep `npm`/`python`/`uv` in default watch patterns | README already warns these hold forever if you run MCP servers. Is the default wrong, or is the warning enough? Needs usage data Liddy doesn't collect (and says it won't). |
