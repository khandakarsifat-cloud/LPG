"""Policy/auth tests; do not open Google Drive or a real database."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import runpy
import tempfile
import unittest
from unittest.mock import patch

FOLDER = Path(__file__).parent / 'backup'
sys.path.insert(0, str(FOLDER))
import core
import control
import worker


class BackupPolicyTests(unittest.TestCase):
    def test_dhaka_window_and_no_daytime_catchup(self):
        self.assertTrue(core.window(dt.datetime(2026, 11, 2, 20, 0, tzinfo=dt.timezone.utc)))
        self.assertFalse(core.window(dt.datetime(2026, 11, 2, 20, 15, tzinfo=dt.timezone.utc)))
        self.assertFalse(core.window(dt.datetime(2026, 11, 2, 8, 0, tzinfo=dt.timezone.utc)))
        self.assertEqual(core.next_run(dt.datetime(2026, 11, 2, 19, 0, tzinfo=dt.timezone.utc)), '2026-11-03T02:00:00+06:00')
        with patch('worker.window', return_value=False), patch('worker.restic') as remote:
            with self.assertRaisesRegex(RuntimeError, 'only'):
                worker.nightly()
            remote.assert_not_called()

    def test_exact_30_calendar_days_12_monthly_fulls_and_latest_daily(self):
        clock = dt.datetime(2026, 11, 3, 3, tzinfo=core.DHAKA)
        snapshots = []
        for offset in range(45):
            day = clock - dt.timedelta(days=offset)
            snapshots.append({'id': f'daily-{offset}', 'time': day.isoformat(), 'tags': ['lpg-system']})
        for index in range(16):
            year, month = divmod(2026 * 12 + 10 - index, 12)
            snapshots.append({'id': f'full-{index}', 'time': dt.datetime(year, month + 1, 1, 2, tzinfo=core.DHAKA).isoformat(), 'tags': ['lpg-system', 'monthly-full']})
        keep = core.retain_ids(snapshots, clock)
        self.assertTrue(all(f'full-{i}' in keep for i in range(12)))
        self.assertFalse(any(f'full-{i}' in keep for i in range(12, 16)))
        self.assertIn('daily-29', keep)
        self.assertNotIn('daily-30', keep)
        snapshots.append({'id': 'latest-today', 'time': (clock + dt.timedelta(hours=1)).isoformat(), 'tags': ['lpg-system']})
        keep = core.retain_ids(snapshots, clock)
        self.assertIn('latest-today', keep)
        self.assertNotIn('daily-0', keep)

    def test_foreign_snapshots_are_never_selected_for_lpg_retention(self):
        self.assertEqual(core.retain_ids([{'id': 'foreign', 'time': core.now().isoformat(), 'tags': ['another-app']}]), set())

    def test_sealing_copies_mutable_metadata_and_links_payloads(self):
        with tempfile.TemporaryDirectory() as folder:
            source, target = Path(folder) / 'source', Path(folder) / 'target'
            source.mkdir()
            (source / 'backup.info').write_text('old')
            (source / 'payload').write_text('data')
            worker.sealed_repository(source, target)
            (source / 'backup.info').write_text('new')
            self.assertEqual((target / 'backup.info').read_text(), 'old')
            self.assertEqual((target / 'payload').stat().st_ino, (source / 'payload').stat().st_ino)

    def test_verification_failure_preserves_capture_and_never_prunes(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            capture = state / 'capture'
            capture.mkdir()
            manifest = {'label': 'test-label', 'captured_at': core.now().isoformat(), 'monthly': False}
            core.write(capture / 'manifest.json', manifest)
            calls = []
            snapshot = {'id': 'a' * 64, 'tags': ['lpg-system', 'point:test-label'], 'time': manifest['captured_at']}

            def repository(*args):
                calls.append(args)
                if args[0] == 'cat':
                    return json.dumps({'id': 'repo-test'})
                if args[0] == 'snapshots':
                    return json.dumps([snapshot])
                if args[0] == 'check':
                    raise RuntimeError('Simulated damaged pack')
                return ''

            with patch('worker.STATE', state), patch('worker.CAPTURE', capture), patch('worker.restic', side_effect=repository), patch('worker.command', return_value='[{"Name":"LPG-System-Recovery"}]'):
                with self.assertRaisesRegex(RuntimeError, 'damaged pack'):
                    worker.upload(manifest)
            self.assertTrue((capture / 'manifest.json').exists())
            self.assertFalse(any(args[0] in ('forget', 'prune') for args in calls))
            self.assertEqual(core.read(state / 'history.json')[0]['status'], 'uploaded')

    def test_unavailable_drive_never_initializes_or_prunes(self):
        with patch('worker.command', side_effect=RuntimeError('Drive unavailable')), patch('worker.restic') as repository:
            with self.assertRaisesRegex(RuntimeError, 'unavailable'):
                worker.upload({'label': 'test'})
            repository.assert_not_called()

    def test_crash_recovery_starts_storage_only_with_a_backup_pause_marker(self):
        with tempfile.TemporaryDirectory() as folder, patch('worker.STATE', Path(folder)), patch('worker.compose') as compose:
            worker.resume_storage()
            compose.assert_not_called()
            core.write(Path(folder) / 'storage-paused.json', {'paused_by_backup_at': 'test'})
            worker.resume_storage()
            self.assertEqual(compose.call_args.args[-1], 'storage')
            self.assertFalse((Path(folder) / 'storage-paused.json').exists())

    def test_startup_does_not_wait_on_a_deployment_lock(self):
        with tempfile.TemporaryDirectory() as folder, patch('core.STATE', Path(folder)), patch('sys.argv', ['worker.py', '--resume-storage', '--if-idle']), patch('core.Lock') as lock:
            lock.side_effect = AssertionError('No pause marker means no lock is needed')
            runpy.run_path(str(FOLDER / 'worker.py'), run_name='__main__')
            lock.assert_not_called()
            core.write(Path(folder) / 'storage-paused.json', {'paused_by_backup_at': 'test'})
            lock.side_effect = BlockingIOError('Deployment owns the lock')
            runpy.run_path(str(FOLDER / 'worker.py'), run_name='__main__')
            self.assertFalse(lock.call_args.kwargs['blocking'])


class BackupAuthorizationTests(unittest.TestCase):
    def test_server_revalidates_auth_and_superadmin_and_rejects_first_login(self):
        active = {'is_superadmin': True, 'access_status': 'active', 'must_change_password': False}
        with patch('control.read', return_value={'publicKey': 'public-test-key'}):
            for context in [dict(active, is_superadmin=False), dict(active, must_change_password=True), dict(active, reset_pending=True), dict(active, access_status='disabled')]:
                with patch('control.request_json', side_effect=[{'id': 'fixture'}, context]), self.assertRaises(control.Fault):
                    control.authenticate('Bearer fixture')
            with patch('control.request_json', side_effect=[{'id': 'fixture'}, active]):
                self.assertEqual(control.authenticate('Bearer fixture'), 'fixture')

    def test_status_reads_cache_without_cloud_access(self):
        with tempfile.TemporaryDirectory() as folder, patch('control.STATE', Path(folder)), patch('control.SECRETS', Path(folder)), patch('control.command') as cloud:
            self.assertFalse(control.status()['connection']['connected'])
            cloud.assert_not_called()

    def test_bad_or_expired_oauth_state_never_exchanges_tokens(self):
        with patch('control.read', return_value={}), patch('control.request_json') as google:
            with self.assertRaises(control.Fault):
                control.callback({'state': ['forged'], 'code': ['bad-code']})
            google.assert_not_called()

    def test_oauth_requests_offline_file_scope_pkce_and_fixed_callback(self):
        with tempfile.TemporaryDirectory() as folder, patch('control.SECRETS', Path(folder)), patch('control.event'):
            core.write(Path(folder) / 'google-client.json', {'web': {'client_id': 'public-client', 'client_secret': 'test-secret'}})
            result = control.start_connect('Bearer fixture-secret', 'fixture-admin')
            self.assertIn('access_type=offline', result['url'])
            self.assertIn('code_challenge_method=S256', result['url'])
            self.assertNotIn('test-secret', result['url'])
            self.assertNotIn('fixture-secret', result['url'])
            pending = core.read(Path(folder) / 'pending-oauth.json')
            self.assertNotIn('state', pending)
            self.assertEqual(pending['actor'], 'fixture-admin')
