# Self-hosted AIOStreams on dagger — design

**Date:** 2026-06-04
**Status:** Draft for review (revised after env-var research + config export)
**Repo:** docker-dagger

## Goal

Run our own [AIOStreams](https://github.com/Viren070/AIOStreams) instances on dagger,
configured in this repo, replacing the hosted AIOStreams we currently point Stremio at.
Self-hosting lets AIOStreams reach the LAN/compose-only services — `nzbdav`
(usenet-as-WebDAV) and `prowlarr` (indexers) — that a hosted instance cannot, so the
same usenet backend serves **both** the `*arr` download path **and** Stremio.

### Why

- The hosted AIOStreams can't talk to `nzbdav` (`http://nzbdav:3000`) or `prowlarr`
  (`http://prowlarr:9696`) — they're bound to loopback/LAN, not the public internet. (The
  exported config confirms `nzbdav` is `enabled: false` with empty credentials today.)
- Self-hosting on dagger puts AIOStreams on the compose network alongside them, and makes
  every usenet/indexer request egress from the home IP (`114.23.254.23`).

### Non-goals

- Replacing the `*arr` → SABnzbd download path. That stays as-is; AIOStreams is the
  *Stremio* consumer of the same usenet backend.
- Off-tailnet usenet streaming. A roaming phone reaches usenet *only* via the tailnet
  instance, which proxies through dagger (see "Usenet-IP guarantee").

## Decisions (from brainstorming)

1. **Replace `usenetstreamer` entirely.** AIOStreams natively supports NzbDAV + Prowlarr,
   subsuming everything usenetstreamer did.
2. **Two instances** (see "Why two instances"): one LAN (for the tailscale-less TV), one
   tailnet (for the roaming phone). Roaming phone streaming is a hard requirement.
3. **Separate SQLite per instance; share behavioural config via import.** Configure one,
   export the config string, import into the other.
4. **Hybrid config:** import the exported JSON for behavioural parity; pin the
   security-critical usenet wiring via `FORCED_*` env vars.
5. **Built-in proxy** for usenet (required — see guarantee) and force-proxy for everything
   else (user opted in).

## Why two instances

AIOStreams derives all installation/stream/proxy URLs from a single `BASE_URL`
(`${baseUrl}/api/v1/proxy/...`, confirmed in `packages/core/src/proxy/builtin.ts`). There
is **no** request-host derivation. So one `BASE_URL` can serve exactly one audience:

- The **TV has no Tailscale client** (confirmed; same constraint that made usenetstreamer
  LAN-bound). It can only install from a LAN HTTP URL → needs `BASE_URL` = LAN.
- The **roaming phone** must reach the addon off-home; the only safe path is the tailnet
  → needs `BASE_URL` = `https://aiostreams.<tailnet>.ts.net`.

One instance can't satisfy both, so we run two, sharing all wiring via env and behavioural
config via import.

| | `aiostreams-lan` | `aiostreams-ts` |
|---|---|---|
| Audience | the TV (LAN, no tailnet) | roaming phone (tailnet) |
| `BASE_URL` | `http://${LOCAL_IP}:8083` | `https://aiostreams.royal-shark.ts.net` |
| Host bind | `127.0.0.1:8083` + `${LOCAL_IP}:8083` | `127.0.0.1:8084` only |
| Tailscale | — | `svc:aiostreams` → `127.0.0.1:8084` |
| DB volume | `${CONFIG_DIR}/aiostreams-lan` | `${CONFIG_DIR}/aiostreams-ts` |
| Container port | `3000` | `3000` |

(Both containers listen on `3000` internally; published on distinct host ports — `8083`,
`8084` — because `nzbdav` already owns host `3000`. Free: `8080` traefik, `8081` sabnzbd.)

## Usenet-IP guarantee (the stretch goal)

**Requirement:** it must be impossible for a client device that later roams onto a foreign
network (e.g. a phone on 5G) to cause a usenet request to our usenet account from any IP
other than home. Usenet providers ban accounts seen from multiple concurrent IPs.

**Mechanism (confirmed in source — `packages/core/src/utils/constants.ts`,
`proxy/builtin.ts`):**

1. **NNTP creds live only in `nzbdav` + SABnzbd on dagger.** When a client plays a usenet
   result it fetches WebDAV bytes from `nzbdav`; `nzbdav` opens the NNTP connection to the
   provider. The client never holds usenet creds and never speaks NNTP. Provider sees
   dagger only, on every path.
