#!/usr/bin/env python3
"""Observe the existing upgrade service; report failures even when ExecStart fails.

No upgrade commands are run here. SMTP uses a root-only copy of the existing
Plunk credential. Failed deliveries remain in an outbox for the retry timer.
"""
import argparse
import datetime
import fcntl
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
import json
import os
from pathlib import Path
import smtplib
import ssl
import subprocess
import time

from events import atomic, record

ROOT = Path('/var/lib/server-tooling/weekly-upgrade')
CONFIG = Path('/etc/server-tooling/weekly-upgrade.json')


def command(args, timeout=60):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, '', type(error).__name__


def packages():
    code, output, error = command(['dpkg-query', '-W', '-f=${binary:Package}\t${Version}\t${db:Status-Status}\n'])
    if code:
        raise RuntimeError('Could not inventory installed packages: ' + error)
    return {name: version for name, version, status in (line.split('\t') for line in output.splitlines()) if status == 'installed'}


def package_changes(before, after):
    return [f'{name}: {before.get(name, "(new)")} -> {after.get(name, "(removed)")}'
            for name in sorted(before.keys() | after.keys()) if before.get(name) != after.get(name)]


def health():
    warnings, sections = [], []
    code, failed, error = command(['systemctl', '--failed', '--no-legend', '--plain'])
    if code or failed:
        warnings.append('Failed system services detected' if failed else 'Could not check failed system services')
    sections.append('Failed system services:\n' + (failed or error or 'None'))
    for unit in ['cloudflared', 'server-tooling-full-upgrade.timer', 'unattended-upgrades']:
        code, output, error = command(['systemctl', 'is-active', unit])
        if code:
            warnings.append(unit + ' is not active')
        sections.append(unit + ': ' + (output or error))
    config = json.loads(CONFIG.read_text())
    user_command = ['runuser', '-u', config['user'], '--', 'env', 'XDG_RUNTIME_DIR=/run/user/' + str(config['uid']), 'systemctl', '--user']
    for unit in config['units']:
        code, output, error = command(user_command + ['is-active', unit])
        if code:
            warnings.append(unit + ' is not active')
        sections.append(unit + ': ' + (output or error))
    reboot = Path('/run/reboot-required')
    if reboot.exists():
        warnings.append('Host reboot required to finish applying updates')
    sections.append('Reboot required: ' + ('YES' if reboot.exists() else 'No'))
    code, output, error = command(['needrestart', '-b', '-r', 'l'])
    if code:
        warnings.append('Restart/security assessment incomplete: needrestart failed')
    else:
        if any(line.startswith(('NEEDRESTART-SVC:', 'NEEDRESTART-SESS:')) for line in output.splitlines()):
            warnings.append('Services or user sessions still use old binaries; review restart list')
        if 'NEEDRESTART-KSTA: 1' not in output:
            warnings.append('Running kernel status needs review')
    sections.append('Restart assessment (read-only):\n' + (output or error))
    # Ubuntu's native APT metadata includes normal and ESM security origins.
    try:
        import apt
        import apt_pkg
        cache = apt.Cache()
        remaining, security = [], []
        for package in cache:
            if package.is_upgradable:
                remaining.append(package.name + ' -> ' + package.candidate.version)
                # Include security versions hidden behind a newer non-security candidate.
                if any(apt_pkg.version_compare(version.version, package.installed.version) > 0 and any('security' in origin.archive.lower()
                       for origin in version.origins) for version in package.versions):
                    security.append(package.name)
        if security:
            warnings.append(f'{len(security)} installed packages still have security updates available')
        if remaining:
            warnings.append(f'{len(remaining)} packages still have upgrades available (may include held packages)')
        sections.append('Available security updates: ' + (', '.join(security) or 'None in configured APT repositories'))
        sections.append('Remaining upgrades:\n' + ('\n'.join(remaining) or 'None'))
    except Exception as error:
        warnings.append('Security update assessment unavailable: ' + type(error).__name__)
    code, output, error = command(['pro', 'security-status', '--format', 'json'])
    if code:
        warnings.append('Ubuntu Pro/ESM security assessment unavailable')
        sections.append('Ubuntu Pro/ESM assessment: unavailable (' + error[:300] + ')')
    else:
        try:
            pro = json.loads(output)
            outstanding = pro['packages']
            if not isinstance(outstanding, list) or not isinstance(pro.get('summary'), dict):
                raise ValueError('Unexpected security-status schema')
            for package in outstanding:
                warnings.append('Ubuntu security update: ' + package['package'] + ' -> ' + package['version']
                                + ' (' + package.get('service_name', 'unknown service') + ', '
                                + package.get('status', 'unknown status') + ')')
            sections.append('Ubuntu Pro/ESM security status:\n' + json.dumps(pro, indent=2))
        except (ValueError, KeyError, TypeError):
            warnings.append('Ubuntu Pro/ESM security result could not be interpreted')
    code, output, error = command(['dpkg', '--audit'])
    if code or output:
        warnings.append('Package database needs review')
    sections.append('Package database audit:\n' + (output or error or 'No issues reported'))
    code, output, error = command(['apt-mark', 'showhold'])
    if code or output:
        warnings.append('Held packages or incomplete hold check; review report')
    sections.append('Held packages:\n' + (output or error or 'None'))
    sections.append('Scope: APT package candidates, Ubuntu Pro/ESM security status, and local restart/service checks. '
                    'This is not a complete vulnerability scan of application dependencies, containers, or third-party/manual installations. '
                    'An ESM update may require enabling coverage; no subscription or repository changes are made by this report.')
    return warnings, sections


