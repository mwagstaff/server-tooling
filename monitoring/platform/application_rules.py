"""Application checks in the active cross-host monitoring stack."""


def application_rules(services, host, alert):
    names = {s['name'] for s in services}
    rules = [
        alert('AppCheckFailing', 'app_check_ok == 0', '5m', '{{ $labels.service }} check {{ $labels.check }} failing'),
        alert('AppCheckFailingLong', 'app_check_ok == 0', '30m', '{{ $labels.service }} check {{ $labels.check }} failing for 30 minutes', 'critical'),
    ]

    if host == 'mini':
        rules.append(alert('HighLoad', 'node_load5{host="mini"} > 8', '15m', 'Mini sustained load average exceeds 8'))

    def add(service, name, expr, duration, summary, severity='warning'):
        if service in names:
            rule = alert(name, expr, duration, summary, severity)
            # Aggregation can remove input labels; always retain the recovery target.
            rule['labels'].update(service=service, host=host)
            rules.append(rule)

    planner = 'service="train-track-planner"'
    for name, expr, duration, summary in [
        ('PlannerTimetableUpdateFailed', f'timetable_ingestion_last_result{{{planner},result=~"error|gap"}} == 1', '1m', 'Planner timetable update failed'),
        ('PlannerTimetableCheckOverdue', f'time() - timetable_ingestion_last_check_timestamp_seconds{{{planner}}} > 7200', '10m', 'Planner has not checked for timetable updates in two hours'),
        ('PlannerTimetableStateUnreadable', f'timetable_ingestion_state_readable{{{planner}}} == 0', '3m', 'Planner ingestion state cannot be read'),
        ('PlannerTimetableIngestionDisabled', f'timetable_ingestion_enabled{{{planner}}} == 0', '3m', 'Planner ingestion is disabled'),
        ('PlannerTimetableRunAbandoned', f'timetable_ingestion_abandoned_run{{{planner}}} == 1', '3m', 'Planner worker died during an update'),
    ]:
        add('train-track-planner', name, expr, duration, summary, 'critical')

    tube = 'service="tube-track-api"'
    for name, expr, duration, summary, severity in [
        ('TubeTrackLiveCacheStale', f'tube_track_live_cache_age_seconds{{{tube}}} > 300', '5m', 'TubeTrack arrivals cache is over five minutes old', 'warning'),
        ('TubeTrackLiveCacheStaleCritical', f'tube_track_live_cache_age_seconds{{{tube}}} > 1800', '5m', 'TubeTrack arrivals cache is over thirty minutes old', 'critical'),
        ('TubeTrackLiveRefreshFailing', f'sum(increase(tube_track_live_refreshes_total{{{tube},status=~"failure|timeout|partial"}}[15m])) / clamp_min(sum(increase(tube_track_live_refreshes_total{{{tube}}}[15m])), 1) > 0.5', '15m', 'Over half of TubeTrack live refreshes are incomplete', 'warning'),
        ('TubeTrackPushSendFailing', f'sum(increase(tube_track_push_sent_total{{{tube},result!="ok"}}[15m])) / clamp_min(sum(increase(tube_track_push_sent_total{{{tube}}}[15m])), 1) > 0.25', '15m', 'Over a quarter of TubeTrack pushes are failing', 'warning'),
        ('TubeTrackPushStoreWriteFailing', f'increase(tube_track_push_store_write_failures_total{{{tube}}}[30m]) > 0', '5m', 'TubeTrack cannot persist its push token store', 'warning'),
        ('TubeTrackPushBudgetExhausted', f'sum(increase(tube_track_push_suppressed_total{{{tube}}}[1h])) > 20', '30m', 'TubeTrack is withholding pushes to stay within its budget', 'warning'),
        ('TubeTrackPushRegistrationFlood', f'sum(increase(tube_track_push_rate_limited_total{{{tube}}}[15m])) > 100', '15m', 'TubeTrack push registrations are being heavily rate-limited', 'warning'),
    ]:
        add('tube-track-api', name, expr, duration, summary, severity)

    # These metrics are exported by the main Top Scores API, not the BSD process.
    bsd = 'top_scores_bsd_http_requests_total{service="top-scores",status_code=~"0|4..|5..",status_code!="404"}'
    add('top-scores', 'TopScoresBSDUpstreamErrors',
        f'sum by(status_code) (increase({bsd}[10m]) > 0 or ({bsd} unless {bsd} offset 10m)) > 0',
        '1m', 'Top Scores BSD upstream failures (status {{ $labels.status_code }})')
    return rules
