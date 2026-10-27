# Mongo backups (sky → mini)

Every database in sky's Mongo is backed up to mini each night, one file per
database, by [`mongo-sky.zsh`](mongo-sky.zsh). New databases are picked up
automatically.

| | |
|---|---|
| Where | mini: `~/backups/mongo-sky/<database>/<UTC time>--<kind>.archive.gz`, with each collection's document count in a `.counts` file alongside |
| When | 03:30 nightly (`com.mike.mongo-sky-backup`); test restore Sundays 05:00 (`com.mike.mongo-sky-restore-test`) |
| Kept | nightly: 14 days, then one a week for 8 weeks and one a month for 12 months; ad hoc and before-restore copies: 30 days |
| Logs | mini: `~/backups/mongo-sky/logs/nightly.log`, `test-restore.log` |
| Alerts | `MongoBackupStale` (no complete nightly for 26 hours) and `MongoRestoreTestStale` (no passing test restore for 8 days), in [`monitoring/platform/auxiliary-mini.json`](../monitoring/platform/auxiliary-mini.json), from the metrics in mini's `node_exporter` textfile `mongo_backup.prom` |

Mini pulls from sky over ssh (`mongodump --archive --gzip`, streamed straight
to mini, so nothing is written on sky). sky's Mongo has no logins; if they're
turned on, give the job a user with the `backup` role (and `restore` for
restores).

Each nightly file is checked as it's written. Once a week every database's
newest backup is restored into a throwaway Mongo on mini, and every
collection must come back with exactly the documents counted when it was
dumped.

## Commands

From your laptop (they run on mini over ssh) or on mini:

```bash
mongo-backups                 # everything that's backed up
mongo-backups bha             # one database's backups
mongo-backup bha              # an ad hoc backup now (no name: every database)
mongo-restore bha             # put bha's latest backup back on sky
mongo-restore bha 2026-10-28  # the newest backup from that day
mongo-restore bha 20261028T033000Z--nightly.archive.gz
mongo-restore bha --as bha_check   # restore alongside, to look before replacing
```

`mongo-restore` shows what's in the backup and on sky now, and asks you to
type the database name (`--yes` skips this). Then it:

1. restores the backup into a temporary database on sky and checks every
   count, so a bad file never touches the real database;
2. backs up what's on sky now (a `before-restore` copy, so the restore can
   itself be undone with `mongo-restore DB <that file>`);
3. replaces the database and checks the counts again.

Database users (stored in `admin`) aren't affected. Apps that cache data, like
the BHA website, pick up the restored data within a minute.

## Install or update

```bash
mongo/install-mongo-sky-backups.zsh
```

Copies the script and commands to mini, (re)loads both launchd jobs, and links
the commands into `~/.local/bin` here. After changing the alert rules, deploy
the monitoring platform as described in `monitoring/platform/README.md`.

## Testing changes

`MONGO_SKY_HOST=local MONGO_SKY_URI=mongodb://127.0.0.1:<port>/?directConnection=true`
points the script at a throwaway Mongo on the same machine instead of sky, and
`MONGO_SKY_BACKUP_DIR` / `MONGO_SKY_TEXTFILE_DIR` at scratch folders. Test
restores there, never against sky. Start throwaway Mongos with `ulimit -n 10240`:
macOS's default of 256 open files makes Mongo abort once a few databases with
many collections are loaded.

The older `backup.sh` (kidsplorers only, kept on sky for 14 days, from
`~/backup-kidsplorers-mongo.sh` in sky's crontab) can be retired once these
backups have run cleanly for a week or two.
