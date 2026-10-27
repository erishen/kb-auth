# kb-auth — 集中身份认证与审计服务

> **这是一套三仓库组合**
>
> | 仓库 | 职责 |
> |---|---|
> | [`kb-auth-shared`](https://github.com/erishen/kb-auth-shared) | ABAC **决策引擎**（纯库：无进程、无网络）。被其余两者 import。 |
> | [`kb-auth`](https://github.com/erishen/kb-auth) | **中央身份权威** —— 账号 CRUD、密码哈希、`htpasswd`。唯一的写入方。 |
> | [`kb-abac`](https://github.com/erishen/kb-abac) | **消费方站点** —— 在进程内运行引擎，并展示它如何决策。想先看效果从这里开始。 |
>
> 三者关系：站点用共享引擎在**本地**完成授权决策（每次请求零网络），只有*身份*是集中的。
> 站点从 `kb-auth-shared` 取引擎，可选地以只读方式挂载 `kb-auth` 的卷来获取账号。

一组内容站点的**中央身份权威**。
它掌握"谁能登录"以及"是什么角色"，并基于共享 ABAC 引擎
（[`kb-auth-shared`](https://github.com/erishen/kb-auth-shared)）对外提供跨项目鉴权端点。

> 迁移与运维的具体步骤由运维侧掌握，不在本仓。本 README 是面向公开仓库的概览。

## 它做什么

- **中央身份**：账号 CRUD + 密码哈希（SHA-512）+ `htpasswd` 重建。登录哈希与 `role`
  （student/teacher/admin）的唯一真相源。
- **跨项目鉴权**：提供各知识站点共用的 `/api/authorize`，用户一次登录，按各项目的
  本地学段授权分别裁决。
- **审计**：写 `abac-audit.jsonl`（谁被放行/拒绝、哪个资源）——运行时产物，从不入库。
- **中央模式权威**：`kb-auth` *就是*权威，必须**永远不**设 `AUTHORITIES_DIR`（设了会让
  所有账号写操作返回 501）。

## 架构一览

```
            kb-auth  (本仓库, 端口 10097)
            ├── accounts.json   (中央身份: role, 哈希)
            ├── htpasswd        (登录哈希, 共享卷 kb-auth-shared)
            └── /api/authorize  (跨项目裁决, import kb-auth-shared 引擎)
                    │
   只读挂载  │  kb-auth-shared 卷
                    ▼
   内容站点  ── 本地 STATE_DIR/accounts.json (各项目学段授权)
```

每个站点把 `kb-auth-shared` 卷只读挂入，并运行**同一份** `abac.lume` 引擎；`kb-auth`
是唯一写入方。决策模型（两层：身份归中央、学段授权留本地）详见
[`kb-auth-shared` README](https://github.com/erishen/kb-auth-shared#两层模型身份归中央学段授权留本地)。

## 仓库结构

| 路径 | 用途 |
|---|---|
| `server.lume` | 服务入口（import `../shared/*.lume`） |
| `docker-compose.yml` | 构建 + 运行；发布 `10097`，向消费方只读挂载 `kb-auth-shared` |
| `docker/` | `Dockerfile` + `entrypoint.sh`（口令未设时首启随机生成） |
| `tools/` | entrypoint 行为测试 |
| `.env.example` | `LUME_AUTH_USER` / `LUME_AUTH_PASSWORD` —— 口令留空 = 首启随机 |
| `examples/accounts.example.json` | 起始用的空身份表 |

## 快速开始

### 1. 把引擎克隆到同级目录

`server.lume` 写的是 `import "../shared/abac.lume"`，所以引擎必须与本仓**同级**，
而不是塞在仓内：

```sh
mkdir kb && cd kb
git clone https://github.com/erishen/kb-auth.git
git clone https://github.com/erishen/kb-auth-shared.git shared   # ← 目录名必须是 shared
```

得到：

```
kb/
├── kb-auth/     ← 本仓
└── shared/      ← kb-auth-shared，克隆为 shared
```

> 跳过这步，`make check` / `make docker` 会报 `../shared: No such file or directory`。
> `kb-auth-shared` 刻意不做成本仓的 submodule：同一份引擎被多个仓共用，各自锁自己的版本。

### 2. 前置条件

- [`lume`](https://github.com/erishen/lume) 运行时（单个静态二进制）。装官方 release：

  ```sh
  VER=v0.11.0
  curl -fsSL -o /tmp/lume.tar.gz \
    "https://github.com/erishen/lume/releases/download/$VER/lume-linux-x64.tar.gz"
  tar -xzf /tmp/lume.tar.gz && sudo install -m755 lume-linux-x64/bin/lume /usr/local/bin/lume
  lume --version
  ```

  查找顺序：`LUME=/abs/path` → `PATH` 上的 `lume` → `../../lume/lume/bin/lume`（本地布局）。
  都找不到时构建会直接停下并给出提示，而不是抛一个看不懂的报错。

- Docker 只有 `make docker` 和 `make entrypoint-test` 需要；`make check` 与 `make dev` 都不需要。

### 前置条件

- [`lume`](https://github.com/erishen/lume) 工具链（提供 `bin/lume`）。
  - 默认查找：`../../lume/lume/bin/lume`（本地布局里与本仓同级）。
  - 若该路径不存在，回退到 `PATH` 上的 `lume`（对新克隆且已装 lume 的场景零配置）。
  - 显式覆盖：`make dev LUME_DIR=/abs/path/to/lume`。
  - **注意**：`make` **不**读取 `.env`；`LUME_DIR` 是环境变量 / 命令行参数，不是 `.env` 键。

### 宿主运行（开发）

```sh
make dev          # → http://127.0.0.1:8097  (本地为方便起见关闭认证)
```

### 容器运行（类生产）

```sh
make docker       # 构建 + 后台启动 → http://127.0.0.1:10097
make docker-stop  # 停容器（卷 kb-auth-shared 保留）
```

### 测试

```sh
make check        # type-check server.lume + 共享引擎单测
make test         # 共享引擎单测 + entrypoint 行为测（后者要 docker）
```

## 配置

| env | 缺省 | 作用 |
|---|---|---|
| `LUME_AUTH_USER` | `admin` | 管理端用户名 |
| `LUME_AUTH_PASSWORD` | 空 → 首启随机 | 管理端口令；为空时 entrypoint 生成并打印 |
| `AUTHORITIES_DIR` | **必须保持未设** | 设了会让 kb-auth 误以为自己是消费方，拒绝所有写操作（501） |
| `STATE_DIR` | `state` | 本地可写层（授权、htpasswd map、审计） |
| `HTPASSWD_FILE` | `auth/htpasswd` | 登录认证文件的（重建）落点 |

> **密钥从不入库**。`data/` 与 `logs/` 均被 gitignore。仓库只随附
> `.env.example` 与 `examples/accounts.example.json`（空）。首启口令为空时随机生成——
> 没有任何硬编码凭据。

## 许可证

MIT —— 见 [`LICENSE`](LICENSE)。
