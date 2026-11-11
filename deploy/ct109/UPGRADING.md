# Upgrading to a new upstream release

How the fork is brought to a new `dree007/caddy-visualizer` release and deployed to CT109. First done for
v1.0.2 to v1.6.0; that run's findings are in `reviews/v1.6.0.md`. The standing rules (never touch CT109,
public repo, no force-push, stage by explicit path, and so on) are in the root `CLAUDE.md`.

Placeholders: `<old>` and `<new>` are upstream tags, `<ver>` is the version string of the built tarball
(a short commit hash unless you pass one), `<ct109>` is the container's address, `<pve-host>` the Proxmox
host, `<ctid>` the container id. Real values stay out of this repo (it is public).

## 1. Prepare

```bash
git status                                  # must be clean (untracked dist/, docs/handoffs/, .claude/ are fine)
git switch main && git pull --ff-only origin main
git remote -v                               # origin = our fork, upstream = dree007; add upstream if missing:
git remote add upstream https://github.com/dree007/caddy-visualizer.git
docker info > /dev/null && gh auth status   # Docker Desktop running, gh logged in
git fetch upstream --tags
git tag --sort=-creatordate | head          # newest stable tag; if it is a new minor, ask before continuing
gh release list --repo dree007/caddy-visualizer
```

`<old>` is the upstream tag the fork is on now. `<new>` is the newest stable tag. Ask the person who runs CT109
which release is installed (`cat /opt/caddy-visualizer/current/VERSION` and `BUILDINFO` there) and keep that
release's tarball in `dist/`: it is the rollback artifact and the baseline for the upgrade tests.

## 2. Review (write it down in `reviews/<new>.md`)

Scope. Review per release, not only the net diff, so something added and later removed still shows up.

```bash
git merge-base --is-ancestor <old> <new> && echo "history intact"     # upstream must not have rewritten history
git log --reverse --stat --format='=== %h %ad %s' --date=short <old>..<new> -- . ':!docs' ':!drizzle/meta' ':!package-lock.json'
git diff --stat <old>..<new>
gh release view <tag> --repo dree007/caddy-visualizer                   # every release between old and new
```

Release notes are claims. Verify each against the code. In priority order:

1. **Supply chain.** `git diff <old>..<new> -- package.json package-lock.json Dockerfile .npmrc`. New or bumped
   dependencies, install scripts (`hasInstallScript`, `postinstall`), non-registry `resolved` URLs, new native
   modules (anything besides better-sqlite3 needs a linux-x64 glibc prebuild), Node engine bumps, new
   `RUN curl | sh` or build args. Then `npm audit --omit=dev` on the new tag.
2. **Egress and telemetry.** Grep `src` for `fetch(`, `http.request`, `https.request`, `undici`, `axios`,
   `node:net`, `node:tls`, `node:dns`, `child_process`, `spawn`, `WebSocket`, and for `https?://`. The only
   expected outbound traffic is the Caddy admin socket (Google Fonts at build time is accepted). Anything else
   needs a reading of what it contacts, when, and whether it can be switched off.
3. **Auth and sessions.** Every `route.ts` and every `"use server"` file: is `requireAccess()` called in each
   exported action? Anything new (API keys, tokens, share links, webhooks, import/export, agent features)?
   Re-read `src/proxy.ts`, `src/server/auth/*`, `src/modules/auth/*`, `src/server/env.ts`. Check which of these
   are unchanged: `git diff --stat <old>..<new> -- <paths>` printing nothing means identical.
4. **Caddy write path.** `src/modules/caddy/`: `generator.ts`, `caddyfile.ts` (the token renderer),
   `contracts.ts`, `upstream*.ts`, `redirect.ts`, `basic-auth*.ts`, `caddyfile-sites.ts`, `apply-engine.ts`,
   `managed-files.ts`, `main-caddyfile.ts`. Look for injection through form fields (newlines, braces, `import`,
   `{env.*}` or `{file.*}` placeholders that could leak the DNS API token), path traversal, SSRF through
   upstream validation, writes outside the managed directory and the Caddyfile, and whether a failed load still
   keeps the old config with a revision to roll back to.
