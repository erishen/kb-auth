#!/bin/sh
# admin/tools/test-entrypoint.sh —— 在一次性容器里跑 docker/entrypoint.sh 的副本
#
# 为什么要专门测它：kb-auth 的 entrypoint 决定「中央卷里到底有哪些账号能登录」，
# 而它跑在 scratch+busybox 里（没有独立的 wc/head/tr，只能 /bin/busybox xx）。
# 宿主 macOS 既没装 busybox、用户态也是 BSD 的，两边行为都不一样，只能进容器测。
#
# 历史教训（这个脚本就是为它而写）：首启只 seed 了 admin 一个哈希，accounts.json
# 里其余账号被静默挡在 htpasswd 外；项目真把这个卷当 HTPASSWD_FILE 挂上去时，表现
# 成「账号明明在、全部登录失败」，排查成本极高。entrypoint 现在会把差值打出来。
#
# 跑法：make -C admin test-entrypoint
#
# 只读宿主、只写自己的临时目录：SHARED/WORKDIR 被 sed 改到容器内 /tmp 下，
# 尾行 exec 换成 echo，所以既不碰 kb-auth-shared 真卷也不起服务。
set -eu

ADMIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$ADMIN_DIR/docker/entrypoint.sh"
SEED="$ADMIN_DIR/data/accounts.json"

# 基座镜像 tag 从 Dockerfile 的 FROM 行解析，不在这里再写死一份——否则升级
# admin/docker/Dockerfile 的 FROM 后，本测试还会拿旧镜像跑得绿（假绿）。
# 与 ../math/Makefile 的 BASE_IMAGE 同一套做法。
BASE_IMAGE="$(sed -n 's/^FROM \(lume:[^[:space:]]*\).*/\1/p' "$ADMIN_DIR/docker/Dockerfile" | head -1)"
if [ -z "$BASE_IMAGE" ]; then
  echo "docker/Dockerfile 里没有 'FROM lume:*' 行，无法确定该用哪个基座测 entrypoint" >&2
  exit 1
fi
IMAGE="${IMAGE:-$BASE_IMAGE}"

# mktemp 建的私有临时目录（不在任何用户路径下），退出时回收自己造的东西。
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kb-admin-entrypoint.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

sed -e 's|^SHARED=/app/kb-shared$|SHARED=/app/kbtest|' \
    -e 's|^WORKDIR=/app/admin$|WORKDIR=/app/seedtest|' \
    -e 's|^exec "\$@"$|echo "[test] STATE_DIR=$STATE_DIR HTPASSWD_FILE=${HTPASSWD_FILE:-<未设>}"|' \
    "$ENTRY" > "$TMP/entrypoint.sh"
cp "$SEED" "$TMP/accounts.json"

grep -q 'SHARED=/app/kbtest' "$TMP/entrypoint.sh" || {
  echo "改写 SHARED 失败：entrypoint 里那行常量格式变了，请同步本脚本的 sed" >&2
  exit 1
}

