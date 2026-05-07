Docker compose files, for
# dagger


## Installation

- Create a system user
- Copy `.env.example` to `.env` and modify
  - Particularly, replace the `PUID` and `PGID` variables with the UID and GID of the user
- Set up docker-nvidia for Plex
- Apply the [Tailscale Services](#tailscale-services) configuration (see below)

## Tailscale Services

Internal HTTPS for the media web UIs is provided by [Tailscale Services][tss]. The single
`tailscaled` already running on dagger advertises one service per app, each with an
auto-issued Let's Encrypt cert on `<svc>.<tailnet>.ts.net`.

[tss]: https://tailscale.com/kb/1552/tailscale-services

URLs (tailnet-only):

| Service | URL                              |
|---------|----------------------------------|
| Sonarr  | `https://sonarr.<tailnet>.ts.net`  |
| Radarr  | `https://radarr.<tailnet>.ts.net`  |
| Lidarr  | `https://lidarr.<tailnet>.ts.net`  |
| SABnzbd | `https://sabnzbd.<tailnet>.ts.net` |
| Plex    | `https://plex.<tailnet>.ts.net` (LAN clients keep using `http://192.168.1.200:32400`) |
| Traefik | `https://traefik.<tailnet>.ts.net` |

One-time tailnet policy edits (admin console):

- Add `tag:media-host` under `tagOwners`.
- Add `autoApprovers.services` mapping each `svc:*` to `["tag:media-host"]`.
- Grant `autogroup:member` access to all six `svc:*` on `tcp:443`.

In the admin console, predefine the six services on the **Services** page
(`sonarr`, `radarr`, `lidarr`, `sabnzbd`, `plex`, `traefik`), each listening
on `tcp:443`. Then on dagger:

```bash
sudo tailscale up --advertise-tags=tag:media-host \
  --advertise-routes=0.0.0.0/0,::/0 --stateful-filtering=false   # follow auth URL
/home/media/tailscale/apply-serve                                 # configure all services
```

`apply-serve` uses imperative `tailscale serve --https=443` for each service
(the declarative `set-config` JSON format doesn't enable TLS termination as
of 1.96.x). Re-run it whenever ports or service names change.

## Remote sudo for Claude Code (pam_ssh_agent_auth)

To allow Claude Code to run `sudo` over SSH without a password prompt, dagger uses `pam_ssh_agent_auth`. This authenticates sudo via the forwarded SSH agent (1Password), so sudo access is gated on SSH key possession.

Setup script: `~/bin/setup-pam-ssh-sudo.sh`

To configure a new host:
```bash
ssh-add -L > /tmp/sudo_authorized_keys
scp /tmp/sudo_authorized_keys HOST:/tmp/
scp ~/bin/setup-pam-ssh-sudo.sh HOST:/tmp/
ssh -t HOST 'bash /tmp/setup-pam-ssh-sudo.sh'
```

The script installs `libpam-ssh-agent-auth`, configures PAM and sudoers to accept SSH agent authentication, and copies the agent's public keys to `/etc/security/authorized_keys`.
