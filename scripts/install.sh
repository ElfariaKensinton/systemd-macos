#!/bin/sh
set -eu

PREFIX=${PREFIX:-/usr/local}
BIN_DIR="$PREFIX/bin"
SYSTEMD_DIR=/etc/systemd/system
STATE_DIR=/var/lib/systemd-macos
PLIST=/Library/LaunchDaemons/com.elfaria.systemd-macos.plist

printf '%s\n' 'Building systemd-macos...'
swift build -c release

install -d "$BIN_DIR" "$SYSTEMD_DIR" "$STATE_DIR/enabled" "$STATE_DIR/log"
install -m 755 .build/release/systemd "$BIN_DIR/systemd"
install -m 755 .build/release/systemctl "$BIN_DIR/systemctl"

cat > "$PLIST" <<EOF
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

launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo "Installed systemd-macos."
echo "Unit files: $SYSTEMD_DIR"
echo "Control socket: /var/run/systemd-macos.sock"
echo "CLI: $BIN_DIR/systemctl"
