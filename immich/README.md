# Immich on dagger

Self-hosted photo library. Source of truth for family photos and the feed for
the idle photo screensaver (replaces the old Google Photos share/scrape loop).

Its **own** compose stack (`name: immich`), deliberately separate from the media
stack in the repo root: different upgrade cadence, different blast radius. It
lives in this repo only so it has a source of truth; `deploy-dagger` does not
touch it.

## What's here

- `docker-compose.yml` - adapted from Immich's official release compose.
  Two local changes vs upstream: server port bound to `127.0.0.1` only, and the
  storage split below. Re-derive from the release compose on every version bump.
- `.env.example` - copy to `.env` and fill `DB_PASSWORD` (the live value is in
  1Password). The real `.env` is gitignored and `chmod 600` on the host.

## Storage layout

- `UPLOAD_LOCATION=/media/storage/immich/library` - originals/thumbs/video on the
  mergerfs pool (bulk, sequential IO).
- `DB_DATA_LOCATION=/home/dominic/immich/pgdata` - Postgres on real ext4. Never
  put the DB on mergerfs/FUSE (corruption risk).

The Postgres data dir sits under `/home/dominic` while the stack itself is
checked out under `/home/media`. That split is deliberate and must not be
"tidied": the requirement is a real local disk, not a particular home directory.

## Access

The container binds `127.0.0.1:2283` only. Two ways in:

- **Tailnet** - `tailscale/apply-serve` advertises `svc:immich`, so the UI is at
  `https://immich.royal-shark.ts.net` with an auto-issued Let's Encrypt cert.
  This is how the photo frame reaches the API.
- **SSH tunnel** - when the tailnet is not an option:

```sh
ssh -L 2283:localhost:2283 dagger
# then open http://localhost:2283 on your laptop
```

No LAN or public exposure.

## Operations

Run as `dominic` (in the `media` and `docker` groups):

```sh
cd /home/media/immich
docker compose ps            # health
docker compose logs -f immich-server
```

Version bump, now that the compose file is under version control - edit here,
not on the host:

1. Fetch the matching release compose from
   `https://github.com/immich-app/immich/releases/download/vX.Y.Z/docker-compose.yml`
   and re-apply the two local changes documented at the top of
   `docker-compose.yml`.
2. Update `IMMICH_VERSION` in `.env.example` and read the release notes for
   breaking DB migrations.
3. Commit and push.
4. On dagger: `cd /home/media && sudo -EH git pull` (the checkout is owned by
   `media`, so the pull needs sudo), then update `IMMICH_VERSION` in
   `/home/media/immich/.env` to match, and:

```sh
cd /home/media/immich
docker compose pull && docker compose up -d
```

Take a `pg_dumpall` before any upgrade that carries migrations.

## Seeding from Google Takeout

`immich-go` (v0.32.0, in `~/.local/bin`) ingests Takeout with metadata intact:

```sh
immich-go upload from-google-photos \
  --server http://127.0.0.1:2283 --api-key <KEY> takeout-*.zip
```

A plain upload would lose album membership, timestamps, and JSON sidecars.

## Screensaver sync

The photo frame (`shiv`) pulls from this server. That side is configured by the
`photo_screensaver` role in `ansible-config`, not from here: it runs
`sync-screensaver-from-immich` against `https://immich.royal-shark.ts.net` and
feeds `build-screensaver-frames`.
