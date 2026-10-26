# kb-auth — centralized authentication & audit service

The **central identity authority** for the knowledge product family (`math`, `chinese`,
`history`, `medical-stats`). It owns who can log in and what role they hold, and exposes a
cross-project authorization endpoint backed by the shared ABAC engine
([`kb-auth-shared`](../kb-auth-shared)).

> Internal onboarding / operations notes (account migration, volume wiring, code-vs-prod
> mapping) live in [`ONBOARDING.md`](ONBOARDING.md). This README is the public-facing overview.

## What it does

- **Central identity**: account CRUD + password hashing (SHA-512) + `htpasswd` rebuild.
  The single source of truth for login hashes and `role` (student/teacher/admin).
- **Cross-project authorize**: serves `/api/authorize` used by every knowledge site, so a
  user logs in once and is authorized per project against that project's local stage grants.
- **Audit**: writes `abac-audit.jsonl` (who was denied/permitted, which resource) — a runtime
  artifact, never committed.
- **Central mode authority**: `kb-auth` *is* the authority. It must **never** set
  `AUTHORITIES_DIR` (doing so makes all account writes return 501).

## Architecture at a glance

```
            kb-auth  (this repo, port 10097)
            ├── accounts.json   (central identity: role, hashes)
            ├── htpasswd        (login hashes, shared volume `kb-auth-shared`)
            └── /api/authorize  (cross-project decision, imports kb-auth-shared engine)
                    │
   read-only mount  │  kb-auth-shared volume
                    ▼
   math / chinese / history  ── local STATE_DIR/accounts.json (per-project stage grants)
```

Each site binds the `kb-auth-shared` volume read-only and runs the **same** `abac.lume`
engine; `kb-auth` is the only writer. The decision model (two-layer: identity central,
stage grants local) is documented in the
[`kb-auth-shared` README](../kb-auth-shared#two-layer-model-identity-is-central-stage-grants-stay-local).

## Repository layout

| Path | Purpose |
|---|---|
| `server.lume` | The service entrypoint (imports `../shared/*.lume`) |
| `docker-compose.yml` | Build + run; publishes `10097`, ro-mounts `kb-auth-shared` to consumers |
| `docker/` | `Dockerfile` + `entrypoint.sh` (random admin password on first boot if unset) |
| `tools/` | entrypoint behavior tests |
| `.env.example` | `LUME_AUTH_USER` / `LUME_AUTH_PASSWORD` — password empty = random on first boot |
| `examples/accounts.example.json` | Empty identity table to start from |

## Quick start

### Prerequisites

- The [`lume`](https://github.com/erishen/lume) toolchain (provides `bin/lume`).
  - Default lookup: `../../lume/lume/bin/lume` (sibling of this repo in the local layout).
  - Falls back to `lume` on `PATH` if that path doesn't exist (zero-config for a fresh clone
    that has lume installed).
  - Override explicitly: `make dev LUME_DIR=/abs/path/to/lume`.
  - **Note**: `make` does **not** read `.env`; `LUME_DIR` is an env var / command-line arg,
    not a `.env` key.

### Run on host (dev)

```sh
make dev          # → http://127.0.0.1:8097  (auth disabled locally for convenience)
```

### Run in Docker (prod-like)

```sh
make docker       # build + start in background → http://127.0.0.1:10097
make docker-stop  # stop container (volume kb-auth-shared is preserved)
```

### Tests

```sh
make check        # type-check server.lume + shared-engine unit tests
make test         # shared-engine unit tests + entrypoint behavior (latter needs docker)
```

## Configuration

| env | Default | Effect |
|---|---|---|
| `LUME_AUTH_USER` | `admin` | Admin username for the management UI |
| `LUME_AUTH_PASSWORD` | empty → random on first boot | Admin password; if empty, the entrypoint generates one and prints it |
| `AUTHORITIES_DIR` | **must stay unset** | Setting it would make `kb-auth` think it's a consumer and reject all writes (501) |
| `STATE_DIR` | `state` | Local writable layer (grants, htpasswd map, audit) |
| `HTPASSWD_FILE` | `auth/htpasswd` | Where the login auth file is (re)built |

> **Secrets are never committed.** `.env`, `data/`, and `logs/` are gitignored. The repo
> ships only `.env.example` and `examples/accounts.example.json` (empty). On first boot with
> an empty password, a random one is generated — there is no hardcoded credential.

## License

MIT — see [`LICENSE`](LICENSE).
