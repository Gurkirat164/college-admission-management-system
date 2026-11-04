import { test } from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/[[path]].js';

test('proxy keeps the upstream fixed, forwards cookies and protects the shared secret', async (t) => {
  const original = globalThis.fetch;
  t.after(() => { globalThis.fetch = original; });
  globalThis.fetch = async (url, options) => {
    assert.equal(String(url), 'https://example.onrender.com/api/v1/auth/login?x=1');
    assert.equal(options.headers.get('x-admission-proxy'), 'server-only-key');
    assert.equal(options.headers.get('origin'), 'https://demo.pages.dev');
    assert.equal(options.headers.get('x-forwarded-for'), '192.0.2.1');
    assert.equal(options.headers.get('cookie'), 'admission_session=opaque');
    return new Response('{}', { headers: { 'Set-Cookie': 'admission_session=new; HttpOnly; Secure; SameSite=Lax; Path=/' } });
  };
  const request = new Request('https://demo.pages.dev/api/v1/auth/login?x=1', {
    headers: { origin: 'https://demo.pages.dev', 'x-admission-proxy': 'forged',
      'cf-connecting-ip': '192.0.2.1', 'x-forwarded-for': 'forged', cookie: 'admission_session=opaque' },
  });
  const response = await onRequest({ request, env: { API_ORIGIN: 'https://example.onrender.com', PROXY_SECRET: 'server-only-key' } });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('set-cookie'), /HttpOnly; Secure/);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
});

test('missing and unsafe configuration fails closed', async () => {
  const request = new Request('https://demo.pages.dev/api/v1/health');
  assert.equal((await onRequest({ request, env: {} })).status, 503);
  assert.equal((await onRequest({ request, env: { API_ORIGIN: 'http://bad', PROXY_SECRET: 'x' } })).status, 503);
});
