import unittest
from unittest.mock import patch
from history import History, episodes


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

    def test_missing_or_stale_rule_does_not_claim_recovery(self):
        data = [{'metric': LABELS, 'values': [[100, '1']]}]
        for groups, now in [([], 300), (group(health='err'), 300), (group(), 1000)]:
            self.assertEqual(episodes(data, groups, now)[0]['status'], 'Unknown')

    def test_filters_apply_to_episode_overlap_and_do_not_change_current_status(self):
        history = History()
        history.updated = 300
        history.rows = [{'fired_at': 100000, 'last_firing': 290000, 'host': 'sky', 'service': 'train-track-api', 'status': 'Resolved'}]
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