5. **Data and migrations.** `git diff <old>..<new> -- drizzle src/server/db/schema.ts`. Destructive or
   non-reversible migrations? `grep -rn "references(" src` for foreign keys that a `DROP TABLE` could cascade.
   Does the old code still start on the new schema (it matters for rollback)? New runtime asset directories the
   standalone build needs (the kit copies `.next/standalone`, `.next/static`, `public`, `drizzle`).
6. **Log ingest.** `src/modules/access-log/ingest.ts`, `parser.ts`: log format assumptions (the kit's snippet
   writes JSON to `/var/log/caddy/access.log`, 10 MiB x 3 rolls), rollup and retention, memory.
7. **Wildcard handling.** Did anything change `hostnameCovered`, `site-inventory.ts` or the add-site form? The
   live Caddyfile is one wildcard site; the README's wildcard section must stay true.
8. **Fit.** New or renamed env vars against `caddy-visualizer.env.example` (`src/server/env.ts`), new writable
   paths against the unit's `ReadWritePaths`, child processes, health path, bind, and the Dockerfile layout
   against what `pack-bundle.sh` expects (stage `build`, `/app`, `/usr/local/bin/node`, `output: standalone`).

Report format: findings by severity (critical, high, medium, low, info), each with file, line and a concrete
failure scenario, then a verdict: **go**, **no-go** or **go with changes**. Keep "what changed" separate from
"what is risky".

**Stop and ask before merging** on any critical or high finding: an auth bypass, injection into the Caddyfile,
unexpected outbound calls or telemetry, an install script you cannot justify, a destructive migration without a
safe rollback, or a build break that needs more than a trivial kit change.

## 3. Branch and merge strategy

`main` is an upstream release plus the kit. Never force-push it.

- **Normal upgrade** (the kit commits are already on `main`, so `main` cannot fast-forward to a tag):

  ```bash
  git switch -c deploy/ct109-v<new> main
  git merge <new>                 # a merge commit; expect conflicts in .gitignore at most
  ```

  Keep `/deploy/** text eol=lf` in `.gitattributes` and `/dist/` in `.gitignore`. If upstream starts touching
  `deploy/`, stop and look.
- The first upgrade (v1.6.0) was different: the kit still lived on a side branch, so `main` was fast-forwarded to
  the tag first and the kit was cherry-picked onto the tag in a PR. That only works once.
- The previous kit branch stays as it is; it is the rollback pointer for the source tree.

## 4. Adapt the kit

Re-verify what the kit assumes about upstream. `build-bundle.sh`, `pack-bundle.sh` and the smoke tests fail
loudly on most of these; the rest is reading:

- Dockerfile has a stage named `build`, working dir `/app`, Node at `/usr/local/bin/node`.
- Next.js `output: standalone` gives `/app/.next/standalone`, plus `/app/.next/static`, `/app/public`,
  `/app/drizzle` (with `meta/_journal.json`).
- `node_modules/better-sqlite3/prebuilds/linux-x64.node` exists in the standalone output.
- Entry point `server.js`; health at `GET /api/health`; Node >= 24.7 (Argon2id via `node:crypto`).
- Env var names match `caddy-visualizer.env.example`.

Change only what the review requires: the env example, the unit, `pack-bundle.sh`, the README (an upgrade
section, the test-status paragraph, version mentions). **Do not change the live Caddyfile.** If a release truly
needs it, write the exact edit as a separate, optional block with `caddy adapt` first and `systemctl reload
caddy` after; the `admin` line is locked in the UI, so it is a hand edit on the shell. Commit each logical
change separately.

## 5. Build

```bash
git status                                  # clean tree: a modified tracked file adds -dirty to the version
./deploy/ct109/build-bundle.sh              # dist/caddy-visualizer-<ver>-linux-x64.tar.gz + .sha256
```

