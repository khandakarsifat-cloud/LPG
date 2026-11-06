"""Short-lived, operation-bound password confirmations. Never persist passwords.

Proofs live outside restored databases, contain only token hashes, and must be
consumed while the caller holds the controller lock. Platform/session authority
must be checked independently at both issuance and action execution.
"""
import hashlib
import secrets
import uuid
from urllib import request as http, error as http_error
import json

from core import ROOT, SECRETS, now, read, write

ACTIONS = {'restore', 'delete-inspection', 'delete-rollback', 'delete-business'}


def target_identity(action, target):
    if action not in ACTIONS or not isinstance(target, str):
        raise ValueError('Invalid confirmation target.')
    if action == 'restore':
        if len(target) != 64 or any(c not in '0123456789abcdef' for c in target):
            raise ValueError('A complete recovery snapshot identity is required.')
        return target
    return str(uuid.UUID(target))


def password_identity(bearer, password):
    """Use GoTrue to verify the same actor; revoke the temporary login session."""
    if not isinstance(password, str) or not 1 <= len(password) <= 128:
        raise ValueError('Enter your current password.')
    config = read(ROOT / 'deploy/.account-service.json')
    base = 'http://127.0.0.1:54321/auth/v1'
    headers = {'apikey': config['publicKey'], 'Authorization': bearer, 'Content-Type': 'application/json'}
    try:
        with http.urlopen(http.Request(base + '/user', headers=headers), timeout=20) as response:
            current = json.load(response)
        payload = json.dumps({'email': current['email'], 'password': password}).encode()
        with http.urlopen(http.Request(base + '/token?grant_type=password', data=payload, headers=headers), timeout=20) as response:
            verified = json.load(response)
        try:
            if verified.get('user', {}).get('id') != current['id']:
                raise ValueError('Password verification failed.')
        finally:
            # Do not leave a second usable session behind after password proof.
            revoke_headers = {**headers, 'Authorization': 'Bearer ' + verified['access_token']}
            with http.urlopen(http.Request(base + '/logout?scope=local', data=b'', headers=revoke_headers), timeout=20):
                pass
        return current['id']
    except (http_error.URLError, KeyError, ValueError) as error:
        raise ValueError('Password verification failed or authentication is unavailable.') from error


def issue(actor, bearer, action, target, password):
    target = target_identity(action, target)
    actor = str(uuid.UUID(actor))
    timestamp = now().timestamp()
    limits = read(SECRETS / 'confirmation-attempts.json', {})
    attempts = [t for t in limits.get(actor, []) if timestamp - t < 300]
    if len(attempts) >= 5:
        raise ValueError('Too many password attempts. Try again in five minutes.')
    limits = {key: [t for t in values if timestamp - t < 300] for key, values in limits.items()}
    limits = {key: values for key, values in limits.items() if values}
    limits[actor] = attempts + [timestamp]
    write(SECRETS / 'confirmation-attempts.json', limits)
    if password_identity(bearer, password) != actor:
        raise ValueError('Password verification failed.')
    token = secrets.token_urlsafe(48)
    digest = hashlib.sha256(token.encode()).hexdigest()
    proofs = read(SECRETS / 'confirmations.json', {})
    proofs = {key: value for key, value in proofs.items() if value['expires'] > timestamp}
    proofs[digest] = {'actor': actor, 'action': action, 'target': target, 'expires': timestamp + 300}
    write(SECRETS / 'confirmations.json', proofs)
    return {'confirmation_token': token, 'expires_in': 300}


def consume(actor, action, target, token, phrase):
    target = target_identity(action, target)
    if phrase != ('RESTORE' if action == 'restore' else 'DELETE'):
        raise ValueError('The confirmation text does not match.')
    if not isinstance(token, str) or not 32 <= len(token) <= 128:
        raise ValueError('Verify your password again.')
    digest = hashlib.sha256(token.encode()).hexdigest()
    proofs = read(SECRETS / 'confirmations.json', {})
    proof = proofs.get(digest)
    if not proof or proof['expires'] <= now().timestamp() or (proof['actor'], proof['action'], proof['target']) != (actor, action, target):
        raise ValueError('Confirmation expired or does not match this operation. Verify your password again.')
    del proofs[digest]
    write(SECRETS / 'confirmations.json', proofs)
