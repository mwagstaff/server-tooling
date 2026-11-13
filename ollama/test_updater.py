import importlib.util
import hashlib
import io
import json
import tarfile
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('updater', Path(__file__).with_name('updater.py'))
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)

class FakeUpdater(u.Updater):
    def __init__(self, root):
        super().__init__(root, root / 'ollama')
        self.switched = []
        self.paused = False
        self.fail_target = False
        self.fail_rollback = False
        self.busy = False
        self.save(installedVersion='0.40.0')
    def stage(self, release): return self.ollama / 'releases' / release['tag_name']
    def gate(self, method):
        if method == 'POST': self.paused = True
        if method == 'DELETE': self.paused = False
        return {'paused': self.paused, 'active': 0, 'owner': self.state['owner']}
    def drain(self): self.gate('POST'); return not self.busy
    def silence(self): pass
    def switch(self, directory): self.switched.append(str(directory))
    def smoke(self, expected):
        if (expected == 'v0.40.12' and self.fail_target) or (expected == '0.40.0' and self.fail_rollback):
            raise RuntimeError('smoke failed')

class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
    def test_policy_excludes_prereleases_young_and_minor_versions(self):
        now = datetime(2026,10,29,tzinfo=timezone.utc).timestamp()
        rows = [{'tag_name': tag, 'published_at': date, 'prerelease': pre} for tag,date,pre in [
            ('v0.40.12','2026-10-26T00:00:00Z',False),('v0.40.13','2026-10-28T00:00:00Z',False),
            ('v0.41.0','2026-10-25T00:00:00Z',False),('v0.40.14','2026-10-25T00:00:00Z',True)]]
        latest, candidate = u.choose_release(rows, '0.40.0', now)
        self.assertEqual(latest['tag_name'],'v0.41.0')
        self.assertEqual(candidate['tag_name'],'v0.40.12')
    def test_window_uses_london_and_dst(self):
        for stamp, expected in [('2026-10-28T12:00:00+00:00',True),('2026-07-01T11:00:00+00:00',True),
                                ('2026-10-29T12:00:00+00:00',False),('2026-10-28T14:00:00+00:00',False)]:
            self.assertEqual(u.install_window(datetime.fromisoformat(stamp).timestamp()),expected)
    def archive(self, name='ollama', link=None):
        path = self.root/'fixture.tgz'
        with tarfile.open(path,'w:gz') as t:
            m=tarfile.TarInfo(name)
            if link:
                m.type=tarfile.SYMTYPE;m.linkname=link;t.addfile(m)
            else:
                m.size=4;t.addfile(m,io.BytesIO(b'test'))
        return path,'sha256:'+hashlib.sha256(path.read_bytes()).hexdigest()
    def test_corrupt_and_unsafe_archives_rejected_before_install(self):
        p,h=self.archive()
        with self.assertRaisesRegex(ValueError,'checksum'): u.extract_verified(p,self.root/'out','sha256:'+'0'*64)
        for name,link in [('../escape',None),('evil','../../escape')]:
            p,h=self.archive(name,link)
            with self.assertRaisesRegex(ValueError,'Unsafe'): u.extract_verified(p,self.root/'out',h)
        p,h=self.archive();u.extract_verified(p,self.root/'out',h)
        self.assertEqual((self.root/'out/ollama').read_text(),'test')
    def test_smoke_requires_completion_and_exact_schema(self):
        valid=[json.dumps({'message':{'content':'{"ok":true,"number":7}'},'done':True}).encode()]
        u.validate_stream(valid)
        for rows in [[b'{"message":{"content":"{}"}}'],[b'{"error":"crashed"}'],[b'{"done":true,"message":{"content":"{}"}}']]:
            with self.assertRaises(ValueError): u.validate_stream(rows)
    def test_success_commits_and_resumes(self):
        f=FakeUpdater(self.root);f.apply({'tag_name':'v0.40.12'})
        self.assertEqual(f.state['installedVersion'],'0.40.12');self.assertFalse(f.paused)
        self.assertEqual(f.state['phase'],'idle');self.assertEqual(len(f.switched),1)
    def test_busy_defers_without_switch(self):
        f=FakeUpdater(self.root);f.busy=True;f.apply({'tag_name':'v0.40.12'})
        self.assertEqual(f.switched,[]);self.assertFalse(f.paused)
        self.assertEqual(f.state['lastOutcome'],'deferred_busy')
    def test_success_resets_patch_wait_but_preserves_major_review(self):
        for review in (False, True):
            f=FakeUpdater(self.root)
            f.save(pendingSince=1, latestVersion='0.41.0' if review else '0.40.13', reviewRequired=review)
            f.apply({'tag_name':'v0.40.12'})
            self.assertEqual(f.state['pendingSince']==1, review)
        f.save(latestVersion='0.40.12', reviewRequired=False)
        f.apply({'tag_name':'v0.40.12'})
        self.assertIsNone(f.state['pendingSince'])

    def test_legacy_pending_clock_repaired_without_installing(self):
        f=FakeUpdater(self.root)
        f.save(pendingSince=1,lastUpgradeAt=100,latestVersion='0.40.13',lastCheckAt=u.time.time())
        f.tick(install=False)
        self.assertEqual(f.state['pendingSince'],100)
        self.assertEqual(f.switched,[])
        f.save(pendingSince=1,reviewRequired=True)
        f.tick(install=False)
        self.assertEqual(f.state['pendingSince'],1)
    def test_failed_generation_restores_previous_and_blocks_release(self):
        f=FakeUpdater(self.root);f.fail_target=True
        with self.assertRaisesRegex(RuntimeError,'smoke'): f.apply({'tag_name':'v0.40.12'})
        self.assertEqual(len(f.switched),2);self.assertFalse(f.paused)
        self.assertEqual(f.state['installedVersion'],'0.40.0')
        self.assertIn('v0.40.12',f.state['blockedVersions'])
    def test_failed_rollback_keeps_admission_closed(self):
        f=FakeUpdater(self.root);f.fail_target=f.fail_rollback=True
        with self.assertRaises(RuntimeError): f.apply({'tag_name':'v0.40.12'})
        self.assertTrue(f.paused);self.assertEqual(f.state['phase'],'rollback')
    def test_interrupted_switch_recovers_from_persisted_journal(self):
        f=FakeUpdater(self.root)
        f.save(phase='switching',owner='id',previousDir=str(self.root/'ollama/releases/old'),previousVersion='0.40.0',targetVersion='v0.40.12')
        other=FakeUpdater(self.root);other.recover()
        self.assertEqual(len(other.switched),1);self.assertEqual(other.state['phase'],'idle')
        self.assertIn('v0.40.12',other.state['blockedVersions'])
    def test_interrupted_drain_reopens_without_restarting_busy_model(self):
        f=FakeUpdater(self.root);f.save(phase='draining',owner='id');f.recover()
        self.assertEqual(f.switched,[]);self.assertFalse(f.paused)

    def test_preparation_does_not_install_inside_weekly_window(self):
        f=FakeUpdater(self.root)
        rows=[{'tag_name':'v0.40.12','published_at':'2026-10-20T00:00:00Z'}]
        with patch.object(f,'installed',return_value='0.40.0'), patch.object(u,'request',return_value=rows), patch.object(u,'install_window',return_value=True):
            f.tick(check_now=True,install=False)
        self.assertEqual(f.switched,[])
        self.assertEqual(f.state['candidate']['tag_name'],'v0.40.12')

    def test_changed_signer_and_wrong_architecture_rejected(self):
        archive,digest=self.archive()
        staging=self.root/'staging';staging.mkdir()
        (staging/'ollama-v0.40.12.tgz').write_bytes(archive.read_bytes())
        release={'tag_name':'v0.40.12','assets':[{'name':'ollama-darwin.tgz','digest':digest,
            'browser_download_url':'https://github.com/ollama/ollama/releases/download/v0.40.12/ollama-darwin.tgz'}]}
        f=u.Updater(self.root,self.root/'ollama')
        with patch.object(u.subprocess,'run',return_value=SimpleNamespace(stderr='TeamIdentifier=OTHER')):
            with self.assertRaisesRegex(ValueError,'identity'):f.stage(release)
        with patch.object(u.subprocess,'run',return_value=SimpleNamespace(stderr='TeamIdentifier=3MU9H2V9Y9')), patch.object(u.subprocess,'check_output',return_value='x86_64'):
            with self.assertRaisesRegex(ValueError,'Apple Silicon'):f.stage(release)

    def test_committed_transaction_resumes_without_rollback(self):
        f=FakeUpdater(self.root);f.paused=True
        f.save(phase='committed',owner='id',installedVersion='0.40.12',lastCheckAt=u.time.time())
        f.tick(install=False)
        self.assertEqual(f.switched,[]);self.assertFalse(f.paused)
        self.assertEqual(f.state['phase'],'idle')

    def test_aiops_request_enforces_patch_policy_and_preserves_transaction_safety(self):
        now = datetime(2026, 11, 12, tzinfo=timezone.utc).timestamp()
        for scenario in ('success', 'busy', 'blocked', 'major', 'young', 'expired', 'interrupted', 'failed', 'not_overdue'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                f = FakeUpdater(Path(directory))
                f.busy = scenario == 'busy'; f.fail_target = scenario == 'failed'
                f.save(phase='idle',pendingSince=now-(86400 if scenario=='not_overdue' else 20*86400),
                       aiopsRequest={'id':'fixture-request','status':'running' if scenario=='interrupted' else 'queued',
                                     'requestedAt':now-700 if scenario=='expired' else now,'expiresAt':now-100 if scenario=='expired' else now+600},
                       blockedVersions=['v0.40.12'] if scenario=='blocked' else [])
                release={'tag_name':'v0.41.0' if scenario=='major' else 'v0.40.12',
                         'published_at':'2026-11-11T00:00:00Z' if scenario=='young' else '2026-10-20T00:00:00Z'}
                with patch.object(f,'installed',return_value='0.40.0'), patch.object(u,'request',return_value=[release]), patch.object(u.time,'time',return_value=now):
                    f.process_aiops_request()
                    switches=len(f.switched)
                    f.process_aiops_request()  # Terminal requests never replay.
                self.assertEqual(len(f.switched),switches)
                expected='succeeded' if scenario in ('success','not_overdue') else 'deferred' if scenario=='busy' else 'failed'
                self.assertEqual(f.state['aiopsRequest']['status'],expected)
                if scenario not in ('success','failed'): self.assertEqual(f.switched,[])
                if scenario=='failed': self.assertIn('v0.40.12',f.state['blockedVersions'])

if __name__=='__main__':unittest.main()
