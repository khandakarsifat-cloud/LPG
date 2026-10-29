import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
from bootstrap import environment, replay_sql


class BootstrapTests(unittest.TestCase):
    def test_independent_secrets_and_development_redirects(self):
        template = (Path(__file__).parent.parent / '.env.example').read_text()
        with patch('bootstrap.auth_keys', return_value={'JWT_KEYS': '[]', 'JWT_JWKS': '{"keys":[]}'}):
            first, second = environment(template), environment(template)
        self.assertNotEqual(first, second)
        self.assertNotIn('replace-with', first)
        self.assertNotIn('20.40.48.3', first)
        self.assertIn("ENABLE_EMAIL_AUTOCONFIRM='true'", first)
        self.assertIn("SMTP_HOST=''", first)
        self.assertIn('https://floral-dew-443b.khandakarsifat.workers.dev/#/login', first)

    def test_all_immutable_migrations_can_replay(self):
        for path in sorted((Path(__file__).parent.parent / 'supabase/migrations').glob('*.sql')):
            before = path.read_bytes()
            replay_sql(path)
            self.assertEqual(path.read_bytes(), before)

    def test_new_transaction_wrappers_cannot_bypass_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / '20261029000000_example.sql'
            path.write_text('begin; select 1; commit;')
            with self.assertRaises(RuntimeError):
                replay_sql(path)
