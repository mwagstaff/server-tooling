#!/usr/bin/env zsh
# Backs up sky's MongoDB to mini, one file per database, and restores from
# those backups. Runs on mini (installed as ~/.local/bin/mongo-sky by
# install-mongo-sky-backups.zsh); the mongo-backup, mongo-restore and
# mongo-backups commands call it from anywhere.
#
#   mongo-sky backup [DB...]            ad hoc backup (default: every database)
#   mongo-sky restore DB [WHEN] [--as NAME] [--yes]
#                                       put a backup back on sky; WHEN is
#                                       "latest" (default), a date (2026-10-28)
#                                       or a file name from "list"
#   mongo-sky list [DB]                 what's backed up
#   mongo-sky nightly                   every database, then prune and publish metrics
#   mongo-sky test-restore              restore each database's newest backup into
#                                       a throwaway Mongo and check every count
#
# Backups: ~/backups/mongo-sky/<db>/<UTC time>--<kind>.archive.gz, with the
# document count of every collection alongside in .counts. Kinds:
#   nightly         kept 14 days, then one a week for 8 weeks, one a month for 12 months
#   adhoc           kept 30 days
#   before-restore  what was replaced by a restore; kept 30 days
set -euo pipefail
SCRIPT=${0:A}

# MONGO_SKY_HOST=local runs against a Mongo on this machine instead (for testing).
SOURCE_HOST="${MONGO_SKY_HOST:-sky}"
SOURCE_URI="${MONGO_SKY_URI:-mongodb://127.0.0.1:27017/?directConnection=true}"
ROOT="${MONGO_SKY_BACKUP_DIR:-$HOME/backups/mongo-sky}"
TEXTFILE_DIR="${MONGO_SKY_TEXTFILE_DIR:-/opt/homebrew/var/lib/node_exporter/textfile}"
TEST_MONGOD="${MONGO_SKY_TEST_MONGOD:-/opt/homebrew/opt/mongodb-community@8.0/bin/mongod}"
TEST_PORT="${MONGO_SKY_TEST_PORT:-27199}"
SKIP_DATABASES=(admin config local)
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

log() { print -r -- "$(date -u +%H:%M:%S) $*"; }
die() { print -u2 -r -- "Error: $*"; exit 1; }
valid_db() { [[ "$1" =~ '^[A-Za-z0-9_-]{1,64}$' ]] || die "\"$1\" isn't a database name"; }
on_sky() {
  if [[ "$SOURCE_HOST" == local ]]; then zsh -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=15 "$SOURCE_HOST" "$@"; fi
}
sky_mongosh() { on_sky "mongosh --quiet --norc '$SOURCE_URI' --eval '$1'"; }
human_size() { local b=$1; (( b > 1048576 )) && print "$(( b / 1048576 )) MB" || print "$(( (b + 1023) / 1024 )) KB"; }

sky_databases() {
  local name
  for name in ${(f)"$(sky_mongosh 'db.adminCommand({listDatabases: 1}).databases.forEach(d => print(d.name))')"}; do
    (( ${SKIP_DATABASES[(Ie)$name]} )) || print -r -- "$name"
  done
}

# Live document counts on sky, as "collection count" lines.
sky_counts() {
  sky_mongosh "const d = db.getSiblingDB(\"$1\"); d.getCollectionNames().sort().forEach(c => print(c, d.getCollection(c).countDocuments()))"
}

# Dumps one database from sky into a new file here. The file only appears once
# the dump has finished and checked out, so a half-made backup is never used.
backup_db() {
  local db=$1 kind=$2 stamp dir file tmp err
  valid_db "$db"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$ROOT/$db"
  file="$dir/$stamp--$kind.archive.gz"
  mkdir -p "$dir"
  tmp="$dir/.$stamp--$kind.partial"
  err="$tmp.log"
  if ! on_sky "mongodump --uri='$SOURCE_URI' --db='$db' --archive --gzip" >"$tmp" 2>"$err"; then
    rm -f "$tmp"
    print -u2 -r -- "$(tail -5 "$err")"
    rm -f "$err"
    print -u2 "Backup of $db FAILED"
    return 1
  fi
  # "done dumping `bha.history` (28 documents)" -> "history 28"
  sed -nE "s/.*done dumping \`?$db\.([^ \`]+)\`? \(([0-9]+) documents?\).*/\1 \2/p" "$err" | sort >"$tmp.counts"
  rm -f "$err"
  if ! gzip -t "$tmp" 2>/dev/null; then
    rm -f "$tmp" "$tmp.counts"
    print -u2 "Backup of $db FAILED: the file is damaged"
    return 1
  fi
  mv "$tmp.counts" "${file%.archive.gz}.counts"
  mv "$tmp" "$file"
  log "$db: $(human_size $(stat -f %z "$file")), $(wc -l <"${file%.archive.gz}.counts" | tr -d ' ') collections -> ${file#$ROOT/}"
}

