# Rejected roadmap ideas

Append-only. Read before any roadmap run so killed ideas don't come back.
One line per rejection, verbatim reason.

## 2026-07-31 — first roadmap run (scope: the proposition)

- **Fan control to survive closed-lid heat** — third-party fan control is restricted on Apple silicon; direct SMC reads misfire (a power-starved Intel Mac reports capped clocks that look like heat). Already rejected in README Honest Limits. Back off on macOS thermal state instead.
- **Kernel extension for lid handling** — no public path, kexts effectively dead on Apple silicon. There is no third lever beyond an external display or `pmset disablesleep`.
- **CPU-threshold workload detection** — an agent waiting on an API sits near 0% CPU, so a CPU floor drops the Mac mid-task. Existence-based matching is deliberate and correct.
- **Webhooks / alert routing / weekly reports / dashboard** — listed in README "Not yet built" but ungrounded: no user, issue, or telemetry demand. Adds surface to a tool whose whole pitch is a small guarded wrapper. Fails the deletion test.
- **Competing on price** — Lidless (MIT) ships the same architecture free. There is no price below free; the wedge has to be the lease API and the depth of the safety envelope.
