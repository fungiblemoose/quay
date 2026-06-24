# Quay

A lightweight supervisor that turns Apple's [`container`](https://github.com/apple/container)
CLI (macOS 26+) into a manager for persistent, self-hosted **appliance** services.

`container` is great at *running* a container, but on its own it has no notion of
a service that should always be up. Quay adds the three things it lacks:

1. **A declarative stack file** — one YAML file describes a stack of services.
2. **A keep-alive / reconcile daemon** — `quayd` continuously drives reality
   toward what the stack files declare (create, start, health-check, restart).
3. **Autostart across reboot** — a per-user LaunchAgent brings everything back
   after a restart or power failure.

Quay is **not** a Docker/OrbStack replacement for day-to-day dev work. It's a
narrow, always-on **service manager** for a self-hosted box. The v1 target
service is [Open WebUI](https://github.com/open-webui/open-webui).

> ✅ **Verified against `container` 1.0.0** (macOS 26, 2026-06). Every CLI call
> Quay makes — `ls --all --format json`, `run --detach/--name/--env/--volume/
> --publish`, `start`, `stop`, `volume create` — was exercised on a real install
> and behaves as assumed. The integration layer (`ContainerClient.swift`,
> `ContainerJSON.swift`) stays deliberately thin, and each shell-out keeps a
> `// VERIFY:` note so a future CLI change is a one-line fix. The tool is still
> young, so **live `container --help` always wins** after an upgrade.
>
> One known platform gap: `container` 1.0.0 reports no exit code in `ls` *or*
> `inspect`, only a coarse running/stopped state. So `restart: on-failure`
> can't distinguish a clean stop from a crash and conservatively restarts on any
> stop (same as `always` for a stopped container). Use `never` to opt out.

## Requirements

- **Build:** Swift 6 toolchain, macOS 14+ (the package's platform floor).
- **Runtime:** macOS **26+** with Apple's `container` CLI installed and on `PATH`
  (commonly `/usr/local/bin/container`). Quay only does useful work there.
- Dependency: [Yams](https://github.com/jpsim/Yams) (YAML), fetched by SwiftPM.

The package *builds and its tests pass* on any platform with a Swift 6 toolchain
(QuayCore is pure Foundation), but `quayd` can only manage containers on a Mac
with `container` present. Without it, `quayd` logs a clear warning, writes a
`status.json` marking the runtime unavailable, and keeps retrying.

## Build & test

```sh
swift build           # build QuayCore, quayd, QuayBar
swift test            # run the QuayCore unit tests

# Run the daemon against the bundled example (one pass, verbose):
swift run quayd --once --stacks ./Examples --verbose

# Supervise continuously (default 15s interval):
swift run quayd --stacks ./Examples
```

`quayd` options:

| Flag | Default | Meaning |
|------|---------|---------|
| `--stacks <dir>` | `~/.config/quay/stacks` | Directory of `*.quay.yaml` stack files |
| `--interval <sec>` | `15` | Reconcile interval |
| `--once` | — | Run a single pass and exit |
| `--verbose` | — | Debug logging |

Logs go to **stderr**. State is published to `~/.config/quay/status.json`.

## Install (autostart as a per-user LaunchAgent)

```sh
scripts/install-agent.sh            # build -c release, install quayd, bootstrap
scripts/install-agent.sh --uninstall
```

The script builds a release binary into `~/.local/bin/quayd`, templates the
LaunchAgent into `~/Library/LaunchAgents/com.backspinlabs.quay.quayd.plist`, and
`launchctl bootstrap`s it into your GUI session. It is a **per-user
LaunchAgent**, not a system LaunchDaemon, because Apple's `container` service is
itself user-scoped — a daemon in a different session couldn't talk to it. Every
path derives from `$HOME`.

After installing, the script prints an **appliance checklist** (disable sleep,
auto-restart after power failure, enable auto-login) so the box comes back on its
own. Bundle id: `com.backspinlabs.quay`.

## Stack schema

One YAML file per stack — a **native** Quay format, not docker-compose. See
[`Examples/openwebui.quay.yaml`](Examples/openwebui.quay.yaml).

```yaml
version: 1
stack: openwebui
services:
  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    env:
      - "WEBUI_AUTH=true"
    volumes:
      - "openwebui-data:/app/backend/data"
    publish:
      - host: 3000
        container: 8080
        protocol: tcp           # default tcp
    restart: always             # always | on-failure | never  (default always)
    health:
      type: http                # http only in v1
      url: "http://127.0.0.1:3000/health"
      interval_seconds: 30
      timeout_seconds: 5
      failures_to_unhealthy: 3  # consecutive failures -> mark degraded
      failures_to_restart: 6    # consecutive failures -> restart (if policy allows)
volumes:
  openwebui-data: {}
```

**Defaults:** missing keys are filled in by custom decoders, not rejected —
`version` ⇒ 1, `restart` ⇒ `always`, `protocol` ⇒ `tcp`, and the health integers
to the values above. A service with no `health` block is treated as healthy and
never churned.

**Container naming.** Every managed container is named
`quay-<stack>-<service>` (e.g. `quay-openwebui-openwebui`). That `quay-` prefix
is the **single source of truth** for "is this container mine."

### How the reconciler behaves each tick

- Lists actual `quay-*` containers. For each desired service:
  - **not present** → create + start
  - **stopped/exited** → start *if* the restart policy allows (`always` and
    `on-failure` both restart — see the exit-code gap above; `never` never)
  - **running** → HTTP health check at the service's `interval_seconds`; after
    `failures_to_restart` consecutive failures (and if policy allows) → restart
    (stop then start)
- **Per-container exponential backoff** (base 2s, ×2, cap 5m, ~10 attempts) so a
  crash-looping image can't pin the CPU. After the cap of attempts the service is
  marked `failed`; a healthy observation resets the backoff.
- **Health:** HTTP GET, `2xx`/`3xx` = healthy. Missing/unknown health type is
  treated as healthy.
- **Orphans:** a `quay-*` container with no matching service is **logged only,
  never removed** — a half-edited stack file must not nuke a live service.
- Publishes a JSON snapshot to `~/.config/quay/status.json`.

The reconciler is an **actor** and the **single writer** of container state, so
ticks can never race.

## QuayBar (menu bar)

`QuayBar` is a SwiftUI `MenuBarExtra` that reads `status.json` every few seconds.
The menu bar glyph aggregates everything: **green** = all healthy, **yellow** =
starting/degraded, **red** = any failed. Each service is listed with its state, a
health dot, and restart count.

Each service also has a **Restart** button (↻). It does *not* start the container
itself — it `container stop`s the service and lets `quayd` bring it back up on the
next reconcile tick (≤ the daemon interval). A stop is indistinguishable from a
crash, which the supervisor already handles, so `quayd` stays the **single writer**
of start/create state and there's no two-writers race. That's why there is no
Start/Stop button — only Restart. Useful for a *zombie* hang (process wedged but
`/health` still answers) that the automatic health check won't catch.

Install it into the menu bar (run in the GUI session you want it in — e.g. over
Screen Sharing on a headless box):

```sh
scripts/install-bar.sh              # build, bundle ~/Applications/QuayBar.app, autostart
scripts/install-bar.sh --uninstall
```

The installer assembles an `LSUIElement` `.app` (menu-bar-only, no Dock icon) and
a per-user LaunchAgent. `KeepAlive` fires **only on a crash** (`SuccessfulExit=false`),
so a clean "Quit QuayBar" stays quit and a startup crash can't tight-loop.

## Scope

**In v1:** the YAML stack schema, the reconcile/keep-alive daemon, HTTP health
checks, per-container backoff, orphan detection (log-only), autostart
LaunchAgent, and a read-only menu bar. Target service: Open WebUI.

**Out of scope for v1** (intentionally left as TODOs):

- Pi-hole — blocked today because `apple/container` can't publish `53/tcp` and
  `53/udp` together.
- socat LAN bridging, UDP publishing, privileged ports (`<1024`).
- `dns` health type, docker-compose import, `depends_on` ordering.
- FSEvents watch on the stacks dir (today files are re-read every tick).

## Architecture

| Target | Kind | Responsibility |
|--------|------|----------------|
| `QuayCore` | library | schema, container client, reconciler, health, backoff, status I/O |
| `quayd` | executable | headless supervisor loop (runs under the LaunchAgent) |
| `QuayBar` | executable | SwiftUI menu bar: status + Restart (stop-and-let-quayd-recover) |
| `QuayCoreTests` | tests | unit tests for the above |

## License

MIT — see [LICENSE](LICENSE). © Quay contributors.
