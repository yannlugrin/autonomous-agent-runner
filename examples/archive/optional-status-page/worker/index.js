// The door in front of the status page. It renders nothing: the page is
// built in CI, in this repository, where it can be read before it ships,
// and this Worker only hands over what it finds in KV.
//
// Two silent failures it is written against.
//
// A Worker also answers on <name>.<account>.workers.dev unless that is
// turned off — an unauthenticated copy of the whole private page, on a
// hostname nothing here can see. `workers_dev = false` in wrangler.toml is
// what shuts it, and this file cannot enforce it. Probe the hostname.
//
// Access protecting a route looks exactly like Access not protecting it,
// from every side except an unauthenticated request. So the assertion is
// verified HERE as well: if the application is deleted, if the policy is
// loosened, if the route is ever reached by a path that skips Access, this
// still refuses. Two mechanisms for one boundary is normally the redundancy
// that drifts — this one is exempt because they fail differently, and the
// one that fails silently is the one above.

const CERTS_TTL_MS = 3600_000;

// Per-isolate, not shared and not persisted. Cloudflare rotates these keys,
// so a cache that never expired would refuse every valid token some morning
// with nothing in the logs to say why.
let certs = { at: 0, keys: null, team: null };

async function keysFor(team) {
  if (certs.keys && certs.team === team && Date.now() - certs.at < CERTS_TTL_MS) {
    return certs.keys;
  }
  const r = await fetch(`https://${team}.cloudflareaccess.com/cdn-cgi/access/certs`);
  if (!r.ok) throw new Error(`certs ${r.status}`);
  const { keys } = await r.json();
  certs = { at: Date.now(), keys, team };
  return keys;
}

function b64u(s) {
  return Uint8Array.from(
    atob(s.replace(/-/g, '+').replace(/_/g, '/').padEnd(s.length + ((4 - s.length % 4) % 4), '=')),
    (c) => c.charCodeAt(0),
  );
}

async function verified(token, env) {
  const parts = token.split('.');
  if (parts.length !== 3) return false;

  let header, payload;
  try {
    header = JSON.parse(new TextDecoder().decode(b64u(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(b64u(parts[1])));
  } catch { return false; }

  // Checked before the signature, so a token signed for another application
  // in the same Zero Trust organisation cannot open this one.
  if (payload.aud !== env.ACCESS_AUD &&
      !(Array.isArray(payload.aud) && payload.aud.includes(env.ACCESS_AUD))) return false;
  if (payload.iss !== `https://${env.ACCESS_TEAM}.cloudflareaccess.com`) return false;
  if (typeof payload.exp !== 'number' || payload.exp * 1000 <= Date.now()) return false;

  const jwk = (await keysFor(env.ACCESS_TEAM)).find((k) => k.kid === header.kid);
  if (!jwk) return false;

  const key = await crypto.subtle.importKey(
    'jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify'],
  );
  return crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5', key, b64u(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
}

export default {
  async fetch(request, env) {
    // The header is what a browser carries through Access. The cookie is
    // read too, because a `curl -b` against the same hostname is how you
    // check this by hand and it would otherwise look broken.
    const token =
      request.headers.get('Cf-Access-Jwt-Assertion') ||
      (request.headers.get('Cookie') || '').match(/(?:^|;\s*)CF_Authorization=([^;]+)/)?.[1];

    if (!token) return deny('no Access assertion');

    let ok = false;
    try {
      ok = await verified(token, env);
    } catch (e) {
      // A certs endpoint that will not answer is not permission to enter.
      return deny(`assertion could not be checked: ${e.message}`, 503);
    }
    if (!ok) return deny('Access assertion rejected');

    const page = await env.PAGE.get('page');
    if (page === null) {
      return html(
        '<h1>Nothing rendered yet</h1><p>The dashboard workflow has not written a page. ' +
          'Run <code>gh workflow run dashboard.yml -R REPLACE_WITH_OWNER/REPLACE_WITH_ARCHIVE</code>.</p>',
        503,
      );
    }
    return html(page, 200);
  },
};

function html(body, status) {
  return new Response(body, {
    status,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      // The page is a private snapshot with a timestamp on it. A cached
      // copy is a page that lies about when it was true.
      'cache-control': 'no-store',
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
    },
  });
}

function deny(why, status = 403) {
  // The reason is stated: this refusing when Access is correctly configured
  // is a bug in this file, and a bare 403 gives nothing to debug it with.
  // It says nothing about what is behind the door.
  return new Response(`403 — ${why}\n`, {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
  });
}
