# Caddy Visualizer on CT109 (native install, no Docker)

Runs the app as a systemd service inside the same container as Caddy. It has to live there:
the app reads and writes Caddy's files and talks to Caddy's admin **unix socket**, which cannot
cross hosts. Releases are built in Docker on your machine and installed as a tarball.

## What was and was not tested

Tested on the 1.6.0 bundle (build `bff30f9e`, Node 24.22.3), run in a Debian 13 container (glibc 2.41,
as on CT109) next to a real Caddy 2.11.4 whose admin socket has mode `0222`:

- `build-bundle.sh` end to end (Docker Desktop on Windows), checksum, and tarball contents.
- Startup with migrations and admin creation, `/api/health`, login through the real form, every page
  rendering (Dashboard, Metrics, Logs, Config, Caddyfile editor, new site, Certificates, Settings),
  Settings showing Caddy as connected, access-log ingestion, CSRF rejection on API posts, security
  headers, static assets.
- Upgrade: a database made by the 1.0.2 build (with a legacy site row) opened by 1.6.0. Migrations went
  from 7 to 12, the row survived, integrity and foreign-key checks were clean. Restoring the backup and
  upgrading again worked. The 1.0.2 build also still starts on the migrated file; what it does with rows
  made by new features was not tested, which is why a manual rollback restores the backup.
- Certificate checks: with a wildcard-only Caddyfile nothing is probed; named sites that resolve to
  loopback or a private address are blocked without a connection.
- Memory, with the unit's 192 MB heap cap and every page rendered three times in a row: peak 229 to
  230 MB over two runs, about the same as the 1.0.2 build (219 to 239 MB), under `MemoryMax`.

Not tested here: the systemd unit and `install-release.sh` (they need root on the target; both are
unchanged since the 1.0.2 install that runs today), changing the Caddyfile or a form site through the UI
against live Caddy, and basic auth, redirects or `header_up` on a real site. Treat the first install of
each release as a trial run, with the snapshot below in place.

## Requirements on CT109

- Debian 12 or newer (**glibc 2.34+**; the bundled SQLite binary will not load on Debian 11).
- Caddy 2.8+ installed from the Debian package, running as the systemd service `caddy`
  (user `caddy`, Caddyfile at `/etc/caddy/Caddyfile`).
- About 200 MB of RAM headroom and 1 GB of disk (each release is roughly 190 MB, three are kept).

## Upgrading from 1.0.x to 1.6

Reviewed against upstream `v1.0.2..v1.6.0`; nothing there blocks this install. What changes for it:

- **Database migrations 0007 to 0011 run on the first start.** They rebuild the `caddy_sites` table
  (existing rows are kept) and add a `certificate_checks` table. Release 1.0.x still starts on the
  migrated file, but it does not know the new features' rows, so a manual rollback should restore the
  pre-update database backup, not only the `current` link.
  `install-release.sh` does both by itself when the new release fails its health check.
- **No new required settings.** The env file from 1.0.x works unchanged. Keep `AUTH_DISABLED`
  unset (see the note in the env example). `CERT_CHECK_PRIVATE_DOMAINS` is optional.
- **New outbound traffic: certificate checks.** Every 6 hours (first run 1 minute after start) and
  on "Check now", the app resolves the host names of Caddy's running config and opens a TLS
  connection to port 443, reading the certificate only. Targets come from Caddy's config alone,
  loopback and link-local addresses are never contacted, and private addresses only for domains in
  `CERT_CHECK_PRIVATE_DOMAINS`. Wildcard names are not probed, so a wildcard-only Caddyfile
  causes no connections at all. There is no switch to turn the checks off.
- **Form sites gain basic auth, redirects, `header_up` rows and "skip upstream certificate check".**
  They apply to sites the UI creates, so none of them help names that a wildcard site covers.
  Basic auth needs Caddy 2.8+ (already required). Header values are stored in the database in
  plain text, so do not put secrets in them.
- **Caddy Config** now lists the site blocks of the main Caddyfile and can add
  `import access_log` to them (checked by Caddy, recorded as a revision like any edit).

## 0. Preflight (run on CT109, check the output before going on)

```bash
. /etc/os-release; echo "$PRETTY_NAME"; ldd --version | head -1
free -m; df -h /
caddy version; id caddy
systemctl cat caddy | head -30
systemctl list-units --type=service --no-pager | grep -iE 'caddy|manager'
ss -ltnp | grep -E ':(80|443|2019|3000)\b'
```

Look for: glibc 2.34 or newer, Caddy 2.8 or newer, user `caddy` present, nothing else
(such as the old manager) listening on 3000 or editing the Caddyfile. If your Caddyfile holds
secrets (DNS API tokens), redact them before pasting it anywhere.

## 1. Safety net

On the Proxmox host (x1): `pct snapshot 109 pre-caddy-visualizer`
On CT109: `cp -a /etc/caddy/Caddyfile /root/Caddyfile.before-visualizer`