# 在一个干净的容器里跑一段 shell（用例自己负责准备 /app/kbtest 的前置状态）。
# 落点用 /app 而不是 /tmp：基础镜像 USER=10001（非 root），scratch 镜像里的 /tmp
# 不是 world-writable，写不进去；/app 才是 Dockerfile 里 chown 给 10001 的可写目录。
#
# 判定网：entrypoint 只往 stderr 打文字，结果不对也不会非零退出，所以断言必须靠
# grep —— 与 shared/Makefile 里 grep FAIL 同一套理由。$3 = 必须出现的固定串，
# $4 = 必须不出现的固定串，$5 = 1 表示给随机口令打码。
# 不写断言的用例直接计一次失败：只打印不判定的 target 是假绿。
FAILED_CASES=0
run_case() {
  echo "════════ 用例：$1"
  out="$(docker run --rm -e PW="$PW" -v "$TMP:/t:ro" "$IMAGE" /bin/sh -c "
    set -eu
    mkdir -p /app/seedtest/data
    cp /t/entrypoint.sh /app/e.sh
    cp /t/accounts.json /app/seedtest/data/accounts.json
    $2
  " 2>&1 || true)"
  [ "${5:-0}" = "1" ] && out="$(printf '%s\n' "$out" | sed 's/已生成随机 admin 密码: [^（]*/已生成随机 admin 密码: <已打码>/')"
  printf '%s\n' "$out" | sed 's/^/   /'

  rc=0
  if [ -z "$3" ] && [ -z "$4" ]; then
    echo "   ✗ 本用例没写断言（只打印不判定＝假绿）"; rc=1
  fi
  if [ -n "$3" ] && ! printf '%s\n' "$out" | grep -qF "$3"; then
    echo "   ✗ 断言失败：期望出现「$3」但没有"; rc=1
  fi
  if [ -n "$4" ] && printf '%s\n' "$out" | grep -qF "$4"; then
    echo "   ✗ 断言失败：不该出现「$4」但出现了"; rc=1
  fi
  [ "$rc" = "0" ] || FAILED_CASES=$((FAILED_CASES + 1))
}

# 测试用的假密码：容器 --rm、写的都是容器内临时目录，不落任何真凭据。
# 走 -e 传进容器再在容器里展开，避免把密码形态的字面量写进用例命令行。
PW='testpw-not-a-real-secret'

# 断言用的固定串（可被环境覆盖——不是为了配置方便，是为了能做**负例对照**：
#   WARN='不可能出现的串' make entrypoint-test   必须变红，
# 否则无法证明判定网真的在看（曾经这个 target 只打印不判定，是假绿）。
WARN="${WARN:-accounts.json 有 5 个账号，htpasswd 只有 1 个可登录}"
OKMSG="${OKMSG:-账号表与 htpasswd 一致（5 个账号可登录）}"

# 用例 1：首启只给 admin 一个密码 → 应报「5 个账号 vs 1 个可登录」。
#         第二次启动走「map 已存在」分支：差值告警要再次出现（幂等），但
#         **不能**再生成随机密码——这条同时证明了「改 compose 默认值改不动
#         已存在的口令」这个机制（也就是本轮没敢用 compose 去动线上口令的原因）。
run_case "首启 seed 只有 admin（复现历史坑）+ 二次启动幂等" "
  LUME_AUTH_USER=admin LUME_AUTH_PASSWORD=\"\$PW\" /bin/sh /app/e.sh /bin/true
  echo '   -- 二次启动（卷已存在，走 map 分支）--'
  LUME_AUTH_PASSWORD=\"\$PW\" /bin/sh /app/e.sh /bin/true
" "$WARN" '未设置 → 已生成随机'

# 用例 2：map 与 accounts 数量一致 → 应报「一致」，且不该再出差值告警
run_case "map 与 accounts 一致" "
  mkdir -p /app/kbtest
  printf %s '{\"admin\":\"x\",\"xiao\":\"x\",\"zhong\":\"x\",\"gao\":\"x\",\"jiao\":\"x\"}' > /app/kbtest/htpasswd.map.json
  cp /app/seedtest/data/accounts.json /app/kbtest/accounts.json
  LUME_AUTH_PASSWORD=\"\$PW\" /bin/sh /app/e.sh /bin/true
" "$OKMSG" "$WARN"

# 用例 3：不配密码 → 自动生成随机 admin 密码（值在本输出里打码，别落进日志），
#         此时 map 仍只有 admin → 差值告警也该出现（与用例 1 同因）
run_case "未设 LUME_AUTH_PASSWORD（随机密码路径）" "
  /bin/sh /app/e.sh /bin/true
" "$WARN" "" 1

echo "════════ 判定：失败 $FAILED_CASES 处"
[ "$FAILED_CASES" = "0" ] || exit 1
echo "════════ 三个用例断言全部通过"
