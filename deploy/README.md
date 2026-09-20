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

TrainTrack's validated timetable belongs in `/home/mwagstaff/.local/share/train-track-api/planner`, outside the synchronised application directory. Its `PLANNER_DATA_DIR` is saved in `static_env`, which regenerates the remote static configuration during subsequent deployments. Source timetable files and local development pointers are excluded from code deployments. Import/validation/activation are separate operations documented in the TrainTrack repository's journey-planner runbook.

## Default hosts and switches

`node_project.zsh` defaults to a quick deploy that tails stderr afterwards (`-q -e`); use `--full` / `--no-tail` to opt out. Bitwarden, assets-only and disable modes imply a full deploy.

When no host is given, each project deploys to its entry in `PROJECT_DEFAULT_HOSTS` at the top of `node_project.zsh` (falling back to `DEFAULT_DEPLOY_HOST`). Edit that mapping to move a project to another host. So `./deploy/node_project.zsh train-track-api` is equivalent to `./deploy/node_project.zsh -q -e train-track-api sky`.

## Regression checks

```bash
rtk proxy zsh -n deploy/node_project.zsh
rtk proxy python3 -m unittest discover -s deploy/tests -v
```

Tests run the actual quick/full control flow with mock SSH, rsync and notification commands. They make no network connections and do not run remote service-management commands.