`<ver>` is the short commit hash: upstream's tags are lightweight, and `git describe` ignores those without
`--tags`. To get a readable version, pass one: `./deploy/ct109/build-bundle.sh <new>-ct109.1`. The installer
refuses a version that is already installed, so never reuse one. The build prints the bundled Node version; it
comes from `node:24-bookworm-slim` at build time, so a rebuild can pick up a newer 24.x patch.
The script verifies the checksum and that the tarball contains `app/server.js` and `bin/node`. A documentation
commit made after the build does not change the app, but say so in the PR (the tarball names the build commit).

## 6. Smoke test

The bundled Node is a Linux binary, so the tarball cannot run on a Windows laptop: the tests run in Debian 13
containers (the same glibc as CT109) next to a real Caddy binary. Never mount `dist/` as a whole (it holds
local-only files); the wrapper mounts the tarballs only.

```bash
./deploy/ct109/smoke/run.sh dist/caddy-visualizer-<ver>-linux-x64.tar.gz dist/caddy-visualizer-<installed>-linux-x64.tar.gz
```

About 5 minutes; the log is `dist/smoke-<ver>.log`. Set `CADDY_VERSION` if CT109's Caddy is not 2.11.4. What it
covers:

1. `smoke.sh`: fresh start; 20 black-box checks (health, redirects, CSRF, security headers, static assets);
   then the upgrade path (a database made by the installed release, with a legacy site row, opened by the
   new one: migration count, row survival, integrity and foreign-key checks), a downgrade without restoring
   the backup, and restore-then-upgrade again.
2. `smoke2.sh`: real Caddy over a mode-`0222` admin socket with the live Caddyfile's shape (wildcard site,
   `@name host` and `handle` blocks, access-log snippet). Real login through the form, every page renders,
   Settings shows Caddy connected, access-log ingestion, and the certificate checks (a wildcard-only
   config must probe nothing; named sites resolving to loopback or a private address must be blocked).
3. `smoke3.sh`: memory, old against new, same workload, under the unit's 192 MB heap cap.

Read the log, do not trust the last line alone. When upstream adds pages, update the `PAGES` list in
`authed.mjs`; when it adds log lines worth asserting, update `smoke2.sh`. Not covered: systemd,
`install-release.sh`, applying a change through the UI against live Caddy, and basic auth, redirects or
`header_up` on a real site.

## 7. Publish

```bash
git push -u origin deploy/ct109-v<new>
gh pr create --repo oneclicktechgroup/caddy-visualizer --base main --head deploy/ct109-v<new> --title "..." --body-file <file>
gh pr merge <n> --repo oneclicktechgroup/caddy-visualizer --merge      # only when the user said to merge
```

Always pass `--repo`: the fork's parent is upstream, and a PR must never target it. Use a merge commit, not
squash or rebase, so the build commit named in `<ver>` stays in `main`'s history. The PR body is public: the
review's findings table, what was tested and what was not, no hostnames or addresses.

## 8. Deploy to CT109 (the person who runs CT109 does this; nothing here is run by a session)

**A. Laptop (Git Bash, repo root)**

```bash
git status                                  # clean
sha256sum -c dist/caddy-visualizer-<ver>-linux-x64.tar.gz.sha256        # expect: ...: OK
scp dist/caddy-visualizer-<ver>-linux-x64.tar.gz dist/caddy-visualizer-<ver>-linux-x64.tar.gz.sha256 root@<ct109>:/tmp/
```

**B. Proxmox host** (snapshot first)

```bash
pct snapshot <ctid> pre-visualizer-<ver>
pct listsnapshot <ctid>                     # expect pre-visualizer-<ver> in the list
```

**C. CT109, as root**

1. Record the current state (paste it back):
   `readlink -f /opt/caddy-visualizer/current; cat /opt/caddy-visualizer/current/VERSION; systemctl is-active caddy caddy-visualizer`
   Expect a path under `/opt/caddy-visualizer/releases/`, the old version, then `active` twice.
2. Env or unit changes, if the review required any (exact `sed` or `install` lines, then
   `systemctl daemon-reload` for the unit). Write "none required" when there are none.
