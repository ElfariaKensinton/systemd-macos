# systemd-macos

A from-scratch service manager for macOS that intentionally speaks the systemd language.

This is **not a port of systemd** and does not embed or link against systemd code. The runtime is implemented natively in Swift using macOS process, filesystem, and Unix-domain socket primitives. `launchd` is used only to bootstrap the manager itself at macOS boot; service lifecycle, dependency handling, enablement state, and the `systemctl` protocol belong to systemd-macos.

## Goals

The compatibility contract is deliberately shaped like systemd:

- Unit files use the familiar INI syntax and section names: `[Unit]`, `[Service]`, `[Install]`.
- `systemctl` keeps the familiar verb-oriented command line: `start`, `stop`, `restart`, `status`, `enable`, `disable`, `is-active`, `is-enabled`, `daemon-reload`, `list-units`, `list-unit-files`, `cat`, and `show`.
- Unit names are `.service` units and may be referenced with or without the `.service` suffix.
- Dependencies use `Requires=`, `Wants=`, `Conflicts=`, `After=`, and `Before=` syntax.
- Service definitions use common systemd keys such as `Type=`, `ExecStart=`, `ExecStartPre=`, `ExecStartPost=`, `ExecStop=`, `Restart=`, `RestartSec=`, `TimeoutStartSec=`, `TimeoutStopSec=`, `WorkingDirectory=`, `Environment=`, `EnvironmentFile=`, `RemainAfterExit=`, `KillSignal=`, `StandardOutput=`, and `StandardError=`.
- `systemctl --now enable foo.service` and `systemctl --now disable foo.service` follow the same command shape users already know.

The project intentionally implements a coherent subset first rather than pretending to be a complete reimplementation of every systemd subsystem. The architecture leaves room for additional unit types, socket activation, timers, targets, cgroups, journaling, notification sockets, and user managers without changing the unit-file or CLI grammar.

## Architecture

```text
                    macOS
                      │
               launchd bootstraps
                      │
                      ▼
              ┌────────────────┐
              │     systemd    │
              │  Swift daemon  │
              └───────┬────────┘
                      │ Unix socket
          /var/run/systemd-macos.sock
                      │
                      ▼
              ┌────────────────┐
              │    systemctl   │
              │  Swift client  │
              └────────────────┘
                      │
                      ▼
               .service units
                      │
                      ▼
                 macOS Process
```

The manager stores enablement markers under `/var/lib/systemd-macos/enabled` and captures service stdout/stderr under `/var/lib/systemd-macos/log` by default. Unit files are discovered from `/etc/systemd/system` and `/usr/local/lib/systemd/system`.

## Build

Requires macOS 13 or newer and Swift 5.10 or newer.

```sh
swift build -c release
swift test
```

The resulting binaries are:

```text
.build/release/systemd
.build/release/systemctl
```

## Install from GitHub Releases

The recommended installation method downloads a verified binary for the current Mac architecture from the latest GitHub Release, installs the daemon, and registers its LaunchDaemon so it starts at boot.

```sh
curl -fsSL https://raw.githubusercontent.com/ElfariaKensinton/systemd-macos/main/scripts/install.sh | bash
```

The installer supports Apple Silicon (`arm64`) and Intel (`x86_64`), verifies the SHA-256 checksum published with the release, and uses the stable `releases/latest/download` asset aliases. It invokes `sudo` only for the system-level installation and LaunchDaemon registration steps.

## Build and release

The GitHub Actions **Build and Release** workflow is manually triggered from the Actions tab. It builds and tests both supported macOS architectures. The workflow can either keep the result as Actions artifacts or publish it as a GitHub Release.

Release tags and titles are generated automatically. For example:

```text
Tag:   v0.1.0-build.20260906.42
Name:  systemd-macos 0.1.0 — Build 42 (20260906)
```

Published releases contain versioned archives, SHA-256 checksums, and stable `latest` aliases used by the one-line installer.

For development from a checkout, build the binaries directly with Swift and install them manually; `scripts/install.sh` is intentionally the release installer rather than a source-build installer.

## Unit example

```ini
[Unit]
Description=My application
Requires=my-backend.service
After=my-backend.service

[Service]
Type=simple
ExecStart=/usr/local/bin/my-app --config /etc/my-app/config.toml
Restart=on-failure
RestartSec=2s
WorkingDirectory=/var/lib/my-app
Environment=APP_ENV=production

[Install]
WantedBy=multi-user.target
```

Put the file at `/etc/systemd/system/my-app.service`, then:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now my-app.service
sudo systemctl status my-app.service
```

The repository includes the same style of example in `example/systemd-macos-demo.service`.

## Implemented systemctl surface

`start`, `stop`, `restart`, `reload`, `status`, `enable`, `disable`, `is-active`, `is-enabled`, `daemon-reload`, `list-units`, `list-unit-files`, `cat`, and `show` are implemented. Common global options `--quiet`, `--no-legend`, `--no-pager`, `--system`, `--user`, `--plain`, `--now`, `--version`, and `--help` are accepted where meaningful.

`reload` currently performs a restart because there is not yet a distinct reload process signal/configuration path. The option is present so the command grammar remains familiar while the reload subsystem is developed separately.

## Design constraints

The implementation does not attempt to replace `launchd`, alter the macOS init process, or pretend that Linux kernel primitives exist on Darwin. Process supervision and dependency semantics are implemented directly, while macOS-specific bootstrapping remains isolated to the small LaunchDaemon plist generated by the installer.

## Status

Early implementation. The current focus is the service manager core and systemd-compatible surface syntax. The parser has unit tests, but integration testing requires a macOS host because the project intentionally uses Darwin APIs and the real filesystem/socket layout.
