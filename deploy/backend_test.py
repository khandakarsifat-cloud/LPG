import tempfile
import json
import io
import base64
import hashlib
import hmac
import urllib.error
from pathlib import Path
import unittest
from unittest.mock import patch
from backend import SERVICES, digest, migration_plan, update, validate_model, validate_sql, verify_health, configure_attendance_token, configure_account_service, apply_migration_batch, ACCOUNTING_CUTOVER, STOCK_CUTOVERS


class AccountingCutoverTests(unittest.TestCase):
    def exercise(self, failure=None, version=ACCOUNTING_CUTOVER):
        calls = []
        def command(args, label, **kwargs):
            calls.append((args, label))
            if label == 'Capture scheduler intent':
                return '[{"id":1,"active":true},{"id":2,"active":false}]'
            if label == 'Drain scheduled database writers':
                return '1' if failure == 'drain' else '0'
            if label.startswith('Approved migrations') and failure == 'sql':
                raise RuntimeError('transaction rolled back')
            if label == 'Resume transaction writers' and failure == 'resume':
                raise RuntimeError('service failure')
            return ''
        with tempfile.TemporaryDirectory() as directory, patch('backend.run', side_effect=command), patch('backend.time.sleep'):
            folder = Path(directory)
            try:
                apply_migration_batch(['psql', '-d', 'postgres'], 'select 1;', [(version, Path('test.sql'))], ['compose'], {'rest': {}, 'account-service': {}}, folder)
            except RuntimeError:
                if failure is None:
                    raise
            state = json.loads((folder / 'accounting-cutover.json').read_text())
        return calls, state

    def test_posting_cutover_drains_backs_up_and_restores_original_intent(self):
        calls, state = self.exercise()
        labels = [label for _, label in calls]
        self.assertLess(labels.index('Drain application transaction writers'), labels.index('Quiesced accounting recovery point'))
        self.assertLess(labels.index('Validate quiesced recovery archive'), labels.index('Approved migrations (entire batch is transactional)'))
        self.assertEqual(state['phase'], 'resumed')
        self.assertEqual(sum(label == 'Restore scheduler intent' for _, label in calls), 2)

    def test_sql_failure_restores_services_and_enabled_and_disabled_jobs(self):
        calls, state = self.exercise('sql')
        self.assertEqual(state['phase'], 'resumed')
        self.assertTrue(any(label == 'Resume transaction writers' for _, label in calls))
        self.assertTrue(any('active=>false' in ' '.join(args) and label == 'Restore scheduler intent' for args, label in calls))

    def test_stock_cutovers_use_the_same_recovery_gate(self):
        for version in STOCK_CUTOVERS:
            with self.subTest(version=version):
                calls, state = self.exercise(version=version)
                labels = [label for _, label in calls]
                self.assertLess(labels.index('Drain application transaction writers'), labels.index('Quiesced accounting recovery point'))
                self.assertEqual(state['phase'], 'resumed')

    def test_jobs_that_do_not_drain_prevent_sql_and_restore_runtime(self):
        calls, state = self.exercise('drain')
        self.assertFalse(any(label.startswith('Approved migrations') for _, label in calls))
        self.assertEqual(state['phase'], 'resumed')

    def test_service_restore_failure_still_restores_every_scheduler_flag(self):
        calls, state = self.exercise('resume')
        self.assertEqual(sum(label == 'Restore scheduler intent' for _, label in calls), 2)
        self.assertEqual(state['phase'], 'recovery_required')


class AccountServiceConfigTests(unittest.TestCase):
    def test_credentials_are_written_only_to_the_private_server_mount(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'deploy').mkdir()
            gateway = {'ANON_KEY': 'test-public', 'SERVICE_ROLE_KEY': 'test-private',
                       'SUPABASE_PUBLIC_URL': 'https://api.lpg.144.79.249.4.sslip.io'}
            model = {'services': {'api-gw': {'environment': gateway}}}
            self.assertTrue(configure_account_service(root, model, write=False))
            self.assertFalse((root / 'deploy/.account-service.json').exists())
            with patch('backend.os.chown', create=True):
                configure_account_service(root, model)
            config = json.loads((root / 'deploy/.account-service.json').read_text())
            self.assertEqual(config['serviceKey'], 'test-private')
            self.assertEqual(config['apiURL'], 'http://api-gw:8000')
            self.assertEqual(len(config['origins']), 2)
            self.assertNotIn('http://localhost:5173', config['origins'])
            self.assertFalse(configure_account_service(root, model, write=False))