3. Install: `/opt/caddy-visualizer/install-release.sh /tmp/caddy-visualizer-<ver>-linux-x64.tar.gz`
   Expect `<file>: OK`, `==> checking the bundle runs on this system`, `==> switching to <ver>`,
   `==> <ver> is healthy`, `Installed <ver>. Previous: <old path>.` The service is stopped for the length of the
   backup and restart (a few seconds); Caddy keeps serving throughout.
4. Verify:
   - `journalctl -u caddy-visualizer -n 20 --no-pager`: look for `database migrations applied` and
     `[access-log] /var/log/caddy/access.log: ok`. About a minute after start, with a wildcard-only Caddyfile,
     expect `[certificates] checked 0 host names`.
   - `curl -sI http://127.0.0.1:3000/api/health | head -3`: `HTTP/1.1 200 OK`. Without curl:
     `/opt/caddy-visualizer/current/bin/node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>r.text()).then(console.log)"`
     prints `{"status":"ok","checks":{"database":"ok"}}`.
   - `ls -l /run/caddy-admin/admin.sock`: still `s-w--w--w-` (write-only, by design).
   - `systemctl is-active caddy` and `systemctl is-active caddy-visualizer`: `active` twice.
5. In the UI: log in; Settings shows Caddy connected and the access log readable; Metrics and Logs show fresh
   traffic; the Caddyfile editor validates (validate only, do not apply); the revision history survived; the
   Certificates page loads.
6. Cleanup note: the previous releases stay (three are kept); the database backup for this update is in
   `/var/lib/caddy-visualizer/data/backups`.

**Rollback** (the installer already rolls back by itself when the new release fails its health check)

```bash
systemctl stop caddy-visualizer
ln -sfn /opt/caddy-visualizer/releases/<old> /opt/caddy-visualizer/current
cp -a /var/lib/caddy-visualizer/data/backups/<newest file named ...pre-<ver>-...> /var/lib/caddy-visualizer/data/caddy-visualizer.db
rm -f /var/lib/caddy-visualizer/data/caddy-visualizer.db-wal /var/lib/caddy-visualizer/data/caddy-visualizer.db-shm
systemctl start caddy-visualizer
```

Last resort, on the Proxmox host: `pct rollback <ctid> pre-visualizer-<ver>` (loses everything since the snapshot).

## 9. After the deploy

Paste the CT109 output back to the session and check it line by line against the expected output above. Put
the result (date, version, anything unexpected) at the bottom of `reviews/<new>.md`. Keep the new tarball and
its `.sha256` in `dist/`.

## Lessons from the v1.6.0 run

- **Check, don't trust, a hand-off's statements about repository state.** It said the kit branch was unpushed;
  `git rev-parse origin/<branch>` showed it was already on the remote.
- **`git describe` without `--tags` ignores lightweight tags**, so versions are bare hashes. Cosmetic, but it
  makes `cat VERSION` on CT109 unreadable at a glance.
- **The fork is public.** Pushes and PR text are public; keep hostnames, addresses and secrets out.
- **`gh` can resolve a fork's default repo to its parent.** Always `--repo oneclicktechgroup/caddy-visualizer`.
- **A `cd` in one shell call leaks into the next.** Use absolute paths.
- **Create the scratch directory before redirecting output into it.** A redirect into a missing directory fails
  before the command runs, and the failure is easy to read as a build failure.
- **Mount tarballs, not `dist/`,** into test containers: `dist/` holds the live Caddyfile copy and merge script.
- **Do not `git add -A`.** The tree has untracked local material (`dist/`, `docs/handoffs/`, `.claude/`).
- **`.git` holds leftover `stale-*lock*` files from earlier sessions.** Harmless; delete them only when no git
  process is running, and ask first.
- **Certificate checks never probe wildcard names.** With a wildcard-only Caddyfile the feature is inert;
  named sites that resolve to private addresses are blocked unless listed in `CERT_CHECK_PRIVATE_DOMAINS`.
- **Do not set `AUTH_DISABLED` in a native install.** Its guard depends on `BIND_ADDRESS`, which only the
  Docker compose file passes in.
