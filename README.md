# kb-auth — centralized authentication & audit service

> **Part of a three-repo setup**
>
> | Repo | Role |
> |---|---|
> | [`kb-auth-shared`](https://github.com/erishen/kb-auth-shared) | The ABAC **decision engine** (a library — no process, no network). Imported by everyone else. |
> | [`kb-auth`](https://github.com/erishen/kb-auth) | The **central identity authority** — account CRUD, password hashing, `htpasswd`. The only writer. |
> | [`kb-abac`](https://github.com/erishen/kb-abac) | A **consumer site** — runs the engine in-process and shows how it decides. Start here if you just want to see it work. |
>
> How they fit together: sites make authorization decisions **locally** (zero network per
> request) using the shared engine; only *identity* is centralized. A site reads the engine
> from `kb-auth-shared`, and optionally read-mounts the `kb-auth` volume to pick up accounts.

The **central identity authority** for a family of content sites. It owns who can log in
and what role they hold, and exposes a cross-project authorization endpoint backed by the
shared ABAC engine ([`kb-auth-shared`](https://github.com/erishen/kb-auth-shared)).

## What it does

- **Central identity**: account CRUD + password hashing (SHA-512) + `htpasswd` rebuild.
  The single source of truth for login hashes and `role` (student/teacher/admin).
- **Cross-project authorize**: serves `/api/authorize` used by every consumer site, so a
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
   content sites  ── local STATE_DIR/accounts.json (per-project stage grants)
```

Each site binds the `kb-auth-shared` volume read-only and runs the **same** `abac.lume`
engine; `kb-auth` is the only writer. The decision model (two-layer: identity central,
stage grants local) is documented in the
[`kb-auth-shared` README](https://github.com/erishen/kb-auth-shared#two-layer-model-identity-is-central-stage-grants-stay-local).

## Repository layout

| Path | Purpose |
|---|---|
| `server.lume` | The service entrypoint (imports `../shared/*.lume`) |
| `docker-compose.yml` | Build + run; publishes `10097`, ro-mounts `kb-auth-shared` to consumers |
| `docker/` | `Dockerfile` + `entrypoint.sh` (random admin password on first boot if unset) |
| `tools/` | entrypoint behavior tests (container-based) |
| `.env.example` | `LUME_AUTH_USER` / `LUME_AUTH_PASSWORD` — password empty = random on first boot |
| `examples/accounts.seed.json` | Demo identity seed copied into the image (neutral names) |
| `examples/resources.seed.json` | Demo cross-project resource registry |

## Quick start

### 1. Clone with the engine alongside

`server.lume` does `import "../shared/abac.lume"`, so the engine must sit **next to** this
repo — not inside it:

```sh
mkdir kb && cd kb
git clone https://github.com/erishen/kb-auth.git
git clone https://github.com/erishen/kb-auth-shared.git shared   # ← directory must be named `shared`
```

Resulting layout (the name matters; the import path is literal):

```
kb/
├── kb-auth/     ← this repo
└── shared/      ← kb-auth-shared, cloned as `shared`
```

> `make check` / `make docker` fail with `../shared: No such file or directory` if you skip
> this step. `kb-auth-shared` is not a git submodule of this repo by design: the same engine
> is shared by several repos, and each pins its own version.

### 2. Prerequisites

- The [`lume`](https://github.com/erishen/lume) toolchain — a single static binary.
  Install the official release build:
  ```sh
  VER=v0.11.0
  curl -fsSL -o /tmp/lume.tar.gz \
    "https://github.com/erishen/lume/releases/download/$VER/lume-linux-x64.tar.gz"
  tar -xzf /tmp/lume.tar.gz && sudo install -m755 lume-linux-x64/bin/lume /usr/local/bin/lume
  lume --version
  ```
  Lookup order: `LUME=/abs/path` → `lume` on `PATH` → `../../lume/lume/bin/lume` (local
  monorepo layout). If none resolves, the build stops with a hint instead of a cryptic error.
  `make` does **not** read `.env`; pass `LUME=` as an env var or command-line argument.

- Docker is required only for `make docker` and `make entrypoint-test`. Both `make check`
  and `make dev` are docker-free.

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
