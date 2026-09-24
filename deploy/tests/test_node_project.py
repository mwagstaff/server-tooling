"""Run real quick/full deployment control flow with SSH and rsync replaced.

No network calls, remote commands, service changes or notifications are executed.
Run: python3 -m unittest discover -s deploy/tests -v
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


DEPLOY = Path(__file__).resolve().parents[1]
DEFAULT_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
PIN = "/opt/private-node24/bin/node"

MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
body = sys.stdin.read() if name in ("ssh", "osascript") else ""
with open(os.environ["DEPLOY_TEST_LOG"], "a") as log:
    log.write(json.dumps({"name": name, "args": sys.argv[1:], "stdin": body}) + "\n")
command = " ".join(sys.argv[1:])
if name == "ssh":
    if "process.versions.node" in command:
        if os.environ.get("DEPLOY_TEST_NODE_MISSING") == "1": sys.exit(1)
        print("24.21.0")
    elif "current_found=1" in command:
        print("1 0")
    elif "curl -sS" in command:
        print('{"status":"ok"}')
'''

TAIL_STUB = r"""#!/usr/bin/env zsh
python3 -c 'import json, os, sys; open(os.environ["DEPLOY_TEST_LOG"], "a").write(json.dumps({"name": "tail", "args": sys.argv[1:], "stdin": ""}) + "\n")' "$@"
"""

BW_STUB = r'''#!/usr/bin/env python3
import os, sys
if "status" in sys.argv:
    print('{"status":"unlocked"}')
elif "list" in sys.argv and "items" in sys.argv:
    print(os.environ["DEPLOY_TEST_BW_ITEMS"])
'''


class NodeProjectDeploymentTests(unittest.TestCase):
    def run_deploy(self, *, quick=False, pin=PIN, pnpm=False, build=False,
                   excludes=None, missing=False, project_arg="test-project", host="test-host", switches=None,
                   service_scope=None, log_file=None, error_log_file=None, metrics_port=None,
                   project_name="test-project", aliases=None, required_bw_env=None, bw_items=None,
                   launchd_admin_helper=None):
        temporary = tempfile.TemporaryDirectory(prefix="node-deploy-test-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        deploy = root / "deploy"
        (deploy / "config").mkdir(parents=True)
        (deploy / "lib").mkdir()
        shutil.copyfile(DEPLOY / "node_project.zsh", deploy / "node_project.zsh")
        shutil.copyfile(DEPLOY / "lib/project_name_matcher.zsh", deploy / "lib/project_name_matcher.zsh")
        # Stub the log tailer so post-deploy tailing is recorded instead of run.
        tail = deploy / "tail_node_project.zsh"
        tail.write_text(TAIL_STUB)
        tail.chmod(0o755)
        project = root / "app"
        project.mkdir()
        package = {"name": "test-project", "scripts": {}}
        if build:
            package["devDependencies"] = {"vite": "1"}
            package["scripts"]["build"] = "vite build"
        (project / "package.json").write_text(json.dumps(package))
        (project / "index.js").write_text("// Synthetic deployment fixture\n")
        (project / ("pnpm-lock.yaml" if pnpm else "package-lock.json")).write_text("{}")
        config = {"name": project_name, "path": str(project),
                  "remote_dir": "/srv/test-project", "startup_port": "", "metrics_port": "",
                  "static_env": {"TEST_CONFIG": "set"}}
        if aliases is not None:
            config["aliases"] = aliases
        if required_bw_env is not None:
            config["required_bitwarden_env"] = required_bw_env
        if metrics_port is not None:
            config["metrics_port"] = metrics_port
        if pin is not None:
            config["node_binary"] = pin
        if excludes is not None:
            config["rsync_excludes"] = excludes
        if build:
            config["build_command"] = "npm run build"
        if service_scope is not None:
            config["service_scope"] = service_scope
        if launchd_admin_helper is not None:
            config["launchd_admin_helper"] = launchd_admin_helper
        if log_file is not None:
            config["log_file"] = log_file
        if error_log_file is not None:
            config["error_log_file"] = error_log_file
        (deploy / "config/node_projects.json").write_text(json.dumps([config]))
        binaries = root / "bin"
        binaries.mkdir()
        for name in ["ssh", "rsync", "say", "afplay", "osascript"]:
            executable = binaries / name
            executable.write_text(MOCK)
            executable.chmod(0o755)
        if bw_items is not None:
            bw = binaries / "bw"
            bw.write_text(BW_STUB)
            bw.chmod(0o755)
        log = root / "calls.jsonl"
        ssh_config = root / "ssh-config"
        ssh_config.write_text("Host test-host\n  HostName example.invalid\n")
        env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                   DEPLOY_TEST_LOG=str(log), SSH_CONFIG_FILE=str(ssh_config), BW_ENV_SYNC="0")
        if bw_items is not None:
            env.update(BW_ENV_SYNC="1", BW_SESSION="test-session", BW_SKIP_SYNC="1",
                       DEPLOY_TEST_BW_ITEMS=json.dumps(bw_items))
        if missing:
            env["DEPLOY_TEST_NODE_MISSING"] = "1"
        command = ["zsh", str(deploy / "node_project.zsh")]
        if project_arg:
            command.append(project_arg)
        if host:
            command.append(host)
        if switches is None:
            switches = ["--quick" if quick else "--full", "--no-tail"]
        command.extend(switches)
        result = subprocess.run(command, input="", text=True, capture_output=True, env=env, timeout=20)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)

    def test_quick_and_full_pin_npm_builds_and_generated_wrappers(self):
        for quick in [True, False]:
            with self.subTest(quick=quick):
                result, calls = self.run_deploy(quick=quick, build=True,
                                              excludes=["/resources/timetable_full/", "/var/planner/"])
                self.assert_success(result)
                commands = [" ".join(call["args"]) for call in calls if call["name"] == "ssh"]
                self.assertIn("process.versions.node", commands[0])
                dependencies = [command for command in commands if "npm install" in command or "npm ci" in command or "npm prune" in command or "npm run build" in command]
                self.assertTrue(dependencies)
                for command in dependencies:
                    self.assertIn(f"export PATH='{Path(PIN).parent}:{DEFAULT_PATH}'", command)
                wrappers = [command for command in commands if "build_wrapper()" in command]
                self.assertEqual(len(wrappers), 1)
                self.assertIn(f"NODE_EXECUTABLE='{PIN}'", wrappers[0])
                self.assertIn('exec "$NODE_EXECUTABLE" "$entry_file"', wrappers[0])
                # Render only the actual heredoc body in a disposable directory,
                # never executing the remote service-management script.
                wrapper_text = wrappers[0].split("<< EOF_START_WRAPPER\n", 1)[1].split("\nEOF_START_WRAPPER", 1)[0]
                rendered = subprocess.run(["bash", "-c", "cat << EOF_TEST\n" + wrapper_text + "\nEOF_TEST"],
                                          text=True, capture_output=True,
                                          env={**os.environ, "NODE_EXECUTABLE": PIN, "entry_file": "/srv/test-project/index.js",
                                               "STATIC_CONFIG_ENV_FILE": "/srv/test-project/static.env", "BW_ENV_FILE": "/srv/test-project/secrets.env"})
                self.assertEqual(rendered.returncode, 0, rendered.stderr)
                self.assertIn(f'exec "{PIN}" "/srv/test-project/index.js"', rendered.stdout)
                rsync = next(call for call in calls if call["name"] == "rsync")
                for excluded in ["/resources/timetable_full/", "/var/planner/"]:
                    index = rsync["args"].index(excluded)
                    self.assertEqual(rsync["args"][index - 1], "--exclude")
                self.assertIn("--delete", rsync["args"])

    def test_pnpm_receives_pinned_path_and_retains_install_flags(self):
        for quick in [True, False]:
            with self.subTest(quick=quick):
                result, calls = self.run_deploy(quick=quick, pnpm=True)
                self.assert_success(result)
                pnpm = next(call for call in calls if "pnpm install" in call["stdin"])
                self.assertIn(f"{Path(PIN).parent}:{DEFAULT_PATH}", pnpm["args"])
                self.assertIn('export PATH="$2"', pnpm["stdin"])
                self.assertIn("shift 2", pnpm["stdin"])
                self.assertIn("--prod", pnpm["args"])
                self.assertEqual("--prefer-offline" in pnpm["args"], quick)

    def test_unconfigured_projects_keep_default_runtime_path_and_exclusions(self):
        for quick in [True, False]:
            with self.subTest(quick=quick):
                result, calls = self.run_deploy(quick=quick, pin=None)
                self.assert_success(result)
                commands = [" ".join(call["args"]) for call in calls if call["name"] == "ssh"]
                self.assertFalse(any("process.versions.node" in command for command in commands))
                install = next(command for command in commands if "npm install" in command)
                self.assertIn(f"export PATH='{DEFAULT_PATH}'", install)
                wrapper = next(command for command in commands if "build_wrapper()" in command)
                self.assertIn("NODE_EXECUTABLE=''", wrapper)
                self.assertIn("NODE_EXECUTABLE=$(command -v node)", wrapper)
                rsync = next(call for call in calls if call["name"] == "rsync")
                self.assertNotIn("/var/planner/", rsync["args"])
                self.assertIn(".static-config*.env.sh", rsync["args"])

    def test_omitted_host_defaults_to_quick_deploy_with_error_tail(self):
        result, calls = self.run_deploy(host=None, switches=[])
        self.assert_success(result)
        self.assertIn("Deploy mode: quick", result.stdout)
        self.assertIn("Tail mode: errors only", result.stdout)
        remote = [call for call in calls if call["name"] in ("ssh", "rsync")]
        self.assertTrue(remote)
        for call in remote:
            self.assertTrue(any(arg == "sky" or arg.startswith("sky:") for arg in call["args"]), call)
            self.assertFalse(any("test-host" in arg for arg in call["args"]), call)
        tails = [call for call in calls if call["name"] == "tail"]
        self.assertEqual([call["args"] for call in tails], [["test-project", "sky", "--errors-only"]])

    def test_journey_planner_alias_defaults_to_mini(self):
        projects = json.loads((DEPLOY / "config/node_projects.json").read_text())
        active = next(project for project in projects if project["name"] == "train-track-journey-planner")
        self.assertIn("journey-planner", active["aliases"])
        self.assertEqual(active["static_env"]["PLANNER_RAPTOR_ONLY"], "true")
        result, calls = self.run_deploy(project_arg="journey-planner", host=None,
                                        project_name="train-track-journey-planner",
                                        aliases=["journey-planner"], switches=["--no-tail"])
        self.assert_success(result)
        self.assertIn("Deploy mode: quick", result.stdout)
        remote = [call for call in calls if call["name"] in ("ssh", "rsync")]
        self.assertTrue(remote)
        for call in remote:
            self.assertTrue(any(arg == "mini" or arg.startswith("mini:") for arg in call["args"]), call)
        self.assertFalse([call for call in calls if call["name"] == "tail"])

    def test_required_bitwarden_vars_are_checked_before_remote_secret_replacement(self):
        def item(name):
            return {"name": name, "fields": [{"name": "Apps", "value": "test-project"}],
                    "login": {"password": "test-value"}}

        missing, calls = self.run_deploy(required_bw_env=["ONE", "TWO"], bw_items=[item("ONE")])
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("Missing required Bitwarden env var 'TWO'", missing.stderr)
        self.assertFalse(any(".incoming." in " ".join(call["args"]) for call in calls if call["name"] == "rsync"))

        complete, calls = self.run_deploy(required_bw_env=["ONE", "TWO"], bw_items=[item("ONE"), item("TWO")])
        self.assert_success(complete)
        self.assertTrue(any(".incoming." in " ".join(call["args"]) for call in calls if call["name"] == "rsync"))
        self.assertTrue(any(".incoming." in " ".join(call["args"]) and "mv " in " ".join(call["args"])
                            for call in calls if call["name"] == "ssh"))

        duplicate, _ = self.run_deploy(required_bw_env=["ONE"], bw_items=[item("ONE"), item("ONE")])
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn("Duplicate Bitwarden env var 'ONE'", duplicate.stderr)

    def test_explicit_host_and_switches_override_defaults(self):
        result, calls = self.run_deploy(switches=["--full", "--tail"])
        self.assert_success(result)
        self.assertIn("Deploy mode: full", result.stdout)
        self.assertIn("Tail mode: stdout + stderr", result.stdout)
        self.assertTrue(any("test-host" in call["args"] for call in calls if call["name"] == "ssh"))
        tails = [call for call in calls if call["name"] == "tail"]
        self.assertEqual([call["args"] for call in tails], [["test-project", "test-host"]])

        result, calls = self.run_deploy(switches=["--no-tail"])
        self.assert_success(result)
        self.assertIn("Tail logs after deploy: no", result.stdout)
        self.assertFalse([call for call in calls if call["name"] == "tail"])

    def test_bare_host_without_project_is_rejected(self):
        result, _ = self.run_deploy(project_arg=None, switches=[])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("looks like a host", result.stderr)

    def test_invalid_or_missing_pins_fail_before_any_deployment_mutation(self):
        for pin in ["relative/node", "/opt/node;touch-bad/node", "/opt/../node/bin/node", "/opt/node\n/bin/node"]:
            with self.subTest(pin=pin):
                result, calls = self.run_deploy(pin=pin)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])
        result, calls = self.run_deploy(missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn("process.versions.node", " ".join(calls[0]["args"]))

    def test_invalid_exclusion_shapes_are_rejected_before_remote_commands(self):
        for excludes in ["/var/planner/", [""], ["/var/\nplanner/"], [12]]:
            with self.subTest(excludes=excludes):
                result, calls = self.run_deploy(excludes=excludes)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_system_launchd_scope_uses_a_launchdaemon_and_administrator_boundary(self):
        result, calls = self.run_deploy(service_scope="system", log_file="/var/log/test-project/service.log",
                                        error_log_file="/var/log/test-project/service.error.log")
        self.assert_success(result)
        service_setup = next(" ".join(call["args"]) for call in calls
                             if call["name"] == "ssh" and "/Library/LaunchDaemons" in " ".join(call["args"]))
        self.assertIn("SERVICE_SCOPE='system'", service_setup)
        self.assertIn("sudo -n install -o root -g wheel -m 644", service_setup)
        self.assertIn("launchctl bootstrap system", service_setup)
        self.assertIn("<key>UserName</key>", service_setup)
        self.assertIn("/var/log/test-project/service.log", service_setup)
        self.assertNotIn("/srv/test-project//var/log/test-project", service_setup)
        self.assertLess(service_setup.index("s|ERROR_LOG_FILE_PLACEHOLDER|"),
                        service_setup.index("s|LOG_FILE_PLACEHOLDER|"))

        result, calls = self.run_deploy(service_scope="invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_system_launchd_helper_is_used_and_removes_the_old_user_agent(self):
        helper = "/usr/local/sbin/test-launchd-admin"
        result, calls = self.run_deploy(service_scope="system", launchd_admin_helper=helper)
        self.assert_success(result)
        service_setup = next(" ".join(call["args"]) for call in calls
                             if call["name"] == "ssh" and "restart_launchd_service" in " ".join(call["args"]))
        self.assertIn(f"LAUNCHD_ADMIN_HELPER='{helper}'", service_setup)
        self.assertIn('sudo -n "$LAUNCHD_ADMIN_HELPER" check', service_setup)
        self.assertIn('sudo -n "$LAUNCHD_ADMIN_HELPER" install', service_setup)
        self.assertIn('launchctl bootout "gui/$UID_NUM/$service_label"', service_setup)
        self.assertIn('rm -f "$old_user_plist"', service_setup)

        result, calls = self.run_deploy(service_scope="user", launchd_admin_helper=helper)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_user_launchd_scope_can_recover_from_bootstrap_failure(self):
        result, calls = self.run_deploy(service_scope="user")
        self.assert_success(result)
        service_setup = next(" ".join(call["args"]) for call in calls
                             if call["name"] == "ssh" and "restart_launchd_service" in " ".join(call["args"]))
        self.assertIn('launchctl load -w', service_setup)
        self.assertIn('launchctl print', service_setup)

    def test_false_metrics_port_disables_monitoring_for_isolated_project(self):
        result, calls = self.run_deploy(metrics_port=False)
        self.assert_success(result)
        self.assertIn('No metrics port configured; skipping Prometheus scrape target.', result.stdout)


if __name__ == "__main__":
    unittest.main()
