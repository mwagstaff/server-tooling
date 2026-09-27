import unittest
from unittest.mock import patch
from history import History, episodes, host_events


LABELS = {'alertname': 'AppMetricsUnavailable', 'host': 'sky', 'service': 'train-track-api', 'severity': 'warning'}


def group(alerts=None, health='ok'):
    return [{'interval': 15, 'lastEvaluation': '1970-01-01T00:05:00Z', 'rules': [{
        'name': LABELS['alertname'], 'type': 'alerting', 'duration': 60, 'health': health,
        'annotations': {'summary': '{{ $labels.service }} application metrics unavailable'}, 'alerts': alerts or []}]}]


class HistoryTests(unittest.TestCase):
    def test_repeated_firings_have_separate_rows_and_current_status(self):
        data = [{'metric': dict(LABELS, __name__='ALERTS', alertstate='firing'),
                 'values': [[100, '1'], [115, '1'], [130, '1'], [280, '1'], [295, '1']]}]
        active = [{'labels': LABELS, 'state': 'firing', 'activeAt': '1970-01-01T00:03:40Z',
                   'annotations': {'summary': 'Current summary'}}]
        rows = episodes(data, group(active), 300)
        self.assertEqual([r['status'] for r in rows], ['Firing', 'Resolved'])
        self.assertEqual([r['fired_at'] for r in rows], [280000, 100000])
        self.assertEqual(rows[1]['summary'], 'train-track-api application metrics unavailable')
        self.assertEqual(rows[0]['summary'], 'Current summary')
        rows = episodes(data, group(), 300)
        self.assertEqual([r['status'] for r in rows], ['Resolved', 'Resolved'])

    def test_pending_to_firing_is_one_episode_and_brief_failure_is_kept(self):
        data = [
            {'metric': dict(LABELS, alertstate='pending'), 'values': [[100, '1'], [115, '1'], [160, '1'], [175, '1']]},
            {'metric': dict(LABELS, alertstate='firing'), 'values': [[190, '1'], [205, '1']]},
        ]
        rows = episodes(data, group(), 300)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['started_at'], 160000)
        self.assertEqual(rows[0]['fired_at'], 190000)
        self.assertEqual(rows[0]['status'], 'Resolved')
        self.assertEqual(rows[1]['status'], 'Recovered (brief)')
        self.assertIsNone(rows[1]['fired_at'])

    def test_current_pending_status_and_recovery(self):
        data = [{'metric': dict(LABELS, alertstate='pending'), 'values': [[280, '1'], [295, '1']]}]
        active = [{'labels': LABELS, 'state': 'pending', 'activeAt': '1970-01-01T00:04:40Z'}]
        self.assertEqual(episodes(data, group(active), 300)[0]['status'], 'Pending')
        self.assertEqual(episodes(data, group(), 300)[0]['status'], 'Recovered (brief)')

    def test_events_deduplicate_scrapes_but_preserve_multiple_reboots(self):
        data = [{'metric': {'__name__': 'node_boot_time_seconds', 'host': 'sky'},
                 'values': [[100, '50'], [115, '50'], [200, '190']]},
                {'metric': {'__name__': 'server_tooling_event_time_seconds', 'host': 'sky',
                            'event': 'weekly-upgrade', 'detail': 'Weekly upgrade started'},
                 'values': [[200, '180'], [215, '180']]}]
        rows = host_events(data)
        self.assertEqual([r['timestamp'] for r in rows], [190000, 180000, 50000])
        self.assertEqual(rows[1]['text'], 'sky: Weekly upgrade started')

    def test_missing_or_stale_rule_does_not_claim_recovery(self):
        data = [{'metric': LABELS, 'values': [[100, '1']]}]
        for groups, now in [([], 300), (group(health='err'), 300), (group(), 1000)]:
            self.assertEqual(episodes(data, groups, now)[0]['status'], 'Unknown')

    def test_filters_apply_to_episode_overlap_and_do_not_change_current_status(self):
        history = History()
        history.updated = 300
        history.rows = [{'started_at': 100000, 'last_seen': 290000, 'host': 'sky', 'service': 'train-track-api', 'status': 'Resolved'}]
        with patch('history.time.time', return_value=310):
            self.assertEqual(history.query(150000, 200000, 'sky')[0]['status'], 'Resolved')
            self.assertEqual(history.query(0, 50000), [])
            self.assertEqual(history.query(150000, 200000, 'mini'), [])
            with self.assertRaises(ValueError):
                history.query(0, 31 * 86400000)

    def test_failed_refresh_never_returns_stale_status(self):
        history = History()
        history.rows = [{'status': 'Resolved'}]
        with patch('history.read_prometheus', side_effect=OSError('offline')):
            with self.assertRaises(OSError):
                history.query(0, 1000)


if __name__ == '__main__':
    unittest.main()
