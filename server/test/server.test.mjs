import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign, randomBytes } from 'node:crypto';
import { createEnergyServer } from '../server.mjs';

async function fixture(t, overrides = {}) {
  const { server } = createEnergyServer({ dbPath: ':memory:', allowDevelopmentAuth: true, ...overrides });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  async function request(path, { token, method = 'GET', body } = {}) {
    const response = await fetch(base + path, { method,
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  }
  async function login(accountName = 'alice') {
    const response = await request('/v1/auth/development', { method: 'POST', body: { accountName } });
    assert.equal(response.status, 200);
    return response.body;
  }
  return { request, login };
}
const ciphertext = () => randomBytes(64).toString('base64');

test('development authentication is opt-in and loopback only', async t => {
  assert.throws(() => createEnergyServer({ host: '0.0.0.0', allowDevelopmentAuth: true, dbPath: ':memory:' }), /loopback/);
  const { request } = await fixture(t, { allowDevelopmentAuth: false });
  assert.equal((await request('/v1/auth/development', { method: 'POST', body: { accountName: 'alice' } })).status, 404);
  assert.equal((await request('/v1/vault')).status, 401);
});

test('accounts are isolated, stable across sessions, and never chosen from request bodies', async t => {
  const { request, login } = await fixture(t);
  const a = await login(); const b = await login('bob'); const again = await login();
  assert.equal(a.accountID, again.accountID); assert.notEqual(a.token, again.token);
  const encrypted = ciphertext();
  assert.equal((await request('/v1/vault', { token: a.token, method: 'PUT', body: { expectedRevision: 0, mutationID: 'one', ciphertext: encrypted, accountID: b.accountID } })).status, 200);
  assert.equal((await request('/v1/vault', { token: b.token })).body.revision, 0);
  assert.equal((await request('/v1/vault', { token: again.token })).body.ciphertext, encrypted);
});

test('CAS rejects stale writes, idempotent replay cannot replace another payload', async t => {
  const { request, login } = await fixture(t); const a = await login();
  const body = { expectedRevision: 0, mutationID: 'op1', ciphertext: ciphertext() };
  const first = await request('/v1/vault', { token: a.token, method: 'PUT', body });
  assert.equal(first.body.revision, 1);
  assert.equal((await request('/v1/vault', { token: a.token, method: 'PUT', body })).body.replayed, true);
  const changed = await request('/v1/vault', { token: a.token, method: 'PUT', body: { ...body, ciphertext: ciphertext() } });
  assert.equal(changed.body.error, 'mutation_reused');
  const stale = await request('/v1/vault', { token: a.token, method: 'PUT', body: { ...body, mutationID: 'op2' } });
  assert.equal(stale.status, 409); assert.equal(stale.body.revision, 1);
});

test('two concurrent writers cannot both commit the same base revision', async t => {
  const { request, login } = await fixture(t); const a = await login();
  const writes = await Promise.all(['left','right'].map(mutationID => request('/v1/vault', { token: a.token, method: 'PUT',
    body: { expectedRevision: 0, mutationID, ciphertext: ciphertext() } })));
  assert.deepEqual(writes.map(x => x.status).sort(), [200,409]);
});

test('account deletion revokes all sessions and gives a fresh namespace on next login', async t => {
  const { request, login } = await fixture(t); const a = await login(); const second = await login();
  await request('/v1/vault', { token: a.token, method: 'PUT', body: { expectedRevision: 0, mutationID: 'one', ciphertext: ciphertext() } });
  assert.equal((await request('/v1/account', { token: a.token, method: 'DELETE' })).status, 200);
  assert.equal((await request('/v1/vault', { token: second.token })).status, 401);
  const fresh = await login(); assert.notEqual(fresh.accountID, a.accountID);
  assert.equal((await request('/v1/vault', { token: fresh.token })).body.revision, 0);
});

test('invalid envelopes and expired sessions are rejected without changing the vault', async t => {
  let now = 1000;
  const { request, login } = await fixture(t, { now: () => now }); const a = await login();
  for (const body of [{}, { expectedRevision: -1, mutationID: 'a', ciphertext: ciphertext() },
    { expectedRevision: 0, mutationID: 'a', ciphertext: 'plaintext' },
    { expectedRevision: 0, mutationID: 'a', ciphertext: 'a'.repeat(1_400_001) }]) {
    assert.equal((await request('/v1/vault', { token: a.token, method: 'PUT', body })).status, 400);
  }
  now += 8 * 24 * 3600;
  assert.equal((await request('/v1/vault', { token: a.token })).status, 401);
});

test('Apple identity verifies RSA signature, audience, expiration and single-use server nonce', async t => {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'test-key', alg: 'RS256' };
  const now = 1_800_000_000;
  const { request } = await fixture(t, { now: () => now, appleAudiences: ['dev.myenergy.ios'], fetchAppleKeys: async () => [jwk] });
  const challenge = (await request('/v1/auth/challenge', { method: 'POST' })).body;
  const claims = { iss: 'https://appleid.apple.com', aud: 'dev.myenergy.ios', sub: 'opaque-sub', iat: now, exp: now + 300,
    nonce: createHash('sha256').update(challenge.nonce).digest('hex') };
  function jwt(payload, key = privateKey) {
    const data = [Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'test-key' })).toString('base64url'), Buffer.from(JSON.stringify(payload)).toString('base64url')].join('.');
    return `${data}.${sign('RSA-SHA256', Buffer.from(data), key).toString('base64url')}`;
  }
  for (const invalid of [{ ...claims, nonce: 'wrong' }, { ...claims, aud: 'other' }, { ...claims, exp: now - 1 }]) {
    assert.equal((await request('/v1/auth/apple', { method: 'POST', body: { challengeID: challenge.id, identityToken: jwt(invalid) } })).status, 401);
  }
  const good = { challengeID: challenge.id, identityToken: jwt(claims) };
  assert.equal((await request('/v1/auth/apple', { method: 'POST', body: good })).body.mode, 'apple');
  assert.equal((await request('/v1/auth/apple', { method: 'POST', body: good })).status, 401);
});

test('malformed and unsigned Apple identities cannot create sessions', async t => {
  const { request } = await fixture(t, { appleAudiences: ['dev.myenergy.ios'], fetchAppleKeys: async () => [] });
  const c = (await request('/v1/auth/challenge', { method: 'POST' })).body;
  for (const token of ['invalid', 'e30.e30.', null]) {
    assert.equal((await request('/v1/auth/apple', { method: 'POST', body: { challengeID: c.id, identityToken: token } })).status, 401);
  }
});
