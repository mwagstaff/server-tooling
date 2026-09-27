#!/usr/bin/env zsh
set -euo pipefail

HOST="${PLANNER_MONGO_HOST:-mini}"
ACTION="${1:-check}"

case "$ACTION" in
  check|setup) ;;
  *) print -u2 'Usage: train_track_planner_mongo.zsh check|setup'; exit 2 ;;
esac

ssh -o ConnectTimeout=10 "$HOST" zsh -s -- "$ACTION" <<'REMOTE'
set -euo pipefail

action="$1"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
config='/opt/homebrew/etc/mongod.conf'
admin_secret="$HOME/.local/share/train-track-planner/mongodb-admin.password"
planner_secret="$HOME/dev/train-track-planner/.bw-secrets.planner.env.sh"
database='train_track_planner'
user='planner_service'

[[ -f "$config" && ! -L "$config" && -w "$config" ]] || {
  print -u2 'Mini Mongo configuration is missing, linked, or not writable by the current user.'; exit 1
}
[[ "$(brew services list | awk '$1 == "mongodb-community@8.0" { print $2 }')" == started ]] || {
  print -u2 'Mini Homebrew Mongo service is not started.'; exit 1
}
if [[ "$action" == check ]]; then
  sed -n '/^[[:space:]]*bindIp:/p; /^[[:space:]]*authorization:/p' "$config"
  [[ -f "$admin_secret" ]] && print 'admin credential=present' || print 'admin credential=absent'
  [[ -f "$planner_secret" ]] && print 'planner credential=present' || print 'planner credential=absent'
  exit 0
fi
[[ "$(mongosh --quiet --norc --eval 'db.adminCommand({getCmdLineOpts:1}).parsed.net.bindIp')" == '127.0.0.1, ::1' ]] || {
  print -u2 'Mongo is not bound exclusively to the expected loopback interfaces.'; exit 1
}

[[ ! -e "$admin_secret" && ! -e "$planner_secret" && ! -L "$admin_secret" && ! -L "$planner_secret" ]] || {
  print -u2 'Planner or Mongo credentials already exist; refusing to rotate or overwrite them.'; exit 1
}
[[ ! -e "$HOME/dev/train-track-planner" || -d "$HOME/dev/train-track-planner" ]] || {
  print -u2 'Planner deployment path is not a directory.'; exit 1
}
[[ -z "$(sed -n '/^[[:space:]]*security:/p' "$config")" ]] || {
  print -u2 'Mongo security configuration already exists; inspect it before continuing.'; exit 1
}
[[ "$(mongosh --quiet --norc --eval 'print(db.adminCommand({getCmdLineOpts:1}).parsed.security?.authorization ?? "disabled")')" == disabled ]] || {
  print -u2 'Mongo authorization is already configured; inspect it before continuing.'; exit 1
}
[[ "$(mongosh --quiet --norc --eval '
  print(db.adminCommand({listDatabases:1}).databases.reduce((count, item) =>
    count + db.getSiblingDB(item.name).getUsers().users.length, 0))
')" == 0 ]] || {
  print -u2 'Mongo already has users; refusing to provision over an existing installation.'; exit 1
}

umask 077
mkdir -p "${admin_secret:h}" "${planner_secret:h}"
admin_password="$(openssl rand -hex 32)"
planner_password="$(openssl rand -hex 32)"
token="$(openssl rand -hex 32)"
print -r -- "$admin_password" > "$admin_secret"
print -r -- "# Mini-local planner credentials; back up outside the deployment checkout." > "$planner_secret"
print -r -- "export MONGODB_URI_TRAIN_TRACK_UK=mongodb://$user:$planner_password@127.0.0.1:27017/$database?authSource=$database" >> "$planner_secret"
print -r -- "export PLANNER_SERVICE_TOKEN=$token" >> "$planner_secret"
chmod 600 "$admin_secret" "$planner_secret"

MONGO_ADMIN_PASSWORD="$admin_password" MONGO_PLANNER_PASSWORD="$planner_password" mongosh --quiet --norc --eval '
  const admin = db.getSiblingDB("admin");
  admin.createUser({user:"planner_admin", pwd:process.env.MONGO_ADMIN_PASSWORD,
    roles:[{role:"root", db:"admin"}]});
  db.getSiblingDB("train_track_planner").createUser({user:"planner_service",
    pwd:process.env.MONGO_PLANNER_PASSWORD,
    roles:[{role:"readWrite", db:"train_track_planner"}]});
' >/dev/null

print -r -- $'\nsecurity:\n  authorization: enabled' >> "$config"
brew services restart mongodb-community@8.0 >/dev/null

for attempt in {1..20}; do
  if MONGO_PLANNER_PASSWORD="$planner_password" mongosh --quiet --norc "$database" \
      --eval 'db.auth("planner_service", process.env.MONGO_PLANNER_PASSWORD); if (db.runCommand({connectionStatus:1}).authInfo.authenticatedUsers.length !== 1) quit(1)' \
      >/dev/null 2>&1; then break; fi
  sleep 1
done
MONGO_PLANNER_PASSWORD="$planner_password" mongosh --quiet --norc "$database" \
  --eval 'db.auth("planner_service", process.env.MONGO_PLANNER_PASSWORD); if (db.runCommand({connectionStatus:1}).authInfo.authenticatedUsers.length !== 1) quit(1)' >/dev/null
if mongosh --quiet --norc "$database" --eval 'db.runCommand({listCollections:1})' >/dev/null 2>&1; then
  print -u2 'Unauthenticated reads are still allowed; inspect Mini Mongo.'; exit 1
fi
print 'Mini Mongo is loopback-only, authorization is enabled, and planner credentials authenticate.'
print "Admin password: $admin_secret (back up securely)"
print "Planner environment: $planner_secret (mode 600; excluded from rsync)"
REMOTE
