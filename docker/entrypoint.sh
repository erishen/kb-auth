#!/bin/sh
# knowledge/kb-auth 集中服务 entrypoint（scratch+busybox）
#
# 职责：
#   1. 确保集中身份卷 /app/kb-shared 可写（named volume 首次挂载继承 10001）。
#   2. 首次从镜像种子 data/accounts.json 拷贝 /app/kb-shared/accounts.json（幂等）。
#   3. 从 /app/kb-shared/htpasswd.map.json（权威，管理端 CRUD 维护）生成
#      /app/kb-shared/htpasswd（user:$6$hash 每行）；各项目的 HTPASSWD_FILE 指向它，
#      agent-httpd 按 mtime 热重载 → 改账号免重启生效。
#   4. export STATE_DIR（审计/账号写目标）+ HTPASSWD_FILE（本服务自身 Basic Auth）。
#
# 可用外部命令（scratch+busybox）：sh/mkdir/printf/cat/cp/grep/sed/busybox。
# 哈希：busybox cryptpw SHA-512($6$)。
set -eu

SHARED=/app/kb-shared
WORKDIR=/app/admin
STATE_DIR="$SHARED"
HTPASSWD="$SHARED/htpasswd"
MAP_FILE="$SHARED/htpasswd.map.json"
ACCOUNTS="$SHARED/accounts.json"

mkdir -p "$SHARED" "$WORKDIR"

# 1) 种子 accounts.json：镜像 data/ → 卷（卷里没有才拷，幂等）
if [ ! -f "$SHARED/accounts.json" ]; then
  cp "$WORKDIR/data/accounts.json" "$SHARED/accounts.json" 2>/dev/null \
    || printf '{"accounts":{}}\n' > "$SHARED/accounts.json"
fi

# 1b) 种子 htpasswd.map.json（首启一次性）：从 LUME_AUTH_USER/LUME_AUTH_PASSWORD
#     生成 admin 哈希；两者都没设 → 随机密码并打印（首启见 docker logs）。
#     格式 {"user":"$6$hash",...}；管理端 CRUD 后续经 shared/admin.lume 维护它。
if [ ! -f "$MAP_FILE" ]; then
  U="${LUME_AUTH_USER:-admin}"
  P="${LUME_AUTH_PASSWORD:-}"
  if [ -z "$P" ]; then
    P="$(/bin/busybox tr -dc 'a-f0-9' < /dev/urandom | /bin/busybox head -c 36)"
    echo "[kb-auth] LUME_AUTH_PASSWORD 未设置 → 已生成随机 admin 密码: $P（自定义请设 LUME_AUTH_PASSWORD 后删卷重来：docker volume rm kb-auth-shared）" >&2
  fi
  H="$(printf '%s' "$P" | /bin/busybox cryptpw -m sha512)"
  printf '{"%s":"%s"}' "$U" "$H" > "$MAP_FILE"
  chmod 600 "$MAP_FILE"
fi

# 2) htpasswd：优先用 map（管理端在线维护的哈希），没有则关闭本服务自身认证
#    ⚠️ 解析容忍 key/value 间的空白（"[...]" : "[...]"）：迁移脚本若用 python
#    json.dump 默认格式（", "/": "）写出，无空白版 grep 会一个都匹配不到、
#    htpasswd 被清空（2026-10-23 实测）。busybox grep/sed 支持 [[:space:]]。
if [ -f "$MAP_FILE" ]; then
  grep -o '"[^"]*"[[:space:]]*:[[:space:]]*"[^"]*"' "$MAP_FILE" \
    | sed 's/"\([^"]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1:\2/' > "$HTPASSWD" 2>/dev/null || : > "$HTPASSWD"
  if [ -s "$HTPASSWD" ]; then
    chmod 600 "$HTPASSWD"
    export HTPASSWD_FILE="$HTPASSWD"
  fi
fi

# 3) 审计/账号写目标 = 共享卷
export STATE_DIR

# 4) 本服务自身认证：卷里 htpasswd 非空则开启（admin 账号在其中）；否则关闭
#    （便于本机无账号时联调 /api/health）。
if [ -n "${HTPASSWD_FILE:-}" ] && [ -s "$HTPASSWD_FILE" ]; then
  :
else
  unset HTPASSWD_FILE 2>/dev/null || true
fi

# 5) 探活端点放行：/api/health 只回 {ok,service,engine,when}，不含账号数据。
#    以前这行只写在注释里（"由 server 默认放行健康端点"）而实际没设，导致
#    无凭据 curl /api/health 拿到的其实是 401 —— 容器健康检查用的是 busybox
#    nc（只看端口），所以 healthy 会掩盖这件事，外部监控脚本则会当红。
#    ⚠️ 这是本服务唯一放开的公开路径，别顺手加。
export AUTH_PUBLIC_PATHS="/api/health"

# 6) 「有账号但登不进来」诊断：首启只 seed 了 admin 一个哈希（见 1b），其余
#    账号在 accounts.json 里存在、却进不了 htpasswd；项目一旦把这卷当
#    HTPASSWD_FILE 挂上去，就会出现「账号明明在、全部登录失败」，且
#    shared/admin.lume 的 rebuild_auth 会持续按「无哈希=不发登录凭据」处理它们。
#    与其等接完卷才发现，不如每次启动把差值打到日志里。
if [ -f "$ACCOUNTS" ] && [ -s "$HTPASSWD" ]; then
  n_acc="$( { /bin/busybox grep -o '"role"' "$ACCOUNTS" || :; } | /bin/busybox wc -l | /bin/busybox sed 's/ //g')"
  n_pw="$( { /bin/busybox grep -c ':' "$HTPASSWD" || :; } )"
  if [ -n "$n_acc" ] && [ -n "$n_pw" ] && [ "$n_acc" != "$n_pw" ]; then
    echo "[kb-auth] ⚠️ accounts.json 有 $n_acc 个账号，htpasswd 只有 $n_pw 个可登录（差额＝没有 password_hash）。" >&2
    echo "[kb-auth]    htpasswd 里现有：$( { /bin/busybox sed 's/:.*//' "$HTPASSWD" || :; } | /bin/busybox tr '\n' ' ')" >&2
    echo "[kb-auth]    接入项目前请先补齐哈希（POST /api/accounts 逐个建，或按 ONBOARDING 的迁移步骤从项目本地 htpasswd.map.json 合并），否则挂卷后那些账号会全部登不进去。" >&2
  else
    echo "[kb-auth] 账号表与 htpasswd 一致（$n_acc 个账号可登录）" >&2
  fi
fi

exec "$@"
