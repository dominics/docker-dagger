# Self-hosted AIOStreams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `usenetstreamer` service with two self-hosted AIOStreams instances on dagger — one LAN (for the tailscale-less TV), one tailnet (for the roaming phone) — wired to our own nzbdav + Prowlarr so usenet serves both the `*arr` download path and Stremio.

**Architecture:** Two `ghcr.io/viren070/aiostreams` containers share all wiring via a compose YAML anchor (`*aiostreams-env`) and differ only in `BASE_URL`, host port, and SQLite volume. Usenet streams route through AIOStreams' built-in proxy (via `nzbdav.aiostreamsAuth`), so the usenet provider only ever sees dagger's IP and WebDAV creds never leak into client URLs. Behavioural config is set per-instance in the UI.

**Tech Stack:** Docker Compose v2, AIOStreams v2 (SQLite, env-pinned wiring), Tailscale Services, bash.

**Spec:** `docs/superpowers/specs/2026-06-04-aiostreams-self-host-design.md`

**Conventions:** Personal repo — conventional-commit subjects, **no `Co-Authored-By` trailer** (match `git log`). Commit only the files each task names. `.env` is gitignored; never commit real secrets.

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `docker-compose.yml` | modify | Remove `usenetstreamer`; add `x-aiostreams-env` anchor + `aiostreams-lan` + `aiostreams-ts` |
| `.env.example` | modify | Drop `USENETSTREAMER_SECRET`; document `AIOSTREAMS_*` + `PROWLARR_API_KEY` |
| `tailscale/apply-serve` | modify | Swap `[usenetstreamer]=7005` → `[aiostreams]=8084` in `SERVICES` |
| `CLAUDE.md` | modify | Update service list, Tailscale/LAN-exposed sections, env-var docs |

Phase 1 (Tasks 1-5) is repo edits + local validation on this machine, then commit/push.
Phase 2 (Tasks 6-9) is deploy + runtime config **on dagger** (and Stremio/Tailscale admin).

---

## Phase 1 — Repository changes (local)

### Task 1: Add the shared env anchor to `docker-compose.yml`

**Files:**
- Modify: `docker-compose.yml:1` (insert a top-level `x-` key before `services:`)

- [ ] **Step 1: Insert the anchor at the top of the file**

Add this block as the new top of `docker-compose.yml`, immediately before the existing `services:` line:

```yaml
# Shared environment for both AIOStreams instances (LAN + tailnet). Anchored so the two
# services stay in lock-step on wiring; only BASE_URL / DB path / published port differ.
x-aiostreams-env: &aiostreams-env
  SECRET_KEY: ${AIOSTREAMS_SECRET_KEY:?Need to set AIOSTREAMS_SECRET_KEY (openssl rand -hex 32)}
  AIOSTREAMS_AUTH: ${AIOSTREAMS_AUTH:?Need to set AIOSTREAMS_AUTH (user:pass)}
  AIOSTREAMS_AUTH_ADMINS: ${AIOSTREAMS_AUTH_ADMINS:-}
  # Locked usenet wiring (nzbdav.* incl. aiostreamsAuth, which enables the built-in proxy
  # so WebDAV creds never appear in client stream URLs and bytes egress from dagger).
  FORCED_SERVICE_CREDENTIALS: ${AIOSTREAMS_FORCED_SERVICE_CREDENTIALS:-}
  # Indexer search over the compose network.
  BUILTIN_PROWLARR_URL: "http://prowlarr:9696"
  BUILTIN_PROWLARR_API_KEY: ${PROWLARR_API_KEY:?Need to set PROWLARR_API_KEY}
  # Force the built-in proxy for debrid/torrent streams too (egress from dagger).
  FORCE_PROXY_ENABLED: "true"
  FORCE_PROXY_ID: "builtin"
  FORCE_PROXY_CREDENTIALS: ${AIOSTREAMS_PROXY_CREDENTIALS:-}
  TZ: ${TZ}

services:
```

(The file previously began with `services:` on line 1; that line is now the last line of the block above — do not duplicate it.)

- [ ] **Step 2: Verify YAML still parses (anchor unused yet is fine)**

Create a throwaway env with every required var, then validate:

