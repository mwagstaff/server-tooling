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

For the TrainTrack planner on the Mac Mini, run `train_track_planner_mongo.zsh check` and then `train_track_planner_mongo.zsh setup` once to provision loopback-only Mongo authentication and a database-scoped planner account. The setup refuses existing credentials or users; it stores local secrets outside synchronised source. Back up the admin password and arrange database backup/restore independently. `train_track_planner.zsh all` installs a checksum-verified Node 24 runtime, retains the host-local service token, deploys the user-scoped `train-track-planner` service using local Mongo, retains Mini's managed timetable when ingestion is enabled, and runs authenticated RAPTOR smoke queries. The smoke run also checks KTH–INV, ABD–PNZ, CLK–CDB, and HHD–NRW; a direct-search timeout is recorded and retried through the longer-running queued-search path. Override the set with `PLANNER_SERVICE_COMPLEX_ROUTES=ORG-DST,...`. For result-cache-miss timings, run `PLANNER_SERVICE_NO_CACHE=1 PLANNER_SERVICE_RUNS=5 train_track_planner.zsh smoke`; this clears search-result caches before every search, without restarting workers or clearing timetable/OS caches. Use `train_track_planner.zsh load` for bounded 5/10/20/50-user RAPTOR stages with process CPU/RSS sampling, a comparison table, and Mongo-verified zero cache hits. `PLANNER_SERVICE_LOAD_LEVELS=5,10,20 train_track_planner.zsh load --admission-cap 20` temporarily tests a custom direct-request cap (1–100) and restores the configured value; deploy the updated service before using this flag. Failed searches, timeouts, busy responses and unverifiable cache misses produce warnings and a non-zero exit status. The planner runs managed ingestion and TubeTrack, binds to loopback, and is the sole planner execution target behind Sky's gateway. Interactive searches default to RAPTOR and explicit Original requests are rejected; saved-route board and disruption calculations may still use legacy routing. Run `train_track_planner.zsh preflight` for a read-only readiness check and `train_track_planner.zsh smoke` to repeat measurements.

Use `train_track_planner.zsh jobs-load` to exercise the queued `/search-jobs` API separately from direct search: the default run submits bursts of 5, 10 and 20 users, then sustains 20 virtual users for 60 seconds. `--levels`, `--users` and `--duration-seconds` adjust those stages; zero duration skips the sustained stage. Each virtual user has at most one outstanding job. The report includes submit-to-result latency, server queue time, planner CPU/RSS and whole-host CPU, memory-pressure free percentage and swap. It verifies zero result-cache hits in Mongo and returns non-zero for failures or timeouts. This authenticated loopback test uses distinct simulated caller networks to bypass the separate four-jobs-per-network safeguard, so it does not validate users sharing a carrier NAT. The default queued-job limit is 20; routing workers and the direct-search cap are unchanged.

TrainTrack's live validated timetable belongs in Mini's `/Users/mwagstaff/.local/share/train-track-planner/planner`, outside the synchronised application directory. Its `PLANNER_DATA_DIR` is saved in `static_env`, which regenerates the remote static configuration during subsequent deployments. Sky's old timetable files are inactive recovery data; Sky's embedded planner and ingestion are disabled. Source timetable files and local development pointers are excluded from code deployments. Import/validation/activation are separate operations documented in the TrainTrack repository's journey-planner runbook.

## Default hosts and switches

`node_project.zsh` defaults to a quick deploy that tails stderr afterwards (`-q -e`); use `--full` / `--no-tail` to opt out. Bitwarden, assets-only and disable modes imply a full deploy.

When no host is given, each project deploys to its entry in `PROJECT_DEFAULT_HOSTS` at the top of `node_project.zsh` (falling back to `DEFAULT_DEPLOY_HOST`). Edit that mapping to move a project to another host. So `./deploy/node_project.zsh train-track-api` is equivalent to `./deploy/node_project.zsh -q -e train-track-api sky`.

`./deploy/node_project.zsh journey-planner` selects the `train-track-journey-planner` project and deploys to `mini` by default. `train-track-planner` is an alias for the same project. The checkout is `/Users/mwagstaff/dev/train-track-planner`, the user LaunchAgent is `com.train-track-planner.api`, and the monitoring job is `train-track-planner`. Use `--no-tail` for a one-shot deploy. There is only one planner service definition. `metrics_port: false` keeps full deploys from attempting a Grafana import; Sky scrapes the authenticated Funnel endpoint through the dedicated monitoring setup. System-service startup remains a separate operational migration requiring administrator authorization and validated Mongo/Funnel/FileVault startup dependencies.

Bitwarden sync atomically replaces the project's private env file; it does not merge host-local values. For this project, `required_bitwarden_env` in `config/node_projects.json` makes a full deploy stop before replacing that file if a required tagged item is missing. The `Apps` field on each item should include `train-track-journey-planner`. Store Mini's working Mongo URI as `MONGODB_URI_JOURNEY_PLANNER` (the previous `MONGODB_URI_TRAIN_TRACK_UK` is accepted only during migration), and store the service token (which must match Sky's `PLANNER_MINI_SERVICE_TOKEN`) and timetable S3 keys in Bitwarden before the next full Bitwarden deploy. Until then, the existing LaunchAgent remains healthy and quick deploys leave its existing secret file untouched. The public live departure board uses `LIVE_DEPARTURE_BOARD_API_KEY`; staff-board recovery uses `LIVE_DEPARTURE_BOARD_STAFF_VERSION_API_KEY` (falling back to `STAFF_DEPARTURES_API_KEY`). A public-board 401 is not fixed by changing the staff-board key.

## Alerting

Prometheus alert rules and Alertmanager (email via Plunk) are documented in
[`monitoring/README.md`](../monitoring/README.md). In short: `monitoring/install-alerting.zsh sky`
installs or updates Alertmanager and the generic rules (`TargetDown`, and
`AppCheckFailing` on the cross-app gauge `app_check_ok{check="..."}`); a full
deploy installs a project's `observability/prometheus/rules.yml` as
`~/monitoring/rules/<job>.yml` via `monitoring/configure-prometheus-rules.sh`.
New apps also need a ufw rule allowing the Prometheus Docker subnet to reach
their metrics port and must not bind `127.0.0.1` only.

## Regression checks

```bash
zsh -n deploy/node_project.zsh
python3 -m unittest discover -s deploy/tests -v
```

Tests run the actual quick/full control flow with mock SSH, rsync and notification commands. They make no network connections and do not run remote service-management commands.
