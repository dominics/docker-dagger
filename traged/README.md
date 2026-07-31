# TrageD on dagger

The game server for `traged.commo.nz`. The static client is served from sabre
(`ansible-config/roles/traged_site`); this host runs the authoritative world and
answers `ws.traged.commo.nz`.

It lives here because a 30Hz world wants room - twelve cores and 31 GiB against
sabre's one and 956 MiB - and because dagger is in Auckland, so it is also the
nearest host to the players.

## Files

| File | What it is |
|---|---|
| `install-deploy-account` | Idempotent installer, run by `deploy-dagger` |
| `traged-ci-deploy` | The forced SSH command; accepts only `deploy` |
| `traged-deploy.service` | The oneshot that does the privileged step |
| `traged-pull` | What the unit runs: pull, then restart only `td-server` |
| `set-registry-token` | Installs the GHCR pull credential |
| `traged-ci.pub` | Public half of the CI deploy key (not secret) |

The container itself is a service in the top-level `docker-compose.yml`, with
Traefik labels routing `ws.traged.commo.nz` to it.

## About the privilege

Being straight about this, because it is easy to describe misleadingly:
**the unit runs as root.**

The deploy account has no privilege of its own. It cannot reach the docker
socket, and sudoers grants it exactly one command with no arguments:
`systemctl start --wait traged-deploy.service`. What that unit does is fixed,
root-owned, and touches only `td-server`.

Running the unit as a docker-group user instead would not be an improvement.
Anyone who can talk to the docker socket can `docker run -v /:/host` and become
root, so docker-group membership *is* root with a friendlier label - and it would
be standing privilege rather than privilege bounded to one command.

So what is bounded here is the command, not the user. A leaked CI key can pull an
image and restart one service. It cannot get a shell, forward a port, or run
anything else.

If that is ever not enough, the real options are a docker socket proxy (narrows
to specific API endpoints, but still lets it restart any container on the host)
or rootless Podman for this one service (genuinely unprivileged, but breaks
Traefik's docker-provider discovery and would need a published port plus a
file-provider route).

## The registry token

The image is private, so the pull needs a credential. It lives in
`/etc/traged/docker/config.json`, root-only, in a directory of its own rather
than `/root/.docker` - scoped to this deploy, and not picked up by anything else
running as root. `traged-deploy.service` points `DOCKER_CONFIG` at it.

**It will expire.** That is the one predictable way this breaks months from now,
so `traged-pull` detects an auth failure and prints the rotation steps itself.
To rotate deliberately:

1. Mint a classic PAT with **only** `read:packages`:
   <https://github.com/settings/tokens/new?scopes=read:packages>
2. `cd /home/media && printf '%s' '<TOKEN>' | sudo ./traged/set-registry-token`
   (reads stdin, so the token never lands in shell history)
3. Update 1Password: Private vault, "TrageD GHCR pull token (dagger)", including
   the new expiry in the notes.
4. `gh workflow run deploy` from a `td` checkout.

A failed pull leaves the running container alone, so an expired token means
"deploys stop working", never "the game goes down".

## Related

- `td/docs/2026-08-01-traged-web-deploy-design.md` - why any of this is shaped so
- `ansible-config/roles/traged_site` - the client half, on sabre
