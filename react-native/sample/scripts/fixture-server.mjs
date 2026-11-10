#!/usr/bin/env node
// A tiny local ZeeChat server for the sample. It answers the contract v1 endpoints with the shared fixtures in
// sdks/contract/v1/fixtures, so the sample runs with no real account.
//
//   npm run fixture-server                       listens on 0.0.0.0:8787
//   baseUrl on the Android emulator:  http://10.0.2.2:8787
//   baseUrl on the iOS simulator:     http://localhost:8787
//
// Debug builds allow cleartext HTTP. Never use this server or an http baseUrl in a release build.
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const fixtures = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'contract', 'v1', 'fixtures');
const load = (name) => JSON.parse(readFileSync(join(fixtures, name), 'utf8'));
const port = Number(process.env.PORT ?? 8787);
const prefix = '/api/v1/zeechat/mobile';

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? '/', 'http://localhost');
  if (!url.pathname.startsWith(prefix)) return send(res, 404, { code: 'NOT_FOUND' });
  const route = `${req.method} ${url.pathname.slice(prefix.length)}`;
  // The wrapper header proves the React Native package set `wrapper`.
  console.log(route, 'wrapper=' + (req.headers['x-zee-sdk-wrapper'] ?? 'none'), 'sdk=' + (req.headers['x-zee-sdk'] ?? 'none'));

  if (route === 'GET /config') return send(res, 200, load('config.json'));
  if (route === 'POST /session' || route === 'POST /session/identify') return send(res, 201, load('session.json'));
  if (route === 'POST /session/logout') return send(res, 200, { data: { loggedOut: true } });
  if (route === 'GET /conversations') return send(res, 200, load('conversations.json'));
  if (/^GET \/conversations\/[^/]+\/messages$/.test(route)) return send(res, 200, load('messages.json'));
  if (route === 'POST /messages') {
    return send(res, 202, { data: { clientMessageId: 'echo', accepted: true, conversationId: 'conv_2' } });
  }
  if (route === 'POST /attachments') return send(res, 201, load('attachment.json'));
  if (route === 'POST /read') return send(res, 200, { data: { unreadTotal: 0 } });
  if (route === 'GET /unread') return send(res, 200, { data: { unreadTotal: 1 } });
  if (route === 'PUT /device') return send(res, 200, { data: { registered: true } });
  if (route === 'DELETE /device') return send(res, 200, { data: { registered: false } });
  if (route === 'GET /events') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    res.write('event: ready\ndata: {"conversationId":"conv_2"}\n\n');
    const timer = setInterval(() => res.write(': ping\n\n'), 20_000);
    req.on('close', () => clearInterval(timer));
    return undefined;
  }
  return send(res, 404, { code: 'NOT_FOUND' });
});

server.listen(port, '0.0.0.0', () => console.log(`ZeeChat fixture server on http://0.0.0.0:${port}`));
