#!/bin/sh
# A demo tmux session for screenshots: never touches "main".
S=weather-api; D=/tmp/projects/weather-api
tmux kill-session -t $S 2>/dev/null
tmux new -d -s $S -n code -c $D -x 200 -y 60
P='export PS1="\[\e[1;32m\]dev@devbox\[\e[0m\]:\[\e[1;34m\]~/weather-api\[\e[0m\]\$ "; clear'
tmux send-keys -t $S:code "$P" Enter
tmux send-keys -t $S:code "git log --oneline --graph --decorate -6 && npm test --silent" Enter
tmux split-window -h -t $S:code -c $D
tmux send-keys -t $S:code.1 "$P" Enter
tmux send-keys -t $S:code.1 "htop -t" Enter
tmux new-window -d -t $S -n server -c $D
tmux send-keys -t $S:server "$P" Enter
tmux select-window -t $S:code
tmux select-pane -t $S:code.0
