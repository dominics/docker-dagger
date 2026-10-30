# Garage

A single-node S3 store, at `https://garage.royal-shark.ts.net` (svc:garage, tailnet only). Its one
bucket, `sccache`, is the shared compiler cache for the Macs: each Mac's sccache reads and writes its
local disk first and this bucket second, so a build on one warms the other. Losing it costs a rebuild
and nothing else.

## Secrets

| What | Where |
|---|---|
| `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN` | `.env` on dagger; 1Password `Garage (dagger)` |
| S3 key `sccache-macs` (read/write on `sccache`) | 1Password `Garage S3 (sccache)`; on each Mac in `~/.config/sccache/garage.env` |

## One-time setup

Done 2026-10-31. The layout, bucket and key live in Garage's metadata (`$CONFIG_DIR/garage/meta`), so
none of this needs repeating on a redeploy, only on a fresh metadata directory.

```sh
g() { docker compose exec -T garage /garage "$@"; }
g status                                   # note the node ID
g layout assign -z dagger -c 200G <node-id>
g layout apply --version 1
g bucket create sccache
g key create sccache-macs
g bucket allow --read --write sccache --key sccache-macs
```

The bucket's size is bounded only by a lifecycle rule that expires objects 14 days after they are
written. Garage's CLI cannot set one, so it goes through the S3 API, with owner rights granted to the
key only for the call:

```sh
g bucket allow --owner sccache --key sccache-macs
AWS_REGION=garage aws s3api put-bucket-lifecycle-configuration \
  --endpoint-url https://garage.royal-shark.ts.net --bucket sccache \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-14d","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":14}}]}'
g bucket deny --owner sccache --key sccache-macs
```

A brand-new svc name takes up to a minute to answer its first HTTPS request while Tailscale fetches
its certificate; until then requests time out rather than fail.

## Checking on it

```sh
g bucket info sccache        # size and object count
```
