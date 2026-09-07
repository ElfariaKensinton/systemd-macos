#!/bin/sh
set -eu

REPO="ElfariaKensinton/systemd-macos"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
SYSTEMD_DIR=/etc/systemd/system
VENDOR_DIR=/usr/local/lib/systemd/system
RUNTIME_DIR=/var/run/systemd/system
STATE_DIR=/var/lib/systemd-macos
PLIST=/Library/LaunchDaemons/com.elfaria.systemd-macos.plist
BASE_URL="https://github.com/$REPO/releases/latest/download"
BASH_COMPLETION_DIR="${BASH_COMPLETION_DIR:-$PREFIX/share/bash-completion/completions}"
ZSH_COMPLETION_DIR="${ZSH_COMPLETION_DIR:-$PREFIX/share/zsh/site-functions}"

case "$(uname -m)" in
  arm64) ARCH=arm64 ;;
  x86_64) ARCH=x86_64 ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

ASSET="systemd-macos-${ARCH}.tar.gz"
CHECKSUM="${ASSET}.sha256"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

printf '%s\n' "Downloading systemd-macos latest release ($ARCH)..."
curl -fsSL "$BASE_URL/$ASSET" -o "$TMP_DIR/$ASSET"
curl -fsSL "$BASE_URL/$CHECKSUM" -o "$TMP_DIR/$CHECKSUM"

( cd "$TMP_DIR" && shasum -a 256 -c "$CHECKSUM" )

tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR"

sudo install -d "$BIN_DIR" "$SYSTEMD_DIR" "$VENDOR_DIR" "$RUNTIME_DIR" "$STATE_DIR/enabled" "$STATE_DIR/log"
sudo install -m 755 "$TMP_DIR/bin/systemd" "$BIN_DIR/systemd"
sudo install -m 755 "$TMP_DIR/bin/systemctl" "$BIN_DIR/systemctl"
sudo install -m 755 "$TMP_DIR/bin/journalctl" "$BIN_DIR/journalctl"
sudo install -m 755 "$TMP_DIR/bin/systemd-exec-helper" "$BIN_DIR/systemd-exec-helper"

sudo install -d "$BASH_COMPLETION_DIR" "$ZSH_COMPLETION_DIR"
sudo install -m 644 "$TMP_DIR/scripts/systemd-macos.bash" "$BASH_COMPLETION_DIR/systemctl"
sudo install -m 644 "$TMP_DIR/scripts/systemd-macos.bash" "$BASH_COMPLETION_DIR/journalctl"
sudo install -m 644 "$TMP_DIR/scripts/_systemctl" "$ZSH_COMPLETION_DIR/_systemctl"
sudo install -m 644 "$TMP_DIR/scripts/_journalctl" "$ZSH_COMPLETION_DIR/_journalctl"

sudo tee "$TMP_DIR/com.elfaria.systemd-macos.plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.elfaria.systemd-macos</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/systemd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$STATE_DIR/daemon.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE_DIR/daemon.stderr.log</string>
</dict>
</plist>
EOF

sudo install -m 644 "$TMP_DIR/com.elfaria.systemd-macos.plist" "$PLIST"
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"

echo "Installed systemd-macos ($ARCH) from the latest GitHub release."
echo "Unit files: $SYSTEMD_DIR"
echo "Vendor unit files: $VENDOR_DIR"
echo "Runtime unit files: $RUNTIME_DIR"
echo "Control socket: /var/run/systemd-macos.sock"
echo "CLI: $BIN_DIR/systemctl"
echo "Journal: $BIN_DIR/journalctl"
echo "Privilege helper: $BIN_DIR/systemd-exec-helper"
echo "Bash completions: $BASH_COMPLETION_DIR"
echo "Zsh completions: $ZSH_COMPLETION_DIR"
