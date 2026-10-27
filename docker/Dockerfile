# syntax=docker/dockerfile:1
# ============================================================================
# knowledge/kb-auth —— 集中 ABAC 管理服务（kb-auth）
#
# 一个 lume 单容器：server.lume（集中账号 CRUD + 审计 + 跨项目 /api/authorize）
# + 共享引擎（shared/*）。
#
# lume 运行时直接取 GitHub Release 的官方静态二进制，**不再依赖私有基础镜像**
# （旧写法 `FROM lume:v0.8.1` 那个镜像从未公开分发，外部 clone 下来必然构建失败）：
#   https://github.com/erishen/lume/releases/download/<LUME_VERSION>/lume-linux-<arch>-static.tar.gz
# 升级运行时改构建参数即可：LUME_VERSION=v0.11.0 docker compose build
#
# 最终镜像基于 alpine 而不是 scratch：本服务的 entrypoint.sh 要用 busybox 的
# cryptpw/grep/sed/tr/wc 做 htpasswd 生成与账号一致性诊断，且需要 /bin/sh。
# alpine 自带 busybox 与 sh，比从 scratch 自建 shell 环境可靠得多。
#
# build context = `..`（= work/knowledge/，shared/ 与 kb-auth/ 同级），
# 即 docker-compose.yml 里的 context: .. + dockerfile: kb-auth/docker/Dockerfile。
# 注意：context 是**上一级目录**，所以 COPY 路径以 kb-auth/ 与 shared/ 开头。
#
# 容器内布局（WORKDIR /app/admin，uid 10001）：
#   /app/admin/server.lume   DSL 入口（端口 8097 写在 server{} 里）
#   /app/admin/data/         resources.json + 账号种子
#   /app/shared/             共享 ABAC 引擎（abac/admin/json.lume）
#   import "../shared/abac.lume" 从 /app/admin/ 解析 → /app/shared/（与 host 一致）
#
# 集中身份（named volume kb-auth-shared → /app/kb-shared，rw）：
#   accounts.json / htpasswd.map.json / htpasswd / abac-audit.jsonl
#   本服务独占写；各项目 ro 挂载同一卷 → AUTHORITIES_DIR=/app/kb-shared +
#   HTPASSWD_FILE=/app/kb-shared/htpasswd，agent-httpd 按 mtime 热重载，
#   本服务改账号 → 各项目免重启全局生效。
#
# 端口：容器内 8097；宿主映射 10097（>10000，见 docker-compose.yml）。
# ============================================================================

# ---- 阶段 1：取 lume 运行时 ----------------------------------------------
FROM alpine:3.20 AS lume-fetch

ARG LUME_VERSION=v0.11.0
ARG TARGETARCH

RUN apk add --no-cache ca-certificates curl

# 下载静态版并校验 sha256；校验失败直接让构建失败。
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64|"") ARCH=x64 ;; \
      arm64)    ARCH=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    BASE="https://github.com/erishen/lume/releases/download/${LUME_VERSION}"; \
    ASSET="lume-linux-${ARCH}-static"; \
    mkdir -p /out; \
    curl -fsSL --retry 3 -o "/out/${ASSET}.tar.gz" "${BASE}/${ASSET}.tar.gz"; \
    curl -fsSL --retry 3 -o "/out/${ASSET}.sha256" "${BASE}/${ASSET}.sha256"; \
    cd /out; \
    sha256sum -c "${ASSET}.sha256"; \
    tar -xzf "${ASSET}.tar.gz"; \
    install -m 0755 "${ASSET}/bin/lume" /out/lume; \
    /out/lume --version

# ---- 阶段 2：运行环境 ----------------------------------------------------
FROM alpine:3.20

# 运行时依赖：
#   busybox（alpine 自带）—— entrypoint 的 cryptpw/grep/sed/tr/wc
#   tzdata —— 审计时间戳按本地时区
#   ca-certificates —— 出站 TLS
RUN apk add --no-cache tzdata ca-certificates \
 && addgroup -g 10001 -S app \
 && adduser -u 10001 -S -G app app

# 静态 lume 运行时
COPY --from=lume-fetch /out/lume /app/bin/lume

WORKDIR /app
# 集中身份卷挂载点（/app/kb-shared，rw）+ 数据与认证目录。
RUN mkdir -p /app/kb-shared /app/admin/data /app/auth \
 && chown -R 10001:10001 /app

# 布局：server.lume → /app/admin/，shared → /app/shared/
# context 是上一级目录，故以 kb-auth/ 与 shared/ 开头。
COPY --chown=10001:10001 kb-auth/server.lume   /app/admin/server.lume
# 种子数据从 examples/ 取（examples/ 入版本库；data/ 被 .gitignore 排除，
# 因为它是真实账号库所在目录）。构建时按种子文件名落位，保持容器内布局不变。
COPY --chown=10001:10001 kb-auth/examples/accounts.seed.json  /app/admin/data/accounts.json
COPY --chown=10001:10001 kb-auth/examples/resources.seed.json /app/admin/data/resources.json
COPY --chown=10001:10001 shared/               /app/shared/

# entrypoint：从 /app/kb-shared/accounts.json 生成 htpasswd + 导 HTPASSWD_FILE/STATE_DIR
COPY --chmod=0755 --chown=10001:10001 kb-auth/docker/entrypoint.sh /app/entrypoint.sh

USER 10001:10001

WORKDIR /app/admin
EXPOSE 8097

# alpine 里有 busybox nc，可以真的探端口（不是只看进程活着）
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD nc -z 127.0.0.1 8097 || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
# 二进制在 /app/bin/lume；WORKDIR 已切到 /app/admin，故用绝对路径；
# server.lume 相对 CWD /app/admin 解析 → /app/admin/server.lume。
CMD ["/app/bin/lume", "server.lume"]
