#!/bin/bash
# Re-register the Ext4Kit file system extension after installing or updating
# the app.
#
# Replacing Ext4Kit.app in place leaves ExtensionKit holding a connection to
# the previous build's code-signature hash, so the first mount/fsck/newfs
# fails with "extensionKit error 2 / connection invalidated". Run this once
# after dropping in a new build.
#
# Usage: Scripts/refresh-extension.sh [/path/to/Ext4Kit.app]
set -euo pipefail

APP="${1:-/Applications/Ext4Kit.app}"
APPEX="$APP/Contents/Extensions/Ext4KitExtension.appex"
ID="com.rayhanadev.Ext4Kit.Ext4KitExtension"

if [ ! -d "$APPEX" ]; then
    echo "No extension found at $APPEX" >&2
    echo "Pass the path to Ext4Kit.app if it isn't in /Applications." >&2
    exit 1
fi

killall -TERM extensionkitservice 2>/dev/null || true
pluginkit -r "$APPEX" 2>/dev/null || true
pluginkit -a "$APPEX"
pluginkit -e use -i "$ID"
launchctl kickstart -kp "user/$(id -u)/com.apple.fskit.fskit_agent" 2>/dev/null || true

echo "Re-registered $ID:"
pluginkit -m -p com.apple.fskit.fsmodule | grep -i ext4 || true
echo
echo "If the first mount still fails with 'error 2', run it once more —"
echo "the extension's cold-start connection occasionally drops on the first try."
