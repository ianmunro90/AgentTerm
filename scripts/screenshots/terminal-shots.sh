#!/bin/bash
# Needs: SSH_HOST (ssh alias of the demo server), APP_HOST (user@host:port as the app connects),
# BUNDLE_ID (the app's bundle ID), SIM_IPAD and SIM_IPHONE (booted simulator UDIDs, iPad 13" and iPhone 6.9", the app installed and
# its key authorized). See README.md here.
: "${SSH_HOST:?}" "${APP_HOST:?}" "${SIM_IPAD:?}" "${SIM_IPHONE:?}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
OUT="$(cd "$(dirname "$0")/../.." && pwd)/docs/screenshots"
ST="printf '\\033]0;dev@devbox: ~/weather-api\\007'; tmux new -A -s weather-api"
redraw() { # after the app attaches: redraw at its width, devbox in the status bar
  ssh "$SSH_HOST" 'tmux set -t weather-api status-right "\"devbox\" 09:41 25-Oct-26" >/dev/null
    tmux send-keys -t weather-api:code.0 C-l "clear; git log --oneline --graph --decorate -6 && npm test --silent" Enter'"$1"; }
shot() { local D=$1 NAME=$2; shift 2
  xcrun simctl launch --terminate-running-process "$D" "${BUNDLE_ID:-com.example.agentterm}" -noLock -noFocus -resetHosts \
    -testHost "$APP_HOST" -testName "Dev Server" -displayHostname devbox -testStartup "$ST" -trustHostKeys "$@" >/dev/null; }
# iPad: both panes, sidebar showing.
shot $SIM_IPAD x -showHosts; sleep 10; redraw ""; sleep 4
xcrun simctl io $SIM_IPAD screenshot "$OUT/ipad-1-terminal.png" >/dev/null 2>&1
# iPhone: the session list, then the terminal with the left pane zoomed.
mv "$OUT/iphone-1-terminal.png" "$OUT/iphone-6-sessions.png" 2>/dev/null
shot $SIM_IPHONE x; sleep 10; redraw "; tmux resize-pane -Z -t weather-api:code.0"; sleep 4
xcrun simctl io $SIM_IPHONE screenshot "$OUT/iphone-1-terminal.png" >/dev/null 2>&1
ssh "$SSH_HOST" 'tmux resize-pane -Z -t weather-api:code.0'   # unzoom
