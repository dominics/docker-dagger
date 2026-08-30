# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker Compose stack for a home media server running on a host called "dagger" (`media.varspool.com`). Services include Sonarr, Radarr, Lidarr, Prowlarr, SABnzbd, nzbdav (usenet-as-WebDAV for streaming), AIOStreams (self-hosted Stremio aggregator over nzbdav + Prowlarr, LAN + tailnet instances), Plex and Jellyfin (both with NVIDIA GPU transcoding, sharing one library), and Traefik as a reverse proxy.

## Architecture

- **Tailscale Services** provide HTTPS for the media web UIs. The host's existing
  `tailscaled` advertises `svc:sonarr`, `svc:radarr`, `svc:lidarr`, `svc:prowlarr`, `svc:sabnzbd`,
  `svc:nzbdav`, `svc:aiostreams`, `svc:plex`, `svc:jellyfin`, `svc:traefik` per
  `tailscale/apply-serve`.
  Each gets an auto-issued Let's Encrypt cert on `<svc>.<tailnet>.ts.net`. Containers bind
  to `127.0.0.1:PORT`; Tailscale Serve terminates TLS on the tailnet side.
- **AIOStreams (two instances)**: AIOStreams bakes a single `BASE_URL` into every stream
  URL (no request-host derivation), so the LAN TV and the roaming phone each get their own
  instance. `aiostreams-lan` serves the TV at `https://aiostreams.media.varspool.com` —
  trusted HTTPS via Traefik (browser-based Stremio blocks a plain-HTTP addon as mixed
  content). It has no host port publish; Traefik reaches it over the compose network at
  `http://aiostreams-lan:3000`. The phone uses `aiostreams-ts` over the tailnet
  (`svc:aiostreams`, loopback 8084). Both proxy usenet streams through AIOStreams' built-in
  proxy (nzbdav holds the NNTP creds on dagger), so the usenet account is only ever used
  from the home IP. `nzbdav` (3000) stays loopback-only. No public exposure.
- **Plex** runs in `host` network mode with `nvidia` runtime, so it's reachable on the LAN
  at `192.168.1.200:32400` *without* Tailscale (TVs, Sonos, guest phones). `svc:plex` is
  additive on top for tailnet HTTPS.
- **Jellyfin** (`192.168.1.200:8096`) runs the same way and over the same library, for the
  same reason: the LG TV's webOS client has no tailnet. Host mode additionally lets
  Jellyfin's 7359/udp discovery broadcast reach clients, so the TV app finds the server
  without being handed an IP. Its `/transcode` is `$STORAGE_DIR/transcode/jellyfin`, kept
  apart from Plex's. GPU is the same 1080 Ti: Pascal has NVENC/NVDEC for H.264 and HEVC
  (including 10-bit decode) but **no AV1 in either direction**, so AV1 must stay unticked
  in Jellyfin's hardware acceleration settings or those files fall back to CPU transcode.
  Deleting media from the Jellyfin UI needs both the read/write library mounts (as
  configured) and the per-user "Allow media deletion from" toggle, which is off by default.
