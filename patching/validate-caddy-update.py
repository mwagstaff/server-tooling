#!/usr/bin/env python3
"""APT v1 pre-install hook: validate a downloaded Caddy package before unpacking."""
from pathlib import Path
import subprocess
import sys
import tempfile

LOG = Path('/var/log/server-tooling-caddy-validation.log')


def validate(package):
    name = subprocess.check_output(['dpkg-deb', '-f', str(package), 'Package'], text=True).strip()
    if name != 'caddy':
        return
    with tempfile.TemporaryDirectory(prefix='caddy-preflight-') as directory:
        root = Path(directory)
        root.chmod(0o755)
        subprocess.run(['dpkg-deb', '-x', str(package), directory], check=True)
        binary = root / 'usr/bin/caddy'
        result = subprocess.run(['runuser', '-u', 'caddy', '--', str(binary), 'validate',
                                 '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'],
                                capture_output=True, text=True, timeout=60)
        LOG.touch(mode=0o600, exist_ok=True)
        LOG.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError('Caddy update refused: configuration validation failed; see ' + str(LOG))
        print('Caddy candidate configuration validated successfully.')


if __name__ == '__main__':
    for line in sys.stdin:
        package = Path(line.strip())
        if package.suffix == '.deb' and package.is_file():
            validate(package)
