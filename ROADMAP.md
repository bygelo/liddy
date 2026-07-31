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
| A documented lease protocol third parties can implement | `claim`/`renew`/`release` are real (`WorkLease.swift:86-133`, keyed leases at `:95` so per-turn hooks don't stack) but undocumented outside `--help`. Nobody can integrate without reading Swift. | `docs/lease-protocol.md` + stable line-JSON schema on `LiddyPath.appSocket` | M | **T3** — hand the doc to a fresh reader; PASS iff they can claim and release a lease from `nc`/Python without opening a `.swift` file. | open |
| Hooks for agents beyond Claude Code | `Hook.swift` hardcodes Claude Code's event names and payload (`session_id`, `cwd`). Cursor, Codex and Amp are named as target workloads by competitors but get only process-matching here — the guess Liddy's own README argues against. | `liddy hook install --agent cursor\|codex\|amp` | M | **T3** — run the installer for each supported agent, drive one turn, `liddy lease`; PASS iff a keyed lease appears during the turn and is gone within TTL after. | open |
| Wrapped commands get the safety floors | `main.swift:122` — when the app is not running, `liddy -- <cmd>` falls back to a bare assertion with **no battery or thermal floor** and only warns on stderr. The README's safety table implies the floors are unconditional. | `liddy -- <cmd>` enforces floors in-process when the app is absent | M | **T3** — stop the app, run `liddy -- sleep 600` on battery below the soft floor; PASS iff the hold releases at the floor. Currently holds indefinitely. | open |

## P2 — Adoption

Liddy is MIT and free. So is Lidless. Price is not a wedge; friction is. Every item here is
already listed in the README's "Not yet built" — this just attaches acceptance tests.

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| Helper installs without a sudo shell script | `Script/install-helper.sh` asks for sudo and hand-rolls a LaunchDaemon. Lidless registers the same daemon via `SMAppService`, which gives a system approval UI and a supported uninstall path. | `Liddy.app` registers the helper on first use of Closed-Lid | M | **T3** — fresh user account, enable lid mode; PASS iff the helper registers via the system prompt with no Terminal step. | **partial** 2026-07-31 — `build-app.sh` bundles the helper into `Contents/Helpers`, and the menu's Closed-lid row installs it via one system authorisation prompt, no Terminal. Still **not** `SMAppService`: that needs a Developer ID signature and a matching `Contents/Library/LaunchDaemons` plist, and this build is ad-hoc signed, so it would fail on exactly the machines that need it. Blocked behind the notarisation row below; the benchmark's "no Terminal step" clause passes today, the supported-uninstall clause does not. |
| Developer ID signature + notarised DMG | README: "ad-hoc signed. Replace with a Developer ID signature before distributing." Gatekeeper blocks the current build for anyone who didn't compile it. | notarised `Liddy.dmg` release artifact | M | **T3** — download the DMG on a Mac that never built Liddy; PASS iff it opens with no Gatekeeper override. | open |
| Homebrew tap | No install path for the CLI that isn't `git clone` + `./Script/install-cli.sh`. | `brew install <tap>/liddy` | S | **T3** — `brew install` on a clean machine; PASS iff `liddy status` runs. | open |

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
| `liddy doctor` no longer disarms closed-lid mode | `LineSocketServer.serve()` fires `onClose?()` when **any** connection closes (`UnixSocket.swift:138`). The helper wires that straight to `guardian.connectionLost()` (`LiddyHelper/main.swift:177`), which reverts `disablesleep` without checking *which* connection dropped. `Doctor.run()` opens a second connection to the helper socket (`Doctor.swift:51-53`) and lets it close — so running `liddy doctor` during an active closed-lid session silently ends it. Checking whether lid mode works breaks lid mode. | `liddy doctor` | M | **T3** — enable lid mode, run `liddy doctor`, then `pmset -g \| grep disablesleep`; PASS iff still `1` and `liddy status` shows clamshell on. Currently fails. | open |
| The deadman switch is covered by tests | The 29 tests cover `LeaseRegistry`, `ProcessWatcher`, `SafetyGovernor` and keyed claims. Nothing covers `Ipc`, `Runtime`, or the helper. The single most safety-critical component — revert-on-disconnect, heartbeat timeout, `reconcileOnLaunch` — has **zero** tests, which is exactly why the row above could break silently. `ClamshellGuard` lives in the `LiddyHelper` executable target, so a test cannot import it. | `LiddyKit.ClamshellGuard` + `Tests/LiddyKitTest/ClamshellGuardTest.swift` | M | **T1** — earned: this is the safety invariant the whole product rests on, and it has already regressed undetected. Fixture = scripted connect/disconnect/heartbeat-gap sequences against a fake pmset; scorer = asserted `disablesleep` state per step. Quarantine: none needed — it tests existing behavior, so it goes straight into the live suite and must be green. | open |
| CI runs the gate on every push | No `.github/` at all. Verified divergence: `swift build` exited 0 from cache while `swift test` failed to compile — so a broken tree looks green, and `Script/build-app.sh` would happily ship an app whose CLI does not build. | `.github/workflows/ci.yml` | S | **T3** — push a commit that breaks a CLI target; PASS iff CI goes red. Gate command must be `swift build && swift test`, never `swift build` alone. | open |

## P1 — Correctness

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| Processes at paths containing spaces match correctly | `ProcessWatcher.executableName(from:)` (`:67`) splits the `ps` row on the first space to strip arguments — but `ps -Ao comm=` returns full paths, so `/Applications/Visual Studio Code.app/Contents/MacOS/Electron` reduces to `Visual`, and `/Applications/My App.app/…` to `My`. Any watched tool installed at a spaced path silently never matches. | `liddy watch <name>` for app-bundle tools | S | **T1** — earned: pure function, gnarly edge cases, and `ProcessWatcherTest` already exists as the bench home (it locked down the `appplaceholdersyncd`/`UVCAssistant` class of bug). Add spaced-path cases there. | open |
| Malformed requests get an error, not a silent status | `AppModel.swift:77` — `(try? Wire.decode(AppRequest.self, from: line)) ?? .status`. A typo'd or version-skewed request returns a snapshot instead of failing, which masks protocol bugs. Actively harmful once the lease protocol is public (P1 above): a third-party client that gets the schema wrong sees a plausible reply and no error. | line-JSON error response on `LiddyPath.appSocket` | S | **T3** — `echo '{"bogus":1}' \| nc -U <app socket>`; PASS iff the reply is a `failed` response naming the decode error. Currently returns a full status snapshot. | open |
| Charging-only release reports the real reason | `SafetyGovernor.swift:69` returns `.release(.userStopped)` for the charging-only rule. `liddy log` then reports "user stopped" for a session the policy ended. The README sells "every session records why it ended" as a feature; this row is a lie in that log. | `liddy log` | S | **T3** — enable `--charging-only on`, unplug, wait for release, run `liddy log`; PASS iff the reason names charging-only, not user-stopped. | open |

## P2 — Robustness

| Item | What it closes | Surface | Effort | Benchmark | Status |
|---|---|---|---|---|---|
| A failed socket bind is visible | `AppModel.swift:81` — `try? server.start(mode: 0o600)` discards the error. If the bind fails the app runs with no CLI socket and every command reports "Liddy is not running", with no way to tell that apart from the app genuinely being closed. | menu-bar warning + `liddy doctor` line | S | **T3** — pre-create an unwritable file at the socket path, launch the app; PASS iff the UI or `doctor` names the bind failure. Currently silent. | **done** 2026-07-31 — the bind error surfaces as a menu-bar alert, an activity-log line, and the `CLI socket` health check; `HealthProbeLocalTest.testUnboundSocketIsDown` locks the verdict |
| Bounded reads on the root helper socket | `UnixSocket.readLine` (`:33-45`) grows `buffer` without limit until a newline arrives. A client that never sends one grows a **root** daemon's memory unbounded. Mode `0600` + `chown` limits this to one local user, so it is hardening rather than a live exploit — but it is a root process with no input bound. | — (internal; `LiddyKit.UnixSocket`) | S | **T3** — send 100 MB with no newline to the helper socket; PASS iff the connection is dropped after a fixed cap and the helper's RSS is flat. | open |
| README matches the tree | README says "21 tests"; the suite runs 29. Small, but the README is the product's only sales surface and the number is checkable in one command. | `README.md` | S | **T3** — `swift test` count equals the README's number. | **done** 2026-07-31 — README says 127, `swift test` runs 127 |

## What we are NOT going to do — 2026-07-31 sweep

| Idea | Why not |
|---|---|
| Replace the Unix socket IPC with XPC (as Lidless does) | The line-JSON socket is precisely what makes the CLI, the Claude Code hooks, and any third-party lease client trivial to write. XPC locks the protocol to Apple frameworks and would kill the public lease API — the one differentiator. Rejecting the sibling's choice deliberately. |
| Replace `ps` with `sysctl(KERN_PROC)` | `ProcessWatcher.swift:95` already justifies `ps`: stable across releases, needs no entitlement, runs once per 10s. Cargo-cult optimisation of a cold path. |
| Multi-user helper support | `install-helper.sh` binds the helper to the installing uid on purpose, so another local account cannot toggle power settings. A documented security tradeoff, not a defect. |

---

## Triage — needs a decision, not a benchmark

| Item | What's blocking |
|---|---|
| Swift 6 sendability annotation | `Package.swift` pins Swift 5 mode deliberately (IOKit/launchd layers are callback-shaped). Not user-visible; no failure attributed to it. Needs a reason to move beyond tidiness. |
| Whether Cursor / Codex / Amp expose turn-level hooks at all | The P1 multi-agent row assumes they do. Claude Code's `UserPromptSubmit`/`Stop` may have no equivalent — unverified. If they don't, that row collapses to process-matching and should be re-scoped. |
| Whether to keep `npm`/`python`/`uv` in default watch patterns | README already warns these hold forever if you run MCP servers. Is the default wrong, or is the warning enough? Needs usage data Liddy doesn't collect (and says it won't). |
