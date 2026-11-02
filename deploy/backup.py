"""Canonical nightly entry point. Legacy bundles are read by restore-check.py."""
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent / 'backup'))
from worker import nightly

if __name__ == '__main__':
    os.umask(0o077)
    try:
        if len(sys.argv) != 1:
            raise RuntimeError('Nightly backups use lpg-backup.timer. Queue manual requests in Superadmin > Backups.')
        nightly()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
