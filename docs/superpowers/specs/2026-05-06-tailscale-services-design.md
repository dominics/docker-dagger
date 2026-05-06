# Tailscale Services for media server HTTPS

**Date:** 2026-05-06
**Status:** Approved
**Repo:** `docker-dagger` (deployed to host `dagger` / `media.varspool.com`)

## Problem

The media server services (Sonarr, Radarr, Lidarr, SABnzbd, Plex, Traefik dashboard) are
fronted by Traefik using a self-signed wildcard cert generated with `minica` for
`*.media.varspool.com`. Browsers flag every visit with a cert warning. We want browser-trusted
HTTPS without exposing these services publicly.

## Solution

Use [Tailscale Services](https://tailscale.com/kb/1552/tailscale-services). Each service gets
its own MagicDNS name (`<svc>.<tailnet>.ts.net`) with an automatically provisioned Let's
Encrypt cert. A single tailscaled (the one already running on dagger) advertises all of them.

Traefik is removed from the path for these services; they're served directly by `tailscale
serve`. Traefik stays for the public `statio.nz` routing only.

## Constraints

- **Plex must remain reachable on the LAN (192.168.1.0/24) without Tailscale.** TVs, Sonos,
  guest phones with the Plex app discover the local server on its LAN IP. This use case is
  served today by Plex running in `network_mode: host` on port 32400 — that doesn't change.
- *arr and SAB admin UIs are used only by the operator on devices that run Tailscale. They
  do not need LAN-without-Tailscale access. (If this assumption changes, add a LAN bind for
  the specific service later.)
- The host `dagger` already runs `tailscaled`. We use that single daemon — no sidecar
  containers, no extra tailnet devices.
- Tailscale Services are currently in beta. Acceptable risk for home use.

## Components

### 1. Tailnet policy file changes (admin console, one-time)

Add a tag for the host, auto-approvers so it can advertise the services without manual
approval, and grants so the operator can reach them.

```jsonc
{
  "tagOwners": {
    "tag:media-host": ["autogroup:admin"]
    // ...existing tagOwners preserved
  },

  "autoApprovers": {
    "services": {
      "svc:sonarr":   ["tag:media-host"],
      "svc:radarr":   ["tag:media-host"],
      "svc:lidarr":   ["tag:media-host"],
      "svc:sabnzbd":  ["tag:media-host"],
      "svc:plex":     ["tag:media-host"],
      "svc:traefik":  ["tag:media-host"]
    }
  },

  "grants": [
    // ...existing grants preserved
    {
      "src": ["autogroup:member"],
      "dst": [
        "svc:sonarr", "svc:radarr", "svc:lidarr",
        "svc:sabnzbd", "svc:plex", "svc:traefik"
      ],
      "ip": ["tcp:443"]
    }
  ]
}
```

Then on dagger:

```bash
sudo tailscale set --advertise-tags=tag:media-host
```

(Use `tailscale set` to add the tag without disturbing other `tailscale up` flags.)

### 2. Tailscale serve declarative config

Checked into the repo at `tailscale/serve.json` so it's reproducible and version-controlled.

```json
{
  "version": "0.0.1",
  "services": {
    "svc:sonarr":  { "endpoints": { "tcp:443": "http://127.0.0.1:8989"  } },
    "svc:radarr":  { "endpoints": { "tcp:443": "http://127.0.0.1:7878"  } },
    "svc:lidarr":  { "endpoints": { "tcp:443": "http://127.0.0.1:8686"  } },
    "svc:sabnzbd": { "endpoints": { "tcp:443": "http://127.0.0.1:8081"  } },
    "svc:plex":    { "endpoints": { "tcp:443": "http://127.0.0.1:32400" } },
    "svc:traefik": { "endpoints": { "tcp:443": "http://127.0.0.1:8080"  } }
  }
}
```

Applied on dagger via:

```bash
sudo tailscale serve set --config /home/media/tailscale/serve.json
```

(Verify the exact verb — `set --config` vs `--set-path` — against the installed `tailscale`
version during implementation. Newer versions use `tailscale serve set --config`.)

### 3. docker-compose.yml changes

For sonarr, radarr, lidarr, sabnzbd:

- Change `100.87.71.30:PORT:PORT` → `127.0.0.1:PORT:PORT`. Tailscale Serve only needs
  loopback. Removing the tailnet IP bind avoids exposing the raw HTTP port on the tailnet
  alongside the new HTTPS service.
- Remove all `traefik.http.routers.<svc>.*` and `traefik.http.services.<svc>.*` labels.
  Remove `traefik.enable: "true"` from these services.

For Plex:

- **No change.** Keep `network_mode: host` so LAN clients keep working.
- The `svc:plex` endpoint points at `127.0.0.1:32400` which works because Plex listens on
  all host interfaces.

For Traefik:

- Add a `127.0.0.1:8080:8080` bind for the dashboard (or expose the API on an existing
  internal port). Remove the `traefik.http.routers.dashboard.*` labels — dashboard is now
  served via `svc:traefik` instead of through Traefik itself.
- Keep the public `:80`/`:443` ports for the `statio.nz` routing.

### 4. dynamic.yml changes

- Remove the `plex` router and `plex` service entries.
- Keep `cdn-station` / `cdn-station-www` (public statio.nz routes).
- Keep the `tailscale-only` middleware (still useful if anything else gets added to Traefik
  later).
- Remove the `tls.certificates` block referencing the minica wildcard cert.

### 5. Filesystem cleanup

- The `ssl/` directory and minica wildcard cert can be deleted. No service in the new
  design uses `*.media.varspool.com` certs.
- Update README if it references the old hostnames or the `ssl/generate` workflow.

## Data flow (after change)

**Tailnet client** (laptop, phone with Tailscale):
```
browser → https://sonarr.<tailnet>.ts.net
         → tailscaled on dagger (TLS termination, valid LE cert)
         → http://127.0.0.1:8989 → sonarr container
```

**LAN client without Tailscale, accessing Plex:**
```
Plex app → http://192.168.1.200:32400 → plex (host network mode)
```
Unchanged from today.

**Public client, accessing statio.nz:**
```
browser → https://statio.nz → dagger:443 → traefik → cdn-station upstream
```
Unchanged from today.

## Migration / cutover

1. Edit tailnet policy in the admin console (component 1). Verify with
   `tailscale status --json` that tag is recognized.
2. Add `tag:media-host` to dagger.
3. Land code changes (compose, dynamic.yml, new `tailscale/serve.json`) and deploy via
   `./deploy-dagger`.
4. On dagger: `sudo tailscale serve set --config /home/media/tailscale/serve.json`.
5. Approve services in the admin console **Services** page if auto-approvers didn't fire.
6. Verify each service in a browser: `https://sonarr.<tailnet>.ts.net/` etc. should show a
   trusted cert.
7. Verify Plex on LAN still works: open Plex on a TV / `http://192.168.1.200:32400` from a
   LAN-only device.
8. Once all green, delete `ssl/` directory and update bookmarks.

## Rollback

If services don't come up correctly:

- `sudo tailscale serve reset` clears the serve config; services stop being advertised.
- Revert the compose / dynamic.yml diff and redeploy. The minica cert and Traefik routes
  come back. (Until `ssl/` is deleted in step 8, this is a clean revert.)

## Out of scope

- Migrating `statio.nz` / public ACME routing to Tailscale — these are intentionally public
  and stay on Traefik with Let's Encrypt.
- LAN-without-Tailscale access to *arr/SAB UIs. If needed later, add a LAN port bind to the
  specific service; Tailscale Service advertisement is unaffected.
- Plex Remote Access / `plex.tv` discovery configuration — orthogonal to this work.

## References

- [Tailscale Services](https://tailscale.com/kb/1552/tailscale-services)
- [Set up HTTPS certificates](https://tailscale.com/docs/how-to/set-up-https-certificates)
- [tailscale serve](https://tailscale.com/kb/1242/tailscale-serve)
- [Grant examples](https://tailscale.com/kb/1458/grant-examples)
