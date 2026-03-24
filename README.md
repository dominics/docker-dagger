Docker compose files, for
# dagger


## Installation

- Create a system user
- Copy `.env.example` to `.env` and modify
  - Particularly, replace the `PUID` and `PGID` variables with the UID and GID of the user
- Change to the `ssl/` directory, and run `./generate`, which will create `minica.pem` and other files
- Set up docker-nvidia for Plex

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
