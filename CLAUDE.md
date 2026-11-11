# Project: Caddy Visualizer (OCTG fork)

A fork of [dree007/caddy-visualizer](https://github.com/dree007/caddy-visualizer), a Next.js web UI for a
Caddy server, plus a native-install kit (`deploy/ct109/`) that runs it as a systemd service inside the
LXC container that hosts Caddy (CT109). **We consume upstream releases; we do not develop the app.**
Our own work is the kit, the upgrade process and the docs around them.

## Session Rules

- Rules live in this file. Standing hand-off documents for a session live in `docs/handoffs/` (local,
  untracked); if one is named in the request, follow it. Where a hand-off contradicts something you
  find in the repo, say so before acting.
- Before escalating a technical judgment call, try to resolve it from the code, upstream release notes
  and `deploy/ct109/README.md`. Escalate only if that does not settle it.
- Upgrading to a new upstream release follows `deploy/ct109/UPGRADING.md`.

## Autonomous Operating Rules

### Commit mode (per session)

Default is **`manual`**: no commits unless explicitly requested. The user can switch modes at any point
by saying `commit mode: auto` or `commit mode: auto-pr`. The mode resets to `manual` at the start of
every new session.

| Mode               | Behavior                                                                                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `manual` (default) | Never commit unsolicited. Suggest a commit message at natural stopping points; the user commits or asks you to.                                                           |
| `auto`             | Commit locally after each completed task once its checks pass. Never push.                                                                                                |
| `auto-pr`          | Commit after each completed task, push to a feature branch, open a PR when the task group completes. Never push to `main`; merge a PR only if the user said to merge it. |

Branch names: `deploy/<slug>` for kit and upgrade work, `chore/<slug>-<yyyymmdd>` for everything else.
Commit messages for kit work start with `ct109 kit:`. Write a message that contains awkward characters
with `git commit -F <file>`.

### Quality gates

- **Application or build changes**: `npm run build` must pass (it includes the type check). Run
  `npm audit --omit=dev` after any dependency change.
- **Kit changes** (`deploy/ct109/`): `bash -n` every changed script (and `shellcheck` if installed). If the
  change can affect the tarball or the installer, run `./deploy/ct109/build-bundle.sh` and the smoke tests
  in `deploy/ct109/smoke/` before committing.
- **Docs-only exception**: skip the gate when every changed file is Markdown or plain text. Check
  `git status` first; if any script, config, or source file is also touched, run the gate as normal.

### Escalate to the user when

- Anything touches production infrastructure (see Hard Rules 1 and 2).
- A security issue is found. Stop, report it with file, line and a concrete failure scenario, and do not
  merge until the user decides.
- A change to `package.json` or `package-lock.json` is needed outside an upstream upgrade.
- Upstream source files would have to be patched (see Hard Rule 4).
- A release adds outbound network behavior, telemetry, install scripts, a destructive migration with no
  safe rollback, or any new way to reach the Caddy admin API.

### Working rules

- **Command hygiene (permission-prompt avoidance)**: one command per Bash call. Do not chain with `&&`,
  `;` or pipes, and do not prefix commands with `cd path &&` (a `cd` also leaks into later calls); use
  absolute paths. If you need only the end of long output, redirect it to a file in one call and read it
  in the next.
- **Scope creep guard**: change only what the current task needs. Anything else becomes a note for the user.
- **Rollback checkpoint**: before any multi-file change, confirm a clean git state. Never start destructive
  work on a dirty tree. Do not force-push, do not `git reset --hard` or `rm -rf` anything you did not create
  in this session, and look at a file before you overwrite or delete it.
- **Stage by explicit path.** The working tree holds untracked local material (`dist/`, `docs/handoffs/`,
  `.claude/`). Never `git add -A` or `git add .`.
- **Environment safety**: never read or write `.env*`, key or `.pem` files, or secret values. You may check
  that a file exists. Do not paste secrets or real hostnames into any file in the repo or into a PR; the
  fork is public.
- **Dead end rule**: if blocked for more than 2 attempts on the same problem, stop and surface it instead
  of trying a third approach.
- **Task tracking**: use the session task list for work items. Put follow-ups for the user in your final
  message rather than creating TODO files.
- **Verification honesty**: never claim to have verified or fixed something you did not directly observe.
  Treat upstream release notes as claims, not facts: verify them against the code. A log or screenshot that
  was not actually read is unverified. State what was tested and what was not, and label extrapolation as
  such.
- **npm only** for this repo (`npm ci`, `npm run`). No pnpm or yarn.

## Hard Rules

1. **Never touch CT109 or the Proxmox host.** No `ssh`, `scp`, `pct`, or anything that reaches them. Produce
   the commands for the user to run, with the output to expect, and let them paste results back.
2. **Never edit the live Caddyfile or run anything against live Caddy.** If a release truly requires a
   Caddyfile change, give the exact edit as a separate, optional block (`caddy adapt` first, then
   `systemctl reload caddy`). The `admin` line is locked in the UI, so such a change is made by hand.
3. **Never commit real hostnames, the live Caddyfile, merge scripts, tokens or passwords.** `dist/` is
   gitignored and holds the build output and local-only files; keep it that way.
4. **Do not modify upstream source files** (`src/`, `drizzle/`, `public/`, `Dockerfile`, `package*.json`,
   `next.config.ts`) unless the user approves and the reason is written in the commit. The kit lives under
   `deploy/ct109/` plus two one-line edits (`.gitattributes`, `.gitignore`); that is what keeps upstream
   upgrades mergeable.
5. **Full data privacy.** The only expected outbound traffic is Caddy's admin API over a unix socket (and
   Google Fonts at build time). Re-check egress, telemetry and update checks in every upgrade review.
