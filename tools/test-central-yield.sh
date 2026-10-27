#!/bin/sh
# knowledge/kb-auth/tools/test-central-yield.sh —— 验证各项目 entrypoint 的
# 「集中身份让位分支」，一份脚本可对任意项目复用。
#
# 要验的行为（三条，缺一不可）：
#   A 注入了可读的 HTPASSWD_FILE → 打「使用中央认证文件」；注入值原样保留；
#     本地 /app/auth/htpasswd 与 state/htpasswd.map.json 都不许被生成
#     （否则就是"在 kb-auth 改了账号，本站不生效"那个静默坑）；
#   B 注入了但文件读不到 → 必须**非零退出**，绝不静默回落到本地生成
#     （静默回落最难查：表现是"接了中央却没生效"，而不是报错）；
#   C 完全没注入 → 保持该项目改动前的旧行为（各站策略不同，本脚本只断言
#     "没有崩"，具体开不开认证由各项目自己的语义决定）。
#
# 为什么进容器测：这些 entrypoint 跑在 scratch+busybox（或 alpine）里，宿主
# macOS 的命令集与用户态都不一样，本地跑绿不算绿。
# 为什么不重建镜像就能测：把新脚本 ro 挂进去覆盖调用，只读宿主、容器 --rm。
#
# 跑法：
#   sh tools/test-central-yield.sh <site>
#   sh tools/test-central-yield.sh <site>
#   （或 make yield-test）
#
# ⚠️ 只适用于「容器内可写目录是 /app、以 uid 10001 运行」的 lume 系镜像；
#    history/medical-stats 的镜像布局不同，接入时再补各自的用例。
set -eu

PROJ="${1:-}"
KNOWLEDGE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

case "$PROJ" in
  math)    ENTRY="${ENTRY_PATH:-$KNOWLEDGE_DIR/math/docker/entrypoint.sh}";    IMAGE="${IMAGE:-math:latest}" ;;
  chinese) ENTRY="${ENTRY_PATH:-$KNOWLEDGE_DIR/chinese/docker/entrypoint.sh}"; IMAGE="${IMAGE:-chinese:latest}" ;;
  *) echo "用法: $0 <math|chinese>   （负例对照可 ENTRY_PATH=/path/旧版.sh 指向别的脚本）" >&2; exit 2 ;;
esac
[ -f "$ENTRY" ] || { echo "找不到 $ENTRY" >&2; exit 2; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "本地没有镜像 $IMAGE（先 docker images 看名字，或 IMAGE=... 指定）" >&2; exit 2; }

FAIL=0
say() { if [ "$1" = "ok" ]; then echo "   ✅ $2"; else echo "   ❌ $2"; FAIL=$((FAIL + 1)); fi; }

echo "════════ 项目=$PROJ 镜像=$IMAGE 脚本=${ENTRY#$KNOWLEDGE_DIR/}"

# ── A) 让位生效 ──────────────────────────────────────────────────────────
# 注意这里**必须带上 LUME_AUTH_PASSWORD**：不带凭据配置时，旧版（没有让位分支的
# 版本）本来就不会生成本地 htpasswd，A2/A3 两条断言恒绿、失去判别力。带上密码才是
# 接卷后的真实形态——那时旧行为会把注入的中央路径覆盖成 /app/auth/htpasswd
# （10-23 实测对照过：旧版 FINAL=/app/auth/htpasswd，新版 FINAL=/app/central-yield/htpasswd）。
outA="$(docker run --rm -v "$ENTRY:/new-entry.sh:ro" --entrypoint /bin/sh "$IMAGE" -c '
  set -eu
  mkdir -p /app/central-yield
  # \$6 必须转义：这段跑在 set -u 的 sh 里，裸 $6 会被当成未赋值的位置参数，
  # busybox/dash 直接 "parameter not set" 中止，让 A 组断言全部拿不到输出
  # （10-23 踩过：现象是 A 全红、B/C 全绿，看着像让位分支坏了，其实是夹具自己炸了）。
  printf "yieldprobe:\$6\$placeholder-not-a-real-hash\n" > /app/central-yield/htpasswd
  HTPASSWD_FILE=/app/central-yield/htpasswd LUME_AUTH_USER=admin LUME_AUTH_PASSWORD=*** \
    /bin/sh /new-entry.sh /bin/sh -c "echo PRESERVED=\$HTPASSWD_FILE" 2>&1
  echo "LOCAL_HT=$([ -f /app/auth/htpasswd ] && echo yes || echo no)"
  echo "LOCAL_MAP=$([ -f /app/state/htpasswd.map.json ] && echo yes || echo no)"
  echo "CENTRAL_INTACT=$(grep -c yieldprobe /app/central-yield/htpasswd)"
' 2>&1 || true)"

printf '%s\n' "$outA" | sed 's/^/     /'
echo "$outA" | grep -q '使用中央认证文件' && say ok "A1 打了让位日志" || say bad "A1 没打让位日志"
echo "$outA" | grep -q 'PRESERVED=/app/central-yield/htpasswd' && say ok "A2 注入值未被覆盖" || say bad "A2 注入值被覆盖/丢失"
echo "$outA" | grep -q 'LOCAL_HT=no'  && say ok "A3 未生成本地 htpasswd"  || say bad "A3 写了本地 /app/auth/htpasswd"
echo "$outA" | grep -q 'LOCAL_MAP=no' && say ok "A4 未生成本地哈希 map"   || say bad "A4 写了 state/htpasswd.map.json"
echo "$outA" | grep -Eq 'CENTRAL_INTACT=[1-9]' && say ok "A5 中央文件未被改写" || say bad "A5 中央文件被改写"

# ── B) 注入但读不到 → 必须非零退出 ────────────────────────────────────────
outB="$(docker run --rm -v "$ENTRY:/new-entry.sh:ro" --entrypoint /bin/sh "$IMAGE" -c '
  HTPASSWD_FILE=/app/definitely-not-here/htpasswd /bin/sh /new-entry.sh /bin/true > /app/b.out 2>&1
  echo "EXIT=$?"
  cat /app/b.out
' 2>&1 || true)"
printf '%s\n' "$outB" | sed 's/^/     /'
# B1 单独不构成判据：实测拿旧版（无让位分支）跑同一条，也会因为后面 papers 迁移段
# 在 set -e 下失败而退 1。真正区分新旧的是 B2 那条「拒绝启动」的明确原因，
# 所以 B1 只当兜底，别把它当回归证据。
echo "$outB" | grep -q 'EXIT=1' && say ok "B1 退出码非 0（兜底，不具判别力，见上）" || say bad "B1 退出码不是 1：$(echo "$outB" | grep EXIT || echo 无)"
echo "$outB" | grep -q '拒绝启动' && say ok "B2 有明确拒绝原因" || say bad "B2 没有说明为什么退出"

# ── C) 没注入 → 旧行为（只断言不崩）──────────────────────────────────────
outC="$(docker run --rm -v "$ENTRY:/new-entry.sh:ro" --entrypoint /bin/sh "$IMAGE" -c '
  /bin/sh /new-entry.sh /bin/sh -c "echo REACHED_END=1" 2>&1
' 2>&1 || true)"
printf '%s\n' "$outC" | tail -2 | sed 's/^/     /'
echo "$outC" | grep -q 'REACHED_END=1' && say ok "C1 未注入时仍走完启动路径" || say bad "C1 未注入时崩了"

echo "════════ 判定：失败 $FAIL 处"
[ "$FAIL" = "0" ] || exit 1
echo "════════ $PROJ 的让位分支三条行为全部符合预期"
