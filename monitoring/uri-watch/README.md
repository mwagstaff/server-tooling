# URI Watch

Continuously `curl` a target URI, log each check, and show rolling availability and latency metrics for:

- `10m`
- `30m`
- `1h`
- `24h`

It also includes a live 1-hour timeline (1 character per minute) showing:

- outcome buckets (`S` success-only, `F` failure-only, `M` mixed, `.` no checks)
- latency buckets (`.` no successes, `_ : - = + * # % @` from fast to slow vs latency SLO)

## Script

`/Users/mwagstaff/dev/server-tooling/monitoring/uri-watch/uri-watch.zsh`

## Usage

```bash
cd /Users/mwagstaff/dev/server-tooling/monitoring/uri-watch
chmod +x ./uri-watch.zsh
./uri-watch.zsh --uri "https://example.com/healthcheck"
```

## Options

```text
--interval <seconds>      Probe interval (default: 30)
--timeout <seconds>       Curl timeout/max-time (default: 15)
--latency-slo-ms <ms>     Success latency threshold for "Latency %" (default: 1000)
--log-file <path>         CSV output path
--header "Name: Value"    Repeatable custom headers for curl
--no-clear                Keep appending output instead of clearing screen
```

## Example

```bash
./uri-watch.zsh \
  --uri "https://api.skynolimit.dev/healthcheck" \
  --interval 30 \
  --timeout 10 \
  --latency-slo-ms 800
```

## Notes

- Success: HTTP status `< 400`
- Failure: HTTP status `>= 400` or any curl/network error
- Log file defaults to:
  - `/Users/mwagstaff/dev/server-tooling/monitoring/uri-watch/logs/<sanitized-uri>.csv`
