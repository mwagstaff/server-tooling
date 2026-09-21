# Per-project Node runtime and persistent data

`config/node_projects.json` supports two optional settings:

```json
{
  "node_binary": "/home/mwagstaff/.local/share/train-track-api/runtime/node24/bin/node",
  "rsync_excludes": ["/resources/timetable_full/", "/var/planner/"]
}
```

`node_binary` pins the remote executable used by both quick and full service wrappers. Its directory is prepended to the existing deployment PATH for npm, pnpm, builds and dependency pruning, including package-manager subprocesses. Install the runtime on the host first; deployment checks that it is executable and can report its Node version before preparing assets, syncing code, writing configuration or restarting services. The deployer does not install runtimes or change the system Node installation.

The path must be absolute, end in `/node`, and contain only letters, digits, underscores, dots, hyphens and slashes, without `.` or `..` path segments. Projects without `node_binary` retain the existing remote PATH and `command -v node` service selection. Asset-only operations do not require an application runtime preflight.

`rsync_excludes` adds patterns only to the application code sync. Leading `/` anchors a pattern to the project root. Excluded remote files are protected from the code sync's `--delete`; this setting does not remove old copies. The deployer does not read `.gitignore` for exclusion rules. Existing asset-bundle publishing remains separate.

On macOS, `service_scope` defaults to `user`. Set it to `system` only for a reviewed service that must run before interactive login. The deployer then installs a root-owned plist in `/Library/LaunchDaemons`, with `UserName` set to the deploying account, and manages it in launchd's `system` domain. Installation and lifecycle changes use non-interactive `sudo`; they fail clearly until administrator authorization is arranged. Linux continues to use user systemd and rejects no existing configurations.

Service `log_file` and `error_log_file` values may be absolute paths. Relative paths remain under the deployed source directory; use absolute paths for persistent logs that must survive source replacement, and configure rotation separately on the host.

For isolated TrainTrack planner measurements on the Mac Mini, run `train_track_planner_mongo.zsh check` and then `train_track_planner_mongo.zsh setup` once to provision loopback-only Mongo authentication and a database-scoped planner account. The setup refuses existing credentials or users; it stores local secrets outside synchronised source. Back up the admin password and arrange database backup/restore independently. Then `train_track_planner_mvp.zsh all` installs a checksum-verified Node 24 runtime, retains the host-local service token, deploys the user-scoped `train-track-planner-mvp` service using local Mongo, copies and activates the validated compact local snapshot, and runs authenticated original/RAPTOR smoke queries. The smoke run also checks KTH–INV, ABD–PNZ, CLK–CDB, and HHD–NRW; a direct-search timeout is recorded and retried through the longer-running queued-search path. Override the set with `PLANNER_MVP_COMPLEX_ROUTES=ORG-DST,...`. For result-cache-miss timings, run `PLANNER_MVP_ALGORITHMS=raptor PLANNER_MVP_NO_CACHE=1 PLANNER_MVP_RUNS=5 train_track_planner_mvp.zsh smoke`; this clears search-result caches before every search, without restarting workers or clearing timetable/OS caches. Use `train_track_planner_mvp.zsh load` for bounded 5/10/20/50-user RAPTOR stages with process CPU/RSS sampling, a comparison table, and Mongo-verified zero cache hits. `PLANNER_MVP_LOAD_LEVELS=5,10,20 train_track_planner_mvp.zsh load --admission-cap 20` temporarily tests a custom direct-request cap (1–100) and restores the configured value; deploy the updated service before using this flag. Failed searches, timeouts, busy responses and unverifiable cache misses produce warnings and a non-zero exit status. The MVP keeps ingestion and TubeTrack disabled, binds only to loopback, and does not change Funnel, `sky`, or the production planner target. Run `train_track_planner_mvp.zsh preflight` for a read-only readiness check and `train_track_planner_mvp.zsh smoke` to repeat measurements.

TrainTrack's validated timetable belongs in `/home/mwagstaff/.local/share/train-track-api/planner`, outside the synchronised application directory. Its `PLANNER_DATA_DIR` is saved in `static_env`, which regenerates the remote static configuration during subsequent deployments. Source timetable files and local development pointers are excluded from code deployments. Import/validation/activation are separate operations documented in the TrainTrack repository's journey-planner runbook.

## Default hosts and switches

`node_project.zsh` defaults to a quick deploy that tails stderr afterwards (`-q -e`); use `--full` / `--no-tail` to opt out. Bitwarden, assets-only and disable modes imply a full deploy.

When no host is given, each project deploys to its entry in `PROJECT_DEFAULT_HOSTS` at the top of `node_project.zsh` (falling back to `DEFAULT_DEPLOY_HOST`). Edit that mapping to move a project to another host. So `./deploy/node_project.zsh train-track-api` is equivalent to `./deploy/node_project.zsh -q -e train-track-api sky`.

## Regression checks

```bash
zsh -n deploy/node_project.zsh
python3 -m unittest discover -s deploy/tests -v
```

Tests run the actual quick/full control flow with mock SSH, rsync and notification commands. They make no network connections and do not run remote service-management commands.
