# systemd-macos

A from-scratch service manager for macOS that intentionally speaks the systemd language.

This is **not a port of systemd** and does not embed or link against systemd code. The runtime is implemented natively in Swift using macOS process, filesystem, and Unix-domain socket primitives. `launchd` is used to bootstrap the manager itself at macOS boot; service lifecycle, dependency handling, enablement state, and the `systemctl` protocol belong to systemd-macos.

## Current scope

The current implementation is focused on `.service` units and the core service-manager workflow:

- service start, stop, restart, reload, status, enable and disable
- `--now` enable/disable transactions
- dependency handling for `Requires=`, `Wants=` and `Conflicts=`
- restart policies and stop timeouts
- credentials and resource limits through `systemd-exec-helper`
- environment files and working-directory configuration
- persistent and runtime unit drop-ins
- `systemctl edit`, including `--full`, `--runtime` and `--force`
- `systemctl show`, `cat`, `list-units` and `list-unit-files`
- project-local service logging through `journalctl`
- systemd-like status formatting and an interactive `less` pager for `status`
- shell completions for `systemctl` and `journalctl`

The project intentionally implements a coherent subset rather than claiming to reproduce every systemd subsystem.

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

The manager stores enablement markers under `/var/lib/systemd-macos/enabled` and captures service stdout/stderr under `/var/lib/systemd-macos/log` by default. Unit files are discovered from `/etc/systemd/system` and `/usr/local/lib/systemd/system`; runtime units and drop-ins use `/var/run/systemd/system`.

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
.build/release/journalctl
.build/release/systemd-exec-helper
```

## Install

The release installer is `scripts/install.sh`. It downloads a release archive for the current Mac architecture, verifies its SHA-256 checksum, installs the binaries and completions, creates the systemd-macos state/unit directories, and registers `/Library/LaunchDaemons/com.elfaria.systemd-macos.plist` with `launchd`.

```sh
curl -fsSL https://elfariakensinton.github.io/systemd-macos/install.sh | bash
```

The installer supports Apple Silicon (`arm64`) and Intel (`x86_64`) and uses `sudo` for system-level installation and LaunchDaemon registration.

The release workflow currently publishes versioned architecture-specific archives and checksum files. The installer expects `releases/latest/download` asset aliases, so those aliases must exist on the release being installed.

For development from a checkout, build the binaries directly with Swift and install them manually. The installer is release-oriented rather than a source-build installer.

## Release workflow

There is one GitHub Actions workflow: **Build and Release**. It is manually triggered from the Actions tab.

It builds and tests both supported macOS architectures:

- `arm64` on `macos-15`
- `x86_64` on `macos-15-intel`

Each build produces an archive and SHA-256 checksum. When `publish_release` is enabled, the workflow creates a GitHub Release with a generated build tag and release title. Releases contain the versioned `arm64` and `x86_64` archives and their checksums.

There is currently **no GitHub Pages deployment workflow**. The `docs/` directory is documentation/source content, not an automatically deployed Pages site.

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
systemctl status my-app.service
```

`disable --now` stops the service before removing its enablement marker:

```sh
sudo systemctl disable --now my-app.service
```

The repository includes the same style of example in `example/systemd-macos-demo.service`.

## Editing units

`systemctl edit` creates or edits a persistent drop-in by default:

```sh
sudo systemctl edit my-app.service
```

Use `--full` to edit the complete unit file, `--runtime` for a runtime-only drop-in/full unit, and `--force` to create a missing unit:

```sh
sudo systemctl edit --full my-app.service
sudo systemctl edit --runtime my-app.service
sudo systemctl edit --force my-new-app.service
```

The editor is selected from `SYSTEMD_EDITOR`, `SUDO_EDITOR`, `EDITOR`, or `VISUAL`, falling back to `/usr/bin/vi`. A successful edit triggers `daemon-reload` automatically.

## Status and pager behaviour

`systemctl status` is the only `systemctl` command that automatically uses the interactive pager. When both standard input and output are terminals, the default pager is:

```text
less -R -F -X
```

`--no-pager` disables it. `SYSTEMD_PAGER` takes precedence over `PAGER`; `cat` disables paging. For `less`, the client normalizes conflicting options and retains color output while allowing short status output to exit immediately.

State-reflecting commands such as `status`, `is-active`, and `is-enabled` retain their normal non-zero exit status while still displaying the manager's response.

## Feature and compatibility reference

The complete unit-file, process-execution, lifecycle, logging, `systemctl`, `journalctl`, platform-limit, editing, pager, and unsupported-feature reference is maintained separately:

**[Feature and Unit-File Reference](docs/UNIT-FILES.md)**

That document is the authoritative compatibility boundary for the current implementation.

## Design constraints

The implementation does not attempt to replace `launchd`, alter the macOS init process, or pretend that Linux kernel primitives exist on Darwin. Process supervision and dependency semantics are implemented directly, while macOS-specific bootstrapping remains isolated to the small LaunchDaemon plist generated by the installer.

## Status

Early implementation. The current focus is the service manager core and systemd-compatible surface syntax. The parser has unit tests, but integration testing requires a macOS host because the project intentionally uses Darwin APIs and the real filesystem/socket layout.
