# App Store screenshots

Staged against a demo project on a test server, with a neutral host name (`devbox`), so no real
hosts appear. Debug builds only (the launch arguments they use are `#if DEBUG`).

1. `make-demo.sh` (run on the server): creates `/tmp/projects/weather-api` with a git history, one
   uncommitted change and a deliberate type error. Then `npm install --no-save @types/node@20
   typescript@6.0.3` there for the language server.
2. `stage.sh` (on the server): a `weather-api` tmux session with git log and tests beside htop.
   Never uses an existing session.
3. Simulators: iPad Pro 13-inch and iPhone 6.9-inch (16 Pro Max) on the current iOS, the Debug
   app installed, its key (`-printPublicKey`) in the server's `authorized_keys`, and
   `xcrun simctl status_bar <udid> override --time 9:41 --batteryState discharging --batteryLevel 100 --wifiBars 3`.
4. `shots.sh`, then `terminal-shots.sh`, with `SSH_HOST`, `APP_HOST`, `SIM_IPAD` and `SIM_IPHONE`
   set. They write `docs/screenshots/{ipad,iphone}-N-*.png` at App Store sizes.
