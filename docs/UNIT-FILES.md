# systemd-macos Feature and Unit-File Reference

This document is the authoritative reference for the current systemd-macos implementation. It describes what the parser accepts, what the manager enforces on macOS, what is metadata-only, and what is intentionally unavailable because the corresponding systemd/Linux primitive has no direct Darwin equivalent.

## Platform and scope

- **Platform:** macOS 13 or newer
- **Language/runtime:** Swift 5.10+
- **Unit types:** `.service` units only
- **Manager transport:** Unix-domain socket at `/var/run/systemd-macos.sock`
- **Bootstrapping:** `launchd` starts the systemd-macos daemon; service lifecycle is handled by systemd-macos itself
- **Persistent unit paths:** `/etc/systemd/system` and `/usr/local/lib/systemd/system`
- **Runtime unit path:** `/var/run/systemd/system`
- **Enablement state:** `/var/lib/systemd-macos/enabled`
- **Service logs:** `/var/lib/systemd-macos/log`

The implementation intentionally speaks a systemd-like unit-file and `systemctl` language without attempting to reproduce Linux systemd internals.

## Unit-file syntax

Only these sections are currently accepted:

- `[Unit]`
- `[Service]`
- `[Install]`

Unknown sections are rejected. Unknown keys inside a recognized section are ignored.

### Drop-ins

Persistent drop-ins are read from a sibling `<unit>.service.d/` directory next to the unit file. Runtime drop-ins are read from `/var/run/systemd/system/<unit>.service.d/`.

Only files ending in `.conf` are loaded, in sorted filename order. Persistent drop-ins are applied first; runtime drop-ins are applied afterward, giving runtime configuration precedence.

`systemctl edit UNIT` creates `override.conf` in the persistent drop-in directory by default. `--runtime` selects the runtime directory instead.

### `[Unit]`

| Key | Status | Behaviour |
|---|---|---|
| `Description=` | Implemented | Stored as unit metadata and displayed by `status`/`list-units`; exposed by `show`. |
| `Documentation=` | Parsed | Stored as metadata. Multiple whitespace-separated references are accepted. It does not launch a browser or otherwise act on the URLs. |
| `Requires=` | Implemented | Dependencies are started recursively before the requested service. Dependency cycles are detected. |
| `Wants=` | Implemented | Dependencies are started recursively before the requested service. The current implementation does not provide the full weak-dependency transaction semantics of Linux systemd. |
| `After=` | Parsed | Ordering metadata is retained but is not currently used to schedule starts. |
| `Before=` | Parsed | Ordering metadata is retained but is not currently used to schedule starts. |
| `Conflicts=` | Implemented | Active conflicting services are stopped before the requested unit is launched. |

`Requires=`, `Wants=`, `After=`, `Before=`, and `Conflicts=` accept whitespace-separated unit names.

### `[Service]`

