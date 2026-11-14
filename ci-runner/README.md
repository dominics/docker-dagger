# GitHub Actions runners on dagger

Self-hosted runners for `dominics/td` and for the private repositories below,
so their CI stops spending hosted minutes. A compose project of its own (`docker compose` from this directory),
not part of the top-level stack, because `deploy-dagger` takes that stack down
and up and a runner caught mid-job would fail it.

| Service | Repository | Runner name | Label | Token variable | Memory | Docker socket |
|---|---|---|---|---|---|---|
| `td-runner-1` | `dominics/td` | `dagger-td-1` | `td` | `RUNNER_TOKEN` | 12g | no |
| `td-runner-2` | `dominics/td` | `dagger-td-2` | `td` | `RUNNER_TOKEN` | 12g | no |
| `td-deploy` | `dominics/td` | `dagger-td-deploy` | `dagger-deploy` | `RUNNER_TOKEN` | 12g | yes |
| `anki-runner` | `dominics/anki` | `dagger-anki` | `anki` | `RUNNER_TOKEN_ANKI` | 4g | no |
| `tf-config-runner` | `dominics/tf-config` | `dagger-tf-config` | `tf-config` | `RUNNER_TOKEN_TF_CONFIG` | 4g | no |
| `home-runner` | `dominics/home` | `dagger-home` | `home` | `RUNNER_TOKEN_HOME` | 4g | no |
| `screamour-runner` | `dominics/screamour` | `dagger-screamour` | `screamour` | `RUNNER_TOKEN_SCREAMOUR` | 6g | no |
| `watched-history-runner` | `dominics/watched-history` | `dagger-watched-history` | `watched-history` | `RUNNER_TOKEN_WATCHED_HISTORY` | 4g | no |

The `td` runners take the test jobs, including pull requests and with them any
dependency's build script, so they get no docker socket. Only td's deploy job
asks for `dagger-deploy`, and it only runs for commits already on `main`. The
socket is root on this host; that is the trade being made for building the
server image here.

The other five are one runner per private repository, labelled with the
repository's name, so a workflow asks for `runs-on: [self-hosted, linux,
<repo>]`. A personal account has no account-wide runners, which is why each
repository has a runner and a registration token of its own. They run pull
requests too, Renovate's among them, so none has the docker socket.
`dominics/docker-dagger` has no runner here: it is public, where a self-hosted
runner would let a fork's pull request run code on dagger, and hosted runners
cost nothing for a public repository.

All of them share one image. Nothing in it is specific to a toolchain beyond
td's build dependencies: workflows bring their own with the setup actions
(`actions/setup-node`, `pnpm/action-setup`, `astral-sh/setup-uv`,
`opentofu/setup-opentofu`). Jobs run as root, so a step that needs system
packages, such as `playwright install --with-deps`, can install them with apt;
they last until the container is next recreated.

sword runs a fourth td runner, `sword-td`, natively in its WSL Ubuntu as the
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

The td runners share one token:

```sh
cd /home/media/ci-runner
docker compose build
RUNNER_TOKEN=$(gh api -X POST repos/dominics/td/actions/runners/registration-token --jq .token) \
  docker compose up -d td-runner-1 td-runner-2 td-deploy
```

A registration token belongs to one repository, so each of the others takes
its own, in the variable the table names. Name the services, so that the
runners already up are left alone:

```sh
RUNNER_TOKEN_ANKI=$(gh api -X POST repos/dominics/anki/actions/runners/registration-token --jq .token) \
  docker compose up -d anki-runner
```

The token is only read on the first start, while `runner/` is empty, and
expires within the hour. To register a runner again, stop it, empty its
`runner/` directory, and start it with a fresh token.

To add a repository: copy one of the per-repository services in
`docker-compose.yml`, change the repository, runner name, label, token
variable and the three paths, add its row to the table above, and start it as
above. Docker creates the directories under `/media/hd3/ci/` itself.

## Updating

The runner updates itself in place when GitHub asks it to, but the image pins
the version it starts from. Bump the tag and digest in `Dockerfile` the same
way as the top-level `docker-compose.yml` (see its header), then
`docker compose build && docker compose up -d`.
