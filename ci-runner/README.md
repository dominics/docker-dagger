# GitHub Actions runners for TrageD

Self-hosted runners for `dominics/td`, so its CI stops spending hosted
minutes. A compose project of its own (`docker compose` from this directory),
not part of the top-level stack, because `deploy-dagger` takes that stack down
and up and a runner caught mid-job would fail it.

| Service | Runner name | Label | Docker socket |
|---|---|---|---|
| `td-runner-1` | `dagger-td-1` | `td` | no |
| `td-runner-2` | `dagger-td-2` | `td` | no |
| `td-deploy` | `dagger-td-deploy` | `dagger-deploy` | yes |

The `td` runners take the test jobs, including pull requests and with them any
dependency's build script, so they get no docker socket. Only td's deploy job
asks for `dagger-deploy`, and it only runs for commits already on `main`. The
socket is root on this host; that is the trade being made for building the
server image here.

sword runs a fourth runner, `sword-td`, natively in its WSL Ubuntu as the
systemd unit `actions.runner.dominics-td.sword-td.service` (installed under
`/opt/actions-runner`, user `runner`). `sword-runner.sh <registration token>`
installs it, run as root inside WSL (`wsl -d Ubuntu -u root -- bash
/mnt/c/Users/Dominic/sword-runner.sh <token>`). WSL needs systemd on
(`/etc/wsl.conf`: `[boot] systemd=true`) and its idle shutdown off
(`%USERPROFILE%\.wslconfig`: `instanceIdleTimeout=-1` under `[general]`,
`vmIdleTimeout=-1` under `[wsl2]`, which also caps it at `memory=10GB`), or the
distro stops a minute after the last shell leaves and the runner with it.
Nothing starts WSL after sword reboots until `sword-wsl-boot-task.ps1` has been
run once from an elevated PowerShell on sword: it registers a startup task that
boots the distro. The job uses `actions/setup-node`, so sword's own Node 18 is
never the one the tests run under.

## Storage

Everything a runner keeps lives under `/media/hd3/ci/<runner name>/`:

- `runner/` - its registration, so a restart does not need a new token
- `work/` - checkouts
- `home/` - root's home: rustup, cargo, the installed tools, and the target
  directories the workflows keep in `$HOME/target/<job>`

The root disk is too small for Rust target directories, so they are on hd3, a
spinning disk. A warm build there still beats a hosted runner starting cold.
Nothing prunes the target directories yet; if hd3 gets tight, deleting
`home/target/` is safe and only costs one cold build.

## CPU

`cpu_shares: 256` against Docker's default 1024: when td-server, Plex or
anything else wants the CPU, a build gets a quarter of a share; when nothing
else does, it gets all twelve cores.

## Setting up, or registering again

```sh
cd /home/media/ci-runner
docker compose build
RUNNER_TOKEN=$(gh api -X POST repos/dominics/td/actions/runners/registration-token --jq .token) \
  docker compose up -d
```

The token is only read on the first start, while `runner/` is empty, and
expires within the hour. To register a runner again, stop it, empty its
`runner/` directory, and start it with a fresh token.

## Updating

The runner updates itself in place when GitHub asks it to, but the image pins
the version it starts from. Bump the tag and digest in `Dockerfile` the same
way as the top-level `docker-compose.yml` (see its header), then
`docker compose build && docker compose up -d`.