```bash
cat > /tmp/aio-validate.env <<'EOF'
PUID=1000
PGID=1000
TZ=Pacific/Auckland
LOCAL_IP=192.168.1.200
CONFIG_DIR=/tmp/cfg
STORAGE_DIR=/tmp/store
AIOSTREAMS_SECRET_KEY=0000000000000000000000000000000000000000000000000000000000000000
AIOSTREAMS_AUTH=admin:pw
AIOSTREAMS_PROXY_CREDENTIALS=admin:pw
PROWLARR_API_KEY=dummy
USENETSTREAMER_SECRET=dummy
EOF
docker compose --env-file /tmp/aio-validate.env config -q && echo "OK: compose valid"
```

Expected: `OK: compose valid` (no errors). `USENETSTREAMER_SECRET` is still in the dummy env because the `usenetstreamer` service is removed in Task 2's combined edit — keep it here so this intermediate state validates.

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "chore(aiostreams): add shared env anchor for AIOStreams services"
```

---

### Task 2: Replace the `usenetstreamer` service with the two AIOStreams services

**Files:**
- Modify: `docker-compose.yml` (the `usenetstreamer` comment + service block — originally lines 108-125)

- [ ] **Step 1: Delete the `usenetstreamer` block and insert the two services**

Remove the entire `usenetstreamer` comment-and-service block (the comment beginning `# Self-hosted Stremio addon that wraps Prowlarr...` through the service's `restart: unless-stopped`). Replace it with:

```yaml
  # Self-hosted AIOStreams — Stremio aggregator wired to our own nzbdav (usenet streaming)
  # + Prowlarr (indexers), replacing usenetstreamer. TWO instances because AIOStreams
  # builds every stream URL from a single BASE_URL (no request-host derivation): the TV
  # has no Tailscale client (LAN HTTP only), while the roaming phone reaches it over the
  # tailnet. Both share wiring via *aiostreams-env; behavioural config is set per-instance
  # in the UI (separate SQLite volumes).
  #
  # Usenet-IP guarantee: nzbdav holds the NNTP creds and does the fetching, so the provider
  # only ever sees dagger. nzbdav.aiostreamsAuth (in AIOSTREAMS_FORCED_SERVICE_CREDENTIALS)
  # forces the built-in proxy, keeping WebDAV creds out of the URLs handed to clients.
  aiostreams-lan:
    image: ghcr.io/viren070/aiostreams:latest
    ports:
      - "127.0.0.1:8083:3000"
      - "${LOCAL_IP}:8083:3000"
    environment:
      <<: *aiostreams-env
      BASE_URL: "http://${LOCAL_IP}:8083"
      DATABASE_URI: "sqlite:///app/data/db.sqlite"
    volumes:
      - ${CONFIG_DIR}/aiostreams-lan:/app/data
    restart: unless-stopped

  # Tailnet instance for the roaming phone. Loopback-only bind; Tailscale Serve
  # (svc:aiostreams) terminates HTTPS and proxies to 127.0.0.1:8084.
  aiostreams-ts:
    image: ghcr.io/viren070/aiostreams:latest
    ports:
      - "127.0.0.1:8084:3000"
    environment:
      <<: *aiostreams-env
      BASE_URL: "https://aiostreams.royal-shark.ts.net"
      DATABASE_URI: "sqlite:///app/data/db.sqlite"
    volumes:
      - ${CONFIG_DIR}/aiostreams-ts:/app/data
    restart: unless-stopped
```

- [ ] **Step 2: Validate the full compose (anchor now consumed; no usenetstreamer)**

```bash
docker compose --env-file /tmp/aio-validate.env config | grep -E "aiostreams-lan|aiostreams-ts|usenetstreamer|BASE_URL|FORCE_PROXY_ID" 
```

Expected: both `aiostreams-lan` and `aiostreams-ts` present, each with its `BASE_URL`, `FORCE_PROXY_ID: builtin` merged in from the anchor, and **no** `usenetstreamer`.

- [ ] **Step 3: Confirm the merge applied shared keys to both services**

```bash
docker compose --env-file /tmp/aio-validate.env config | grep -c "BUILTIN_PROWLARR_URL"
```

