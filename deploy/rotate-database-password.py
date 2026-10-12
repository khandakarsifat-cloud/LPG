"""Set remote database login passwords from the private VPS environment file."""
import pathlib
import subprocess

values = {}
for line in pathlib.Path('/opt/lpg/.env').read_text().splitlines():
    if line and not line.startswith('#') and '=' in line:
        name, value = line.split('=', 1)
        values[name] = value.strip().strip('"').strip("'")
password = values['POSTGRES_PASSWORD']
assert len(password) >= 32 and all(c in '0123456789abcdef' for c in password)
command = ['sudo', 'docker', 'compose', 'exec', '-T', 'db', 'psql',
           '-U', 'supabase_admin', '-d', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1']
roles = subprocess.check_output(command + ['-c',
    'select rolname from pg_authid where rolcanlogin and rolpassword is not null'], text=True).splitlines()
sql = '\n'.join('ALTER ROLE "' + role.replace('"', '""') + '" PASSWORD ' + "'" + password + "';" for role in roles)
subprocess.run(command, input=sql, text=True, check=True, stdout=subprocess.DEVNULL)
print(f'Rotated {len(roles)} database login passwords on the VPS')
