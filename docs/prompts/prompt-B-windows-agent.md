# PROMPT B — WINDOWS MONITORING AGENT (for Claude Code / Cursor)

Paste this into a code-first AI agent (Claude Code or Cursor), **together with `agent-api-contract.md`**. The contract is the source of truth for every endpoint, payload, and rule; this prompt tells you what to build around it. Do not redefine anything the contract already specifies.

---

## Role

Build a separately deployable **C#/.NET 8 Windows monitoring agent** for a consent-based, transparent workforce-analytics product. The agent is a thin, honest collector: it fetches policy from the backend and obeys it, captures only what policy allows during authorized sessions, queues everything locally, and syncs reliably. It is **not** covert surveillance software and must never behave like one.

Treat `agent-api-contract.md` as authoritative. Where this prompt and the contract overlap, the contract wins.

## Non-negotiable constraints (read first)

- **No keylogging, no keystroke content, no clipboard, no password/field capture, no private-message collection.** Input monitoring produces event *counts* over a time window only.
- **No covert operation.** A persistent, visible monitoring indicator (system tray icon + status) is always present and cannot be hidden by the agent.
- **No collection outside an authorized session**, outside the policy work schedule, or against an excluded app/domain/path.
- **No fabricated data.** If a feature can't run (permission denied, unsupported), report the capability status honestly and collect nothing for it.
- The agent ships with **every feature off** and enables features only from fetched policy.

## Target & stack

- **.NET 8**, Windows 10 21H2+ and Windows 11.
- **Windows Service** (background collector, runs under a service account) **+ a user-session tray app** (status, privacy pause, "what's being collected" view). They communicate over a local named pipe. A user-session component is required because screenshots and active-window/input signals are only reachable from an interactive session.
- **Local store:** SQLite with an encryption key protected by **DPAPI (machine scope)**. Store the `device_token` the same way.
- **Installer:** MSIX preferred, or WiX/MSI. Must handle install, silent/MDM install, update, and clean uninstall (removes service, tray app, local queue, tokens).
- **Code signing:** the build must be signable with an Authenticode certificate; document the signing step. Unsigned, a screenshot-taking agent will be flagged by SmartScreen and AV.

## Architecture (modules)

1. **Enrollment** — one-time enrollment code → `device_token` + `access_token` (contract §3). Idempotent on `machine_fingerprint`.
2. **Auth/token manager** — holds tokens, refreshes before expiry, rotates device_token when the server returns a new one, handles `device_revoked` (stop → wipe → exit).
3. **Policy manager** — fetches `/policy`, caches it, re-fetches when heartbeat reports a higher `policy_version`. Exposes a single "is X allowed right now?" gate that every collector calls.
4. **Session manager** — start/break/resume/stop, manual + schedule modes, task selection at session start, privacy pause (honouring `max_pause_minutes`). Emits session events (contract §5.1).
5. **Collectors** (each one checks the policy gate before every capture):
   - *Screenshot* — interval + jitter from policy, JPEG resize/quality from policy, skip when paused/excluded.
   - *App activity* — foreground process name/path; window title only if policy allows.
   - *Website activity* — active browser **domain** via UI Automation; full URL only if policy allows.
   - *Input metrics* — low-level hooks that **increment counters only** over `window_seconds`; never buffer characters.
   - *Idle detection* — `GetLastInputInfo`; on threshold, raise an idle event and prompt the employee (keep / break / reassign) via the tray.
   - *File activity* — `FileSystemWatcher` on policy `watched_paths` only; optional hash only if policy says so. Off by default.
6. **Exclusion filter** — applied *before* anything is recorded or queued (apps, domains, paths from policy).
7. **Local queue** — encrypted SQLite; every event persisted on capture, before upload (contract §9).
8. **Sync service** — batches events (contract §6), runs the 3-step screenshot upload (contract §7), heartbeat + command handling (contract §5.2), exponential backoff + jitter, removes items only on confirmed accept.
9. **Capability/diagnostics reporter** — maps each collector to `ok | permission_denied | unsupported | disabled_by_policy | error` (contract §8).
10. **Updater** — checks for signed updates; applies them safely; never downgrades silently.
11. **Tray/status UI** — monitoring on/off indicator, current session + task, privacy-pause control, a plain-language "what is being collected" panel, capability warnings, revoked state.

## Behavioural rules

- Immediate-screenshot command: honour only if online + active monitored session + screenshots allowed by policy; otherwise confirm with `refused_by_policy` (contract §7.3).
- Clock: stamp every event in UTC at capture time; upload may be arbitrarily later.
- Network loss: keep collecting permitted events, keep queuing, keep backing off; never drop a session because sync is down.
- On crash/restart: resume from the local queue; re-send is safe because of idempotency keys.
- Resource budget: cap CPU and memory; screenshot compression off the UI thread; document measured idle/active footprint.

## Deliverables

1. Solution with `Agent.Service`, `Agent.Tray`, `Agent.Core` (collectors/queue/sync), `Agent.Installer`.
2. Enrollment flow wired to the real `/enroll` endpoint.
3. All collectors behind the policy gate, with exclusions enforced pre-capture.
4. Encrypted local queue + reliable sync against the contract.
5. Three-step screenshot upload to signed object-storage URLs.
6. Heartbeat + command channel + capability reporting.
7. MSIX/WiX installer with silent-install switches for MDM, plus uninstall that cleans everything.
8. A **mock backend** (minimal local server implementing the contract) so the agent can be run end-to-end without the real SaaS.
9. `README` with build, sign, install, enroll, and MDM-deploy steps.
10. A **capabilities matrix**: each feature, the Windows API used, the permission it needs, and its failure mode.
11. Automated tests (below).

## Tests (must pass before "done")

- Enrollment is idempotent on the same machine fingerprint.
- Token refresh + device_token rotation; `device_revoked` → stop, wipe, exit.
- Policy gate: with a feature disabled or outside the work window, the collector produces **zero** output.
- Exclusions drop excluded apps/domains/paths before they reach the queue.
- Input metrics store counts only — assert no character data is ever persisted or sent.
- Offline → online: events captured offline sync exactly once (idempotency), out-of-order accepted.
- Screenshot 3-step upload, plus `capture_failed` and `refused_by_policy` paths.
- Privacy pause and break stop all collection for their duration.
- Clean uninstall removes service, tray, queue, and tokens.

## Execution order

1. Scaffold the solution + a mock backend implementing the contract.
2. Enrollment + auth/token manager + policy manager (prove the gate works).
3. Session manager + tray status UI.
4. Screenshot collector + 3-step upload end to end (prove **real** capture, not simulated).
5. App / website / input / idle collectors behind the gate, exclusions enforced.
6. Local queue + sync + heartbeat/commands + backoff.
7. Capability/diagnostics reporting + file activity (off by default).
8. Installer, signing, update, uninstall.
9. Full test pass; document the capabilities matrix and resource footprint.

At the end of each step, report what works end to end, what's stubbed, any Windows permission that blocks a feature, and the next tasks. Do not mark a collector complete until it has run against the mock backend end to end.
