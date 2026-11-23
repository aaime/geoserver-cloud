/* (c) 2026 Open Source Geospatial Foundation - all rights reserved
 * This code is licensed under the GPL 2.0 license, available at the root
 * application directory.
 */
// Shared authentication of the GeoServer Cloud gateway, with the session in a signed cookie.
// The web interface answers a login with the headers x-gsc-username and x-gsc-roles, and a logout with an empty
// x-gsc-username. answer() turns the login into the cookie gsc_auth (payload.signature, HMAC-SHA256 with the key
// of the environment variable GATEWAY_SHARED_AUTH_KEY), clears the cookie on logout, and removes both headers
// from what the client sees. user() and roles() give the values of a valid cookie, for the headers nginx sends to
// the services. Without a key no cookie is set or accepted, so the services never get the two headers.
import crypto from 'crypto';

const KEY = process.env.GATEWAY_SHARED_AUTH_KEY;
const LIFETIME_S = 8 * 3600;
const NOBODY = { u: '', r: '' };

function sign(payload) {
    return crypto.createHmac('sha256', KEY).update(payload).digest('base64url');
}

// compares every character, so the time taken does not tell how many leading characters match
function same(a, b) {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
}

function session(r) {
    if (r.gscSession) return r.gscSession;
    r.gscSession = NOBODY;
    const cookie = KEY && r.variables.cookie_gsc_auth;
    const dot = cookie ? cookie.lastIndexOf('.') : -1;
    if (dot > 0 && same(cookie.substring(dot + 1), sign(cookie.substring(0, dot)))) {
        const found = JSON.parse(Buffer.from(cookie.substring(0, dot), 'base64url').toString());
        if (found.e > Date.now() / 1000) r.gscSession = found;
    }
    return r.gscSession;
}

function user(r) { return session(r).u; }
function roles(r) { return session(r).r; }

function answer(r) {
    const name = r.headersOut['x-gsc-username'];
    if (name === undefined) return;
    const granted = r.headersOut['x-gsc-roles'] || '';
    delete r.headersOut['x-gsc-username'];
    delete r.headersOut['x-gsc-roles'];
    if (!KEY) return;
    const https = r.variables.scheme === 'https' || r.headersIn['X-Forwarded-Proto'] === 'https';
    const attributes = '; Path=/; HttpOnly; SameSite=Lax' + (https ? '; Secure' : '');
    let cookie = 'gsc_auth=; Max-Age=0' + attributes;
    if (name.trim()) {
        const payload = Buffer.from(JSON.stringify({ u: name, r: granted, e: Math.floor(Date.now() / 1000) + LIFETIME_S }))
            .toString('base64url');
        cookie = `gsc_auth=${payload}.${sign(payload)}; Max-Age=${LIFETIME_S}${attributes}`;
    }
    const others = r.headersOut['Set-Cookie'] || [];
    r.headersOut['Set-Cookie'] = others.concat(cookie);
}

export default { user, roles, answer };
