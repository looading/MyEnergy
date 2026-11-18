import http from 'node:http';
import { createHash, createPublicKey, randomBytes, randomUUID, verify } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const MAX_BODY = 1_500_000;
const MAX_CIPHERTEXT = 1_400_000;
const SESSION_SECONDS = 7 * 24 * 60 * 60;
const digest = value => createHash('sha256').update(value).digest('hex');
const loopback = host => ['127.0.0.1', '::1', 'localhost'].includes(host);
class APIError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}

export function createEnergyServer(options = {}) {
  const host = options.host ?? '127.0.0.1';
  const allowDevelopmentAuth = options.allowDevelopmentAuth === true;
  if (allowDevelopmentAuth && !loopback(host)) throw new Error('Development authentication requires loopback binding');
  const dbPath = options.dbPath ?? './data/myenergy.sqlite';
  if (dbPath !== ':memory:') mkdirSync(dirname(resolve(dbPath)), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(dbPath);
  db.exec(`PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, subject_hash TEXT NOT NULL UNIQUE);
    CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS challenges (id TEXT PRIMARY KEY, nonce_hash TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS vaults (account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE, revision INTEGER NOT NULL, ciphertext TEXT NOT NULL, mutation_id TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS mutations (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, mutation_id TEXT NOT NULL, revision INTEGER NOT NULL, ciphertext_hash TEXT NOT NULL, PRIMARY KEY(account_id,mutation_id));
  `);
  const now = options.now ?? (() => Math.floor(Date.now() / 1000));
  const audiences = new Set(options.appleAudiences ?? []);
  let appleKeys = [];
  let keysExpire = 0;
  const fetchKeys = options.fetchAppleKeys ?? (async () => {
    const response = await fetch('https://appleid.apple.com/auth/keys', { signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new APIError(503, 'identity_provider_unavailable');
    const body = await response.json();
    if (!Array.isArray(body.keys)) throw new APIError(503, 'identity_provider_unavailable');
    return body.keys;
  });
  const counters = new Map();
  function rateLimit(request) {
    const key = request.socket.remoteAddress ?? 'unknown';
    const minute = Math.floor(now() / 60);
    let current = counters.get(key);
    if (!current || current.minute !== minute) current = { minute, requests: 0 };
    current.requests++;
    counters.set(key, current);
    if (counters.size > 5000) {
      for (const [ip, value] of counters) if (value.minute !== minute) counters.delete(ip);
    }
    if (current.requests > 180) throw new APIError(429, 'rate_limited');
  }
  async function readBody(request) {
    const length = Number(request.headers['content-length'] ?? 0);
    if (length > MAX_BODY) throw new APIError(413, 'body_too_large');
    if (!String(request.headers['content-type'] ?? '').startsWith('application/json')) throw new APIError(415, 'json_required');
    let size = 0;
    const chunks = [];
    for await (const chunk of request) {
      size += chunk.length;
      if (size > MAX_BODY) throw new APIError(413, 'body_too_large');
      chunks.push(chunk);
    }
    try {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error();
      return body;
    } catch { throw new APIError(400, 'invalid_json'); }
  }
  function accountFor(request) {
    const header = request.headers.authorization;
    if (typeof header !== 'string' || !header.startsWith('Bearer ')) throw new APIError(401, 'authentication_required');
    const token = header.slice(7);
    if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new APIError(401, 'invalid_session');
    const session = db.prepare('SELECT account_id, expires FROM sessions WHERE token_hash=?').get(digest(token));
    if (!session || session.expires <= now()) throw new APIError(401, 'invalid_session');
    return session.account_id;
  }
  function createSession(subject) {
    const subjectHash = digest(subject);
    let account = db.prepare('SELECT id FROM accounts WHERE subject_hash=?').get(subjectHash);
    if (!account) {
      account = { id: randomUUID() };
      db.prepare('INSERT INTO accounts(id,subject_hash) VALUES(?,?)').run(account.id, subjectHash);
    }
    const token = randomBytes(32).toString('base64url');
    const expiresAt = now() + SESSION_SECONDS;
    db.prepare('INSERT INTO sessions(token_hash,account_id,expires) VALUES(?,?,?)').run(digest(token), account.id, expiresAt);
    return { accountID: account.id, token, expiresAt };
  }
  async function verifyAppleToken(token, nonceHash) {
    if (typeof token !== 'string' || token.length > 20_000 || audiences.size === 0) throw new APIError(401, 'invalid_identity');
    let header, claims, parts;
    try {
      parts = token.split('.');
      if (parts.length !== 3) throw new Error();
      header = JSON.parse(Buffer.from(parts[0], 'base64url'));
      claims = JSON.parse(Buffer.from(parts[1], 'base64url'));
    } catch { throw new APIError(401, 'invalid_identity'); }
    if (header.alg !== 'RS256' || typeof header.kid !== 'string' || header.kid.length > 100) throw new APIError(401, 'invalid_identity');
    if (keysExpire <= now() || !appleKeys.some(k => k.kid === header.kid)) {
      appleKeys = await fetchKeys();
      keysExpire = now() + 3600;
    }
    const jwk = appleKeys.find(k => k.kid === header.kid && k.kty === 'RSA' && (!k.alg || k.alg === 'RS256'));
    let signatureValid = false;
    try {
      signatureValid = !!jwk && verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`),
        createPublicKey({ key: jwk, format: 'jwk' }), Buffer.from(parts[2], 'base64url'));
    } catch { signatureValid = false; }
    if (!signatureValid || claims.iss !== 'https://appleid.apple.com' || !audiences.has(claims.aud) ||
      typeof claims.sub !== 'string' || !claims.sub || claims.sub.length > 255 ||
      !Number.isFinite(claims.exp) || claims.exp <= now() ||
      !Number.isFinite(claims.iat) || claims.iat > now() + 60 ||
      claims.nonce !== nonceHash) throw new APIError(401, 'invalid_identity');
    return claims.sub;
  }
  function vaultFor(accountID) {
    const row = db.prepare('SELECT revision,ciphertext,mutation_id FROM vaults WHERE account_id=?').get(accountID);
    return row ? { revision: row.revision, ciphertext: row.ciphertext, mutationID: row.mutation_id }
      : { revision: 0, ciphertext: null, mutationID: null };
  }
  const server = http.createServer(async (request, response) => {
    const send = (status, body) => {
      response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
      response.end(JSON.stringify(body));
    };
    try {
      rateLimit(request);
      const path = new URL(request.url ?? '/', 'http://localhost').pathname;
      const method = request.method;
      if (path === '/healthz' && method === 'GET') return send(200, { status: 'ok', protocolVersion: 1, developmentAuth: allowDevelopmentAuth });
      if (path === '/v1/auth/challenge' && method === 'POST') {
        db.prepare('DELETE FROM challenges WHERE expires<=?').run(now());
        db.prepare('DELETE FROM sessions WHERE expires<=?').run(now());
        const id = randomUUID();
        const nonce = randomBytes(32).toString('base64url');
        db.prepare('INSERT INTO challenges(id,nonce_hash,expires) VALUES(?,?,?)').run(id, digest(nonce), now() + 300);
        return send(200, { id, nonce });
      }
      if (path === '/v1/auth/development' && method === 'POST') {
        if (!allowDevelopmentAuth) throw new APIError(404, 'not_found');
        const body = await readBody(request);
        if (typeof body.accountName !== 'string' || !/^[a-zA-Z0-9_-]{3,40}$/.test(body.accountName)) throw new APIError(400, 'invalid_development_account');
        return send(200, { ...createSession(`development:${body.accountName}`), mode: 'development' });
      }
      if (path === '/v1/auth/apple' && method === 'POST') {
        const body = await readBody(request);
        if (typeof body.challengeID !== 'string') throw new APIError(400, 'invalid_challenge');
        const challenge = db.prepare('SELECT nonce_hash,expires FROM challenges WHERE id=?').get(body.challengeID);
        if (!challenge || challenge.expires <= now()) throw new APIError(401, 'invalid_challenge');
        const subject = await verifyAppleToken(body.identityToken, challenge.nonce_hash);
        // Consume after asynchronous verification with a single conditional delete: races cannot replay it.
        const consumed = db.prepare('DELETE FROM challenges WHERE id=? AND expires>?').run(body.challengeID, now());
        if (consumed.changes !== 1) throw new APIError(401, 'invalid_challenge');
        return send(200, { ...createSession(`apple:${subject}`), mode: 'apple' });
      }
      const accountID = accountFor(request);
      if (path === '/v1/session' && method === 'DELETE') {
        db.prepare('DELETE FROM sessions WHERE token_hash=?').run(digest(request.headers.authorization.slice(7)));
        return send(200, { signedOut: true });
      }
      if (path === '/v1/account' && method === 'DELETE') {
        db.prepare('DELETE FROM accounts WHERE id=?').run(accountID);
        return send(200, { deleted: true });
      }
      if (path === '/v1/vault' && method === 'GET') return send(200, vaultFor(accountID));
      if (path === '/v1/vault' && method === 'PUT') {
        const body = await readBody(request);
        if (!Number.isSafeInteger(body.expectedRevision) || body.expectedRevision < 0 ||
          typeof body.mutationID !== 'string' || !/^[a-zA-Z0-9-]{1,80}$/.test(body.mutationID) ||
          typeof body.ciphertext !== 'string' || body.ciphertext.length < 40 ||
          body.ciphertext.length > MAX_CIPHERTEXT || !/^[A-Za-z0-9+/]+={0,2}$/.test(body.ciphertext)) throw new APIError(400, 'invalid_vault');
        const hash = digest(body.ciphertext);
        const previous = db.prepare('SELECT revision,ciphertext_hash FROM mutations WHERE account_id=? AND mutation_id=?').get(accountID, body.mutationID);
        if (previous) {
          if (previous.ciphertext_hash !== hash) throw new APIError(409, 'mutation_reused');
          return send(200, { revision: previous.revision, mutationID: body.mutationID, replayed: true });
        }
        const current = vaultFor(accountID);
        if (current.revision !== body.expectedRevision) return send(409, { error: 'revision_conflict', ...current });
        const revision = current.revision + 1;
        db.exec('BEGIN IMMEDIATE');
        try {
          db.prepare('INSERT INTO vaults(account_id,revision,ciphertext,mutation_id) VALUES(?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET revision=excluded.revision,ciphertext=excluded.ciphertext,mutation_id=excluded.mutation_id')
            .run(accountID, revision, body.ciphertext, body.mutationID);
          db.prepare('INSERT INTO mutations(account_id,mutation_id,revision,ciphertext_hash) VALUES(?,?,?,?)').run(accountID, body.mutationID, revision, hash);
          db.exec('COMMIT');
        } catch (error) { db.exec('ROLLBACK'); throw error; }
        return send(200, { revision, mutationID: body.mutationID, replayed: false });
      }
      throw new APIError(404, 'not_found');
    } catch (error) {
      const status = error instanceof APIError ? error.status : 500;
      send(status, { error: error instanceof APIError ? error.code : 'internal_error' });
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5000;
  server.on('close', () => db.close());
  return { server, host };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const { server, host } = createEnergyServer({
    host: process.env.MYENERGY_HOST ?? '127.0.0.1',
    dbPath: process.env.MYENERGY_DATABASE ?? './data/myenergy.sqlite',
    allowDevelopmentAuth: process.env.MYENERGY_ALLOW_DEV_AUTH === '1',
    appleAudiences: (process.env.MYENERGY_APPLE_AUDIENCES ?? '').split(',').filter(Boolean)
  });
  const port = Number(process.env.MYENERGY_PORT ?? 8787);
  server.listen(port, host, () => process.stdout.write(`MyEnergy sync service listening on ${host}:${port}\n`));
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => server.close());
}
