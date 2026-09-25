"""Shared Prometheus, Alertmanager and Grafana configuration (JSON is valid YAML)."""
import json
from pathlib import Path


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def alert(name, expr, duration, summary, severity='warning'):
    return dict(alert=name, expr=expr, **{'for': duration},
                labels={'severity': severity},
                annotations={'summary': summary,
                             'description': '{{ $labels.host }} / {{ $labels.service }}: {{ printf "%.3g" $value }}',
                             'runbook_url': 'https://github.com/mwagstaff/server-tooling/tree/main/monitoring/platform#alerts'})


def make_rules(services, target):
    rules = [dict(alert='MonitoringWatchdog', expr='vector(1)', labels={'severity': 'none'})]
    rules += [
        alert('MetricsAccessUnavailable', 'up{kind="host"} == 0', '3m', 'Cannot collect host metrics from {{ $labels.host }}', 'critical'),
        alert('RuntimeUnavailable', 'up{kind="runtime"} == 0', '3m', '{{ $labels.service }} runtime metrics unavailable', 'critical'),
        alert('AppMetricsUnavailable', 'up{kind="app"} == 0', '5m', '{{ $labels.service }} application metrics unavailable'),
        alert('PublicEndpointUnavailable', 'probe_success{kind="public"} == 0', '2m', '{{ $labels.service }} public endpoint failed', 'critical'),
        alert('PublicProbeUnavailable', 'up{kind="public"} == 0', '3m', 'Cannot run public check for {{ $labels.service }}'),
        alert('HostCpuPressure', '1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.90', '15m', 'Sustained CPU pressure on {{ $labels.host }}'),
        alert('HostMemoryPressure', 'node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10', '10m', 'Less than 10% memory available on {{ $labels.host }}'),
        alert('MacMemoryPressure', '(node_memory_free_bytes + node_memory_inactive_bytes) / node_memory_total_bytes < 0.10 and rate(node_memory_swapped_out_bytes_total[5m]) > 1048576', '10m', 'Low reclaimable memory with sustained swap-out on {{ $labels.host }}'),
        alert('HostIoPressure', 'avg by (host) (rate(node_cpu_seconds_total{mode="iowait"}[5m])) > 0.20', '10m', 'Sustained I/O wait on {{ $labels.host }}'),
        alert('HostOomKill', 'increase(node_vmstat_oom_kill[10m]) > 0', '0m', 'Kernel killed a process for memory exhaustion on {{ $labels.host }}', 'critical'),
        alert('DiskSpaceLow', 'node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|devtmpfs"} / node_filesystem_size_bytes < 0.15 and node_filesystem_readonly == 0', '10m', 'Disk space below 15% on {{ $labels.host }}'),
        alert('DiskSpaceCritical', 'node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|devtmpfs"} / node_filesystem_size_bytes < 0.05 and node_filesystem_readonly == 0', '2m', 'Disk space below 5% on {{ $labels.host }}', 'critical'),
        alert('DiskWillFill', 'predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|devtmpfs"}[6h], 86400) < 0 and node_filesystem_readonly == 0', '30m', 'Disk may fill within 24 hours on {{ $labels.host }}'),
        alert('HeapPressure', 'monitoring:heap_ratio > 0.85', '10m', '{{ $labels.service }} heap usage above 85% of limit'),
        alert('HeapCritical', 'monitoring:heap_ratio > 0.95', '3m', '{{ $labels.service }} heap usage above 95% of limit', 'critical'),
        alert('RestartLoop', 'changes(monitoring_process_start_time_seconds[15m]) >= 3', '0m', '{{ $labels.service }} restarted at least 3 times in 15 minutes', 'critical'),
        alert('HttpErrors', 'monitoring:http_error_ratio5m > 0.05 and on(host,service) monitoring:http_requests5m >= 100', '5m', '{{ $labels.service }} errors exceed 5%', 'critical'),
        alert('CertificateExpiring', 'probe_ssl_earliest_cert_expiry - time() < 14 * 86400', '30m', '{{ $labels.service }} certificate expires within 14 days'),
        alert('MonitoringRuleFailures', 'increase(prometheus_rule_evaluation_failures_total[5m]) > 0', '5m', 'Monitoring rule evaluations failing', 'critical'),
        alert('MonitoringNotificationFailures', 'increase(alertmanager_notifications_failed_total[10m]) > 0', '5m', 'Monitoring notification delivery failing', 'critical'),
        alert('MonitoringComponentUnavailable', 'up{kind="monitor"} == 0', '3m', 'Monitoring component {{ $labels.job }} unavailable', 'critical'),
    ]
    for service in services:
        labels = '{host="' + target + '",service="' + service['name'] + '",kind="runtime"}'
        missing = alert('RuntimeTargetMissing', 'absent(up' + labels + ')', '5m', service['name'] + ' disappeared from scrape inventory', 'critical')
        missing['labels'].update(host=target, service=service['name'])
        rules.append(missing)
        if service.get('latency_p95_seconds'):
            latency = alert('HttpLatencyHigh', 'monitoring:http_p95_seconds{host="' + target + '",service="' + service['name'] + '"} > ' + str(service['latency_p95_seconds']) + ' and on(host,service) monitoring:http_requests5m >= 100', '10m', service['name'] + ' p95 latency above established threshold')
            latency['labels'].update(host=target, service=service['name'])
            rules.append(latency)
    records = [
        ('monitoring:http_requests5m', 'sum by(host,service) (increase(monitoring_http_request_duration_seconds_count[5m]))'),
        ('monitoring:http_rps5m', 'sum by(host,service) (rate(monitoring_http_request_duration_seconds_count[5m]))'),
        ('monitoring:http_error_ratio5m', '(sum by(host,service) (rate(monitoring_http_requests_total{status=~"5..|aborted"}[5m])) or on(host,service) (0 * sum by(host,service) (rate(monitoring_http_request_duration_seconds_count[5m])))) / sum by(host,service) (rate(monitoring_http_request_duration_seconds_count[5m]))'),
        ('monitoring:heap_ratio', 'monitoring_heap_used_bytes / monitoring_heap_limit_bytes'),
    ]
    for quantile in [90, 95, 99]:
        records.append((f'monitoring:http_p{quantile}_seconds', f'histogram_quantile({quantile / 100}, sum by(host,service,le) (rate(monitoring_http_request_duration_seconds_bucket[5m])))'))
    return {'groups': [{'name': 'monitoring-recordings', 'rules': [dict(record=k, expr=v) for k, v in records]},
                       {'name': 'monitoring-alerts', 'rules': rules}]}


