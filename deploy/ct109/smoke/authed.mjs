// Run with the bundled node: node authed.mjs http://127.0.0.1:3111 <username> <password-file>
// Logs in through the real login form (Server Action, no-JS form post) and renders every page.
import fs from "node:fs";
import http from "node:http";

const base = new URL(process.argv[2]);
const username = process.argv[3];
const password = fs.readFileSync(process.argv[4], "utf8").replace(/\r?\n$/, "");
const host = `${base.hostname}:${base.port}`;
let failed = 0;

function request(method, path, headers = {}, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: base.hostname, port: base.port, method, path, headers: { host, ...headers } },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
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
const dec = (s) => s.replace(/&quot;/g, '"').replace(/&#x27;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
const text = (html) =>
  dec(html.replace(/<script[\s\S]*?<\/script>/g, " ").replace(/<style[\s\S]*?<\/style>/g, " ").replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();

// ---- login
const page = await request("GET", "/login");
const fields = [...page.body.matchAll(/<input\b[^>]*>/g)]
  .map((m) => m[0])
  .filter((s) => /type="hidden"/.test(s))
  .map((s) => ({ name: dec(/name="([^"]*)"/.exec(s)?.[1] ?? ""), value: dec(/value="([^"]*)"/.exec(s)?.[1] ?? "") }))
  .filter((f) => f.name);
check("login form carries Server Action hidden fields", fields.some((f) => f.name.startsWith("$ACTION")), fields.map((f) => f.name).join(","));
fields.push({ name: "username", value: username }, { name: "password", value: password });
const boundary = "----smoke" + Math.random().toString(16).slice(2);
const body = fields.map((f) => `--${boundary}\r\nContent-Disposition: form-data; name="${f.name}"\r\n\r\n${f.value}\r\n`).join("") + `--${boundary}--\r\n`;

const bad = await request("POST", "/login", { origin: `http://${host}`, "content-type": `multipart/form-data; boundary=${boundary}` },
  body.replace(password, "wrong-password-123"));
check("wrong password does not create a session", !(bad.headers["set-cookie"] ?? []).some((c) => /cm_session=[A-Za-z0-9_-]{20,}/.test(c)), String(bad.status));

const login = await request("POST", "/login", { origin: `http://${host}`, "content-type": `multipart/form-data; boundary=${boundary}` }, body);
const setCookie = (login.headers["set-cookie"] ?? []).join(";");
const cookie = /((?:__Host-)?cm_session=[^;]+)/.exec(setCookie)?.[1];
check("correct password logs in (303 + session cookie)", login.status === 303 && Boolean(cookie), `${login.status} location=${login.headers.location} cookie=${cookie ? "set" : "missing"}`);
check("session cookie is HttpOnly, SameSite=Lax, Secure", /HttpOnly/i.test(setCookie) && /SameSite=lax/i.test(setCookie) && /Secure/i.test(setCookie));
if (!cookie) {
  console.log("cannot continue without a session");
  process.exit(1);
}

// ---- every page renders for a logged-in user
const PAGES = (process.env.PAGES ?? "/dashboard,/metrics,/logs,/config,/config/caddyfile,/config/new,/certificates,/settings").split(",");
for (const path of PAGES) {
  const r = await request("GET", path, { cookie });
  const t = text(r.body);
  const broken = /Application error|Internal Server Error|This page couldn.t load|Something went wrong/i.test(t);
  check(`GET ${path} renders`, r.status === 200 && r.body.length > 2000 && !broken, `${r.status}, ${r.body.length} bytes${broken ? ", ERROR TEXT" : ""}`);
  const interesting = [...t.matchAll(/[^.]{0,80}(Caddy|certificate|Certificate|wildcard|Wildcard|not applicable|Not applicable|Valid|Invalid|Blocked|readable|connected|Connected|unreachable|Unreachable)[^.]{0,100}/g)]
    .slice(0, 4).map((m) => m[0].trim());
  if (path === "/certificates" || path === "/settings" || path === "/config") console.log(`   TEXT ${path}: ${interesting.join(" | ")}`);
}

// ---- logout with a stale session must not work as a bypass
const anon = await request("GET", "/dashboard");
check("without the cookie the dashboard still redirects", anon.status === 307, String(anon.status));

console.log(failed === 0 ? "AUTHED CHECKS PASSED" : `${failed} AUTHED CHECK(S) FAILED`);
process.exit(failed === 0 ? 0 : 1);