| Key | Status | Accepted values / format | Behaviour |
|---|---|---|---|
| `Type=` | Implemented (partial semantics) | `simple`, `exec`, `forking`, `oneshot`, `notify`, `idle` | Parsed into the service model. Process supervision is based on the launched process; the distinct Linux semantics of `exec`, `forking`, `notify`, and `idle` are not fully reproduced. |
| `ExecStart=` | Implemented | Command string | Main service command. One value is retained. Required unless `Type=oneshot`. |
| `ExecStartPre=` | Implemented | Command string, repeatable | Commands run before `ExecStart`. Their stdout/stderr is discarded. A non-zero exit fails the start. |
| `ExecStartPost=` | Implemented | Command string, repeatable | Commands are launched after a long-running main process has been started. Their stdout/stderr is discarded. Failures are currently ignored. |
| `ExecStop=` | Implemented | Command string, repeatable | The first configured stop command is run during stop. Its stdout/stderr is discarded. |
| `Restart=` | Implemented | `no`, `on-success`, `on-failure`, `on-abnormal`, `on-watchdog`, `on-abort`, `always` | Controls automatic restart after process exit. `on-abnormal`, `on-watchdog`, and `on-abort` currently use non-zero exit as the restart condition. |
| `RestartSec=` | Implemented | seconds, milliseconds, minutes, hours, days, or `infinity` | Delay before automatic restart. `infinity` maps to the maximum finite `TimeInterval` and is not intended as a practical restart delay. |
| `TimeoutStartSec=` | Parsed | duration | Stored in the service model but not currently enforced as a hard launch timeout. |
| `TimeoutStopSec=` | Implemented | duration | Maximum time waited for the service process to exit after `KillSignal=`. |
| `User=` | Implemented | user name | Service commands are launched through the privileged `systemd-exec-helper` when needed so the target UID is applied. |
| `Group=` | Implemented | group name | Service commands are launched through the privileged helper so the target primary GID is applied. |
| `SupplementaryGroups=` | Implemented | whitespace-separated group names | Supplementary groups are applied through the helper. |
| `WorkingDirectory=` | Implemented | filesystem path | Sets the launched process current working directory. |
| `UMask=` | Implemented | octal `000` through `777` | Applies the process file-creation mask through the helper. |
| `LimitNOFILE=` | Implemented | unsigned integer | Applies the open-file descriptor limit through the helper. `infinity` is not accepted. |
| `Environment=` | Implemented | `KEY=VALUE` | Adds or overrides a process environment variable. A surrounding pair of quotes is accepted. |
| `EnvironmentFile=` | Implemented | filesystem path | Reads simple `KEY=VALUE` lines, ignoring blank lines and `#` comments. A leading `-` path is ignored for compatibility. Shell expansion and full systemd environment-file quoting are not implemented. |
| `RemainAfterExit=` | Implemented | `yes`/`no`, `true`/`false`, `1`/`0` | A successfully exited service is represented as `exited` rather than `dead` when enabled. |
| `KillSignal=` | Implemented | numeric signal or supported name | Used for the main process during stop. Supported names: `HUP`, `INT`, `QUIT`, `ABRT`, `KILL`, `TERM`, `STOP`, `CONT`, with or without `SIG`. |
| `StandardOutput=` | Implemented (limited) | default `journal`; `null` | Default output is captured in the unit stdout log. `null` discards stdout. Other values are currently treated as file-backed capture rather than implementing the complete systemd output-target matrix. |
| `StandardError=` | Implemented (limited) | default `inherit`; `null` | Default stderr is captured in the unit stderr log. `null` discards stderr. Other values are currently treated as file-backed capture rather than implementing the complete systemd output-target matrix. |
| `CapabilityBoundingSet=` | Linux-only / rejected | capability names | A non-empty value is rejected because Linux capabilities do not have a direct macOS equivalent implemented here. |
| `AmbientCapabilities=` | Linux-only / rejected | capability names | A non-empty value is rejected because Linux ambient capabilities do not have a direct macOS equivalent implemented here. |
| `NoNewPrivileges=` | Linux-only / rejected | `yes`/`no`, `true`/`false`, `1`/`0` | The key is parsed. `yes` is rejected because no exact macOS equivalent is implemented. |

### `[Install]`

| Key | Status | Behaviour |
|---|---|---|
| `WantedBy=` | Implemented as metadata | Stored with the unit and retained in the unit model. `enable` creates an enablement marker; target activation semantics are not implemented. |
| `Alias=` | Implemented | `enable` creates markers for aliases and `disable` removes them. |

## Required service configuration

For every non-`oneshot` service, `ExecStart=` is required. `oneshot` services may omit `ExecStart=` and are represented as immediately exited successfully.

Example:

```ini
[Unit]
Description=Example application
Documentation=https://example.invalid/docs
Requires=example-backend.service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/example-app --config /etc/example/config.toml
ExecStartPre=/bin/mkdir -p /var/lib/example
Restart=on-failure
RestartSec=2s
TimeoutStartSec=30s
TimeoutStopSec=10s
User=nobody
Group=staff
SupplementaryGroups=wheel
WorkingDirectory=/var/lib/example
UMask=027
LimitNOFILE=1048576
Environment=APP_ENV=production
EnvironmentFile=/etc/example/environment
RemainAfterExit=no
KillSignal=TERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
Alias=example.service
```

## Process execution model

The manager launches commands through `/bin/sh -c`, so unit command strings can use ordinary shell syntax.

