"""Policy/auth tests; do not open Google Drive or a real database."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import runpy
import tempfile
import unittest
from contextlib import nullcontext
import os
import uuid
from unittest.mock import patch

FOLDER = Path(__file__).parent / 'backup'
sys.path.insert(0, str(FOLDER))
import core
import control
import worker
import restore
import confirmations


class ConfirmationTests(unittest.TestCase):
    def test_proof_is_hashed_bound_and_single_use(self):
        actor = 'f0050000-0000-4000-8000-000000000001'
        target = 'f0050000-0000-4000-8000-000000000002'
        with tempfile.TemporaryDirectory() as folder, patch.object(confirmations, 'SECRETS', Path(folder)), patch.object(confirmations, 'password_identity', return_value=actor):
            result = confirmations.issue(actor, 'Bearer private', 'delete-business', target, 'private-password')
            stored = (Path(folder) / 'confirmations.json').read_text()
            self.assertNotIn(result['confirmation_token'], stored)
            self.assertNotIn('private-password', stored)
            self.assertNotIn('Bearer', stored)
            with self.assertRaises(ValueError):
                confirmations.consume(actor, 'delete-inspection', target, result['confirmation_token'], 'DELETE')
            with self.assertRaises(ValueError):
                confirmations.consume(actor, 'delete-business', target, result['confirmation_token'], 'delete')
            confirmations.consume(actor, 'delete-business', target, result['confirmation_token'], 'DELETE')
            with self.assertRaises(ValueError):
                confirmations.consume(actor, 'delete-business', target, result['confirmation_token'], 'DELETE')

    def test_password_attempts_are_rate_limited(self):
        actor = 'f0050000-0000-4000-8000-000000000001'
        target = 'a' * 64
        with tempfile.TemporaryDirectory() as folder, patch.object(confirmations, 'SECRETS', Path(folder)), patch.object(confirmations, 'password_identity', side_effect=ValueError('Denied')) as password:
            for _ in range(6):
                with self.assertRaises(ValueError):
                    confirmations.issue(actor, 'Bearer private', 'restore', target, 'wrong')
            self.assertEqual(password.call_count, 5)


class BackupPolicyTests(unittest.TestCase):
    def test_engine_stream_keeps_transfer_stats_distinct_from_processed_bytes(self):
        self.assertEqual(worker.engine_message('rclone: {"stats":{"bytes":512},"msg":"Transfer statistics"}')['stats']['bytes'], 512)
        self.assertEqual(worker.engine_message('{"message_type":"status","bytes_done":4096}')['bytes_done'], 4096)
        self.assertEqual(worker.engine_message('rclone: transient diagnostic'), {})
        self.assertEqual(worker.engine_message('not-json {broken'), {})

    def test_transfer_engine_stderr_drives_progress_without_reflecting_tool_errors(self):
        lines = []
        core.command([sys.executable, '-c', 'import sys;print(\'{"message_type":"status","bytes_done":4096}\',flush=True);print(\'rclone: {"stats":{"bytes":512}}\',file=sys.stderr,flush=True)'], on_output=lines.append)
        self.assertTrue(any(worker.engine_message(line).get('stats', {}).get('bytes') == 512 for line in lines))
        with self.assertRaises(RuntimeError) as caught:
            core.command([sys.executable, '-c', 'import sys;print("private-test-secret",file=sys.stderr);sys.exit(1)'], on_output=lambda line: None)
        self.assertNotIn('private-test-secret', str(caught.exception))

    def test_reset_generations_cannot_shadow_current_points_or_expire_protected_copy(self):
        today = core.now().isoformat()
        snapshots = [
            {'id': 'old', 'time': today, 'tags': ['lpg-system', 'generation:original']},
            {'id': 'clean', 'time': today, 'tags': ['lpg-system', 'generation:clean']},
            {'id': 'protected', 'time': '2020-01-01T00:00:00Z', 'tags': ['lpg-system', 'protected-pre-reset']},
        ]
        self.assertEqual(core.retain_ids(snapshots, protected_ids=['old']), {'old', 'clean', 'protected'})
        self.assertEqual(core.retain_ids(snapshots), {'clean', 'protected'})
        with patch('restore.generation_id', return_value='clean'):
            with self.assertRaisesRegex(RuntimeError, 'previous business-data generation'):
                restore.verify_generation({'generation': 'original'})
            restore.verify_generation({'generation': 'clean'})
            restore.verify_generation({'generation': 'original'}, allow_previous_generation=True)

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
    def test_reused_pid_is_recorded_as_interrupted_and_safe_retry_uses_a_new_job(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            (state / 'rclone.conf').write_text('fixture only')
            core.write(state / 'job.json', {'status': 'running', 'pid': 123, 'process_started': 'old-process', 'job_id': 'interrupted', 'started_at': core.now().isoformat()})
            with patch('control.STATE', state), patch('control.SECRETS', state), patch('control.Lock', side_effect=lambda *_: nullcontext()), patch('control.process_identity', return_value='different-process'), patch('control.command') as start, patch('control.event'):
                self.assertEqual(control.status()['job']['status'], 'interrupted')
                self.assertEqual(control.status()['job']['status'], 'interrupted')
                self.assertEqual(len(core.read(state / 'jobs.json')), 1)
                new_id = str(uuid.uuid4())
                control.start_full({'request_id': new_id}, 'fixture-admin')
                self.assertEqual(core.read(state / 'job.json')['job_id'], new_id)
                start.assert_called_once()
                self.assertEqual(core.read(state / 'jobs.json')[0]['status'], 'interrupted')

    def test_full_backup_request_is_durable_idempotent_and_does_not_change_schedule(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            (state / 'rclone.conf').write_text('fixture only')
            request_id = str(uuid.uuid4())
            with patch('control.STATE', state), patch('control.SECRETS', state), patch('control.Lock', side_effect=lambda *_: nullcontext()), patch('control.command') as start, patch('control.event'):
                result = control.start_full({'request_id': request_id}, 'fixture-admin')
                self.assertEqual(result['job_id'], request_id)
                self.assertEqual(core.read(state / 'manual-request.json')['actor'], 'fixture-admin')
                self.assertEqual(core.read(state / 'job.json')['status'], 'queued')
                start.assert_called_once_with(['systemctl', 'start', '--no-block', 'lpg-backup-manual.service'])
                self.assertTrue(control.start_full({'request_id': request_id}, 'fixture-admin')['already_requested'])
                start.assert_called_once()
                with self.assertRaises(control.Fault) as error:
                    control.start_full({'request_id': str(uuid.uuid4())}, 'fixture-admin')
                self.assertEqual(error.exception.status, 409)
                self.assertFalse((state / 'settings.json').exists())

    def test_full_request_requires_connection_and_valid_request_identity(self):
        with tempfile.TemporaryDirectory() as folder, patch('control.STATE', Path(folder)), patch('control.SECRETS', Path(folder)), patch('control.command') as start:
            with self.assertRaises(control.Fault):
                control.start_full({'request_id': 'not-an-id'}, 'fixture')
            with self.assertRaisesRegex(control.Fault, 'Connect'):
                control.start_full({'request_id': str(uuid.uuid4())}, 'fixture')
            start.assert_not_called()

    def test_progress_preserves_unknown_totals_and_actual_engine_measurements(self):
        with tempfile.TemporaryDirectory() as folder, patch('core.STATE', Path(folder)):
            state = Path(folder)
            core.write(state / 'job.json', {'status': 'running', 'pid': os.getpid(), 'job_id': 'fixture', 'started_at': core.now().isoformat()})
            core.job_update('Database Backup', detail='Capturing')
            self.assertIsNone(core.read(state / 'job.json')['percent'])
            core.job_update('Uploading to Google Drive', percent=37.5, processed_bytes=300, total_bytes=800)
            job = core.read(state / 'job.json')
            self.assertEqual((job['percent'], job['processed_bytes'], job['total_bytes']), (37.5, 300, 800))
            core.job_update('Verification')
            self.assertIsNone(core.read(state / 'job.json')['percent'])
            self.assertEqual(len(core.read(state / 'job.json')['stages']), 3)

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