2. **Built-in proxy hides WebDAV creds and pins egress.** The nzbdav service has an
   `aiostreamsAuth` credential. Its description: *"If you would like to proxy your NzbDAV
   streams, you will need to provide a username:password pair for your AIOStreams instance
   … Other proxies will not work and you must define it here only."* The matching
   in-UI security note: *"WebDAV credentials are exposed in stream URLs unless proxied. To
   proxy, provide the Auth Token below (built-in proxy only)."* Setting
   `nzbdav.aiostreamsAuth` routes nzbdav streams through AIOStreams' built-in proxy, so the
   stream URL handed to the client contains **no** WebDAV creds and the bytes egress from
   dagger.
3. **Forced, not default.** We set the nzbdav wiring via `FORCED_SERVICE_CREDENTIALS` so it
   is locked and hidden from the UI — neither a UI user nor an imported config can redirect
   nzbdav off dagger or drop the proxy.

Result: `phone (5G + tailnet) → aiostreams-ts (dagger) → built-in proxy → nzbdav (dagger)
→ NNTP → provider`. Provider sees dagger's IP, always. Off-tailnet, `aiostreams-ts` is
unreachable, so no leak path exists.

Force-proxy (`FORCE_PROXY_*`, below) extends "egress from dagger" to debrid/torrent bytes
too; it is belt-and-suspenders for the usenet account guarantee, which `nzbdav` +
`aiostreamsAuth` already provide.

## Architecture

### Service definitions (`docker-compose.yml`)

Replaces the `usenetstreamer` block. Shared env factored into a YAML anchor; per-instance
env (BASE_URL, ports, DB path) differs.

