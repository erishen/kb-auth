# syntax=docker/dockerfile:1
# ============================================================================
# knowledge/admin —— 集中 ABAC 管理服务（kb-auth）
#
# 一个 lume 单容器：server.lume（集中账号 CRUD + 审计 + 跨项目 /api/authorize）
# + 共享引擎（shared/*）。基于 lume:v0.8.1（scratch+busybox，math 同款）。
#
# build context = work/knowledge/（docker-compose.yml 里 context 设这里，
# dockerfile=admin/docker/Dockerfile），故 shared/ 与 admin/ 都在 context 内。
#
# 容器内布局（WORKDIR /app/admin，uid 10001）：
#   /app/admin/server.lume   DSL 入口（端口 8097 写在 server{} 里）
#   /app/admin/data/         resources.json + 账号种子
#   /app/shared/             共享 ABAC 引擎（abac/admin/json.lume）
#   import "../shared/abac.lume" 从 /app/admin/ 解析 → /app/shared/（与 host 一致）
#
# 集中身份（named volume kb-auth-shared → /app/kb-shared，rw；建在 /app 下而非
# 根目录，因基础镜像 USER=10001，根目录 mkdir 无权限，/app 已 chown 10001 可写）：
#   accounts.json / htpasswd.map.json / htpasswd / abac-audit.jsonl
#   本服务独占写；各项目 ro 挂载同一卷 → AUTHORITIES_DIR=/app/kb-shared +
#   HTPASSWD_FILE=/app/kb-shared/htpasswd，agent-httpd 按 mtime 热重载，
#   本服务改账号 → 各项目免重启全局生效。
#
# 端口：容器内 8097；宿主映射 10097（>10000，见 docker-compose.yml）。
# ============================================================================

FROM lume:v0.8.1

WORKDIR /app
# 集中身份卷挂载点（/app/kb-shared，rw；/app 已 chown 10001，RUN mkdir 子目录可行）。
RUN mkdir -p /app/kb-shared /app/admin/data /app/auth

# 布局：server.lume → /app/admin/，shared → /app/shared/
COPY --chown=10001:10001 admin/server.lume   /app/admin/server.lume
COPY --chown=10001:10001 admin/data/         /app/admin/data/
COPY --chown=10001:10001 shared/             /app/shared/
# 本服务 entrypoint：从 /app/kb-shared/accounts.json 生成 htpasswd + 导 HTPASSWD_FILE/STATE_DIR
COPY --chown=10001:10001 admin/docker/entrypoint.sh /app/entrypoint.sh
RUN chmod 755 /app/entrypoint.sh

WORKDIR /app/admin
EXPOSE 8097
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD /bin/busybox nc -z 127.0.0.1 8097 || exit 1

# 二进制在基础镜像 /app/bin/lume（WORKDIR 已切到 /app/admin，故用绝对路径；
# server.lume 相对 CWD /app/admin 解析 → /app/admin/server.lume）。
CMD ["/app/bin/lume", "server.lume"]
