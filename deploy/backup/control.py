"""Root-owned Unix-socket API; only the private account service mounts this socket."""
from http.server import BaseHTTPRequestHandler
import base64
import configparser
import datetime as dt
import hashlib
import json
import os
import secrets
import socketserver
import urllib.error
import urllib.parse
import urllib.request
import uuid

from core import CALLBACK, FRONTEND, ROOT, SECRETS, STATE, Lock, command, event, next_run, now, process_identity, read, write


class Fault(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


class InvalidState(Fault):
    pass


def request_json(url, data=None, headers=None):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Deliberately discard upstream payloads and never log authorization codes.
        raise Fault('Authorization failed. Sign in again.', 403) from error
    except (OSError, ValueError) as error:
        raise Fault('Authorization service is unavailable. Try again shortly.', 503) from error


def authenticate(bearer):
    if not bearer or not bearer.startswith('Bearer ') or len(bearer) > 8192:
        raise Fault('Sign in required.', 401)
    config = read(ROOT / 'deploy/.account-service.json')
    headers = {'apikey': config['publicKey'], 'Authorization': bearer, 'Content-Type': 'application/json'}
    user = request_json('http://127.0.0.1:54321/auth/v1/user', headers=headers)
    access = request_json('http://127.0.0.1:54321/rest/v1/rpc/get_access_context', b'{}', headers)
    if not access.get('is_superadmin') or access.get('access_status') != 'active' or access.get('must_change_password') or access.get('reset_pending'):
        raise Fault('Only an active platform administrator can manage system backups.', 403)
    return user['id']


def start_connect(bearer, actor):
    client = read(SECRETS / 'google-client.json', {}).get('web', {})
    if not client.get('client_id') or not client.get('client_secret'):
        raise Fault('The private Google Web OAuth credential has not been installed on the VPS.', 503)
    verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(32)
    write(SECRETS / 'pending-oauth.json', {'state_hash': hashlib.sha256(state.encode()).hexdigest(),
        'verifier': verifier, 'bearer': bearer, 'actor': actor, 'expires': now().timestamp() + 600})
    params = {'client_id': client['client_id'], 'redirect_uri': CALLBACK, 'response_type': 'code',
        'scope': 'https://www.googleapis.com/auth/drive.file', 'access_type': 'offline',
        'prompt': 'consent', 'state': state, 'code_challenge_method': 'S256',
        'code_challenge': base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')}
    event('google_connect_started', actor)
    return {'url': 'https://accounts.google.com/o/oauth2/v2/auth?' + urllib.parse.urlencode(params)}


def oauth_state(params):
    pending = read(SECRETS / 'pending-oauth.json', {})
    if pending.get('expires', 0) < now().timestamp() or not secrets.compare_digest(
            pending.get('state_hash', ''), hashlib.sha256(params.get('state', [''])[0].encode()).hexdigest()):
        raise InvalidState('Google authorization expired. Connect again from Backup Management.', 403)
    return pending


def callback(params):
    path = SECRETS / 'pending-oauth.json'
    pending = oauth_state(params)
    path.unlink(missing_ok=True)
    if 'error' in params or not params.get('code'):
        raise Fault('Google authorization was cancelled. The existing connection is unchanged.')
    authenticate(pending['bearer'])
    client = read(SECRETS / 'google-client.json')['web']
    token = request_json('https://oauth2.googleapis.com/token', urllib.parse.urlencode({
        'code': params['code'][0], 'client_id': client['client_id'], 'client_secret': client['client_secret'],
        'redirect_uri': CALLBACK, 'grant_type': 'authorization_code', 'code_verifier': pending['verifier']}).encode())
    if not token.get('refresh_token') or 'https://www.googleapis.com/auth/drive.file' not in token.get('scope', ''):
        raise Fault('Google did not grant offline file access. Reconnect and accept the requested permission.')
    credentials = {'access_token': token['access_token'], 'token_type': 'Bearer', 'refresh_token': token['refresh_token'],
        # Exercise unattended refresh as part of explicit connection validation.
        'expiry': (now() - dt.timedelta(minutes=1)).isoformat()}
    temporary = SECRETS / 'candidate-rclone.conf'
    temporary.write_text('[lpg-drive]\ntype = drive\nscope = drive.file\nclient_id = ' + client['client_id'] +
        '\nclient_secret = ' + client['client_secret'] + '\ntoken = ' + json.dumps(credentials) + '\n')
    temporary.chmod(0o600)
    try:
        base = ['rclone', '--config', temporary, '--tpslimit', '4']
        about = json.loads(command(base + ['about', 'lpg-drive:', '--json']))
        refreshed = configparser.ConfigParser(interpolation=None)
        refreshed.read(temporary)
        saved_token = json.loads(refreshed['lpg-drive']['token'])
        if dt.datetime.fromisoformat(saved_token['expiry'].replace('Z', '+00:00')) <= now():
            raise Fault('Google offline token refresh did not complete. Reconnect the account.')
        user = request_json('https://www.googleapis.com/drive/v3/about?fields=user(emailAddress,permissionId)',
            headers={'Authorization': 'Bearer ' + saved_token['access_token']})['user']
        email = user.get('emailAddress')
        if not email:
            raise Fault('Google account identity could not be verified.')
        identity = read(STATE / 'repository-identity.json', {})
        if identity.get('account') and identity['account'] != email:
            raise Fault('Reconnect the original Google account so existing recovery points stay accessible.')
        temporary.replace(SECRETS / 'rclone.conf')
        write(STATE / 'connection.json', {'connected': True, 'connected_at': now().isoformat(),
            'validated_at': now().isoformat(), 'token_refresh_verified_at': now().isoformat(), 'status': 'Connected', 'account': email})
        usage = read(STATE / 'usage.json', {})
        write(STATE / 'usage.json', {**usage, **about, 'backup_bytes': usage.get('backup_bytes', 0), 'measured_at': now().isoformat()})
        (STATE / 'authorization-error.json').unlink(missing_ok=True)
        event('google_connected', pending['actor'])
    finally:
        temporary.unlink(missing_ok=True)


def status():
    connection = read(STATE / 'connection.json', {'connected': False, 'status': 'Not connected'})
    connection['configured'] = (SECRETS / 'rclone.conf').exists()
    connection['connected'] = connection['configured'] and bool(connection.get('validated_at'))
    if connection['configured'] and not connection['connected']:
        connection['status'] = 'Configured · awaiting nightly validation'
    settings = read(STATE / 'settings.json', {'enabled': True})
    history = read(STATE / 'history.json', [])
    current_generation = read(STATE / 'generation.json', {}).get('id', 'original')
    history = [{**point, 'previous_generation': point.get('generation', 'original') != current_generation} for point in history]
    latest = next((p for p in history if p.get('status') == 'verified' and not p['previous_generation']), None)
    overdue = bool(latest and now().timestamp() - dt.datetime.fromisoformat(latest['captured_at']).timestamp() > 36 * 3600)
    job = read(STATE / 'job.json', {'status': 'idle'})
    # A killed process must not leave a permanent optimistic running indicator.
    if job.get('status') == 'running':
        if not job.get('process_started') or process_identity(job.get('pid')) != job['process_started']:
            job = {**job, 'status': 'interrupted', 'error': 'Backup worker ended before verification. Sealed data is preserved; retry the full backup.'}
    if job.get('status') == 'queued' and now().timestamp() - dt.datetime.fromisoformat(job['started_at']).timestamp() > 30:
        state = command(['systemctl', 'show', '--property=ActiveState', '--value', 'lpg-backup-manual.service']).strip()
        if state not in ('active', 'activating', 'reloading'):
            job = {**job, 'status': 'interrupted', 'error': 'The full-backup worker did not start. Retry the full backup.'}
    if job.get('status') == 'interrupted':
        try:
            with Lock(ROOT / 'deploy/.deployment.lock'):
                current = read(STATE / 'job.json', {})
                if current.get('job_id') == job.get('job_id') and current.get('status') in ('queued', 'running'):
                    job.update(failed_at=now().isoformat())
                    write(STATE / 'job.json', job)
                    jobs = [entry for entry in read(STATE / 'jobs.json', []) if entry.get('job_id') != job.get('job_id')]
                    write(STATE / 'jobs.json', ([job] + jobs)[:400])
        except BlockingIOError:
            pass  # An active worker/deployer owns lifecycle state.
    return {'connection': connection, 'settings': settings, 'job': job, 'history': history[:400], 'overdue': overdue,
        'next_run': next_run(), 'queued': (STATE / 'queued.json').exists(),
        'recovery': read(STATE / 'restore.json'), 'usage': read(STATE / 'usage.json'),
        'credentials_installed': (SECRETS / 'google-client.json').exists(),
        'authorization_error': read(STATE / 'authorization-error.json'),
        'key_exported': (STATE / 'key-exported.json').exists(), 'jobs': read(STATE / 'jobs.json', [])[:400]}


def start_full(body, actor):
    if set(body) != {'request_id'}:
        raise Fault('A full-backup request ID is required.')
    try:
        request_id = str(uuid.UUID(body['request_id']))
    except (ValueError, TypeError, AttributeError):
        raise Fault('Invalid full-backup request ID.')
    previous = status()['job']
    attempts = read(STATE / 'jobs.json', [])
    if any(job.get('job_id') == request_id for job in [previous, *attempts]):
        return {'ok': True, 'job_id': request_id, 'already_requested': True}
    if not (SECRETS / 'rclone.conf').exists():
        raise Fault('Connect Google Drive before creating a full backup.')
    if previous.get('status') in ('queued', 'running'):
        raise Fault('A backup is already queued or running. Follow its progress below.', 409)
    with Lock(ROOT / 'deploy/.deployment.lock'):
        requested = now().isoformat()
        write(STATE / 'manual-request.json', {'request_id': request_id, 'actor': actor, 'requested_at': requested})
        write(STATE / 'job.json', {'job_id': request_id, 'status': 'queued', 'mode': 'manual-full',
              'phase': 'Preparing', 'requested_at': requested, 'started_at': requested, 'percent': None,
              'detail': 'The server has accepted the full backup request.'})
        try:
            command(['systemctl', 'start', '--no-block', 'lpg-backup-manual.service'])
        except Exception:
            write(STATE / 'job.json', {'job_id': request_id, 'status': 'failed', 'phase': 'Failed',
                  'started_at': requested, 'failed_at': now().isoformat(), 'error': 'The backup worker could not start. Retry or inspect its service health.'})
            raise
        event('manual_full_backup_requested', actor)
    return {'ok': True, 'job_id': request_id}


class Handler(BaseHTTPRequestHandler):
    server_version = 'LPGBackup'
    sys_version = ''

    def log_message(self, *_):
        pass

    def do_POST(self):
        self.handle_request()

    def do_GET(self):
        self.handle_request()

    def handle_request(self):
        try:
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path == '/backups/v1/oauth/callback' and self.command == 'GET':
                params = urllib.parse.parse_qs(parsed.query)
                # Unsolicited callbacks cannot change the administrator's cached status.
                oauth_state(params)
                try:
                    with Lock(SECRETS / '.control.lock'), Lock(ROOT / 'deploy/.deployment.lock'):
                        callback(params)
                except Fault as error:
                    write(STATE / 'authorization-error.json', {'message': str(error), 'at': now().isoformat()})
                except Exception:
                    write(STATE / 'authorization-error.json', {'message': 'Google connection could not be validated. Check the Drive API and retry.', 'at': now().isoformat()})
                self.send_response(303)
                self.send_header('Location', FRONTEND + '/#/admin?section=backups')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Referrer-Policy', 'no-referrer')
                self.end_headers()
                return
            actor = authenticate(self.headers.get('Authorization'))
            if self.command != 'POST':
                raise Fault('Not found', 404)
            length = int(self.headers.get('Content-Length', '0'))
            if length < 0 or length > 8192:
                raise Fault('Request too large', 413)
            try:
                body = json.loads(self.rfile.read(length) or b'{}')
            except (ValueError, UnicodeError):
                raise Fault('Invalid JSON')
            if not isinstance(body, dict):
                raise Fault('Invalid request')
            with Lock(SECRETS / '.control.lock'):
                path = parsed.path
                if path == '/backups/v1/status':
                    result = status()
                elif path == '/backups/v1/full':
                    result = start_full(body, actor)
                elif path == '/backups/v1/connect':
                    result = start_connect(self.headers['Authorization'], actor)
                elif path == '/backups/v1/disconnect':
                    with Lock(ROOT / 'deploy/.deployment.lock'):
                        (SECRETS / 'rclone.conf').unlink(missing_ok=True)
                        (SECRETS / 'pending-oauth.json').unlink(missing_ok=True)
                        (STATE / 'authorization-error.json').unlink(missing_ok=True)
                        write(STATE / 'connection.json', {'connected': False, 'status': 'Disconnected'})
                        event('google_disconnected', actor)
                    result = {'ok': True}
                elif path == '/backups/v1/queue':
                    with Lock(ROOT / 'deploy/.deployment.lock'):
                        write(STATE / 'queued.json', {'requested_at': now().isoformat(), 'actor': actor})
                        event('backup_queued', actor)
                    result = {'ok': True, 'next_run': next_run()}
                elif path == '/backups/v1/settings':
                    if set(body) != {'enabled'} or not isinstance(body['enabled'], bool):
                        raise Fault('Only scheduled backup pause/resume is configurable. Retention is fixed at 30 days and 12 months.')
                    with Lock(ROOT / 'deploy/.deployment.lock'):
                        write(STATE / 'settings.json', body)
                        event('schedule_resumed' if body['enabled'] else 'schedule_paused', actor)
                    result = {'ok': True}
                else:
                    raise Fault('Not found', 404)
            self.respond(200, result)
        except BlockingIOError:
            self.respond(409, {'error': 'A backup or deployment is running. Retry when it finishes.'})
        except Fault as error:
            self.respond(error.status, {'error': str(error)})
        except Exception:
            self.respond(500, {'error': 'Backup management is unavailable. Inspect the private service health.'})

    def respond(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.end_headers()
        self.wfile.write(data)


if __name__ == '__main__':
    class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True

    os.umask(0o077)
    socket = __import__('pathlib').Path('/run/lpg-backup/control.sock')
    socket.parent.mkdir(mode=0o750, exist_ok=True)
    os.chown(socket.parent, 0, 1000)
    socket.parent.chmod(0o750)
    socket.unlink(missing_ok=True)
    server = Server(str(socket), Handler)
    socket.chmod(0o660)
    os.chown(socket, 0, 1000)
    server.serve_forever()