Expected: `2` (the anchor's `BUILTIN_PROWLARR_URL` rendered into both services).

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat(aiostreams): replace usenetstreamer with LAN + tailnet AIOStreams instances"
```

---

### Task 3: Update `.env.example`

**Files:**
- Modify: `.env.example` (replace the `USENETSTREAMER_SECRET` block)

- [ ] **Step 1: Rewrite the file**

Replace the entire contents of `.env.example` with:

```sh
PUID=1000
PGID=1000
TZ=Pacific/Auckland
LOCAL_IP=192.168.1.200

# --- AIOStreams (self-hosted Stremio aggregator; replaces usenetstreamer) ---
# 64-char hex encryption key. Generate: openssl rand -hex 32  (cannot change later)
AIOSTREAMS_SECRET_KEY=change-me
# Config-UI login(s): user:pass[,user2:pass2]
AIOSTREAMS_AUTH=admin:change-me
# Which of the above usernames are admins (comma-separated; blank = all are admins)
AIOSTREAMS_AUTH_ADMINS=admin
# A user:pass pair from AIOSTREAMS_AUTH used by the built-in stream proxy
AIOSTREAMS_PROXY_CREDENTIALS=admin:change-me
# Locked usenet wiring: one serviceId.credentialId=value per line, joined with literal
# \n into a single value (AIOStreams splits on \n). nzbdav.aiostreamsAuth (a user:pass
# from AIOSTREAMS_AUTH) enables the built-in proxy so nzbdav WebDAV creds never leak into
# the stream URLs handed to clients, and usenet bytes egress from dagger.
#   nzbdav.url=http://nzbdav:3000
#   nzbdav.apiKey=<nzbdav SABnzbd-section API key>
#   nzbdav.username=<nzbdav WebDAV user>
#   nzbdav.password=<nzbdav WebDAV pass>
#   nzbdav.aiostreamsAuth=<user:pass from AIOSTREAMS_AUTH>
AIOSTREAMS_FORCED_SERVICE_CREDENTIALS=nzbdav.url=http://nzbdav:3000\nnzbdav.apiKey=change-me\nnzbdav.username=change-me\nnzbdav.password=change-me\nnzbdav.aiostreamsAuth=admin:change-me
# Prowlarr API key (Prowlarr → Settings → General → API Key)
PROWLARR_API_KEY=change-me
```

- [ ] **Step 2: Verify no stray usenetstreamer reference remains**

```bash
grep -i usenetstreamer .env.example; echo "exit:$?"
```

Expected: no output, `exit:1`.

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "docs(aiostreams): document AIOStreams env vars in .env.example"
```

---

### Task 4: Update `tailscale/apply-serve`

**Files:**
- Modify: `tailscale/apply-serve:37` (the `SERVICES` associative array)

- [ ] **Step 1: Swap the service entry**

In the `declare -A SERVICES=( ... )` block, replace the line:

```bash
  [usenetstreamer]=7005
```

with:

```bash
  [aiostreams]=8084
```

(8084 is the tailnet instance's loopback port. The LAN instance on 8083 is intentionally **not** a Tailscale Service.)

- [ ] **Step 2: Verify bash syntax**

```bash
bash -n tailscale/apply-serve && echo "OK: syntax valid"
grep -E "aiostreams|usenetstreamer" tailscale/apply-serve
```

Expected: `OK: syntax valid`; the grep shows `[aiostreams]=8084` and no `usenetstreamer`.

- [ ] **Step 3: Commit**

```bash
git add tailscale/apply-serve
git commit -m "feat(tailscale): serve svc:aiostreams (8084), drop svc:usenetstreamer"
```

---

### Task 5: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (5 references at lines 7, 13, 16-18, 68, 69)

- [ ] **Step 1: Project overview (line 7)**

Replace `UsenetStreamer (Stremio addon over nzbdav + Prowlarr)` with:

```
AIOStreams (self-hosted Stremio aggregator over nzbdav + Prowlarr, LAN + tailnet instances)
```

- [ ] **Step 2: Tailscale Services list (line 13)**

Replace `svc:nzbdav`, `svc:usenetstreamer`, `svc:plex` with `svc:nzbdav`, `svc:aiostreams`, `svc:plex` (i.e. swap `svc:usenetstreamer` → `svc:aiostreams`).

- [ ] **Step 3: LAN-exposed services (lines 16-18)**

Replace the LAN-exposed-services bullet so it reads:

```
- **LAN-exposed services**: `nzbdav` (3000) and `aiostreams-lan` (8083) are also
  bound to `${LOCAL_IP}` because Stremio runs on a TV that's LAN-only (no tailnet
  client). The roaming phone uses a second instance, `aiostreams-ts`, over the tailnet
  (`svc:aiostreams`, loopback 8084) — needed because AIOStreams bakes a single
  `BASE_URL` into every stream URL. Usenet streams proxy through AIOStreams' built-in
  proxy (nzbdav holds the NNTP creds on dagger), so the usenet account is only ever
  used from the home IP. No public exposure.
```

- [ ] **Step 4: Env var — LOCAL_IP (line 68)**

Replace `used to bind LAN-only services (nzbdav, usenetstreamer)` with `used to bind LAN-only services (nzbdav, aiostreams-lan)`.

- [ ] **Step 5: Env var — secret (line 69)**

Replace the `USENETSTREAMER_SECRET` bullet with:

```
- `AIOSTREAMS_SECRET_KEY` / `AIOSTREAMS_AUTH` / `AIOSTREAMS_PROXY_CREDENTIALS` /
  `AIOSTREAMS_FORCED_SERVICE_CREDENTIALS` / `PROWLARR_API_KEY` — AIOStreams encryption
  key, UI login, built-in-proxy creds, locked nzbdav usenet wiring, and the Prowlarr API
  key. See `.env.example` for formats.
```

- [ ] **Step 6: Verify all references updated**

```bash
grep -niE "usenetstreamer" CLAUDE.md; echo "exit:$?"
```

Expected: no output, `exit:1`.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(aiostreams): update CLAUDE.md for AIOStreams instances"
```

---

### Task 6: Push and clean up validation artifact

- [ ] **Step 1: Remove the throwaway env**

```bash
rm -f /tmp/aio-validate.env
```

- [ ] **Step 2: Review the branch and push**

```bash
git log --oneline -6
git push
```

Expected: 5 commits pushed (autoSetupRemote handles a first push). Confirm with the user before pushing if working on a feature branch.

---

## Phase 2 — Deploy & configure (on dagger)

> These run **on dagger** (`ssh dagger`, or interactively). They need real secret values.
> Remote sudo on dagger is passwordless via the forwarded 1Password agent.

### Task 7: Populate `.env` on dagger and deploy

**Files:**
- Modify (on dagger): `/home/media/.env`

- [ ] **Step 1: Gather the real secret values**

Collect, from 1Password (Shared vault has TorBox/TMDB per `stremio-credentials.md`) and the running services:
- `AIOSTREAMS_SECRET_KEY` — generate: `openssl rand -hex 32`
- `AIOSTREAMS_AUTH` — choose e.g. `admin:<strong-pw>`; reuse the same pair for `AIOSTREAMS_PROXY_CREDENTIALS` and `nzbdav.aiostreamsAuth`
- nzbdav `apiKey` — nzbdav UI → Settings → SABnzbd section
- nzbdav WebDAV `username`/`password` — nzbdav UI → Settings → WebDAV section
- `PROWLARR_API_KEY` — Prowlarr → Settings → General → API Key

- [ ] **Step 2: Edit `/home/media/.env` on dagger**

Add the AIOStreams keys (from Task 3's template) with real values; remove `USENETSTREAMER_SECRET`. The forced-creds line must use literal `\n` separators, e.g.:

```sh
AIOSTREAMS_FORCED_SERVICE_CREDENTIALS=nzbdav.url=http://nzbdav:3000\nnzbdav.apiKey=REAL\nnzbdav.username=REAL\nnzbdav.password=REAL\nnzbdav.aiostreamsAuth=admin:REALPW
```

Do not wrap that value in quotes (compose passes it literally; AIOStreams splits on `\n`).

- [ ] **Step 3: Store the new secrets in 1Password**

Create item `AIOStreams (dagger)` (API Credential, personal `Private` vault) holding `AIOSTREAMS_SECRET_KEY`, `AIOSTREAMS_AUTH`, and the nzbdav WebDAV/API creds. Notes: "used by docker-dagger aiostreams-lan/-ts; local copy in /home/media/.env on dagger; rotate by regenerating + `docker compose up -d`".

- [ ] **Step 4: Deploy**

```bash
cd /home/media
git pull
docker compose pull aiostreams-lan aiostreams-ts
docker compose up -d aiostreams-lan aiostreams-ts
# usenetstreamer is gone from the compose file; stop/remove the old container:
docker compose rm -sf usenetstreamer 2>/dev/null || docker rm -f usenetstreamer 2>/dev/null || true
```

- [ ] **Step 5: Verify both start cleanly**

```bash
docker compose ps aiostreams-lan aiostreams-ts
docker compose logs --tail=40 aiostreams-lan
docker compose logs --tail=40 aiostreams-ts
```

Expected: both `Up`; logs show the server listening on `3000` and no `SECRET_KEY`/DB errors. If you see permission errors writing `/app/data`, `sudo chown -R 1000:1000 /etc/media-server/aiostreams-lan /etc/media-server/aiostreams-ts` and restart.

---

### Task 8: Wire up the tailnet service `svc:aiostreams`

- [ ] **Step 1: Create the VIP service object + ACL grants (Tailscale admin)**

Per the `tailscale/apply-serve` header prereqs:
1. Create the VIP service: admin console → Services → add `svc:aiostreams` with port `tcp:443` (or `PUT /api/v2/tailnet/-/vip-services/svc:aiostreams` body `{"ports":["tcp:443"]}`).
2. In the tailnet policy file: add `svc:aiostreams: ["tag:media-host"]` to `autoApprovers.services`, and add `svc:aiostreams` to the relevant `grants[].dst`.
3. Remove the now-orphaned `svc:usenetstreamer` from the VIP services and ACL.

- [ ] **Step 2: Apply serve config + restart tailscaled**

```bash
/home/media/tailscale/apply-serve
sudo systemctl restart tailscaled
```

- [ ] **Step 3: Verify**

```bash
sudo tailscale serve status --json | jq -r '.Services | to_entries[] | "\(.key)\t\(.value.TCP."443".HTTPS)"'
```

Expected: `svc:aiostreams` listed with `HTTPS=true`, and `svc:usenetstreamer` absent. Then browse `https://aiostreams.royal-shark.ts.net` from a tailnet device — the AIOStreams UI loads (login via `AIOSTREAMS_AUTH`).

---

### Task 9: Configure both instances and verify the usenet-IP guarantee

- [ ] **Step 1: Configure the LAN instance**

Open `http://192.168.1.200:8083`, log in. Either import `~/Downloads/aiostreams-config-*.json` (then enable nzbdav, add a Prowlarr built-in) or configure from scratch: TorBox debrid; the sources you want (Comet / StremThru Torz / Knaben / MediaFusion); enable the **NzbDAV** service and the **Prowlarr** built-in; leave proxy = `builtin`. The nzbdav creds and proxy come from the forced env (hidden/locked) — you only flip nzbdav on. Save & install.

- [ ] **Step 2: Mirror config to the tailnet instance**

Export the config from `8083` (UI → export), open `https://aiostreams.royal-shark.ts.net`, import it. (Config need not be a precise copy — close is fine.)

- [ ] **Step 3: Install the addons in Stremio**

- TV: install from `http://192.168.1.200:8083/stremio/...` manifest.
- Phone: install from `https://aiostreams.royal-shark.ts.net/stremio/...` manifest.
- Uninstall the old hosted AIOStreams + usenetstreamer addons.

- [ ] **Step 4: Verify usenet results + the proxy/egress guarantee**

1. Search a title; confirm both **usenet** (nzbdav/Prowlarr) and torrent/debrid results appear.
2. Inspect a usenet result's stream URL: it must be a `…/api/v1/proxy/…` URL on the instance's own `BASE_URL`, containing **no** WebDAV username/password.
3. `docker compose logs -f nzbdav` while playing a usenet stream — nzbdav opens the NNTP connection (provider sees dagger's IP).
4. **Roaming test:** put the phone on mobile data only (Wi-Fi off, Tailscale on), play a usenet stream — it plays, and step 3's nzbdav log still shows dagger making the NNTP request. This proves a foreign client IP can never reach your usenet account directly.

- [ ] **Step 5: Final cleanup**

```bash
# On dagger, once everything is confirmed working:
sudo rm -rf /etc/media-server/usenetstreamer
```

Delete `~/Downloads/aiostreams-config-*.json` (it holds plaintext secrets).

---

## Self-Review notes

- **Spec coverage:** replace usenetstreamer (T2), two instances/anchor (T1-T2), exact env vars incl. nzbdav credential IDs + `FORCE_PROXY_ID=builtin` (T1, T3), `apply-serve` swap (T4), CLAUDE.md (T5), deploy (T7), tailnet svc + ACL/VIP prereqs (T8), config import + usenet-IP verification incl. roaming test (T9), cleanup of orphaned svc + config dir + Downloads secret (T8 step1, T9 step5). All spec sections mapped.
- **No placeholders:** every edit shows literal content; commands have expected output.
- **Consistency:** ports `8083` (LAN) / `8084` (tailnet→`apply-serve`/`svc:aiostreams`), `BASE_URL`s, `${CONFIG_DIR}/aiostreams-lan|-ts` volumes, and env-var names match across compose, `.env.example`, `apply-serve`, and CLAUDE.md.
```
