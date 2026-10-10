#!/bin/bash
# Removes fushicho from this Mac: the login agent, the program and its files.
# The signing certificate ("fushicho Local Signing") is left in your keychain. To delete it too, run:
#   security delete-identity -c "fushicho Local Signing" ~/Library/Keychains/login.keychain-db
# (On recent macOS the Passwords app does not show certificates; this command is the easy way.)
ID="local.fushicho"
launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$ID.plist"
rm -rf "$HOME/Library/Application Support/fushicho"
rm -f "$HOME/Library/Logs/fushicho.log"
echo "fushicho was removed. (You can also remove it from System Settings → Privacy & Security → Accessibility.)"
echo "The signing certificate was left in your keychain. To delete it:"
echo '  security delete-identity -c "fushicho Local Signing" ~/Library/Keychains/login.keychain-db'
read -r -p "Press Return to close " _
