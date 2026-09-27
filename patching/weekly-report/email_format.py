"""Gmail-friendly HTML with inline styles and an unchanged plain-text fallback."""
import datetime
from html import escape
import json
from zoneinfo import ZoneInfo


def table(headers, rows):
    head = ''.join('<th align="left" style="padding:10px;border-bottom:2px solid #dce3eb;color:#475569;font-size:12px">'
                   + escape(str(value)) + '</th>' for value in headers)
    body = ''.join('<tr>' + ''.join('<td style="padding:10px;border-bottom:1px solid #e8edf3;vertical-align:top;word-break:break-word">'
                                  + escape(str(value)) + '</td>' for value in row) + '</tr>' for row in rows)
    return '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px">' + '<tr>' + head + '</tr>' + body + '</table>'


def block(title, content):
    return '<h2 style="font-size:17px;line-height:24px;margin:28px 0 10px;color:#142638">' + escape(title) + '</h2>' + content


def paragraph(text):
    return '<p style="margin:8px 0;line-height:1.6">' + escape(text) + '</p>'


def html_report(status, text):
    intro, remainder = text.split('\nATTENTION\n', 1)
    attention, remainder = remainder.split('\n\nPACKAGES CHANGED\n', 1)
    packages, remainder = remainder.split('\n\nCURRENT STATUS\n', 1)
    health = remainder.split('\n\nUPGRADE LOG ', 1)[0]
    colors = {'OK': ('#e6f4ea', '#17643a'), 'REVIEW': ('#fff4db', '#875600'), 'FAILED': ('#fde8e7', '#a32121')}
    background, foreground = colors.get(status, colors['REVIEW'])
    title = intro.splitlines()[0].split(' — ')[0]
    metadata = []
    for line in intro.splitlines()[1:]:
        key, value = line.split(': ', 1)
        if key in ('Completed', 'Started'):
            value = datetime.datetime.fromisoformat(value).astimezone(ZoneInfo('Europe/London')).strftime('%d %b %Y, %H:%M:%S %Z')
        metadata.append((key, value))
    content = '<span style="display:inline-block;padding:6px 12px;border-radius:6px;background:' + background + ';color:' + foreground + ';font-size:12px;font-weight:bold">' + escape(status) + '</span>'
    content += '<h1 style="font-size:26px;line-height:34px;margin:14px 0 8px;color:#142638">' + escape(title) + '</h1>'
    content += paragraph('Sky · weekly maintenance') + table(['Run details', ''], metadata)
    warnings = [line[2:] for line in attention.splitlines() if line.startswith('- ')]
    if warnings:
        content += block('Needs attention', '<ul style="margin:0;padding:16px 20px 16px 36px;background:' + background + ';border-radius:6px">'
                         + ''.join('<li style="padding:5px 0;line-height:1.5">' + escape(line) + '</li>' for line in warnings[:30]) + '</ul>')
        if len(warnings) > 30:
            content += paragraph('Additional findings are included in the attached report.')
    else:
        content += block('Assessment', paragraph(attention))
    changes = []
    for line in packages.splitlines():
        if ': ' in line and ' -> ' in line:
            name, versions = line.split(': ', 1)
            before, after = versions.split(' -> ', 1)
            changes.append((name, before, after))
    content += block('Package changes' + (f' ({len(changes)})' if changes else ''),
                     table(['Package', 'Previous', 'Installed'], changes[:100]) if changes else paragraph(packages))
    if len(changes) > 100:
        content += paragraph('First 100 changes shown. The attachment contains the full list.')
    services, checks, details = [], [], []
    for section in health.split('\n\n'):
        key, separator, value = section.partition(':')
        value = value.strip()
        if not separator:
            details.append(paragraph(section))
        elif value in ('active', 'inactive', 'failed', 'activating', 'deactivating'):
            services.append((key.removesuffix('.service'), value))
        elif key == 'Ubuntu Pro/ESM security status':
            data = json.loads(value)
            pending = data.get('packages', [])
            checks.append(('Ubuntu Pro/ESM', f'{len(pending)} outstanding security update(s)' if pending else 'No outstanding updates reported'))
        elif key == 'Restart assessment (read-only)':
            restart = [line.split(': ', 1)[1] for line in value.splitlines() if line.startswith(('NEEDRESTART-SVC: ', 'NEEDRESTART-SESS: '))]
            checks.append(('Restart required', ', '.join(restart) if restart else 'None reported'))
        elif key == 'Scope':
            details.append(paragraph('Coverage: ' + value))
        else:
            checks.append((key, value[:3000]))
    content += block('Security and system checks', table(['Check', 'Result'], checks))
    content += block('Services', table(['Service', 'Current status'], services))
    content += block('Full diagnostic details', paragraph('The attached text report contains all findings and the upgrade log. Keep it for troubleshooting.'))
    content += '<div style="margin-top:24px;padding-top:16px;border-top:1px solid #dce3eb;color:#64748b;font-size:12px">' + ''.join(details) + '</div>'
    return ('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>'
            '<body style="margin:0;background:#f2f5f8;font-family:Arial,Helvetica,sans-serif;color:#334155">'
            '<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">'
            '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:760px;background:#ffffff;border:1px solid #dce3eb;border-radius:10px">'
            '<tr><td style="padding:28px 24px">' + content + '</td></tr></table></td></tr></table></body></html>')
