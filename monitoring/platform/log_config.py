"""Bounded pilot log storage and collection. No request bodies or headers are exported."""
import json
from pathlib import Path

LOKI_VERSION = '3.7.9'
ALLOY_VERSION = '1.21.2'


def loki_config(root):
    data = str(Path(root) / 'data/loki')
    return {
        'auth_enabled': False,
        'server': {'http_listen_address': '127.0.0.1', 'http_listen_port': 13100,
                   'grpc_listen_address': '127.0.0.1', 'grpc_listen_port': 13109},
        'common': {'path_prefix': data, 'replication_factor': 1, 'instance_addr': '127.0.0.1',
                   'ring': {'kvstore': {'store': 'inmemory'}, 'instance_addr': '127.0.0.1'},
                   'storage': {'filesystem': {'chunks_directory': data + '/chunks', 'rules_directory': data + '/rules'}}},
        'schema_config': {'configs': [{'from': '2026-01-01', 'store': 'tsdb', 'object_store': 'filesystem',
                                      'schema': 'v13', 'index': {'prefix': 'index_', 'period': '24h'}}]},
        'compactor': {'working_directory': data + '/compactor', 'retention_enabled': True,
                      'delete_request_store': 'filesystem', 'retention_delete_delay': '2h',
                      'retention_delete_worker_count': 5},
        'limits_config': {'retention_period': '336h', 'ingestion_rate_mb': 0.1, 'ingestion_burst_size_mb': 1,
                          'max_global_streams_per_user': 2000, 'max_line_size': '8KB',
                          'max_line_size_truncate': True, 'max_query_parallelism': 2,
                          'split_queries_by_interval': '1h', 'max_query_length': '337h'},
        'query_range': {'results_cache': {'cache': {'embedded_cache': {'enabled': True, 'max_size_mb': 32}}}},
        'querier': {'max_concurrent': 2},
        'analytics': {'reporting_enabled': False},
    }


def alloy_config(root, host, services, url, linux=False):
    root = Path(root)
    q = json.dumps
    targets = []
    for service in services:
        if service['host'] != host:
            continue
        for path in service['logs']:
            targets.append({'__path__': path, 'host': host, 'service': service['name'], 'source': 'application', 'timestamp_source': 'collected'})
    for filename in ['aiops.log','aiops.error.log']:
        targets.append({'__path__': str(root.parents[2] / 'dev/aiops' / filename), 'host': host, 'service': 'aiops', 'source':'application','timestamp_source':'collected'})
    targets.append({'__path__': str(root / 'logs/log-canary.jsonl'), 'host': host, 'service': 'log-canary', 'source': 'canary'})
    # Alloy's syntax uses '=' inside map literals.
    maps = ',\n'.join('{' + ', '.join(k + ' = ' + q(v) for k, v in target.items()) + '}' for target in targets)
    text = f'''logging {{
  level = "warn"
}}
local.file_match "applications" {{
  path_targets = [{maps}]
  sync_period = "10s"
}}
loki.source.file "applications" {{
  targets = local.file_match.applications.targets
  tail_from_end = true
  forward_to = [loki.process.redact.receiver]
}}
loki.process "redact" {{
  forward_to = [loki.write.central.receiver]
  stage.replace {{
    expression = `(?i)((?:authorization|cookie|password|api[_-]?key|access[_-]?token|secret)["' :=]+.*)`
    replace = "[credential-bearing line redacted]"
  }}
  stage.replace {{
    expression = `((?:https?://|mongodb(?:\\+srv)?://)[^\\s"']+)`
    replace = "[url redacted]"
  }}
  stage.replace {{
    expression = `([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{{2,}})`
    replace = "[email redacted]"
  }}
  stage.replace {{
    expression = `((?:sk-[A-Za-z0-9_-]{{12,}}|eyJ[A-Za-z0-9_.-]{{20,}}))`
    replace = "[token redacted]"
  }}
  stage.drop {{
    expression = `(?:.*(?:BEGIN|END).*PRIVATE KEY.*|^[A-Za-z0-9+/]{{48,}}={{0,2}}$)`
    drop_counter_reason = "private_key"
  }}
  stage.limit {{
    rate = 50
    burst = 100
    drop = false
  }}
}}
loki.write "central" {{
  endpoint {{
    url = {q(url + '/loki/api/v1/push')}
    basic_auth {{
      username = "logs"
      password_file = {q(str(root / 'secrets/LOKI_TOKEN'))}
    }}
  }}
  wal {{
    enabled = true
  }}
}}
'''
    if linux:
        # Whitelist Caddy fields, excluding cookies, authorization, client IPs and query strings.
        text += '''
loki.source.journal "caddy" {
  matches = "_SYSTEMD_UNIT=caddy.service"
  max_age = "1h"
  labels = {host = "sky", service = "caddy", source = "proxy", timestamp_source = "journal"}
  forward_to = [loki.process.caddy.receiver]
}
loki.process "caddy" {
  forward_to = [loki.process.redact.receiver]
  stage.json {
    expressions = {level = "level", message = "msg", error = "error", host = "request.host", method = "request.method", path = "request.uri", status = "status", duration = "duration", request_id = "request_id", monitoring = "monitoring", agent = "request.headers.\\\"User-Agent\\\"[0]"}
  }
  stage.replace {
    source = "path"
    expression = `([?#].*)`
    replace = ""
  }
  stage.template {
    source = "service"
    template = "{{ if eq .host \\"kidsplorers.com\\" }}kidsplorers-web{{ else if eq .host \\"api.kidsplorers.com\\" }}kidsplorers-api{{ else }}caddy{{ end }}"
  }
  stage.labels {
    values = {service = "", level = ""}
  }
  stage.template {
    source = "line"
    template = "message={{ printf \\"%q\\" .message }} error={{ printf \\"%q\\" .error }} method={{ printf \\"%q\\" .method }} path={{ printf \\"%q\\" .path }} status={{ .status }} duration={{ .duration }} request_id={{ .request_id }} probe={{ .monitoring }} monitoring={{ eq .agent \\"ServerToolingMonitoring/1.0\\" }}"
  }
  stage.output {
    source = "line"
  }
}
'''
        for index, service in enumerate(s for s in services if s['host'] == host):
            text += f'''
loki.source.journal "service_{index}" {{
  matches = {q('_SYSTEMD_USER_UNIT=' + service['unit'] + '.service')}
  max_age = "1h"
  labels = {{host = "sky", service = {q(service['name'])}, source = "journal", timestamp_source = "journal"}}
  forward_to = [loki.process.redact.receiver]
}}
'''
    return text
