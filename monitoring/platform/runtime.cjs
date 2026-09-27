'use strict';

// Opt-in Node preload. No dependencies; never binds on a public interface.
const { isMainThread } = require('node:worker_threads');
const path = require('node:path');
if (isMainThread && process.env.MONITORING_ENTRY &&
    path.resolve(process.argv[1] || '') === process.env.MONITORING_ENTRY) {
  const http = require('node:http');
  const v8 = require('node:v8');
  const { performance, monitorEventLoopDelay, PerformanceObserver } = require('node:perf_hooks');
  const buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60];
  const startedAt = Date.now() / 1000 - process.uptime();
  const requests = new Map();
  const durations = buckets.map(() => 0);
  let count = 0, sum = 0, active = 0, gcCount = 0, gcSeconds = 0;
  const delay = monitorEventLoopDelay({ resolution: 20 });
  delay.enable();
  const observer = new PerformanceObserver(list => {
    for (const entry of list.getEntries()) { gcCount++; gcSeconds += entry.duration / 1000; }
  });
  observer.observe({ entryTypes: ['gc'] });
  const internal = Symbol('monitoring');
  const emit = http.Server.prototype.emit;
  http.Server.prototype.emit = function (event, ...args) {
    if (event === 'request' && !this[internal]) {
      const [req, res] = args;
      // Scrapes and liveness requests must not dominate quiet services' traffic.
      const pathname = (req.url || '').split('?')[0];
      if (!['/metrics', '/healthcheck', '/health', '/health/ready'].includes(pathname)) {
        const start = performance.now();
        let done = false;
        active++;
        const finish = () => {
          if (done) return;
          done = true;
          active--;
          const seconds = (performance.now() - start) / 1000;
          const status = res.writableFinished ? String(res.statusCode) : 'aborted';
          requests.set(status, (requests.get(status) || 0) + 1);
          count++; sum += seconds;
          buckets.forEach((limit, i) => { if (seconds <= limit) durations[i]++; });
        };
        res.once('finish', finish);
        res.once('close', finish);
      }
    }
    return emit.call(this, event, ...args);
  };
  const server = http.createServer((req, res) => {
    if (req.url !== '/metrics') { res.writeHead(404); res.end(); return; }
    const memory = process.memoryUsage(), heap = v8.getHeapStatistics(), cpu = process.cpuUsage();
    const lines = [];
    function metric(name, type, value, labels = '') {
      lines.push(`# TYPE monitoring_${name} ${type}`, `monitoring_${name}${labels} ${Number.isFinite(value) ? value : 0}`);
    }
    metric('runtime_info', 'gauge', 1);
    metric('process_start_time_seconds', 'gauge', startedAt);
    metric('process_cpu_seconds_total', 'counter', (cpu.user + cpu.system) / 1e6);
    metric('process_resident_memory_bytes', 'gauge', memory.rss);
    metric('heap_used_bytes', 'gauge', heap.used_heap_size);
    metric('heap_limit_bytes', 'gauge', heap.heap_size_limit);
    metric('external_memory_bytes', 'gauge', memory.external);
    metric('event_loop_delay_p99_seconds', 'gauge', delay.percentile(99) / 1e9);
    metric('gc_duration_seconds_total', 'counter', gcSeconds);
    metric('gc_runs_total', 'counter', gcCount);
    metric('http_requests_in_flight', 'gauge', active);
    lines.push('# TYPE monitoring_http_requests_total counter');
    for (const [status, value] of requests) lines.push(`monitoring_http_requests_total{status="${status}"} ${value}`);
    lines.push('# TYPE monitoring_http_request_duration_seconds histogram');
    buckets.forEach((limit, i) => lines.push(`monitoring_http_request_duration_seconds_bucket{le="${limit}"} ${durations[i]}`));
    lines.push(`monitoring_http_request_duration_seconds_bucket{le="+Inf"} ${count}`);
    lines.push(`monitoring_http_request_duration_seconds_count ${count}`, `monitoring_http_request_duration_seconds_sum ${sum}`);
    delay.reset();
    res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4' });
    res.end(lines.join('\n') + '\n');
  });
  server[internal] = true;
  server.on('error', error => console.error('[monitoring] metrics listener failed:', error.code));
  server.listen(Number(process.env.MONITORING_PORT), '127.0.0.1');
  server.unref();
}
