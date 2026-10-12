import tempfile
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from backend import SERVICES, digest, migration_plan, update, validate_sql


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


class DeploymentFlowTests(unittest.TestCase):
    def fixture(self, folder):
        root, stage = Path(folder) / 'root', Path(folder) / 'stage'
        for directory in (root, stage):
            (directory / 'supabase/migrations').mkdir(parents=True)
            (directory / 'deploy').mkdir()
            (directory / 'compose.yml').write_text('existing\n')
            (directory / 'compose.azure.yml').write_text('existing\n')
            (directory / 'supabase/migrations/20261012000000_existing.sql').write_text('select 1;')
        model = {'volumes': {key: {'external': True, 'name': name} for key, name in [('lpg_db_data', 'lpg_db_data'), ('lpg_storage_data', 'lpg_storage_data'), ('db-config', 'lpg_db-config')]}, 'services': {name: {'image': name + ':1', 'environment': {}, 'volumes': []} for name in SERVICES}}
        model['services']['api-gw']['environment'] = {'SUPABASE_PUBLIC_URL': 'https://api.lpg.20.40.48.3.sslip.io', 'ANON_KEY': 'not-used'}
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

    def test_pending_sql_fails_before_sync_backup_or_service_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)
            (stage / 'supabase/migrations/20261013000000_new.sql').write_text('select 2;')
            (stage / 'compose.yml').write_text('new\n')
            with patch('backend.run', fake), self.assertRaisesRegex(RuntimeError, 'explicitly approve'):
                update(root, stage, 'lpg', 'https://api.lpg.20.40.48.3.sslip.io', '')
            self.assertEqual((root / 'compose.yml').read_text(), 'existing\n')
            self.assertFalse((root / 'backups').exists())
            self.assertFalse(any('up' in args or 'pull' in args for args, _, _ in calls))

    def test_pending_service_receipt_recovers_interrupted_bind_update(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)
            (root / 'deploy/.pending-services.json').write_text('["api-gw"]')
            with patch('backend.run', fake), patch('backend.verify_health'):
                update(root, stage, 'lpg', 'https://api.lpg.20.40.48.3.sslip.io', '')
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
                update(root, stage, 'lpg', 'https://api.lpg.20.40.48.3.sslip.io', '20261013000000')
            self.assertEqual((root / 'compose.yml').read_text(), 'existing\n')
            self.assertFalse(any('up' in args or '--single-transaction' in args for args, _, _ in calls))

    def test_sql_and_history_commit_together_before_services_update(self):
        with tempfile.TemporaryDirectory() as folder:
            root, stage, calls, fake = self.fixture(folder)
            (stage / 'supabase/migrations/20261013000000_new.sql').write_text('select 2;')
            with patch('backend.run', fake), patch('backend.verify_health'):
                update(root, stage, 'lpg', 'https://api.lpg.20.40.48.3.sslip.io', '20261013000000')
            migration_calls = [(args, kwargs['data'].decode()) for args, _, kwargs in calls if '--single-transaction' in args]
            self.assertEqual(len(migration_calls), 1)
            args, sql = migration_calls[0]
            self.assertIn('ON_ERROR_STOP=1', args)
            self.assertIn('LOCK TABLE supabase_migrations.schema_migrations', sql)
            self.assertIn('select 2;', sql)
            self.assertIn('INSERT INTO supabase_migrations.schema_migrations', sql)
            self.assertIn("NOTIFY pgrst, 'reload schema'", sql)


if __name__ == '__main__':
    unittest.main()
