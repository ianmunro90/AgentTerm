#!/bin/bash
# Needs: SSH_HOST (ssh alias of the demo server), APP_HOST (user@host:port as the app connects),
# BUNDLE_ID (the app's bundle ID), SIM_IPAD and SIM_IPHONE (booted simulator UDIDs, iPad 13" and iPhone 6.9", the app installed and
# its key authorized). See README.md here.
: "${SSH_HOST:?}" "${APP_HOST:?}" "${SIM_IPAD:?}" "${SIM_IPHONE:?}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
OUT="$(cd "$(dirname "$0")/../.." && pwd)/docs/screenshots"; mkdir -p "$OUT"
ST="printf '\\033]0;dev@devbox: ~/weather-api\\007'; tmux new -A -s weather-api"
run() { local D=$1 NAME=$2 WAIT=$3; shift 3
  xcrun simctl launch --terminate-running-process "$D" "${BUNDLE_ID:-com.example.agentterm}" -noLock -resetHosts \
    -testHost "$APP_HOST" -testName "Dev Server" -displayHostname devbox -testStartup "$ST" -trustHostKeys "$@" >/dev/null
  sleep "$WAIT"; xcrun simctl io "$D" screenshot "$OUT/$NAME.png" >/dev/null 2>&1; }
for pair in "$SIM_IPAD ipad" "$SIM_IPHONE iphone"; do
  read -r D P <<< "$pair"
  run "$D" "$P-1-terminal" 12 -showHosts
  run "$D" "$P-2-editor" 26 -openEditor -openFile src/server.ts -symbolCard summarise
  run "$D" "$P-3-changes" 20 -openEditor -sourceControl -openFirstChange
  run "$D" "$P-4-markdown" 18 -openEditor -openFile README.md -theme github-light
  run "$D" "$P-5-tools" 12 -checkServer
done
for f in "$OUT"/*.png; do echo "$(sips -g pixelWidth -g pixelHeight "$f" | tail -2 | awk '{print $2}' | tr '\n' 'x') $(basename "$f")"; done
