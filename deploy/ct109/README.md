# Caddy Visualizer on CT109 (native install, no Docker)

Runs the app as a systemd service inside the same container as Caddy. It has to live there:
the app reads and writes Caddy's files and talks to Caddy's admin **unix socket**, which cannot
cross hosts. Releases are built in Docker on your machine and installed as a tarball.

## What was and was not tested

Tested (Linux amd64, Node 24.22, fonts stubbed because the test sandbox could not reach Google):
production build, standalone layout used here, startup with migrations and admin creation,
`/api/health`, login redirects, CSRF rejection on API posts, static assets, security headers.

Not tested: `build-bundle.sh` against Docker, the systemd unit, the Caddy integration on CT109.
Treat the first install as a trial run, with the snapshot below in place.

## Requirements on CT109

- Debian 12 or newer (**glibc 2.34+**; the bundled SQLite binary will not load on Debian 11).
- Caddy 2.8+ installed from the Debian package, running as the systemd service `caddy`
  (user `caddy`, Caddyfile at `/etc/caddy/Caddyfile`).
- About 200 MB of RAM headroom and 1 GB of disk (each release is roughly 190 MB, three are kept).

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

On your machine, from the repo (needs Docker and internet, because the build downloads fonts):

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

Validate, then reload through the **old** admin address. The new config moves the admin endpoint
to the socket, and Caddy keeps serving throughout (tested with live requests: none failed):

```bash
# Placeholders such as {env.CF_API_TOKEN} only need some value for a syntax check. Use your own names.
runuser -u caddy -- env HOME=/var/lib/caddy CF_API_TOKEN=dummy \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# Port 2019 is whatever your Caddy listens on today (the default).
caddy reload --address localhost:2019 --config /etc/caddy/Caddyfile --adapter caddyfile --force

ls -l /run/caddy-admin/admin.sock        # expect srw--w--w-
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

Rebuild with `build-bundle.sh`, copy, run `install-release.sh`. That is the whole procedure.
Releases stay in `/opt/caddy-visualizer/releases`, three are kept, and the database backup
from each update is in `/var/lib/caddy-visualizer/data/backups` (root only).

Manual rollback to an older release:
```bash
systemctl stop caddy-visualizer
ln -sfn /opt/caddy-visualizer/releases/<old> /opt/caddy-visualizer/current
# if the newer release migrated the database, also restore the matching backup file
systemctl start caddy-visualizer
```

## When something goes wrong

- **The UI is down or broken:** Caddy keeps running and serving; it does not depend on the UI.
  `journalctl -u caddy-visualizer -n 50`.
- **Edit the Caddyfile without the UI:** `systemctl stop caddy-visualizer`, edit as root,
  `caddy validate`, `systemctl reload caddy`.
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