def begin():
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    state = {'started': time.time()}
    atomic(ROOT / 'current.json', json.dumps(state))
    record('weekly-upgrade', 'Weekly upgrade started', state['started'])
    state['packages'] = packages()
    atomic(ROOT / 'current.json', json.dumps(state))


def build_report(state, result, validation=False):
    warnings, sections = health()
    now = datetime.datetime.now(datetime.timezone.utc)
    started = state.get('started', now.timestamp())
    try:
        changes = package_changes(state['packages'], packages()) if 'packages' in state else []
    except RuntimeError:
        changes = []
        warnings.append('Post-upgrade package inventory failed; changes could not be verified')
    if result != 'success':
        warnings.insert(0, 'Upgrade service failed: ' + result)
    if not validation and 'packages' not in state:
        warnings.append('Pre-upgrade package snapshot missing; changes cannot be reconstructed')
    journal = ''
    if not validation:
        code, journal, error = command(['journalctl', '-u', 'server-tooling-full-upgrade.service',
                                        '--since', '@' + str(int(started)), '--no-pager', '-o', 'cat'])
        if code:
            warnings.append('Upgrade log unavailable: ' + error)
        for line in journal.splitlines():
            if line.startswith(('W:', 'E:', 'Err:')) or 'Illegal number' in line:
                warnings.append('Upgrade log: ' + line[:300])
        code, tunnel, error = command(['journalctl', '-u', 'cloudflared.service', '--since', '@' + str(int(started)), '--no-pager', '-o', 'cat'])
        if 'timed out' in tunnel or 'Failed with result' in tunnel:
            warnings.append('Cloudflare Tunnel encountered a shutdown timeout or service failure during the upgrade')
    status = 'FAILED' if result != 'success' else ('REVIEW' if warnings else 'OK')
    title = 'Report validation (no upgrade run)' if validation else 'Weekly upgrade'
    text = f'{title} — sky — {status}\nCompleted: {now.isoformat()}\n'
    if not validation:
        text += f'Started: {datetime.datetime.fromtimestamp(started, datetime.timezone.utc).isoformat()}\nService result: {result}\n'
    text += '\nATTENTION\n' + ('\n'.join('- ' + item for item in warnings) or 'No concerns found by the checks below.')
    text += '\n\nPACKAGES CHANGED\n' + ('\n'.join(changes) or ('Not applicable: validation only.' if validation else 'No package changes detected.'))
    text += '\n\nCURRENT STATUS\n' + '\n\n'.join(sections)
    if journal:
        text += '\n\nUPGRADE LOG (last 60,000 characters)\n' + journal[-60000:]
    return status, text


def queue_report(status, text, validation=False):
    config = json.loads(CONFIG.read_text())
    message = EmailMessage()
    message['From'], message['To'] = config['from'], config['to']
    message['Subject'] = f'[{status}] sky ' + ('upgrade report validation' if validation else 'weekly upgrade report')
    message['Date'], message['Message-ID'] = formatdate(localtime=True), make_msgid(domain=config['from'].split('@')[-1])
    message.set_content(text)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    outbox = ROOT / 'outbox'
    outbox.mkdir(mode=0o700, parents=True, exist_ok=True)
    atomic(ROOT / ('report-' + stamp + '.txt'), text)
    atomic(outbox / (stamp + '.eml'), message.as_string())


def deliver():
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (ROOT / 'delivery.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        deliver_locked()


def deliver_locked():
    config = json.loads(CONFIG.read_text())
    for path in sorted((ROOT / 'outbox').glob('*.eml')):
        # One connection per report keeps retries independent. Never print SMTP credentials.
        with smtplib.SMTP(config['smtp_host'], config['smtp_port'], timeout=30) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ssl.create_default_context())
            smtp.ehlo()
            smtp.login(config['smtp_user'], Path(config['password_file']).read_text().strip())
            refused = smtp.sendmail(config['from'], [config['to']], path.read_bytes())
            if refused:
                raise RuntimeError('SMTP recipient rejected')
        path.unlink()
        record('upgrade-report', 'Weekly upgrade report accepted by email relay')
    # Keep reports for 90 days; never discard queued undelivered mail.
    for path in ROOT.glob('report-*.txt'):
        if path.stat().st_mtime < time.time() - 90 * 86400:
            path.unlink()


def finish(validation=False):
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = ROOT / 'current.json'
    state = {} if validation or not path.exists() else json.loads(path.read_text())
    result = 'success' if validation else os.environ.get('SERVICE_RESULT', 'unknown')
    status, text = build_report(state, result, validation)
    queue_report(status, text, validation)
    if not validation:
        record('weekly-upgrade', 'Weekly upgrade finished: ' + status + ' (service result: ' + result + ')')
        path.unlink(missing_ok=True)
    deliver()
    print('Upgrade report accepted by SMTP relay; status: ' + status)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['begin', 'finish', 'retry', 'validate', 'preview'])
    args = parser.parse_args()
    try:
        if args.action == 'begin':
            begin()
        elif args.action == 'retry':
            deliver()
        elif args.action == 'preview':
            print(build_report({}, 'success', validation=True)[1])
        else:
            finish(validation=args.action == 'validate')
    except Exception as error:
        record('upgrade-report', 'Upgrade report failed: ' + type(error).__name__ + '; inspect report service/outbox')
        raise SystemExit('Upgrade reporting failed: ' + type(error).__name__)