When any of `User=`, `Group=`, `SupplementaryGroups=`, `UMask=`, or `LimitNOFILE=` is configured, commands are launched through the root-owned `systemd-exec-helper` binary. The helper applies the supported credential/resource settings and then executes the command.

`ExecStartPre=`, `ExecStartPost=`, and `ExecStop=` are control commands. Their stdout and stderr are intentionally redirected to `/dev/null` so setup/teardown output does not become service log content.

The main service process uses file-backed stdout/stderr logs by default. Logs are truncated when a new service instance is started.

## Dependency and lifecycle semantics

### Start

`start UNIT` resolves `Requires=` and `Wants=` recursively, detects dependency cycles, stops active `Conflicts=`, and launches the requested service.

### Stop

`stop UNIT` runs the configured `ExecStop=` command, sends `KillSignal=` to the main process, waits up to `TimeoutStopSec=`, and terminates the process if it is still running.

### Restart

`restart UNIT` stops an active service and starts it again. An explicitly requested `restart` starts the service even when it is disabled; enablement controls boot/startup eligibility, not whether an explicit lifecycle command may start the unit.

### Reload

`reload UNIT` currently performs a restart because there is no separate reload protocol or process-signal implementation yet.

### `--now`

`enable --now UNIT` enables the unit and then starts it. `disable --now UNIT` stops the unit first and then removes its enablement marker.

### Automatic restart

When the main process exits, the manager records a `success` result for exit status zero and `exit-code` otherwise. Depending on `Restart=`, it may wait `RestartSec=` and start the unit again.

The current implementation does not model every systemd restart classification distinction. `on-abnormal`, `on-watchdog`, and `on-abort` currently use non-zero exit as the restart condition.

## Enablement and boot

`systemctl enable` creates a persistent marker under `/var/lib/systemd-macos/enabled`. On daemon startup, enabled services are loaded and started.

`WantedBy=` is retained for systemd-compatible unit syntax, but this project does not implement target units or full target transaction semantics. Enabling a service therefore does not create a graph of target dependencies.

The systemd-macos daemon itself is bootstrapped by a small `/Library/LaunchDaemons/com.elfaria.systemd-macos.plist` generated by the installer. `launchd` owns only the daemon bootstrap process, not the individual `.service` lifecycle.

## Logging and `journalctl`

Service logs are stored in:

```text
/var/lib/systemd-macos/log/<unit>.service.stdout.log
/var/lib/systemd-macos/log/<unit>.service.stderr.log
```

`journalctl` reads these files and presents them with unit-prefixed timestamps. This is a project-local journal implementation, not the Linux `systemd-journald` daemon or binary journal format.

The daemon's own launchd-managed stdout/stderr are stored under:

```text
/var/lib/systemd-macos/daemon.stdout.log
/var/lib/systemd-macos/daemon.stderr.log
```

Supported `journalctl` operations are:

```text
journalctl -u UNIT
journalctl -u UNIT -n N
journalctl -u UNIT -f
```

The following compatibility options are accepted but do not add the corresponding full systemd feature:

```text
-x, --catalog
-e, --pager-end
--no-pager
```

## `systemctl` command surface

Implemented commands:

```text
start UNIT...
stop UNIT...
restart UNIT...
reload UNIT...
status UNIT...
enable UNIT...
disable UNIT...
edit UNIT
is-active UNIT...
is-enabled UNIT...
daemon-reload
list-units
list-unit-files
cat UNIT...
show UNIT...
```

Accepted options:

```text
--quiet, -q
--no-legend
--no-pager
--system
--user
--plain
--now
--full
--runtime
--force
--version
--help, -h
```

### Command notes

- `edit UNIT` edits a persistent drop-in by default.
- `edit --full UNIT` edits the complete persistent unit file.
- `edit --runtime UNIT` places the edit under `/var/run/systemd/system`.
- `edit --force UNIT` permits creating a missing unit.
- A successful `edit` automatically requests `daemon-reload` after the editor exits.
- The editor is selected from `SYSTEMD_EDITOR`, `SUDO_EDITOR`, `EDITOR`, or `VISUAL`, falling back to `/usr/bin/vi`.
- `--system` is accepted; system scope is the default.
- `--user` is accepted for command-line compatibility but there is no independent per-user manager or user-unit directory implementation.
- `--plain` disables ANSI colors and underlines in status output.
- `--quiet` suppresses successful command output.
- `--no-legend` suppresses supported status/list headers.
- `--now` combines enable/disable with immediate start/stop.
- `status` and list commands display unit descriptions and runtime state.
- `show` exposes machine-readable properties including `Id`, `Description`, `LoadState`, `ActiveState`, `SubState`, `MainPID`, `UnitFileState`, `Result`, and `FragmentPath`.

