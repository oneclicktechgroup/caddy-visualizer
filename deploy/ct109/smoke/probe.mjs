// Run with the bundled node: node probe.mjs http://127.0.0.1:3111
// Unauthenticated black-box checks of a running release. Exit code 1 if any check fails.
import http from "node:http";

const base = new URL(process.argv[2]);
let failed = 0;

function request(method, path, headers = {}, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: base.hostname, port: base.port, method, path, headers },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () =>
          resolve({
            status: res.statusCode,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          }),
        );
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

function check(name, ok, detail = "") {
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  [" + detail + "]" : ""}`);
}

const host = `${base.hostname}:${base.port}`;

// 1. health
const health = await request("GET", "/api/health", { host });
check("GET /api/health is 200", health.status === 200, health.body.trim());
check(
  "health body reports database ok",
  JSON.parse(health.body).checks?.database === "ok",
);

// 2. root and protected pages redirect to the login page
const root = await request("GET", "/", { host });
check(
  "GET / redirects to /login",
  [302, 303, 307, 308].includes(root.status) && /\/login$/.test(root.headers.location ?? ""),
  `${root.status} ${root.headers.location}`,
);
const cfg = await request("GET", "/config", { host });
check(
  "GET /config (no session) redirects to /login?next=/config",
  [302, 303, 307, 308].includes(cfg.status) && /\/login\?next=%2Fconfig$/.test(cfg.headers.location ?? ""),
  `${cfg.status} ${cfg.headers.location}`,
);
const certs = await request("GET", "/certificates", { host });
check(
  "GET /certificates (new page, no session) redirects to /login",
  [302, 303, 307, 308].includes(certs.status) && /\/login/.test(certs.headers.location ?? ""),
  `${certs.status} ${certs.headers.location}`,
);

// 3. login page renders
const login = await request("GET", "/login", { host });
check("GET /login is 200 html", login.status === 200 && /text\/html/.test(login.headers["content-type"] ?? ""));
check("login page does not set a session cookie", !login.headers["set-cookie"]);

// 4. CSRF: cross-origin state-changing request to an API path is rejected before anything else
const cross = await request("POST", "/api/health", { host, origin: "http://evil.example" });
check(
  "POST /api/health with foreign Origin is 403",
  cross.status === 403 && /forbidden/.test(cross.body),
  `${cross.status} ${cross.body.trim()}`,
);
const cross2 = await request("POST", "/api/anything", { host, origin: "http://evil.example" });
check("POST /api/anything with foreign Origin is 403", cross2.status === 403, String(cross2.status));
// same origin but no session on a protected API path: 401, not a 2xx
const noAuth = await request("POST", "/api/anything", { host, origin: `http://${host}` });
check("POST /api/anything same-origin without session is 401", noAuth.status === 401, String(noAuth.status));
// non-API POST without session
const postCfg = await request("POST", "/config", { host, origin: `http://${host}` });
check("POST /config without session is 401", postCfg.status === 401, String(postCfg.status));

// 5. security headers (on the login page)
const h = login.headers;
check("X-Frame-Options: DENY", h["x-frame-options"] === "DENY", h["x-frame-options"]);
check("X-Content-Type-Options: nosniff", h["x-content-type-options"] === "nosniff");
check("Referrer-Policy: same-origin", h["referrer-policy"] === "same-origin");
check("Permissions-Policy denies camera/mic/geolocation", /camera=\(\)/.test(h["permissions-policy"] ?? ""));
check("CSP frame-ancestors 'none'", /frame-ancestors 'none'/.test(h["content-security-policy"] ?? ""));
check("no X-Powered-By header", h["x-powered-by"] === undefined);

// 6. static assets referenced by the login page are served
const assets = [...new Set([...login.body.matchAll(/(\/_next\/static\/[^"')\s]+\.(?:css|js))/g)].map((m) => m[1]))];
check("login page references static assets", assets.length > 0, `${assets.length} found`);
let okAssets = 0;
for (const a of assets.slice(0, 4)) {
  const r = await request("GET", a, { host });
  if (r.status === 200 && r.body.length > 0) okAssets++;
}
check("static assets are served (200, non-empty)", okAssets === Math.min(4, assets.length), `${okAssets}/${Math.min(4, assets.length)}`);

// 7. unknown path
const nf = await request("GET", "/definitely-not-here", { host });
check("unknown path without session does not leak a page (redirect or 404)", [302, 303, 307, 308, 404].includes(nf.status), String(nf.status));

console.log(failed === 0 ? "ALL CHECKS PASSED" : `${failed} CHECK(S) FAILED`);
process.exit(failed === 0 ? 0 : 1);
