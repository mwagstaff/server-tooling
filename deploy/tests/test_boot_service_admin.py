from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "deploy/macos/train-track-boot-service-admin"
FUNNEL_PLIST = ROOT / "tailscale/resources/com.mike.tailscale-funnel-apply.plist"
DEPLOY_FUNNEL_SCRIPT = ROOT / "deploy/tailscale-funnel-apply.sh"
RESOURCE_FUNNEL_SCRIPT = ROOT / "tailscale/resources/tailscale-funnel-apply.sh"


class BootServiceAdminTests(unittest.TestCase):
    def test_reviewed_funnel_plist_matches_the_root_helper_allowlist(self):
        with tempfile.TemporaryDirectory(prefix="boot-service-admin-") as directory:
            rendered = Path(directory) / "funnel.plist"
            command = (
                f"source {HELPER!s}; "
                f'write_expected_plist "$FUNNEL_LABEL" {rendered!s}'
            )
            result = subprocess.run(["bash", "-c", command], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(rendered.read_bytes(), FUNNEL_PLIST.read_bytes())

    def test_unprivileged_or_unlisted_calls_are_rejected(self):
        result = subprocess.run(
            ["bash", str(HELPER), "check", "com.example.not-allowed"],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must run as root", result.stderr)

    def test_funnel_script_starts_the_saved_macos_vpn_before_applying_routes(self):
        script = DEPLOY_FUNNEL_SCRIPT.read_text()
        self.assertEqual(
            DEPLOY_FUNNEL_SCRIPT.read_bytes(), RESOURCE_FUNNEL_SCRIPT.read_bytes()
        )
        self.assertIn('scutil --nc start "Tailscale"', script)
        self.assertLess(
            script.index('launchctl kickstart "system/$extension_label"'),
            script.index('scutil --nc start "Tailscale"'),
        )
        self.assertLess(
            script.index('scutil --nc start "Tailscale"'),
            script.index('echo "Applying Funnel routes..."'),
        )
        self.assertLess(
            script.index("/usr/local/bin/tailscale"),
            script.index("/opt/homebrew/bin/tailscale"),
        )


if __name__ == "__main__":
    unittest.main()
