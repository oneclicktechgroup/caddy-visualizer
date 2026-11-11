// node traffic.mjs  -> a few HTTPS requests to the local Caddy on 443 with SNI/Host of the test names.
import https from "node:https";

function get(name, path = "/") {
  return new Promise((resolve) => {
    const req = https.request(
      { host: "127.0.0.1", port: 443, path, method: "GET", servername: name, headers: { host: name }, rejectUnauthorized: false },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve(`${name}${path} -> ${res.statusCode} ${Buffer.concat(chunks).toString().trim()}`));
      },
    );
    req.on("error", (e) => resolve(`${name}${path} -> ERROR ${e.code}`));
    req.end();
  });
}
for (const [n, p] of [["app.smoke.test", "/"], ["app.smoke.test", "/x"], ["other.smoke.test", "/"], ["app.smoke.test", "/y"]]) {
  console.log(await get(n, p));
}