backups_of() { # newest first; restore leaves out its own safety copies unless asked
  local db=$1
  [[ -d "$ROOT/$db" ]] || return 0
  print -l "$ROOT/$db"/*.archive.gz(N.) | sort -r
}

find_backup() {
  local db=$1 when=${2:-latest} candidates
  candidates=(${(f)"$(backups_of "$db")"})
  (( ${#candidates} )) || die "there are no backups of $db"
  case "$when" in
    latest) candidates=(${candidates:#*--before-restore.archive.gz}) ;;
    <->-<->-<->) candidates=(${(M)${candidates:#*--before-restore.archive.gz}:#*/${when//-/}T*}) ;;
    *) candidates=(${(M)candidates:#*/${when%.archive.gz}.archive.gz}) ;;
  esac
  (( ${#candidates} )) || die "no backup of $db matches \"$when\" (see: mongo-backups $db)"
  print -r -- "${candidates[1]}"
}

describe() { # 20261028T033000Z--nightly.archive.gz -> 2026-10-28 03:30:00 UTC (nightly)
  local name=${1:t} m
  m=(${(s:--:)${name%.archive.gz}})
  print -r -- "${m[1][1,4]}-${m[1][5,6]}-${m[1][7,8]} ${m[1][10,11]}:${m[1][12,13]}:${m[1][14,15]} UTC (${m[2]})"
}

cmd_backup() {
  local dbs=("$@") failed=0 db existing
  existing=(${(f)"$(sky_databases)"}) || die "couldn't list the databases on $SOURCE_HOST"
  (( ${#dbs} )) || dbs=($existing)
  for db in $dbs; do
    valid_db "$db"
    if (( ! ${existing[(Ie)$db]} )); then print -u2 "$db: there's no such database on $SOURCE_HOST"; failed=1; continue; fi
    backup_db "$db" adhoc || failed=1
  done
  write_metrics
  return $failed
}

cmd_list() {
  local db dbs file
  dbs=("$@")
  (( ${#dbs} )) || dbs=("$ROOT"/*(N/:t))
  (( ${#dbs} )) || { print "No backups yet in $ROOT"; return; }
  for db in $dbs; do
    valid_db "$db"
    print "$db"
    for file in ${(f)"$(backups_of "$db")"}; do
      [[ -n "$file" ]] && printf '  %-44s %8s  %s\n' "${file:t}" "$(human_size $(stat -f %z "$file"))" "$(describe "$file")"
    done
  done
}

# Replaces database $3 on sky with $2 from backup file $1, and checks every
# collection came back with the documents counted when it was backed up.
restore_into() {
  local file=$1 from=$2 into=$3 restored
  sky_mongosh "db.getSiblingDB(\"$into\").dropDatabase()" >/dev/null
  on_sky "mongorestore --uri='$SOURCE_URI' --archive --gzip --nsInclude='$from.*' --nsFrom='$from.*' --nsTo='$into.*' --quiet" <"$file" ||
    { print -u2 "Restoring into $into failed"; return 1; }
  restored=$(sky_counts "$into")
  if [[ "$into" == *__restore_check ]]; then sky_mongosh "db.getSiblingDB(\"$into\").dropDatabase()" >/dev/null; fi
  if [[ "$restored" != "$(<"${file%.archive.gz}.counts")" ]]; then
    print -u2 "The backup didn't restore cleanly (the counts differ), so nothing was changed:"
    diff <(<"${file%.archive.gz}.counts") <(print -r -- "$restored") | sed 's/^/    /' >&2
    return 1
  fi
}

cmd_restore() {
  local db="" when="" target="" yes=0 file answer
  while (( $# )); do
    case "$1" in
      --as) target=${2:-}; shift ;;
      --yes|-y) yes=1 ;;
      -*) die "unknown option $1" ;;
      *) if [[ -z "$db" ]]; then db=$1; elif [[ -z "$when" ]]; then when=$1; else die "too many arguments"; fi ;;
    esac
    shift
  done
  [[ -n "$db" ]] || die "usage: mongo-restore DB [latest|YYYY-MM-DD|FILE] [--as NAME] [--yes]"
  valid_db "$db"
  target=${target:-$db}
  valid_db "$target"
  file=$(find_backup "$db" "${when:-latest}") || exit 1
  [[ -s "$file" && -s "${file%.archive.gz}.counts" ]] || die "no usable backup of $db was found, so nothing was changed"

  print "Restore $db from the backup taken $(describe "$file")"
  print "  into the database \"$target\" on $SOURCE_HOST, replacing everything in it."
  print "\n  In the backup:"
  sed 's/^/    /' "${file%.archive.gz}.counts"
  print "\n  On $SOURCE_HOST now:"
  sky_counts "$target" | sed 's/^/    /'
  if (( ! yes )); then
    print -n "\nType \"$target\" to go ahead: "
    read -r answer
    [[ "$answer" == "$target" ]] || die "nothing was changed"
  fi

  # The backup is first restored into a temporary database and checked, so a
  # bad file can never leave the real one empty.
  restore_into "$file" "$db" "${target}__restore_check"

  # What's there now is kept first, so the restore can itself be undone.
  if [[ -n "$(sky_counts "$target")" ]]; then
    backup_db "$target" before-restore || die "couldn't back up $target first, so nothing was changed"
  fi
  [[ -s "$file" ]] || die "the backup file has gone, so nothing was changed"
  log "Restoring..."
  if ! restore_into "$file" "$db" "$target"; then
    local safety=$(backups_of "$target" | grep -- '--before-restore' | head -1)
    die "the restore FAILED part-way.${safety:+ The previous contents are in $safety; put them back with: mongo-restore $target ${safety:t}}"
  fi
  print "\nDone. \"$target\" on $SOURCE_HOST now has:"
  sky_counts "$target" | sed 's/^/    /'
  write_metrics
}

# 14 daily, then the newest per ISO week for 8 weeks and per month for 12 months.
# Ad hoc backups and safety copies are kept for 30 days.
prune() {
  local db file name day week month keep
  local -A weeks months
  for db in "$ROOT"/*(N/:t); do
    weeks=() months=()
    local -i dailies=0
    for file in ${(f)"$(backups_of "$db")"}; do
      [[ -n "$file" ]] || continue
      name=${file:t}
      if [[ "$name" == *--nightly.archive.gz ]]; then
        day=${name[1,8]}
        week=$(date -j -f %Y%m%d "$day" +%G-%V)
        month=${day[1,6]}
        keep=0
        (( ++dailies <= 14 )) && keep=1
        if [[ -z "${weeks[$week]:-}" ]] && (( ${#weeks} < 8 )); then weeks[$week]=1; keep=1; fi
        if [[ -z "${months[$month]:-}" ]] && (( ${#months} < 12 )); then months[$month]=1; keep=1; fi
        (( keep )) || { rm -f "$file" "${file%.archive.gz}.counts"; log "pruned ${file#$ROOT/}"; }
      elif [[ -n "$(find "$file" -mtime +30)" ]]; then
        rm -f "$file" "${file%.archive.gz}.counts"
        log "pruned ${file#$ROOT/}"
      fi
    done
  done
}

# For the monitoring on mini (node_exporter's textfile collector).
write_metrics() {
  [[ -d "$TEXTFILE_DIR" ]] || return 0
  local out="$TEXTFILE_DIR/mongo_backup.prom" db newest
  {
    print '# HELP mongo_backup_last_success_timestamp_seconds When the last nightly backup of every database finished.'
    print '# TYPE mongo_backup_last_success_timestamp_seconds gauge'
    [[ -f "$ROOT/.last-nightly-success" ]] && print "mongo_backup_last_success_timestamp_seconds{source=\"$SOURCE_HOST\"} $(<"$ROOT/.last-nightly-success")"
    print '# HELP mongo_backup_database_newest_timestamp_seconds When the newest backup of each database was made.'
    print '# TYPE mongo_backup_database_newest_timestamp_seconds gauge'
    print '# HELP mongo_backup_database_newest_size_bytes Size of the newest backup of each database.'
    print '# TYPE mongo_backup_database_newest_size_bytes gauge'
    for db in "$ROOT"/*(N/:t); do
      newest=$(backups_of "$db" | grep -v -- '--before-restore' | head -1)
      [[ -n "$newest" ]] || continue
      print "mongo_backup_database_newest_timestamp_seconds{source=\"$SOURCE_HOST\",database=\"$db\"} $(stat -f %m "$newest")"
      print "mongo_backup_database_newest_size_bytes{source=\"$SOURCE_HOST\",database=\"$db\"} $(stat -f %z "$newest")"
    done
    print '# HELP mongo_backup_restore_test_last_success_timestamp_seconds When every database last passed a test restore.'
    print '# TYPE mongo_backup_restore_test_last_success_timestamp_seconds gauge'
    [[ -f "$ROOT/.last-restore-test-success" ]] && print "mongo_backup_restore_test_last_success_timestamp_seconds{source=\"$SOURCE_HOST\"} $(<"$ROOT/.last-restore-test-success")"
  } >"$out.tmp"
  mv "$out.tmp" "$out"
}

# Runs a command while holding the lock. The command runs as a separate
# process, so however it ends (zsh skips EXIT traps when set -e stops a
# script) the lock is released and any throwaway test Mongo is stopped
# afterwards. It must be a separate process, not a ( subshell ) || ...:
# zsh switches set -e off inside the left side of ||, and then a failed
# step (such as finding no backup) would carry on to the next.
TEST_DIR="$ROOT/.restore-test"
with_lock() {
  local lock="$ROOT/.lock" rc=0
  mkdir -p "$ROOT"
  mkdir "$lock" 2>/dev/null || die "another backup, restore or restore test is running (remove $lock if not)"
  zsh "$SCRIPT" __locked "$@" || rc=$?
  if [[ -d "$TEST_DIR" ]]; then
    mongosh --quiet --norc "mongodb://127.0.0.1:$TEST_PORT/admin" --eval 'db.shutdownServer()' >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
  fi
  rmdir "$lock"
  return $rc
}

cmd_nightly() {
  local failed=0 db dbs
  log "Nightly backup of $SOURCE_HOST"
  dbs=(${(f)"$(sky_databases)"}) || die "couldn't list the databases on $SOURCE_HOST"
  (( ${#dbs} )) || die "no databases found on $SOURCE_HOST"
  for db in $dbs; do backup_db "$db" nightly || failed=1; done
  prune
  (( failed )) || date +%s >"$ROOT/.last-nightly-success"
  write_metrics
  (( failed )) && die "at least one database wasn't backed up"
  log "All ${#dbs} databases backed up"
}

# Every database's newest backup, restored into a throwaway Mongo; each
# collection must come back with exactly the documents counted when it was dumped.
cmd_test_restore() {
  local tmp=$TEST_DIR failed=0 tested=0 db file restored expected
  rm -rf "$tmp"
  mkdir -p "$tmp"
  # macOS starts processes (launchd jobs and ssh sessions alike) with 256 open
  # files, and Mongo aborts with "Too many open files" once a few databases
  # with many collections and indexes are loaded.
  ulimit -n 10240
  "$TEST_MONGOD" --dbpath "$tmp" --port "$TEST_PORT" --bind_ip 127.0.0.1 --logpath "$tmp/mongod.log" --fork >/dev/null
  for db in "$ROOT"/*(N/:t); do
    file=$(backups_of "$db" | grep -v -- '--before-restore' | head -1)
    [[ -n "$file" ]] || continue
    if ! mongorestore --uri="mongodb://127.0.0.1:$TEST_PORT" --archive="$file" --gzip --quiet 2>"$tmp/restore.log"; then
      print -u2 "$db: restore FAILED ($(tail -1 "$tmp/restore.log"))"; failed=1; continue
    fi
    restored=$(mongosh --quiet --norc "mongodb://127.0.0.1:$TEST_PORT/$db" --eval 'db.getCollectionNames().sort().forEach(c => print(c, db.getCollection(c).countDocuments()))')
    expected=$(<"${file%.archive.gz}.counts")
    (( ++tested ))
    if [[ "$restored" == "$expected" ]]; then
      log "$db: ${file:t} restored, $(print -r -- "$expected" | grep -c .) collections, every count matches"
    else
      print -u2 "$db: ${file:t} restored, but the counts differ"
      diff <(print -r -- "$expected") <(print -r -- "$restored") | sed 's/^/    /' >&2
      failed=1
    fi
  done
  (( tested )) || { print -u2 "There were no backups to test"; failed=1; }
  (( failed )) || date +%s >"$ROOT/.last-restore-test-success"
  write_metrics
  (( failed )) && die "at least one backup didn't restore cleanly"
  log "The newest backups of all $tested databases restore cleanly"
}

case "${1:-}" in
  __locked) shift; "$@" ;; # internal: see with_lock
  backup) shift; with_lock cmd_backup "$@" ;;
  restore) shift; with_lock cmd_restore "$@" ;;
  list) shift; cmd_list "$@" ;;
  nightly) with_lock cmd_nightly ;;
  test-restore) with_lock cmd_test_restore ;;
  *) sed -n '2,22p' "$SCRIPT" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