- **Traefik v3.6** carries the public `statio.nz` route (Let's Encrypt via ACME HTTP-01,
  resolver `letsencrypt`) and one internal route, `aiostreams.media.varspool.com`
  (Let's Encrypt via DNS-01/Route53, resolver `letsencrypt-dns` — the name resolves to a
  private IP so HTTP-01 can't validate it; gated to LAN/tailnet by `tailscale-only`). The
  DNS-01 resolver authenticates with the `AWS_*` env vars (least-priv IAM user
  `traefik-acme-route53`, see `terraform/varspool/iam.tf`). Two entry points: `:80`
  redirects to HTTPS, `:443` serves it. The dashboard is bound to `127.0.0.1:8080` and
  exposed via `svc:traefik`.
- **dynamic.yml**: File-based Traefik provider for the `statio.nz` / `www.statio.nz` routes
  and the internal `aiostreams.media.varspool.com` route. The `tailscale-only` IP allowlist
  middleware (Tailscale CGNAT `100.64.0.0/10` + LAN `192.168.1.0/24`) gates the AIOStreams
  route and any future internal Traefik routes.
- **Config persistence**: Service configs stored at `$CONFIG_DIR` (default `/etc/media-server`), media at `$STORAGE_DIR` (default `/media/storage`)

## Key Files

- `docker-compose.yml` — All service definitions
- `traefik.yml` — Traefik static configuration (entry points, providers, ACME)
- `dynamic.yml` — Traefik dynamic configuration (statio.nz routes, middlewares)
- `tailscale/apply-serve` — Configures Tailscale Services for all media apps. Run on
  dagger to apply. Uses imperative `tailscale serve --https=443` per service because
  the declarative `set-config` JSON format does not enable TLS termination as of
  tailscale 1.96.x.
- The tailnet ACL (policy file) is OpenTofu-managed in the `tf-config` repo at
  `tf-config/tailscale/policy/policy.hujson` (`tailscale_acl` resource). Edit it
  and `just apply tailscale/policy` there instead of the Tailscale admin console;
  its `README.md` has the OAuth-client credential and bootstrap/apply runbook.
  When onboarding a new `svc:*`, prereq #2 in `apply-serve` points here.
- `.env` / `.env.example` — Environment variables (`PUID`, `PGID`, `TZ`, `LOCAL_IP`)
- `deploy-dagger` — Deployment script: pulls code, syncs config, pulls images, restarts containers
- `config/home-assistant/` — Home Assistant configuration (currently disabled in compose)
- `immich/` - a **separate** compose stack (`name: immich`), not part of the media
  stack and not deployed by `deploy-dagger`. Runs from `/home/media/immich` as
  `dominic`. See `immich/README.md` before changing it.

## Common Commands

```bash
# Deploy to dagger (runs on dagger itself)
./deploy-dagger

# Or manually:
docker compose pull              # Pull latest images
docker compose up -d             # Start/restart all services
docker compose logs -f           # Follow logs
docker compose ps                # Check running services
docker compose down              # Stop all services

# Apply Tailscale Services config (run on dagger after deploy)
/home/media/tailscale/apply-serve
sudo tailscale serve status --json | jq
```

## Environment Variables

All required in `.env` (see `.env.example`):
- `PUID` / `PGID` — UID/GID for LinuxServer.io containers
- `TZ` — Timezone (e.g. `Pacific/Auckland`)
- `LOCAL_IP` — LAN IP of dagger; the name `*.media.varspool.com` resolves here on the LAN
- `AIOSTREAMS_SECRET_KEY` / `AIOSTREAMS_AUTH` / `AIOSTREAMS_AUTH_ADMINS` /
  `AIOSTREAMS_PROXY_CREDENTIALS` / `PROWLARR_API_KEY` — AIOStreams encryption key, UI login,
  admin usernames, built-in-proxy creds, and the Prowlarr API key. See `.env.example`.
- **nzbdav creds are NOT in `.env`** — they're configured per-config in each AIOStreams
  instance's dashboard UI (url=`http://nzbdav:3000`, apiKey, WebDAV user/pass, Auth Token).
  AIOStreams v2.30.2 has a bug where env-injected service creds (`*_SERVICE_CREDENTIALS`) are
  stored encrypted and never decrypted at resolve → "Invalid URL" / 21KB placeholder on usenet
  streams; typed-in-UI creds decrypt fine. The home-IP guarantee is independent (FORCE_PROXY
  routes everything through the built-in proxy). UI config lives in
  `$CONFIG_DIR/aiostreams-*/db.sqlite` (per instance) — re-do it on a fresh deploy. nzbdav's
  own usenet providers (giganews, astraweb, xsnews, vipernews) live in nzbdav's `/config` DB.
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` / `AWS_HOSTED_ZONE_ID` —
  Route53 DNS-01 creds for Traefik's `letsencrypt-dns` resolver (internal HTTPS for
  `aiostreams.media.varspool.com`). Least-priv IAM user `traefik-acme-route53`
  (`terraform/varspool/iam.tf`). `.env` is `640 media:media` on dagger.
- `CONFIG_DIR` / `STORAGE_DIR` — Set in `deploy-dagger` to `/etc/media-server` and `/media/storage`

## Conventions

- Services use [LinuxServer.io](https://linuxserver.io) images where available
- Internal HTTPS for the media UIs goes through Tailscale Services (`tailscale/serve.json`).
  Traefik handles the public `statio.nz` route plus the one internal browser-facing route
  (`aiostreams.media.varspool.com`) that needs a publicly-trusted cert without a tailnet client
- Containers bind to `127.0.0.1` (not the tailnet IP) — Tailscale Serve proxies from the
  tailnet to loopback
- Plex and Jellyfin are the exceptions: `network_mode: host` so LAN clients without
  Tailscale keep working
- Commented-out services (nzbget, home-assistant) are kept for reference
