# Rejected roadmap ideas

Append-only. Read before any roadmap run so killed ideas don't come back.
One line per rejection, verbatim reason.

## 2026-07-31 — first roadmap run (scope: the proposition)

- **Fan control to survive closed-lid heat** — third-party fan control is restricted on Apple silicon; direct SMC reads misfire (a power-starved Intel Mac reports capped clocks that look like heat). Already rejected in README Honest Limits. Back off on macOS thermal state instead.
- **Kernel extension for lid handling** — no public path, kexts effectively dead on Apple silicon. There is no third lever beyond an external display or `pmset disablesleep`.
- **CPU-threshold workload detection** — an agent waiting on an API sits near 0% CPU, so a CPU floor drops the Mac mid-task. Existence-based matching is deliberate and correct.
- **Webhooks / alert routing / weekly reports** — listed in README "Not yet built" but ungrounded: no user, issue, or telemetry demand. Adds surface to a tool whose whole pitch is a small guarded wrapper. Fails the deletion test.
- **Dashboard** — *partially overturned 2026-07-31.* The rejection was "ungrounded"; a direct user request grounded it. Shipped as an in-menu health panel (rings, lease sparkline, four check groups), **not** as the dashboard originally rejected: no separate window, no CPU/memory/throughput charts, no history past a 15-minute ring. A gauge earns its place only if the quantity behind it can end a hold.
- **Competing on price** — Lidless (MIT) ships the same architecture free. There is no price below free; the wedge has to be the lease API and the depth of the safety envelope.

## 2026-07-31 — whole-project sweep

- **Replace the Unix socket IPC with XPC (as Lidless does)** — the line-JSON socket is what makes the CLI, the Claude Code hooks, and third-party lease clients trivial. XPC locks the protocol to Apple frameworks and would kill the public lease API, which is the differentiator. Rejecting the sibling's choice deliberately.
- **Replace `ps` with `sysctl(KERN_PROC)`** — `ProcessWatcher.swift:95` already justifies `ps`: stable across releases, no entitlement, once per 10s. Cargo-cult optimisation of a cold path.
- **Multi-user helper support** — `install-helper.sh` binds the helper to the installing uid deliberately so another local account cannot toggle power settings. Documented security tradeoff, not a defect.