## 2. One-time setup on CT109 (as root)

```bash
adduser --system --group --no-create-home --home /var/lib/caddy-visualizer \
  --shell /usr/sbin/nologin caddymgr

install -d -m 755 -o caddymgr -g caddymgr /var/lib/caddy-visualizer /var/lib/caddy-visualizer/managed
install -d -m 750 -o caddymgr -g caddymgr /var/lib/caddy-visualizer/data
install -d -m 755 -o caddy    -g caddy    /var/log/caddy
install -d -m 750 -o root     -g caddymgr /etc/caddy-visualizer
install -d -m 755 /opt/caddy-visualizer/releases

# Empty file so Caddy can start even before the UI has written anything.
install -m 644 -o caddymgr -g caddymgr /dev/null /var/lib/caddy-visualizer/managed/sites.caddy

# The manager edits the Caddyfile in place, so the group needs write access to that one file.
chgrp caddymgr /etc/caddy/Caddyfile && chmod 664 /etc/caddy/Caddyfile
```

Copy these from your clone to the container (`scp deploy/ct109/<file> root@<ct109>:<target>`):

| File | Target on CT109 |
|---|---|
| `caddy-admin.tmpfiles.conf` | `/etc/tmpfiles.d/caddy-admin.conf` |
| `caddy-visualizer.service` | `/etc/systemd/system/caddy-visualizer.service` |
| `caddy-visualizer.env.example` | `/etc/caddy-visualizer/env` (then edit: `TZ`, check the paths) |
| `install-release.sh` | `/opt/caddy-visualizer/install-release.sh` (`chmod 755`) |

```bash
systemd-tmpfiles --create /etc/tmpfiles.d/caddy-admin.conf
chown root:caddymgr /etc/caddy-visualizer/env && chmod 640 /etc/caddy-visualizer/env

# First-login password (12+ characters). Printed once; it is deleted in step 6.
umask 077
head -c 24 /dev/urandom | base64 > /etc/caddy-visualizer/initial-password
chgrp caddymgr /etc/caddy-visualizer/initial-password && chmod 640 /etc/caddy-visualizer/initial-password
cat /etc/caddy-visualizer/initial-password

systemctl daemon-reload && systemctl enable caddy-visualizer
```

## 3. Build and install a release

On your machine, from the repo (Docker Desktop must be running, and the build needs internet because
it downloads fonts; no admin rights or Windows Developer Mode needed, since the tarball is packed
inside the container):

```bash
./deploy/ct109/build-bundle.sh            # writes dist/caddy-visualizer-<ver>-linux-x64.tar.gz
scp dist/caddy-visualizer-*-linux-x64.tar.gz* root@<ct109>:/tmp/
```

On CT109:

```bash
/opt/caddy-visualizer/install-release.sh /tmp/caddy-visualizer-<ver>-linux-x64.tar.gz
```

The script verifies the checksum, checks that Node and SQLite run on this system, backs up the
database, switches the `current` link, restarts the service, waits for `/api/health`, and
switches back (restoring the database backup) if it does not come up.
It does not need Caddy to be configured yet; the UI will just show Caddy as unreachable.

## 4. Change the Caddyfile

Merge `Caddyfile.snippet` into `/etc/caddy/Caddyfile`:

- the `admin` line goes in the global block, which must be the first block in the file;
- the `(access_log)` snippet, and `import access_log` inside the sites you want measured;
- a site for the UI itself, as a manual site (change the hostname);
- one `import /var/lib/caddy-visualizer/managed/sites.caddy` line.

Make this first edit by hand on the shell. The UI refuses any edit that changes the `admin`
line (that rule is what keeps the connection from being cut later), so it cannot make this one.

Check the syntax, then reload through the **old** admin address. The new config moves the admin
endpoint to the socket, and Caddy keeps serving throughout (tested with live requests: none failed):

```bash
# Syntax only. Do not use `caddy validate` with a fake token: a DNS provider module such as
# Cloudflare checks the token's format and rejects a made-up one. The reload below is the real
# check, because it provisions the config with the service's real environment.
caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null && echo syntax-ok

# Port 2019 is whatever your Caddy listens on today (the default).
caddy reload --address localhost:2019 --config /etc/caddy/Caddyfile --adapter caddyfile --force

ls -l /run/caddy-admin/admin.sock        # expect s-w--w--w- (mode 0222: write-only, by design)
systemctl reload caddy && echo reload-ok # the normal reload now finds the socket by itself
```

If the reload reports an error, Caddy keeps the old config (a failed load changes nothing).
Fallback: `systemctl restart caddy` (a few seconds of downtime for everything it proxies).
To undo this step: `cp /root/Caddyfile.before-visualizer /etc/caddy/Caddyfile && systemctl restart caddy`.

## 5. First login