class AttendanceTokenTests(unittest.TestCase):
    def test_only_scoped_jwt_is_written_and_rotation_is_detected_before_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'deploy').mkdir()
            model = {'services': {'auth': {'environment': {'GOTRUE_JWT_SECRET': 'test-only-signing-secret'}}}}
            self.assertTrue(configure_attendance_token(root, model, write=False))
            self.assertFalse((root / 'deploy/.attendance-token').exists())
            with patch('backend.os.chown', create=True):
                self.assertTrue(configure_attendance_token(root, model))
            token = (root / 'deploy/.attendance-token').read_text().strip()
            header, claims, signature = token.split('.')
            decode = lambda s: base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
            self.assertEqual(json.loads(decode(claims))['role'], 'attendance_receiver')
            self.assertEqual(decode(signature), hmac.new(b'test-only-signing-secret', (header + '.' + claims).encode(), hashlib.sha256).digest())
            self.assertNotIn('test-only-signing-secret', token)
            self.assertFalse(configure_attendance_token(root, model, write=False))
            model['services']['auth']['environment']['GOTRUE_JWT_SECRET'] = 'rotated-test-only-secret'
            self.assertTrue(configure_attendance_token(root, model, write=False))


class MigrationSafetyTests(unittest.TestCase):
    def test_history_and_forward_only(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            previous = root / 'old'
            previous.mkdir()
            first = root / '20261012000000_first.sql'
            first.write_text('select 1;\n')
            (previous / first.name).write_bytes(b'select 1;\r\n')
            second = root / '20261013000000_second.sql'
            second.write_text('select 2;')
            files = [first, second]
            self.assertEqual(migration_plan(files, ['20261012000000'], previous, {}), [('20261013000000', second)])
            first.write_text('select 3;')
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                migration_plan(files, ['20261012000000'], previous, {})
            with self.assertRaisesRegex(RuntimeError, 'absent'):
                migration_plan(files, ['20261014000000'], previous, {})
            with self.assertRaisesRegex(RuntimeError, 'Out-of-order'):
                migration_plan(files, ['20261013000000'], previous, {'20261013000000': digest(second)})

    def test_recorded_hash_prevents_edit_after_partial_deployment(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / '20261012000000_first.sql'
            path.write_text('select 1;')
            receipts = {'20261012000000': digest(path)}
            self.assertEqual(migration_plan([path], list(receipts), root, receipts), [])
            path.write_text('select 2;')
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                migration_plan([path], list(receipts), root, receipts)

    def test_transaction_ownership_and_psql_escape(self):
        for sql in ['begin; select 1; commit;', 'select 1; COMMIT;', 'ROLLBACK;', 'START TRANSACTION;', 'VACUUM;', 'CREATE INDEX CONCURRENTLY x on t(id);', '\\! echo dangerous']:
            with self.subTest(sql=sql), self.assertRaises(RuntimeError):
                validate_sql(sql)
        validate_sql("-- COMMIT;\n/* BEGIN; /* COMMIT; */ END; */\nDO $fn$ BEGIN PERFORM 1; END $fn$; SELECT 'COMMIT;';")
        validate_sql('SELECT CASE WHEN true THEN 1 ELSE 0 END; CREATE TABLE t (n int CHECK (n <= CASE WHEN true THEN 3 ELSE 2 END));')


class DeploymentFlowTests(unittest.TestCase):
    def setUp(self):
        token = patch('backend.configure_attendance_token', return_value=False)
        token.start()
        self.addCleanup(token.stop)
        account = patch('backend.configure_account_service', return_value=False)
        account.start()
        self.addCleanup(account.stop)

    def test_new_receiver_is_added_without_recreating_existing_core_services(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)

            def original_stack(args, label, **kwargs):
                result = fake(args, label, **kwargs)
                if label == 'Existing production Compose validation':
                    model = json.loads(result)
                    del model['services']['attendance-receiver']
                    return json.dumps(model)
                if label == 'Container discovery':
                    return ' '.join(s for s in SERVICES if s != 'attendance-receiver')
                if label == 'Existing container inspection':
                    return json.dumps([c for c in json.loads(result) if c['Id'] != 'attendance-receiver'])
                return result

            with patch('backend.run', original_stack), patch('backend.verify_health'):
                update(root, stage, 'lpg', 'https://api.lpg.144.79.249.4.sslip.io', '')
            self.assertEqual([args[-1] for args, _, _ in calls if '--force-recreate' in args], ['attendance-receiver'])
            self.assertTrue(any(label == 'Pre-deployment database backup' for _, label, _ in calls))

    def test_internal_publication_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            _, _, _, fake = self.fixture(folder)
            model = json.loads(fake([], 'Candidate production Compose validation'))
            model['services']['db']['ports'] = [{'target': 5432, 'published': '5432', 'host_ip': '0.0.0.0'}]
            with self.assertRaisesRegex(RuntimeError, 'publicly published'):
                validate_model(model)

    def fixture(self, folder):
        root, stage = Path(folder) / 'root', Path(folder) / 'stage'
        for directory in (root, stage):
            (directory / 'supabase/migrations').mkdir(parents=True)
            (directory / 'deploy').mkdir()
            (directory / 'compose.yml').write_text('existing\n')
            (directory / 'compose.vps.yml').write_text('existing\n')
            (directory / 'supabase/migrations/20261012000000_existing.sql').write_text('select 1;')
        model = {'volumes': {key: {'external': True, 'name': name} for key, name in [('lpg_db_data', 'lpg_db_data'), ('lpg_storage_data', 'lpg_storage_data'), ('db-config', 'lpg_db-config')]}, 'services': {name: {'image': name + ':1', 'environment': {}, 'volumes': []} for name in SERVICES}}
        model['services']['api-gw']['environment'] = {'SUPABASE_PUBLIC_URL': 'https://api.lpg.144.79.249.4.sslip.io', 'ANON_KEY': 'not-used', 'DASHBOARD_USERNAME': 'test-only', 'DASHBOARD_PASSWORD': 'test-only-not-a-real-password'}
        model['services']['auth']['environment']['GOTRUE_SITE_URL'] = 'https://floral-dew-443b.khandakarsifat.workers.dev'
        model['services']['db']['environment']['POSTGRES_DB'] = 'postgres'
        containers = [{'Id': name, 'Config': {'Image': name + ':1', 'Labels': {'com.docker.compose.service': name, 'com.docker.compose.project': 'lpg', 'com.docker.compose.config-hash': 'hash'}}, 'State': {'Running': True, 'Health': {'Status': 'healthy'}}, 'Mounts': []} for name in SERVICES]
        containers[0]['Mounts'] = [{'Name': 'lpg_db_data', 'Destination': '/var/lib/postgresql/data'}, {'Name': 'lpg_db-config', 'Destination': '/etc/postgresql-custom'}]
        containers[5]['Mounts'] = [{'Name': 'lpg_storage_data', 'Destination': '/var/lib/storage'}]
        calls = []

        def fake_run(args, label, **kwargs):
            calls.append((args, label, kwargs))
            if 'configuration hashes' in label:
                return '\n'.join(name + ' hash' for name in SERVICES)
            if 'Compose validation' in label:
                return json.dumps(model)
            if label == 'Container discovery':
                return ' '.join(SERVICES)
            if label == 'Existing container inspection':
                return json.dumps(containers)
            if label == 'Migration history inspection':
                return '20261012000000\n'
            return ''
        return root, stage, calls, fake_run

    def test_existing_eight_service_stack_adds_only_dashboard_services(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)

            def without_dashboard(args, label, **kwargs):
                result = fake(args, label, **kwargs)
                if label == 'Container discovery':
                    return ' '.join(name for name in SERVICES if name not in ('studio', 'meta'))
                if label == 'Existing container inspection':
                    return json.dumps([c for c in json.loads(result) if c['Id'] not in ('studio', 'meta')])
                return result

            with patch('backend.run', without_dashboard), patch('backend.verify_health'):
                update(root, stage, 'lpg', 'https://api.lpg.144.79.249.4.sslip.io', '')
            updates = [args[-1] for args, _, _ in calls if '--force-recreate' in args]
            self.assertEqual(updates, ['meta', 'studio'])
            self.assertTrue(any(label == 'Pre-deployment database backup' for _, label, _ in calls))
            self.assertFalse(any('--single-transaction' in args for args, _, _ in calls))
            for args, label, _ in calls:
                if 'Compose validation' in label:
                    self.assertIn('--profile', args)

    def test_missing_core_service_is_not_treated_as_dashboard_installation(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)

            def without_auth(args, label, **kwargs):
                result = fake(args, label, **kwargs)
                if label == 'Existing container inspection':
                    return json.dumps([c for c in json.loads(result) if c['Id'] != 'auth'])
                return result

            with patch('backend.run', without_auth), self.assertRaisesRegex(RuntimeError, 'identity mismatch'):
                update(root, stage, 'lpg', 'https://api.lpg.144.79.249.4.sslip.io', '')
            self.assertFalse(any('up' in args or 'pull' in args for args, _, _ in calls))

    def test_weak_dashboard_login_stops_before_runtime_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)

            def weak_login(args, label, **kwargs):
                result = fake(args, label, **kwargs)
                if 'Compose validation' in label:
                    model = json.loads(result)
                    model['services']['api-gw']['environment']['DASHBOARD_PASSWORD'] = 'weak'
                    return json.dumps(model)
                return result

            with patch('backend.run', weak_login), self.assertRaisesRegex(RuntimeError, 'strong dashboard login'):
                update(root, stage, 'lpg', 'https://api.lpg.144.79.249.4.sslip.io', '')
            self.assertFalse(any('up' in args or 'pull' in args for args, _, _ in calls))

    def test_pending_sql_fails_before_sync_backup_or_service_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)
            (stage / 'supabase/migrations/20261013000000_new.sql').write_text('select 2;')
            (stage / 'compose.yml').write_text('new\n')
            with patch('backend.run', fake), self.assertRaisesRegex(RuntimeError, 'explicitly approve'):
                update(root, stage, 'lpg', 'https://api.lpg.144.79.249.4.sslip.io', '')
            self.assertEqual((root / 'compose.yml').read_text(), 'existing\n')
            self.assertFalse((root / 'backups').exists())
            self.assertFalse(any('up' in args or 'pull' in args for args, _, _ in calls))

    def test_pending_service_receipt_recovers_interrupted_bind_update(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)
            (root / 'deploy/.pending-services.json').write_text('["api-gw"]')
            with patch('backend.run', fake), patch('backend.verify_health'):
                update(root, stage, 'lpg', 'https://api.lpg.144.79.249.4.sslip.io', '')
            updates = [args for args, _, _ in calls if '--force-recreate' in args]
            self.assertEqual(len(updates), 1)
            self.assertEqual(updates[0][-1], 'api-gw')
            self.assertIn('--no-deps', updates[0])
            self.assertFalse((root / 'deploy/.pending-services.json').exists())

    def test_failed_backup_prevents_source_or_database_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)
            (stage / 'supabase/migrations/20261013000000_new.sql').write_text('select 2;')
            (stage / 'compose.yml').write_text('new\n')

            def fail_backup(args, label, **kwargs):
                if label == 'Pre-deployment database backup':
                    raise RuntimeError('backup failed')
                return fake(args, label, **kwargs)
            with patch('backend.run', fail_backup), self.assertRaisesRegex(RuntimeError, 'backup failed'):
                update(root, stage, 'lpg', 'https://api.lpg.144.79.249.4.sslip.io', '20261013000000')
            self.assertEqual((root / 'compose.yml').read_text(), 'existing\n')
            self.assertFalse(any('up' in args or '--single-transaction' in args for args, _, _ in calls))

    def test_sql_and_history_commit_together_before_services_update(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)
            (stage / 'supabase/migrations/20261013000000_new.sql').write_text('select 2;')
            with patch('backend.run', fake), patch('backend.verify_health'):
                update(root, stage, 'lpg', 'https://api.lpg.144.79.249.4.sslip.io', '20261013000000')
            migration_calls = [(args, kwargs['data'].decode()) for args, _, kwargs in calls if '--single-transaction' in args]
            self.assertEqual(len(migration_calls), 1)
            args, sql = migration_calls[0]
            self.assertIn('ON_ERROR_STOP=1', args)
            self.assertIn('LOCK TABLE supabase_migrations.schema_migrations', sql)
            self.assertIn('select 2;', sql)
            self.assertIn('INSERT INTO supabase_migrations.schema_migrations', sql)
            self.assertIn("NOTIFY pgrst, 'reload schema'", sql)


