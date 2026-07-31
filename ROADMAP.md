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
| Helper installs without a sudo shell script | `Script/install-helper.sh` asks for sudo and hand-rolls a LaunchDaemon. Lidless registers the same daemon via `SMAppService`, which gives a system approval UI and a supported uninstall path. | `Liddy.app` registers the helper on first use of Closed-Lid | M | **T3** — fresh user account, enable lid mode; PASS iff the helper registers via the system prompt with no Terminal step. | open |
| Developer ID signature + notarised DMG | README: "ad-hoc signed. Replace with a Developer ID signature before distributing." Gatekeeper blocks the current build for anyone who didn't compile it. | notarised `Liddy.dmg` release artifact | M | **T3** — download the DMG on a Mac that never built Liddy; PASS iff it opens with no Gatekeeper override. | open |
| Homebrew tap | No install path for the CLI that isn't `git clone` + `./Script/install-cli.sh`. | `brew install <tap>/liddy` | S | **T3** — `brew install` on a clean machine; PASS iff `liddy status` runs. | open |

---

## What we are NOT going to do

| Idea | Why not |
|---|---|
| Fan control to survive closed-lid heat | Third-party fan control is restricted on Apple silicon, and direct SMC reads misfire. Already rejected in the README's Honest Limits, correctly. Back off on thermal state instead. |
| A kernel extension for lid handling | No public path; kexts are effectively dead on Apple silicon. There is no third lever. |
| CPU-threshold workload detection | Deliberately rejected: an agent waiting on an API sits near 0% CPU, so a CPU floor drops the Mac mid-task. Existence-based matching is the correct call (`README` §Agent awareness). |
| Webhooks, alert routing, weekly reports, dashboard | Listed as "not yet built" but ungrounded — no user, issue or telemetry asks for them. Pure added surface on a tool whose pitch is a small guarded wrapper. Fails the deletion test. |
| Competing on price | Lidless is MIT and free with the same architecture. There is no price below free. |

## Triage — needs a decision, not a benchmark

| Item | What's blocking |
|---|---|
| Swift 6 sendability annotation | `Package.swift` pins Swift 5 mode deliberately (IOKit/launchd layers are callback-shaped). Not user-visible; no failure attributed to it. Needs a reason to move beyond tidiness. |
| Whether Cursor / Codex / Amp expose turn-level hooks at all | The P1 multi-agent row assumes they do. Claude Code's `UserPromptSubmit`/`Stop` may have no equivalent — unverified. If they don't, that row collapses to process-matching and should be re-scoped. |
| Whether to keep `npm`/`python`/`uv` in default watch patterns | README already warns these hold forever if you run MCP servers. Is the default wrong, or is the warning enough? Needs usage data Liddy doesn't collect (and says it won't). |
