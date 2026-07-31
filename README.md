# Liddy

Keep a Mac awake — lid closed — while a long AI or dev job finishes, then let it sleep.

Free, open source, no licence check, no telemetry, no account.

```
liddy claim "overnight migration" --ttl 300   # declare live work
liddy lid on --timer 8h                       # close the lid and walk away
liddy log                                     # in the morning: why it stopped
```

## Why this needs to exist

macOS has **two** sleeps, and most keep-awake tools only fight one.

| | Trigger | What stops it |
|---|---|---|
| **Idle sleep** | inactivity | a power assertion (`IOPMAssertionCreateWithName`) — what `caffeinate` and every menu-bar keep-awake app uses |
| **Clamshell sleep** | the instant the lid closes | **no power assertion can stop it** |

There are exactly two public ways to survive a lid close: attach an external display on AC power, or set `pmset -a disablesleep 1`. There is no third lever, no kernel extension, no private API.

So closing the lid on a running agent means flipping `disablesleep` — a **global, sticky, root-only** setting with no on-screen indicator that a reboot does not reliably clear. Forget the matching `disablesleep 0` and your Mac stops honouring the lid close for every app, indefinitely, including in a bag.

That risk *is* the product. Liddy is a guarded wrapper around that one toggle.

## What makes it safe

**The helper owns the toggle, on a deadman switch.** `disablesleep` is set by a root launchd daemon, not by the app. While it is on, the app must hold a socket open and heartbeat every 5s. The helper reverts on:

- the app disconnecting (crash, force-quit, kill -9) — immediately
- 15s without a heartbeat (app hung or wedged)
- `SIGTERM` / `SIGINT`
- its own startup, if it finds the setting left on

Four independent paths back to normal sleep. Reverting only on next launch — which is what comparable tools do — leaves a wedged Mac unable to sleep for however long it takes you to notice.

**The governor is pure and tested.** Readings in, verdict out, no side effects — so the rules deciding whether an overnight run survives are directly testable rather than inferred from the app looking plausible.

| Rule | Default | Action |
|---|---|---|
| Hard battery floor | 4% (4–8) | `pmset sleepnow` — must beat *every* assertion, not just ours |
| Critical thermal, lid shut | — | force sleep (no airflow, so releasing is not enough) |
| Soft battery floor | 20% (15–50) | release, sleep normally with headroom to resume |
| Thermal ceiling | critical | release |
| Charging-only | off | release on battery |

Both floors are on for everyone. A guardrail behind a paywall is not a guardrail.

**Every session records why it ended** — finished, timer, battery, thermal, manual, or heartbeat lost. `liddy log` instead of guessing from a cold trackpad.

## Agent awareness: claim, don't guess

Name-matching a process is a guess. Liddy prefers letting the work **declare itself**:

```bash
TOKEN=$(liddy claim "fine-tune run" --ttl 300)
trap 'liddy release $TOKEN' EXIT
./train.sh
```

A lease has a TTL, so a claimer that dies stops holding the Mac on its own — nothing has to notice it crashed. Auto-watch still exists as a fallback, and treats a matched process as working **by existing, never by CPU** (an agent sits near 0% CPU waiting on an API between tool calls; a CPU threshold would drop the Mac mid-task).

Two things the matcher gets right that a naive one does not:

- **Exact match on the executable basename**, not substring on the full path. `rsync` otherwise matches macOS's own `appplaceholde`**`rsync`**`d`; `uv` matches `UVCAssistant`; `docker` matches the always-running `com.docker.vmnetd`. Any one of those holds an idle Mac awake forever. Locked down in `ProcessWatcherTest`.
- **Server-shaped tools are not watched by default** — `ollama serve`, the Docker Desktop backend, colima, a `vite` dev server all run for as long as they are open. Those belong to `liddy claim`.

> **Tune this for your machine.** `npm`, `python` and `uv` are in the defaults for long training runs and builds — but if you run MCP servers, those same names are live permanently and Liddy will never let go. Check with `liddy status`; drop them with `liddy unwatch npm` and use `liddy claim` instead.

`liddy -- <command>` also registers a renewing lease when the app is running, so a wrapped command is covered by the battery and thermal floors. Only when the app genuinely is not running does it fall back to a bare assertion — and it tells you so on stderr.

## Install

```bash
./Script/install-cli.sh        # liddy → ~/.local/bin (no sudo; --system for /usr/local/bin)
./Script/build-app.sh          # → dist/Liddy.app
./Script/install-helper.sh     # root launchd daemon (asks for sudo) — needed only for lid-closed
```

Keep-awake, timers, charging-only, both battery floors and thermal watch all work **without** the helper. The helper is required only to close the lid.

Uninstall: `./Script/uninstall-helper.sh` — unloads the daemon and asserts `disablesleep 0` regardless of how it exited.

## Commands

```
liddy status                     what is holding the Mac, and why
liddy start [--timer 3h] [--mode smart|manual]
liddy stop
liddy lid on|off [--timer 8h]    closed-lid mode (needs the helper)
liddy autowatch on|off|toggle
liddy watch <pattern> | unwatch <pattern> | pattern
liddy claim <label> [--ttl 300]  declare live work, prints a token
liddy renew <token> | release <token> | lease
liddy log [-n 20]
liddy -- <command>               hold for exactly one command, passes its exit code
```

`smart` (default) releases ~10 min after the last lease disappears. `manual` holds for the full window.

## Layout

```
Sources/LiddyKit/     Model · Power (IOKit) · Safety (governor) · Work (lease, watcher) · Runtime · Ipc
Sources/LiddyApp/     MenuBarExtra app; hosts the CLI socket
Sources/LiddyCli/     liddy
Sources/LiddyHelper/  root daemon: pmset + deadman switch
```

`swift build && swift test` — 21 tests, no external dependency.

## Honest limits

- Liddy **cannot** stop your Mac getting hot. It reads the thermal state macOS reports and backs off. It does not control fans — third-party fan control is restricted on Apple silicon, and reading SMC temperature directly misfires (a power-starved Intel Mac reports capped clocks that look like heat while the machine is cool).
- A closed lid cuts off the main airflow path. Hard ventilated surface, on mains power. **Never** a bag, a bed, or a drawer.
- The app is ad-hoc signed. Replace with a Developer ID signature before distributing.
- v0 builds in Swift 5 language mode; full Swift 6 sendability annotation is a follow-up.

## Not yet built

Watchdog rules, webhooks, alert routing, weekly reports, a dashboard, Homebrew tap, notarised DMG.

MIT.
