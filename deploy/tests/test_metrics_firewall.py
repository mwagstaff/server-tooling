"""Exercise the deployment's remote firewall command without touching a host."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


DEPLOY = Path(__file__).resolve().parents[1]


class MetricsFirewallTests(unittest.TestCase):
    def run_firewall(self, active=True, fail_allow=False):
        source = (DEPLOY / 'node_project.zsh').read_text()
        start = source.index('        ssh "$HOST" "if sudo ufw status')
        end = source.index('\n      done', start)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sudo = root / 'sudo'
            sudo.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$FIREWALL_LOG"
if [ "$1 $2" = "ufw status" ]; then
  echo "Status: $UFW_STATE"
elif [ "$1 $2" = "ufw allow" ]; then
  exit "$ALLOW_EXIT"
elif [ "$1 $2" = "iptables -C" ]; then
  exit 1
fi
''')
            sudo.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:' + os.environ['PATH'],
                       FIREWALL_LOG=str(root / 'calls'),
                       UFW_STATE='active' if active else 'inactive',
                       ALLOW_EXIT='1' if fail_allow else '0')
            result = subprocess.run(['zsh', '-c', '''
HOST=sky
AUTO_PROM_SUBNET=172.18.0.0/16
AUTO_PROM_SCRAPE_PORT=3040
ssh() { bash -c "$2"; }
''' + source[start:end]], env=env, capture_output=True, text=True)
            return result.returncode, (root / 'calls').read_text()

    def test_active_ufw_uses_persistent_scoped_rule(self):
        code, calls = self.run_firewall()
        self.assertEqual(code, 0)
        self.assertIn('ufw allow from 172.18.0.0/16 to any port 3040 proto tcp', calls)
        self.assertNotIn('iptables', calls)

    def test_inactive_ufw_preserves_existing_fallback(self):
        code, calls = self.run_firewall(active=False)
        self.assertEqual(code, 0)
        self.assertIn('iptables -I INPUT 1 -p tcp -s 172.18.0.0/16 --dport 3040', calls)
        self.assertNotIn('ufw allow', calls)

    def test_persistent_rule_failure_is_not_hidden_by_temporary_rule(self):
        code, calls = self.run_firewall(fail_allow=True)
        self.assertNotEqual(code, 0)
        self.assertNotIn('iptables', calls)