Open `https://<your UI hostname>` (or, before DNS is ready, tunnel with
`ssh -L 3000:127.0.0.1:3000 root@<ct109>` and use `http://localhost:3000`).
Log in as `admin` with the password from step 2. Check **Settings**: Caddy should show as
connected, and the access log as readable.

## 6. Remove the first-run password

```bash
sed -i '/^ADMIN_INITIAL_PASSWORD_FILE=/d' /etc/caddy-visualizer/env   # the line first...
rm /etc/caddy-visualizer/initial-password                              # ...then the file
systemctl restart caddy-visualizer
```

## Updating later

Rebuild with `build-bundle.sh`, copy, run `install-release.sh`. That is the whole procedure for a
rebuild of what you already have. To move to a **new upstream release** (review, merge, smoke test,
deploy), follow `UPGRADING.md`.
Releases stay in `/opt/caddy-visualizer/releases`, three are kept, and the database backup
from each update is in `/var/lib/caddy-visualizer/data/backups` (root only).

Manual rollback to an older release:
```bash
systemctl stop caddy-visualizer
ln -sfn /opt/caddy-visualizer/releases/<old> /opt/caddy-visualizer/current
# If the newer release migrated the database (1.0.x -> 1.6 does), also restore the matching backup
# file over the live one and remove its -wal/-shm files before starting:
#   cp -a /var/lib/caddy-visualizer/data/backups/<file> /var/lib/caddy-visualizer/data/caddy-visualizer.db
#   rm -f /var/lib/caddy-visualizer/data/caddy-visualizer.db-wal /var/lib/caddy-visualizer/data/caddy-visualizer.db-shm
systemctl start caddy-visualizer
```

## When something goes wrong

- **The UI is down or broken:** Caddy keeps running and serving; it does not depend on the UI.
  `journalctl -u caddy-visualizer -n 50`.
- **Edit the Caddyfile without the UI:** `systemctl stop caddy-visualizer`, edit as root,
  `caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null` (syntax check),
  `systemctl reload caddy` (a rejected config leaves the running one in place).
- **Caddy will not start after a UI change:** the UI only writes files after Caddy accepted the
  config, but if it happens, previous versions are `/var/lib/caddy-visualizer/managed/sites.caddy.prev`
  and `.../managed/Caddyfile.prev`, plus your `/root/Caddyfile.before-visualizer`.
  Last resort: `pct rollback 109 pre-caddy-visualizer` on x1 (loses everything since the snapshot).
- **Forgot the password:** set `ADMIN_RESET_PASSWORD=true` and `ADMIN_INITIAL_PASSWORD_FILE=...`
  in the env file with a new password file, restart, log in, remove both and the file again.
- **Service fails with `status=226/NAMESPACE`:** this container does not allow the sandboxing
  options; remove the hardening lines from the unit as noted inside it.
- **Metrics page shows gaps:** Caddy rotated the log faster than it was read. Settings shows the
  gap counter. Raise `roll_size` in the snippet if it keeps happening.
- **Disk:** the log keeps at most about 40 MB, and request rows are kept 14 days. Watch the
  size of `/var/lib/caddy-visualizer/data` if you have a busy site.

## If your Caddyfile is one wildcard site with `@name host ...` / `handle` blocks

Common in homelabs (`*.example.com { @app host app.example.com  handle @app { reverse_proxy ... } }`,
one wildcard certificate for everything). It works with this tool, with one limit you should know:

- **Works:** the Metrics and Logs pages (they use the request host, so every service gets its own
  numbers), the raw Caddyfile editor with validation through Caddy, revision history and rollback,
  and the dashboard.
- **Does not work:** the "add site" form for any name the wildcard covers. The apply step refuses it
  on purpose, because a separate site block for `app.example.com` next to `*.example.com` would take
  over that name. Add services by editing the Caddyfile in the UI (a new `@name host` + `handle` pair).
- **Dashboard:** the wildcard site is shown as one row with all its upstreams merged, not one row
  per host.

Do not "fix" this by splitting the wildcard into one site block per host: each name then gets its
own certificate, and every internal host name ends up in the public Certificate Transparency logs.
The import line for the managed sites file is still required exactly once; with a wildcard setup
that file simply stays empty.

Putting the UI itself behind the wildcard: add a `handle` for its host that proxies to
`127.0.0.1:3000`, and guard it with `@lan remote_ip private_ranges` plus a `respond 403` fallback.
The tool can reconfigure your proxy, so it must not be reachable from the internet. If something
sits in front of Caddy (a tunnel or CDN), the connecting address is that proxy, so the guard
proves nothing: use an allow-list for that proxy's real client header instead.

## Notes

- The service user can rewrite `/etc/caddy/Caddyfile` and reconfigure Caddy through the socket.
  That is inherent in what the tool does, so keep it behind Caddy with HTTPS and a long password.
- Put `*.sh text eol=lf` in the fork's `.gitattributes` and `dist/` in `.gitignore`; Windows
  checkouts otherwise turn the scripts into CRLF files that fail with `bash\r`.