class DashboardHealthTests(unittest.TestCase):
    def check(self, anonymous_status):
        model = {'services': {'api-gw': {'environment': {
            'ANON_KEY': 'test-public-key', 'DASHBOARD_USERNAME': 'test-only',
            'DASHBOARD_PASSWORD': 'test-only-not-a-real-password'}}}}
        seen = []

        def response(request, timeout):
            url = request if isinstance(request, str) else request.full_url
            seen.append(request)
            if '/rest/' in url:
                raise urllib.error.HTTPError(url, 401, 'Unauthorized', {}, io.BytesIO(b'{"code":"42501"}'))
            if url.endswith('/') and anonymous_status == 401:
                raise urllib.error.HTTPError(url, 401, 'Unauthorized', {}, io.BytesIO(b''))
            result = io.BytesIO(b'<html><script src="/_next/test.js"></script></html>')
            result.status = 200
            return result

        with patch('backend.urllib.request.urlopen', response):
            verify_health(model, 'https://example.invalid')
        return seen

    def test_authenticated_dashboard_and_unchanged_api_health(self):
        seen = self.check(401)
        request = seen[-1]
        self.assertEqual(request.full_url, 'https://example.invalid/project/default')
        self.assertTrue(request.get_header('Authorization').startswith('Basic '))

    def test_public_dashboard_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'without authentication'):
            self.check(200)


if __name__ == '__main__':
    unittest.main()