```yaml
x-aiostreams-env: &aiostreams-env
  SECRET_KEY: ${AIOSTREAMS_SECRET_KEY:?Need AIOSTREAMS_SECRET_KEY (openssl rand -hex 32)}
  AIOSTREAMS_AUTH: ${AIOSTREAMS_AUTH:?Need AIOSTREAMS_AUTH (user:pass)}
  AIOSTREAMS_AUTH_ADMINS: ${AIOSTREAMS_AUTH_ADMINS}
  # Locked, security-critical usenet wiring (hidden from UI; can't be redirected):
  FORCED_SERVICE_CREDENTIALS: ${AIOSTREAMS_FORCED_SERVICE_CREDENTIALS}
  # Indexer wiring (compose network):
  BUILTIN_PROWLARR_URL: "http://prowlarr:9696"
  BUILTIN_PROWLARR_API_KEY: ${PROWLARR_API_KEY:?Need PROWLARR_API_KEY}
  # Force the built-in proxy for all (debrid/torrent) streams too:
  FORCE_PROXY_ENABLED: "true"
  FORCE_PROXY_ID: "builtin"
  FORCE_PROXY_CREDENTIALS: ${AIOSTREAMS_PROXY_CREDENTIALS}   # a user:pass from AIOSTREAMS_AUTH
  TZ: ${TZ}

services:
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

### `.env` additions

```sh
# AIOStreams — generate: openssl rand -hex 32
AIOSTREAMS_SECRET_KEY=
# Operator login for the config UI (user:pass[,user2:pass2])
AIOSTREAMS_AUTH=
AIOSTREAMS_AUTH_ADMINS=
# A user:pass pair from AIOSTREAMS_AUTH, used by the built-in proxy
AIOSTREAMS_PROXY_CREDENTIALS=
# Locked usenet wiring — one serviceId.credentialId=value per line (\n-joined):
#   nzbdav.url=http://nzbdav:3000
#   nzbdav.apiKey=<nzbdav SABnzbd API key>
#   nzbdav.username=<nzbdav WebDAV user>
#   nzbdav.password=<nzbdav WebDAV pass>
#   nzbdav.aiostreamsAuth=<user:pass from AIOSTREAMS_AUTH>   ← enables built-in proxy
#   torbox.apiKey=<...>            (optional: pin debrid here instead of in import)
AIOSTREAMS_FORCED_SERVICE_CREDENTIALS=
# Prowlarr indexer search
PROWLARR_API_KEY=
```

### nzbdav credential IDs (verified in source)

`url` (required, → `http://nzbdav:3000`), `publicUrl` (leave blank when proxied), `apiKey`
(required — nzbdav's SABnzbd-section API key), `username` + `password` (WebDAV), and
`aiostreamsAuth` (a `user:pass` from `AIOSTREAMS_AUTH` — enables the built-in proxy).

### Proxy IDs (verified in source)

`FORCE_PROXY_ID` ∈ {`mediaflow`, `stremthru`, `builtin`}. We use `builtin`. Proxy URLs are
built from `BASE_URL`, so each instance proxies to its own audience's URL.

### Exposure

- `aiostreams-lan`: `127.0.0.1` + `${LOCAL_IP}` (mirrors old usenetstreamer). HTTP on a LAN
  IP is accepted by native Stremio apps.
- `aiostreams-ts`: `127.0.0.1` only; tailnet HTTPS via a new `svc:aiostreams`.

### Tailscale (`tailscale/apply-serve`)

- Remove `[usenetstreamer]=7005` from the `SERVICES` map.
- Add `[aiostreams]=8084` (points the tailnet service at the **ts** instance).
- New `svc:aiostreams` needs the standard VIP-service + ACL prereqs (script header):
  create the VIP service object, add `svc:aiostreams` to `autoApprovers.services` and
  `grants[].dst`, run the script, restart `tailscaled`. (Tailnet-admin/ACL steps are on the
  Tailscale side, outside this repo.)

## Configuration (guided by the export — not a precise copy)

The exported config is a **reference for sensible defaults**, not a replication target.
The non-negotiable parts are the new usenet/indexer wiring; the rest is "set it up
reasonably, close to what you had."

Must-have (the point of this work):
- **nzbdav** service enabled, wired + proxied via the forced env (the usenet stream path).
- **Prowlarr** built-in active (`BUILTIN_PROWLARR_URL`/`_API_KEY`) for usenet indexer search.
- **Built-in proxy** on (matches today's `"proxy": {"id": "builtin"}`).

Reasonable defaults to carry over (no need to match exactly): TorBox debrid; a handful of
torrent/debrid sources (the export uses Comet, StremThru Torz, Knaben, MediaFusion);
`excludeUncached`; quality/resolution preferences; cached-first sorting; `prism` formatter.

Fastest path: import the exported JSON into one instance, flip nzbdav on, add Prowlarr,
tweak to taste, then export that and import into the second instance. Real-Debrid can be
dropped (it looks vestigial post-TorBox) — but it's your call, and not worth fussing over.

## Secrets

All secret values stay out of git. The container reads them from `.env` (gitignored);
`.env.example` documents the keys with placeholders. Already in 1Password (per
`stremio-credentials.md`, Shared vault): TorBox, TMDB, Real-Debrid. New items to store in
1Password (personal `Private` vault, category API Credential, title `AIOStreams (dagger)`):
`AIOSTREAMS_SECRET_KEY`, `AIOSTREAMS_AUTH`, and the nzbdav WebDAV/API creds — with notes on
what uses them and that the local copy lives in `docker-dagger/.env` on dagger.

The exported `~/Downloads/aiostreams-config-*.json` holds live secrets in plaintext —
**not committed**; delete or secure it after the structure is extracted.

## Files changed

- `docker-compose.yml` — remove `usenetstreamer`; add `aiostreams-lan` + `aiostreams-ts`
  (shared env anchor).
- `tailscale/apply-serve` — swap `usenetstreamer` → `aiostreams` (port `8084`) in `SERVICES`.
- `.env.example` — remove `USENETSTREAMER_SECRET`; add the `AIOSTREAMS_*` / `PROWLARR_API_KEY`
  keys above with comments.
- `CLAUDE.md` — update service list, LAN-exposed-services and env-var sections to describe
  the two `aiostreams` instances instead of `usenetstreamer`.

## Cleanup / manual follow-ups (outside repo)

- Tailscale admin: delete the orphaned `svc:usenetstreamer` VIP service object + its ACL
  entries.
- Stremio: uninstall the old hosted AIOStreams + usenetstreamer addons; install
  `aiostreams-lan` on the TV (`http://192.168.1.200:8083`) and `aiostreams-ts` on the phone
  (`https://aiostreams.royal-shark.ts.net`).
- Remove `${CONFIG_DIR}/usenetstreamer` on dagger once confirmed unneeded.

## Verification

1. `docker compose up -d aiostreams-lan aiostreams-ts` — both start (valid `SECRET_KEY`).
2. From a container, `prowlarr:9696` and `nzbdav:3000` are reachable.
3. Config UI loads at `http://192.168.1.200:8083` and `https://aiostreams.royal-shark.ts.net`;
   login via `AIOSTREAMS_AUTH`.
4. Import config into both; nzbdav + Prowlarr active; a search returns usenet **and**
   torrent/debrid results.
5. Play a usenet result and confirm: the stream URL is a `…/api/v1/proxy/…` URL on the
   instance's own `BASE_URL` (no WebDAV creds in it), and `nzbdav` logs show it opened the
   NNTP connection (provider sees dagger only).
6. On the phone, disconnect from home Wi-Fi (mobile data + Tailscale) and confirm a usenet
   stream still plays — proving egress stays on dagger from a foreign client IP.
```
