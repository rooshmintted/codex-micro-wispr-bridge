#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
install_dir="$HOME/Library/Application Support/CodexMicroWisprBridge"
binary_path="$install_dir/codex-micro-wispr-bridge"
log_path="$install_dir/bridge.log"
launch_agents_dir="$HOME/Library/LaunchAgents"
plist_path="$launch_agents_dir/com.roosh.codex-micro-wispr-bridge.plist"
template_path="$script_dir/com.roosh.codex-micro-wispr-bridge.plist.template"

if [[ ! -f "$project_dir/Package.swift" || ! -f "$template_path" ]]; then
    print -u2 "Run this installer from a complete codex-micro-wispr-bridge checkout."
    exit 1
fi

cd "$project_dir"
swift build -c release

mkdir -p "$install_dir" "$launch_agents_dir"
install -m 0755 "$project_dir/.build/release/codex-micro-wispr-bridge" "$binary_path"

escaped_binary_path="${binary_path//&/\\&}"
escaped_log_path="${log_path//&/\\&}"
sed \
    -e "s|__BINARY_PATH__|$escaped_binary_path|g" \
    -e "s|__LOG_PATH__|$escaped_log_path|g" \
    "$template_path" > "$plist_path"

plutil -lint "$plist_path"
launchctl bootout "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist_path"
launchctl kickstart -k "gui/$(id -u)/com.roosh.codex-micro-wispr-bridge"

print "Installed and started: $binary_path"
print "Logs: $log_path"
print "If permissions are not granted yet, run:"
print "  '$binary_path' --check-permissions"