6. **SQLite consistency.** Never copy a live WAL database. Stop the service, then back up (the installer does
   exactly that). A rollback that crosses a migration restores the backup as well as the release link.
7. **Releases are immutable.** Never edit a tag or rebuild a version string that is already installed;
   `install-release.sh` refuses a version it already has.

## Fork and branches

- `origin` = `git@github.com:oneclicktechgroup/caddy-visualizer.git` (our fork, public). `upstream` =
  `https://github.com/dree007/caddy-visualizer.git` (read-only for us; never push or open PRs there).
- `main` = an upstream release plus our kit. It moves forward only through a reviewed PR (or a deliberate
  fast-forward the user asked for). Never force-push it.
- Pass `--repo oneclicktechgroup/caddy-visualizer` to `gh`, so a PR can never target upstream.
- Upstream tags are lightweight; `git describe` needs `--tags` to see them.

## Stack and commands

- **App**: Next.js 16 (`output: standalone`), React 19, Drizzle ORM on SQLite (better-sqlite3), Node >= 24.7,
  Argon2id via `node:crypto`. Upstream's design decisions are theirs; do not re-litigate them here.
- **Deploy**: bundled tarball (standalone output + Node binary) installed by `install-release.sh` as a
  systemd service; Caddy admin API over a unix socket. Details and runbook: `deploy/ct109/README.md`.

```bash
npm ci                                   # install exactly what the lockfile says
npm run build                            # production build (type check included)
npm audit --omit=dev                     # production dependency audit
./deploy/ct109/build-bundle.sh [version] # Docker build, tarball + .sha256 in dist/
git fetch upstream --tags                # see new upstream releases
```

Windows (Git Bash) notes already solved in the kit; do not regress them: pack the tarball inside the
container (NTFS symlink privilege), `MSYS_NO_PATHCONV=1` for container paths, scripts stay LF
(`/deploy/** text eol=lf`), read command output into a variable before `grep -q` under `set -o pipefail`,
and Docker Desktop's engine must be running.
