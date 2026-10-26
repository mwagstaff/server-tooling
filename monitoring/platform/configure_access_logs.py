#!/usr/bin/env python3
"""Enable sanitized access logs on Sky's existing Caddy listener; validate then reload."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import subprocess

BLOCK = '''
  # BEGIN server-tooling access logs
  log {
    output stdout
    format filter {
      wrap json
      fields {
        request>headers delete
        request>remote_ip delete
        request>remote_port delete
        request>client_ip delete
        request>uri regexp "[?].*$" ""
        resp_headers delete
      }
    }
  }
  request_header X-Request-ID {http.request.uuid}
  log_append request_id {http.request.uuid}
  @monitoring_probe header User-Agent ServerToolingMonitoring/1.0
  log_append @monitoring_probe monitoring true
  # END server-tooling access logs
'''


def render(text):
    if '# BEGIN server-tooling access logs' in text:
        start = text.index('  # BEGIN server-tooling access logs')
        end = text.index('  # END server-tooling access logs', start) + len('  # END server-tooling access logs')
        return text[:start] + BLOCK.strip('\n') + text[end:]
    if text.count(':4080 {') != 1:
        raise ValueError('Expected exactly one existing :4080 listener')
    return text.replace(':4080 {', ':4080 {\n' + BLOCK, 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    path = Path('/etc/caddy/Caddyfile')
    candidate = Path.home() / '.local/share/server-tooling-monitoring/Caddyfile.logs'
    candidate.write_text(render(path.read_text()))
    subprocess.run(['sudo', '-n', 'caddy', 'validate', '--config', candidate, '--adapter', 'caddyfile'], check=True)
    if args.apply:
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        subprocess.run(['sudo', '-n', 'cp', '-p', path, str(path) + '.' + stamp + '.bak'], check=True)
        subprocess.run(['sudo', '-n', 'install', '-m', '644', candidate, path], check=True)
        subprocess.run(['sudo', '-n', 'systemctl', 'reload', 'caddy'], check=True)


if __name__ == '__main__':
    main()