def render(root, monitor, target, target_ip, monitor_ip, services, watchdog=False, hostname=None, target_os=None):
    root = Path(root)
    dashboard_host = hostname or monitor_ip
    endpoint = f'{target_ip}:19443'
    jobs = []
    def scrape(job, kind, service, address, path='/metrics'):
        jobs.append({'job_name': job, 'metrics_path': path, 'scrape_timeout': '10s',
                     'static_configs': [{'targets': [address], 'labels': {'host': target, 'service': service, 'kind': kind}}]})
    scrape('host', 'host', 'host', endpoint, '/node')
    for service in services:
        name = service['name']
        scrape('runtime-' + name, 'runtime', name, endpoint, '/runtime/' + name)
        if service.get('metrics_path'):
            scrape('app-' + name, 'app', name, endpoint, '/app/' + name)
        if service.get('public_url'):
            jobs.append({'job_name': 'public-' + name, 'metrics_path': '/probe', 'params': {'module': ['http_2xx']},
                         'static_configs': [{'targets': [service['public_url']], 'labels': {'host': target, 'service': name, 'kind': 'public'}}],
                         'relabel_configs': [{'source_labels': ['__address__'], 'target_label': '__param_target'},
                                             {'source_labels': ['__param_target'], 'target_label': 'instance'},
                                             {'target_label': '__address__', 'replacement': '127.0.0.1:19115'}]})
    for name, port in [('prometheus', 19090), ('alertmanager', 19093), ('blackbox', 19115)]:
        jobs.append({'job_name': name, 'static_configs': [{'targets': [f'127.0.0.1:{port}'], 'labels': {'host': monitor, 'kind': 'monitor', 'service': name}}]})
    write_json(root / 'prometheus.json', {'global': {'scrape_interval': '15s', 'evaluation_interval': '15s', 'external_labels': {'monitor': monitor}},
                                        'rule_files': [str(root / 'rules.json')],
                                        'alerting': {'alertmanagers': [{'static_configs': [{'targets': ['127.0.0.1:19093']}]}]}, 'scrape_configs': jobs})
    write_json(root / 'rules.json', make_rules(services, target))
    write_json(root / 'blackbox.json', {'modules': {'http_2xx': {'prober': 'http', 'timeout': '8s', 'http': {'preferred_ip_protocol': 'ip4', 'follow_redirects': True, 'headers': {'User-Agent': 'ServerToolingMonitoring/1.0'}}}}})
    receivers = [{'name': 'silent'}, {'name': 'pushover', 'pushover_configs': [{
        'user_key_file': str(root / 'secrets/PUSHOVER_USER_KEY'),
        'token_file': str(root / 'secrets/PUSHOVER_API_KEY_MONITORING'),
        'send_resolved': True,
        'priority': '{{ if eq .Status "resolved" }}0{{ else if eq .CommonLabels.severity "critical" }}1{{ else }}0{{ end }}',
        'title': '[{{ .Status | toUpper }}] {{ .CommonLabels.host }} {{ .CommonLabels.service }}',
        'message': '{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}',
        'url': f'http://{dashboard_host}:13000/d/monitoring-fleet', 'url_title': 'Monitoring dashboards',
    }]}]
    routes = [{'matchers': ['alertname="MonitoringWatchdog"'], 'receiver': 'watchdog' if watchdog else 'silent', 'group_wait': '0s', 'group_interval': '1m', 'repeat_interval': '1m'}]
    if watchdog:
        receivers.append({'name': 'watchdog', 'webhook_configs': [{'url_file': str(root / 'secrets' / ('HEALTHCHECKS_PING_URL_' + monitor.upper())), 'send_resolved': False}]})
    write_json(root / 'alertmanager.json', {'global': {'resolve_timeout': '5m'},
        'route': {'receiver': 'pushover', 'group_by': ['host', 'service', 'alertname'], 'group_wait': '30s', 'group_interval': '5m', 'repeat_interval': '4h', 'routes': routes},
        'receivers': receivers,
        'inhibit_rules': [
            {'source_matchers': ['alertname="MetricsAccessUnavailable"'], 'target_matchers': ['alertname=~"RuntimeUnavailable|AppMetricsUnavailable"'], 'equal': ['host']},
            {'source_matchers': ['alertname="HeapCritical"'], 'target_matchers': ['alertname="HeapPressure"'], 'equal': ['host', 'service']},
            {'source_matchers': ['alertname="DiskSpaceCritical"'], 'target_matchers': ['alertname="DiskSpaceLow"'], 'equal': ['host', 'device', 'mountpoint']}
        ]})
    write_json(root / 'grafana/provisioning/datasources/monitoring.yaml', {'apiVersion': 1, 'datasources': [
        {'name': 'Monitoring Prometheus', 'uid': 'monitoring-prometheus', 'type': 'prometheus', 'access': 'proxy', 'url': 'http://127.0.0.1:19090', 'isDefault': True, 'editable': False},
        {'name': 'Monitoring Alertmanager', 'uid': 'monitoring-alertmanager', 'type': 'alertmanager', 'access': 'proxy', 'url': 'http://127.0.0.1:19093', 'jsonData': {'implementation': 'prometheus'}, 'editable': False}]})
    write_json(root / 'grafana/provisioning/dashboards/monitoring.yaml', {'apiVersion': 1, 'providers': [{'name': 'Monitoring', 'folder': 'Monitoring', 'type': 'file', 'updateIntervalSeconds': 30, 'options': {'path': str(root / 'grafana/dashboards')}}]})
    (root / 'grafana.ini').write_text(f'''[server]
http_addr = {monitor_ip}
http_port = 13000
domain = {dashboard_host}
root_url = http://{dashboard_host}:13000/
[paths]
data = {root}/data/grafana
logs = {root}/logs
plugins = {root}/data/grafana/plugins
provisioning = {root}/grafana/provisioning
[security]
admin_user = admin
admin_password = $__file{{{root}/secrets/GRAFANA_PASSWORD}}
[users]
allow_sign_up = false
[auth.anonymous]
enabled = false
''')
    dashboards(root, target_os)


