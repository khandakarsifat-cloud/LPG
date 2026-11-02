import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('restore_check', Path(__file__).with_name('restore-check.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IsolatedRestoreTests(unittest.TestCase):
    def test_scheduler_is_excluded_but_application_maintenance_is_preserved(self):
        toc = '\n'.join([
            '; Archive contents',
            '1; 3079 200 EXTENSION - pg_cron postgres',
            '2; 0 0 COMMENT - EXTENSION pg_cron postgres',
            '3; 2615 201 SCHEMA - cron postgres',
            '4; 0 201 ACL - SCHEMA cron postgres',
            '5; 1259 202 TABLE cron job postgres',
            '6; 0 202 TABLE DATA cron job postgres',
            '7; 1255 203 FUNCTION cron schedule(text, text) postgres',
            '8; 1259 204 TABLE public accounting_journals postgres',
            '9; 1255 205 FUNCTION app_private run_accounting_maintenance(integer) postgres',
        ])
        result = module.isolated_restore_toc(toc)
        self.assertNotIn('pg_cron', result)
        self.assertNotIn(' cron ', result)
        self.assertIn('TABLE public accounting_journals', result)
        self.assertIn('FUNCTION app_private run_accounting_maintenance', result)

    def test_pre_scheduler_archives_keep_all_objects(self):
        toc = '1; 1259 204 TABLE public accounting_journals postgres\n'
        self.assertEqual(module.isolated_restore_toc(toc), toc)


if __name__ == '__main__':
    unittest.main()
