"""Destructive lifecycle fault tests with private IO replaced; no real deletion."""
import datetime as dt
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import nullcontext
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent / 'backup'))
import business_deletion as deletion
import worker


class BusinessDeletionTests(unittest.TestCase):
    def test_verified_backup_precedes_every_destructive_step_and_retry_skips_purge(self):
        for phase in ('prepared', 'data_removed'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as folder:
                job_id='f0050000-0000-4000-8000-000000000001'
                target='f0050000-0000-4000-8000-000000000002'
                manifest={'business_id':target,'files':[],'users':['f0050000-0000-4000-8000-000000000003']}
                job={'job_id':job_id,'business_id':target,'business_name':'Disposable fixture','actor_id':'f0050000-0000-4000-8000-000000000004','status':phase,'manifest':manifest,'created_at':'2026-11-05T00:00:00+00:00','backup_id':'a'*64 if phase!='prepared' else None}
                root=Path(folder)
                (root/'business-deletions').mkdir()
                (root/'business-deletion-request.json').write_text(json.dumps({'job_id':job_id}))
                (root/'business-deletions'/f'{job_id}.json').write_text(json.dumps({k:v for k,v in job.items() if k!='manifest'}))
                calls=[]
                def sql(query):
                    calls.append(('sql',query))
                    if query.startswith('select to_jsonb'): return job
                    if "jsonb_build_object('count'" in query: return {'count':0}
                def backup(**kwargs):
                    calls.append(('backup',None));return {'status':'verified','available':True,'type':'full','captured_at':'2026-11-05T01:00:00+00:00','snapshot_id':'a'*64}
                with patch.object(deletion,'STATE',root),patch.object(deletion.os,'geteuid',return_value=0,create=True),patch.object(deletion,'Lock',return_value=nullcontext()),patch.object(deletion,'sql',side_effect=sql),patch.object(deletion,'remove_files',side_effect=lambda m:calls.append(('files',None))),patch.object(deletion,'request_api',side_effect=lambda *a:calls.append(('api',a))),patch.object(deletion,'event'),patch.object(deletion,'process_identity',return_value='test'),patch.object(worker,'nightly',side_effect=backup):
                    deletion.run()
                names=[c[0] for c in calls]
                if phase=='prepared':
                    self.assertLess(names.index('backup'),names.index('files'))
                    self.assertEqual(sum('purge_business_data' in (c[1] or '') for c in calls if c[0]=='sql'),1)
                else:
                    self.assertNotIn('backup',names)
                    self.assertFalse(any('purge_business_data' in (c[1] or '') for c in calls if c[0]=='sql'))
                state=json.loads((root/'business-deletions'/f'{job_id}.json').read_text())
                self.assertEqual(state['status'],'completed')

    def test_backup_failure_never_removes_files_records_or_identities(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);job_id='f0050000-0000-4000-8000-000000000001'
            (root/'business-deletion-request.json').write_text(json.dumps({'job_id':job_id}))
            job={'job_id':job_id,'business_id':'f0050000-0000-4000-8000-000000000002','status':'prepared','actor_id':'actor','created_at':dt.datetime.now(dt.timezone.utc).isoformat(),'manifest':{'files':[],'users':[]}}
            with patch.object(deletion,'STATE',root),patch.object(deletion.os,'geteuid',return_value=0,create=True),patch.object(deletion,'Lock',return_value=nullcontext()),patch.object(deletion,'sql',return_value=job) as sql,patch.object(deletion,'remove_files') as files,patch.object(deletion,'request_api') as api,patch.object(deletion,'process_identity',return_value='test'),patch.object(worker,'nightly',side_effect=RuntimeError('private upstream error')):
                with self.assertRaises(RuntimeError):deletion.run()
                self.assertEqual(sql.call_count,1);files.assert_not_called();api.assert_not_called()
            state=json.loads((root/'business-deletions'/f'{job_id}.json').read_text())
            self.assertEqual(state['status'],'failed')
            self.assertNotIn('private upstream error',json.dumps(state))

    def test_uuid_paths_and_sql_literals_are_bounded(self):
        with self.assertRaises(ValueError):deletion.job_path('../../another-business')
        self.assertEqual(deletion.literal("O'Brien"),"'O''Brien'")

if __name__=='__main__':unittest.main()
