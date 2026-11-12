import { afterEach, beforeEach, describe, it, expect, vi } from 'vitest';
import { api, errorMessage, friendly } from './api';
describe('API request boundary', () => {
  beforeEach(() => vi.stubGlobal('document', { cookie: 'admission_csrf=fixture-csrf' }));
  afterEach(() => vi.unstubAllGlobals());
  it('sends the session cookie and CSRF header for mutations', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ saved: true }), { status: 200 }));
    vi.stubGlobal('fetch', fetch);
    await api('/me/choices/2026', { method: 'PUT', body: JSON.stringify({ program_ids: [2, 1] }) });
    const [path, options] = fetch.mock.calls[0];
    expect(path).toBe('/api/v1/me/choices/2026');
    expect(options.credentials).toBe('same-origin');
    expect(options.headers.get('X-CSRF-Token')).toBe('fixture-csrf');
    expect(options.headers.get('Content-Type')).toBe('application/json');
  });
  it('lets the browser supply the multipart boundary for documents', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response('{}'));
    vi.stubGlobal('fetch', fetch);
    await api('/me/applications/2026/documents', { method: 'POST', body: new FormData() });
    expect(fetch.mock.calls[0][1].headers.has('Content-Type')).toBe(false);
  });
  it('preserves actionable authorization errors and their status', async () => {
    vi.stubGlobal(
      'fetch',
      vi
        .fn()
        .mockResolvedValue(new Response(JSON.stringify({ detail: 'Choices are locked' }), { status: 409 })),
    );
    await expect(api('/me/choices/2026')).rejects.toMatchObject({
      message: 'Choices are locked',
      status: 409,
    });
  });
  it('explains an unavailable admission service', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('network failed')));
    await expect(api('/workspace')).rejects.toThrow('The admission service is unavailable or starting');
  });
  it('does not render arbitrary error objects as messages', () =>
    expect(errorMessage({ password: 'private' })).toBe('Request failed. Please try again.'));
  it('renders database status codes in readable form', () =>
    expect(friendly('REJECTED_FULL')).toBe('Rejected full'));
});
