"""Reset safety guards with private IO mocked; no VPS, database or files deleted."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import nullcontext
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent / 'backup'))
import core

spec = importlib.util.spec_from_file_location('baseline', Path(__file__).parent / 'development-baseline.py')
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


class DevelopmentBaselineTests(unittest.TestCase):
    def test_reset_refuses_missing_maintenance_or_deletion_authorization(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(baseline, 'FILE', Path(folder) / 'state.json'), patch.object(baseline, 'sql') as sql:
            with self.assertRaisesRegex(RuntimeError, 'authorization'):
                baseline.reset({})
            with self.assertRaisesRegex(RuntimeError, 'prepared'):
                baseline.reset({'delete_business_data': True})
            sql.assert_not_called()

    def test_reset_requires_a_backup_after_writers_were_stopped(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder) / 'state.json'
            core.write(state, {'active': True, 'phase': 'prepared', 'administrator': 'admin', 'generation': 'original', 'pre_reset_job': 'job', 'paused_at': '2026-11-04T00:00:00+00:00'})
            with patch.object(baseline, 'FILE', state), patch.object(baseline, 'Lock', side_effect=lambda *_: nullcontext()), patch.object(baseline, 'verified_point', return_value={'job_id': 'job', 'captured_at': '2026-11-03T23:00:00+00:00'}), patch.object(baseline, 'sql') as sql:
                with self.assertRaisesRegex(RuntimeError, 'after source writers stopped'):
                    baseline.reset({'delete_business_data': True, 'administrator': 'admin', 'snapshot': 'a' * 64})
                sql.assert_not_called()

    def test_full_verification_requires_matching_restore_and_administrator_proof(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(baseline, 'STATE', Path(folder)):
            state = Path(folder); snapshot = 'a' * 64
            core.write(state / 'history.json', [{'snapshot_id': snapshot, 'type': 'full', 'status': 'verified', 'available': True}])
            with self.assertRaisesRegex(RuntimeError, 'isolated restore'):
                baseline.verified_point(snapshot)
            core.write(state / 'restore.json', {'snapshot_id': snapshot, 'files_verified': True, 'auth_health': True, 'storage_health': True, 'database': {'admin_identity_verified': True}})
            self.assertEqual(baseline.verified_point(snapshot, 'original')['snapshot_id'], snapshot)
            with self.assertRaisesRegex(RuntimeError, 'different data generation'):
                baseline.verified_point(snapshot, 'new-generation')

    def test_finishing_restores_the_timer_only_after_verified_new_full_baseline(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); state = root / 'cloud'; evidence = {'original_admin': 'same'}
            core.write(state / 'core-baseline.json', {'active': True, 'phase': 'testing', 'new_generation': 'new', 'admin_evidence': evidence, 'timer_active': True, 'pre_reset_snapshot': 'old'})
            core.write(state / 'protected-snapshots.json', ['old', 'independent-protection'])
            with patch.object(baseline, 'ROOT', root), patch.object(baseline, 'STATE', state), patch.object(baseline, 'FILE', state / 'core-baseline.json'), patch.object(baseline, 'verified_point', return_value={'snapshot_id': 'new-full'}), patch.object(baseline, 'admin_evidence', return_value=evidence), patch.object(baseline, 'sql', return_value='current-schema'), patch.object(baseline, 'command') as command:
                core.write(state / 'baseline-required.json', {})
                with self.assertRaisesRegex(RuntimeError, 'has not completed'):
                    baseline.complete('new-full')
                command.assert_not_called()
                (state / 'baseline-required.json').unlink()
                core.write(root / 'deploy/.source-version.json', {'backend_sha256': 'current-backend'})
                for schema, backend in [('old-schema', 'current-backend'), ('current-schema', 'old-backend')]:
                    core.write(state / 'restore.json', {'database': {'migration_fingerprint': schema}, 'backend_source_sha256': backend})
                    with self.assertRaisesRegex(RuntimeError, 'predates'):
                        baseline.complete('new-full')
                    command.assert_not_called()
                    self.assertIn('old', core.read(state / 'protected-snapshots.json'))
                core.write(state / 'restore.json', {'database': {'migration_fingerprint': 'current-schema'}, 'backend_source_sha256': 'current-backend'})
                baseline.complete('new-full')
                command.assert_called_once_with(['systemctl', 'start', 'lpg-backup.timer'])
                self.assertFalse(core.read(state / 'core-baseline.json')['active'])
                self.assertEqual(core.read(state / 'protected-snapshots.json'), ['independent-protection'])
