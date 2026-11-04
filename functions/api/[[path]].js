// Keep authentication cookies on the Pages domain; the upstream is fixed by deployment settings.
export async function onRequest({ request, env }) {
  if (!env.API_ORIGIN || !env.PROXY_SECRET) {
    return Response.json({ detail: 'The admission service is being configured.' }, { status: 503 });
  }
  const upstream = new URL(env.API_ORIGIN);
  if (upstream.protocol !== 'https:' || upstream.pathname !== '/' || upstream.search || upstream.hash || upstream.username || upstream.password) {
    return Response.json({ detail: 'Invalid service configuration.' }, { status: 503 });
  }
  const url = new URL(request.url);
  upstream.pathname = url.pathname;
  upstream.search = url.search;
  const headers = new Headers(request.headers);
  headers.delete('host');
  headers.set('x-admission-proxy', env.PROXY_SECRET);
  // Trust only the address supplied by Cloudflare, never browser-supplied forwarded headers.
  headers.set('x-forwarded-for', request.headers.get('cf-connecting-ip') || 'unknown');
  try {
    const response = await fetch(upstream, {
      method: request.method, headers,
      body: ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
      redirect: 'manual',
    });
    const result = new Response(response.body, response);
    result.headers.set('Cache-Control', 'no-store');
    result.headers.set('X-Content-Type-Options', 'nosniff');
    result.headers.set('X-Frame-Options', 'DENY');
    return result;
  } catch {
    return Response.json({ detail: 'The admission service is starting. Please try again shortly.' }, { status: 503 });
  }
}