### Status exit codes and output

`status`, `is-active`, and `is-enabled` are state-reflecting commands. A non-zero manager exit code is returned to the shell when the requested state is not satisfied, while the response output is still displayed.

Other commands treat a non-zero manager response as an operation failure and return that exit code after reporting the error unless `--quiet` is in effect.

### Status pager

`status` is the only `systemctl` action that automatically invokes the pager. Paging occurs only when both stdin and stdout are terminals and `--no-pager` has not been supplied.

The default pager is:

```text
less -R -F -X
```

`SYSTEMD_PAGER` takes precedence over `PAGER`. Setting the pager to `cat` disables paging. When a configured pager is `less`, conflicting `-S`, `--chop-long-lines`, `-R`, `-F`, and `--no-init` options are removed and the client ensures `-R -F -X` behaviour.

## Editing units

The editing workflow is deliberately close to systemd's drop-in model:

```sh
sudo systemctl edit example.service
```

This creates or edits:

```text
/etc/systemd/system/example.service.d/override.conf
```

Runtime editing uses:

```sh
sudo systemctl edit --runtime example.service
```

which targets:

```text
/var/run/systemd/system/example.service.d/override.conf
```

Full-file editing uses `--full`; `--force` permits creating a unit that does not already exist. The editor must exit successfully for the command to succeed.

## Metadata vs enforced behaviour

**Actually enforced on macOS:** command execution, recursive `Requires=`/`Wants=` handling, `Conflicts=`, restart policy, restart delay, stop timeout, user/group credentials, supplementary groups, working directory, umask, `LimitNOFILE=`, environment, environment files, remain-after-exit state, kill signal, service stdout/stderr capture, persistent enablement markers, aliases, persistent/runtime drop-ins, and the `--now` enable/disable lifecycle operations.

**Parsed/stored but not fully enforced:** `Documentation=`, `After=`, `Before=`, `TimeoutStartSec=`, target-specific `WantedBy=` semantics, several `Type=` distinctions, and most `StandardOutput=`/`StandardError=` destinations.

**Explicitly unavailable/rejected:** non-empty `CapabilityBoundingSet=`, non-empty `AmbientCapabilities=`, and `NoNewPrivileges=yes`.

## Not implemented by design/current scope

These common systemd subsystems are outside the current implementation:

- socket activation and `.socket` units
- timer units and calendar timers
- target units and full target transactions
- path units
- mount/automount units
- swap units
- device units
- slice/cgroup resource management
- Linux namespaces and container isolation
- Linux capabilities
- `systemd-journald` and binary journal storage
- service notification sockets / full `Type=notify` protocol semantics
- watchdog management
- transient units
- user managers and per-login service instances
- D-Bus activation
- full systemd dependency transaction ordering
- Linux-specific security controls without a direct Darwin equivalent

The absence of these features is intentional; unsupported Linux-only primitives are not silently emulated.

## Installation layout

Release installation places the main binaries in `/usr/local/bin` by default and registers the daemon with `launchd`. The release package also contains shell completions and `systemd-exec-helper` for credential/resource-limit execution.

The installer creates or uses:

```text
/usr/local/bin/systemd
/usr/local/bin/systemctl
/usr/local/bin/journalctl
/usr/local/bin/systemd-exec-helper
/etc/systemd/system
/usr/local/lib/systemd/system
/var/run/systemd/system
/var/lib/systemd-macos/enabled
/var/lib/systemd-macos/log
/Library/LaunchDaemons/com.elfaria.systemd-macos.plist
```

## Compatibility principle

A Linux unit file can often be reused when it stays within the supported subset, but matching syntax does not imply matching kernel semantics. The authoritative compatibility boundary is this document and the implementation itself.
