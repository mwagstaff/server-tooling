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


class NodeProjectDeploymentTests(unittest.TestCase):
    def run_deploy(self, *, quick=False, pin=PIN, pnpm=False, build=False,
                   excludes=None, missing=False):
        temporary = tempfile.TemporaryDirectory(prefix="node-deploy-test-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        deploy = root / "deploy"
        (deploy / "config").mkdir(parents=True)
        (deploy / "lib").mkdir()
        shutil.copyfile(DEPLOY / "node_project.zsh", deploy / "node_project.zsh")
        shutil.copyfile(DEPLOY / "lib/project_name_matcher.zsh", deploy / "lib/project_name_matcher.zsh")
        project = root / "app"
        project.mkdir()
        package = {"name": "test-project", "scripts": {}}
        if build:
            package["devDependencies"] = {"vite": "1"}
            package["scripts"]["build"] = "vite build"
        (project / "package.json").write_text(json.dumps(package))
        (project / "index.js").write_text("// Synthetic deployment fixture\n")
        (project / ("pnpm-lock.yaml" if pnpm else "package-lock.json")).write_text("{}")
        config = {"name": "test-project", "path": str(project),
                  "remote_dir": "/srv/test-project", "startup_port": "", "metrics_port": "",
                  "static_env": {"TEST_CONFIG": "set"}}
        if pin is not None:
            config["node_binary"] = pin
        if excludes is not None:
            config["rsync_excludes"] = excludes
        if build:
            config["build_command"] = "npm run build"
        (deploy / "config/node_projects.json").write_text(json.dumps([config]))
        binaries = root / "bin"
        binaries.mkdir()
        for name in ["ssh", "rsync", "say", "afplay", "osascript"]:
            executable = binaries / name
            executable.write_text(MOCK)
            executable.chmod(0o755)
        log = root / "calls.jsonl"
        ssh_config = root / "ssh-config"
        ssh_config.write_text("Host test-host\n  HostName example.invalid\n")
        env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                   DEPLOY_TEST_LOG=str(log), SSH_CONFIG_FILE=str(ssh_config), BW_ENV_SYNC="0")
        if missing:
            env["DEPLOY_TEST_NODE_MISSING"] = "1"
        command = ["zsh", str(deploy / "node_project.zsh"), "test-project", "test-host"]
        if quick:
            command.append("--quick")
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


if __name__ == "__main__":
    unittest.main()
