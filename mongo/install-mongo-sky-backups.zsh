#!/usr/bin/env zsh
# Installs the sky -> mini Mongo backups (see mongo-sky.zsh). Run from this
# repository on your laptop; safe to run again after changing the scripts.
#
#   mongo/install-mongo-sky-backups.zsh
#
# On mini:  ~/.local/bin/mongo-sky and the mongo-backup, mongo-restore and
#           mongo-backups commands; launchd jobs for the nightly backup
#           (03:30) and the weekly test restore (Sundays 05:00); logs in
#           ~/backups/mongo-sky/logs.
# Here:     the same three commands in ~/.local/bin, linked to this repository,
#           so they run on mini over ssh.
set -euo pipefail

BACKUP_HOST="${MONGO_SKY_BACKUP_HOST:-mini}"
here=${0:A:h}

print "==> Installing on $BACKUP_HOST"
ssh "$BACKUP_HOST" 'mkdir -p ~/.local/bin ~/backups/mongo-sky/logs ~/Library/LaunchAgents'
scp -q "$here/mongo-sky.zsh" "$BACKUP_HOST:.local/bin/mongo-sky"
scp -q "$here/bin/mongo-backup" "$here/bin/mongo-restore" "$here/bin/mongo-backups" "$BACKUP_HOST:.local/bin/"
ssh "$BACKUP_HOST" 'chmod +x ~/.local/bin/mongo-sky ~/.local/bin/mongo-backup ~/.local/bin/mongo-restore ~/.local/bin/mongo-backups'

# One launchd job per schedule. $1 label, $2 mongo-sky command, $3 calendar interval.
ssh "$BACKUP_HOST" zsh -s <<'REMOTE'
set -euo pipefail
job() {
  local label=$1 command=$2 when=$3 plist="$HOME/Library/LaunchAgents/$1.plist"
  cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$HOME/.local/bin/mongo-sky</string><string>$command</string></array>
  <key>StartCalendarInterval</key>
  <dict>$when</dict>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StandardOutPath</key><string>$HOME/backups/mongo-sky/logs/$command.log</string>
  <key>StandardErrorPath</key><string>$HOME/backups/mongo-sky/logs/$command.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  print "    $label: $command"
}
job com.mike.mongo-sky-backup nightly '<key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer>'
job com.mike.mongo-sky-restore-test test-restore '<key>Weekday</key><integer>0</integer><key>Hour</key><integer>5</integer><key>Minute</key><integer>0</integer>'
REMOTE

print "==> Linking the commands into ~/.local/bin here"
mkdir -p "$HOME/.local/bin"
for name in mongo-backup mongo-restore mongo-backups; do ln -sf "$here/bin/$name" "$HOME/.local/bin/$name"; done
print "Done. Try: mongo-backups"