def dashboards(root, target_os=None):
    selector = '{host=~"$host",service=~"$service"}'
    def panel(title, expression, unit='short', description='', legend='{{service}}'):
        return {'title': title, 'type': 'timeseries', 'datasource': {'type': 'prometheus', 'uid': 'monitoring-prometheus'},
                'targets': [{'expr': expression, 'legendFormat': legend, 'refId': 'A'}],
                'fieldConfig': {'defaults': {'unit': unit}, 'overrides': []}, 'description': description}
    def dashboard(slug, title, panels):
        for index, item in enumerate(panels):
            item.update(id=index + 1, gridPos={'x': (index % 2) * 12, 'y': (index // 2) * 8, 'w': 12, 'h': 8})
        write_json(root / f'grafana/dashboards/{slug}.json', {
            'uid': 'monitoring-' + slug, 'title': title, 'schemaVersion': 39, 'version': 1, 'refresh': '30s',
            'time': {'from': 'now-6h', 'to': 'now'}, 'tags': ['monitoring'], 'panels': panels,
            'links': [{'title': 'Monitoring dashboards', 'type': 'dashboards', 'tags': ['monitoring']}],
            'templating': {'list': [
                {'name': 'host', 'type': 'query', 'datasource': {'type': 'prometheus', 'uid': 'monitoring-prometheus'}, 'query': 'label_values(up, host)', 'refresh': 1, 'includeAll': True, 'allValue': '.*', 'current': {'text': 'All', 'value': '$__all'}},
                {'name': 'service', 'type': 'query', 'datasource': {'type': 'prometheus', 'uid': 'monitoring-prometheus'}, 'query': 'label_values(up{host=~"$host"}, service)', 'refresh': 1, 'includeAll': True, 'allValue': '.*', 'current': {'text': 'All', 'value': '$__all'}}]}})
    dashboard('fleet', 'Fleet overview', [
        panel('Runtime availability', 'up{kind="runtime",host=~"$host",service=~"$service"}'),
        panel('Public HTTPS availability', 'probe_success' + selector),
        panel('Requests per second', 'monitoring:http_rps5m' + selector, 'reqps'),
        panel('Server errors / aborted requests', 'monitoring:http_error_ratio5m' + selector, 'percentunit'),
        panel('p95 response time', 'monitoring:http_p95_seconds' + selector, 's'),
        panel('Heap used / V8 limit', 'monitoring:heap_ratio' + selector, 'percentunit'),
        panel('Active alerts', 'ALERTS{alertstate="firing",alertname!="MonitoringWatchdog"}')])
    dashboard('service', 'Service health', [
        panel('HTTP responses by status', 'sum by(service,status) (rate(monitoring_http_requests_total' + selector + '[5m]))', 'reqps', legend='{{service}} · {{status}}'),
        panel('HTTP latency p90 / p95 / p99', '{__name__=~"monitoring:http_p(90|95|99)_seconds",host=~"$host",service=~"$service"}', 's', legend='{{service}} · {{__name__}}'),
        panel('CPU cores used', 'rate(monitoring_process_cpu_seconds_total' + selector + '[5m])'),
        panel('Resident memory', 'monitoring_process_resident_memory_bytes' + selector, 'bytes'),
        panel('Heap used', 'monitoring_heap_used_bytes' + selector, 'bytes'),
        panel('Heap limit', 'monitoring_heap_limit_bytes' + selector, 'bytes'),
        panel('External memory', 'monitoring_external_memory_bytes' + selector, 'bytes'),
        panel('Event-loop p99 delay', 'monitoring_event_loop_delay_p99_seconds' + selector, 's'),
        panel('Time spent in garbage collection', 'rate(monitoring_gc_duration_seconds_total' + selector + '[5m])', 'percentunit'),
        panel('Restarts in 1 hour', 'changes(monitoring_process_start_time_seconds' + selector + '[1h])')])
    memory_panels = []
    if target_os != 'darwin':
        memory_panels.append(panel('Available memory (Linux)', 'node_memory_MemAvailable_bytes{kind="host",host=~"$host"}', 'bytes', legend='{{host}}'))
    if target_os != 'linux':
        memory_panels.append(panel('Memory by type (macOS)', '{__name__=~"node_memory_(free|active|inactive|wired|compressed)_bytes",kind="host",host=~"$host"}', 'bytes', legend='{{__name__}}'))
    dashboard('host', 'Host health', [
        panel('CPU busy', '1 - avg by(host) (rate(node_cpu_seconds_total{kind="host",mode="idle",host=~"$host"}[5m]))', 'percentunit', legend='{{host}}'),
        *memory_panels,
        panel('Filesystem free space', 'node_filesystem_avail_bytes{kind="host",host=~"$host",fstype!~"tmpfs|overlay|squashfs|devtmpfs|efivarfs"}', 'bytes', legend='{{host}} · {{mountpoint}}'),
        panel('Disk reads', 'rate(node_disk_read_bytes_total{kind="host",host=~"$host"}[5m])', 'Bps', legend='{{host}} · {{device}}'),
        panel('Disk writes', 'rate(node_disk_written_bytes_total{kind="host",host=~"$host"}[5m])', 'Bps', legend='{{host}} · {{device}}'),
        panel('Read latency', 'rate(node_disk_read_time_seconds_total{kind="host",host=~"$host"}[5m]) / rate(node_disk_reads_completed_total{kind="host",host=~"$host"}[5m])', 's', legend='{{host}} · {{device}}'),
        panel('Network received', 'rate(node_network_receive_bytes_total{kind="host",host=~"$host"}[5m])', 'Bps', legend='{{host}} · {{device}}')])
    dashboard('monitor', 'Monitoring health', [
        panel('Scrape success', 'up{host=~"$host",service=~"$service"}'),
        panel('Scrape duration', 'scrape_duration_seconds{host=~"$host"}', 's'),
        panel('Stored metric series', 'prometheus_tsdb_head_series'),
        panel('Rule failures', 'rate(prometheus_rule_evaluation_failures_total[5m])'),
        panel('Notification failures', 'increase(alertmanager_notifications_failed_total[1h])'),
        panel('Watchdog firing', 'ALERTS{alertname="MonitoringWatchdog",alertstate="firing"}')])
