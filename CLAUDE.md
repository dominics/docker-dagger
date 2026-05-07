# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker Compose stack for a home media server running on a host called "dagger" (`media.varspool.com`). Services include Sonarr, Radarr, SABnzbd, qBittorrent, Plex (with NVIDIA GPU transcoding), and Traefik as a reverse proxy.

## Architecture

- **Tailscale Services** provide HTTPS for the media web UIs. The host's existing
  `tailscaled` advertises `svc:sonarr`, `svc:radarr`, `svc:lidarr`, `svc:sabnzbd`,
  `svc:plex`, `svc:traefik` per `tailscale/serve.json`. Each gets an auto-issued Let's
  Encrypt cert on `<svc>.<tailnet>.ts.net`. Containers bind to `127.0.0.1:PORT`; Tailscale
  Serve terminates TLS on the tailnet side.
- **Plex** runs in `host` network mode with `nvidia` runtime, so it's reachable on the LAN
  at `192.168.1.200:32400` *without* Tailscale (TVs, Sonos, guest phones). `svc:plex` is
  additive on top for tailnet HTTPS.
- **Traefik v3.6** is retained only for the public `statio.nz` route (Let's Encrypt via
  ACME HTTP challenge). Two entry points: `:80` redirects to HTTPS, `:443` serves it. The
  dashboard is bound to `127.0.0.1:8080` and exposed via `svc:traefik`.
- **dynamic.yml**: File-based Traefik provider for the `statio.nz` / `www.statio.nz`
  routes. The `tailscale-only` IP allowlist middleware (Tailscale CGNAT `100.64.0.0/10` +
  LAN `192.168.1.0/24`) is retained for any future internal Traefik routes.
- **Config persistence**: Service configs stored at `$CONFIG_DIR` (default `/etc/media-server`), media at `$STORAGE_DIR` (default `/media/storage`)

## Key Files

- `docker-compose.yml` — All service definitions
- `traefik.yml` — Traefik static configuration (entry points, providers, ACME)
- `dynamic.yml` — Traefik dynamic configuration (statio.nz routes, middlewares)
- `tailscale/apply-serve` — Configures Tailscale Services for all media apps. Run on
  dagger to apply. Uses imperative `tailscale serve --https=443` per service because
  the declarative `set-config` JSON format does not enable TLS termination as of
  tailscale 1.96.x.
- `.env` / `.env.example` — Environment variables (`PUID`, `PGID`, `TZ`, `LOCAL_IP`)
- `deploy-dagger` — Deployment script: pulls code, syncs config, pulls images, restarts containers
- `config/home-assistant/` — Home Assistant configuration (currently disabled in compose)

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
- `CONFIG_DIR` / `STORAGE_DIR` — Set in `deploy-dagger` to `/etc/media-server` and `/media/storage`

## Conventions

- Services use [LinuxServer.io](https://linuxserver.io) images where available
- Internal HTTPS goes through Tailscale Services (`tailscale/serve.json`); Traefik is only
  for the public `statio.nz` route
- Containers bind to `127.0.0.1` (not the tailnet IP) — Tailscale Serve proxies from the
  tailnet to loopback
- Plex is the exception: `network_mode: host` so LAN clients without Tailscale keep working
- Commented-out services (nzbget, home-assistant) are kept for reference
