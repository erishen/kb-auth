#!/bin/sh
# admin/tools/migrate-central-auth.sh —— 把各项目本地的账号哈希并进中央卷，
# 让 kb-auth 的 htpasswd 成为全族可用的唯一凭据源。
#
# 为什么必须先做这一步（10-23 实测）：中央卷 kb-auth-shared 里 accounts.json 有
# 5 个账号，但 htpasswd.map.json 只有 admin 一个 → htpasswd 只有 1 行。真正的哈希底
# 散在各项目自己的 state 卷里（math 5 个、chinese 1 个）。此时按 ONBOARDING 步骤 2
# 把中央卷当 HTPASSWD_FILE 挂给项目，math 的 xiao/zhong/gao/jiao 会当场全部登不进去。
#
# ⚠️ 两个会静默坑你的机制，脚本都已按此设计：
#   1) admin/docker/entrypoint.sh 的 seed 分支只在 map 缺失时生效 —— 所以改 compose
#      里的 LUME_AUTH_PASSWORD 对已存在的卷**完全无效**，换口令只能走 API（--rotate）。
#   2) shared/admin.lume 的 rebuild_auth() 以 accounts.json 的账号集为准回写 map ——
#      如果 map 里出现 accounts.json 没有的名字，下次任何一次 CRUD 就会把那个哈希丢掉。
#      所以导入前必须校验 map ⊆ accounts（预检第 3 项）。
#
# 用法：
#   sh admin/tools/migrate-central-auth.sh            # 预检 + 干跑（只读，不写卷）
#   sh admin/tools/migrate-central-auth.sh --apply    # 真正合并 + 重启 kb-auth + 复验
#   sh admin/tools/migrate-central-auth.sh --rotate   # 合并之后再走 API 换 admin 口令
#
# 只有 --apply/--rotate 会写；备份永远先落在 .backup/kb-auth-shared-<时间戳>/。
# 不做任何删除动作：历史备份留在 .backup/ 里，要清由你决定。
set -eu

MODE="${1:---dry}"
REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"   # → individular-invest/
KNOWLEDGE="$REPO_ROOT/work/knowledge"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$REPO_ROOT/.backup/kb-auth-shared-$TS"

fail() { echo "❌ $*" >&2; exit 1; }
say()  { echo "   $*"; }

case "$MODE" in
  --dry)   APPLY=0; ROTATE=0 ;;
  --apply) APPLY=1; ROTATE=0 ;;
  --rotate) APPLY=1; ROTATE=1 ;;
  *) fail "未知参数 $MODE（可用：无参/--dry、--apply、--rotate）" ;;
esac

[ "$APPLY" = "1" ] && echo "⚠️  本次会改写中央卷 kb-auth-shared 并重启 kb-auth 容器" || echo "ℹ️  干跑模式：只读预检，不写卷、不重启"

# ── 0) 前置：三个容器必须在跑，且没有任何项目已经挂了中央卷 ──────────────
echo "════ 0) 前置检查"
for c in kb-auth math-site chinese-kb; do
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  [ "$st" = "running" ] || fail "$c 状态=$st，先在跑起来再迁"
  say "$c running ✅"
done
# 已经挂卷的项目其 htpasswd 由中央控制，中途合并会立刻改变它们的可登录集合 —— 那是
# 另一套变更窗口，本脚本不负责。
for c in math-site chinese-kb medical-stats history-kb-history-1; do
  if docker inspect "$c" >/dev/null 2>&1; then
    m="$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$c" 2>/dev/null || true)"
    case " $m" in *" kb-auth-shared"*) fail "$c 已挂 kb-auth-shared 卷，别在接入状态下做迁移";; esac
  fi
done
say "无项目挂着中央卷 ✅（迁移窗口正确）"

# ── 1) 读三方现状（全部只读 docker exec）────────────────────────────────
echo "════ 1) 读取现状"
mkdir -p "$BK"
docker exec kb-auth     /bin/busybox cat /app/kb-shared/accounts.json     > "$BK/central-accounts.json"
docker exec kb-auth     /bin/busybox cat /app/kb-shared/htpasswd.map.json > "$BK/central-map.json"
docker exec kb-auth     /bin/busybox sh -c 'cat /app/kb-shared/htpasswd'  > "$BK/central-htpasswd" 2>/dev/null || : > "$BK/central-htpasswd"
docker exec math-site   /bin/busybox cat /app/state/htpasswd.map.json     > "$BK/math-map.json"     2>/dev/null || echo '{}' > "$BK/math-map.json"
docker exec chinese-kb  /bin/busybox cat /app/state/htpasswd.map.json     > "$BK/chinese-map.json"  2>/dev/null || echo '{}' > "$BK/chinese-map.json"
say "快照与备份目录：$BK"

python3 - "$BK" <<'PY'
import json, sys, pathlib
bk = pathlib.Path(sys.argv[1])
ca   = json.loads((bk/'central-accounts.json').read_text())
acc  = set(ca.get('accounts', {}))
cm   = json.loads((bk/'central-map.json').read_text())
mm   = json.loads((bk/'math-map.json').read_text())
chm  = json.loads((bk/'chinese-map.json').read_text())
print(f"   中央 accounts.json 账号 : {sorted(acc)}")
print(f"   中央 map 账号           : {sorted(cm)}   （htpasswd 行数 {len([l for l in (bk/'central-htpasswd').read_text().splitlines() if l.strip()])}）")
print(f"   math  map 账号          : {sorted(mm)}")
print(f"   chinese map 账号        : {sorted(chm)}")

incoming = dict(mm); incoming.update(chm)          # 同名以 chinese 为准（后写覆盖）
imported = {k: v for k, v in incoming.items() if k not in cm}
conflict = {k for k, v in incoming.items() if k in cm and cm[k] != v}
print(f"   将新增导入              : {sorted(imported) or '（无）'}")
if conflict:
    print(f"   ⚠️ 同名但哈希不同（中央保留不动，需人工确认哪个是活的）: {sorted(conflict)}")
    print("      —— 例如 admin：中央与 math 各有一套口令，本脚本不会覆盖中央。")

# 陷阱 2：map 里有、accounts.json 里没有的名字，下次 rebuild_auth 会被丢掉
missing = (set(cm) | set(imported)) - acc
if missing:
    print(f"   ❌ 这些账号在中央 accounts.json 里没有记录，导入后会被静默丢弃: {sorted(missing)}")
    print("      先补记录（POST /api/accounts 或往 accounts.json 加条目）再重跑。")
    sys.exit(3)
print("   ✅ map ⊆ accounts 校验通过（不会被 rebuild_auth 丢哈希）")

merged = dict(cm); merged.update(imported)
# ⚠️ 必须紧凑分隔（separators=(',', ':')）：kb-auth/entrypoint.sh 用
#    grep '"[^"]*":"[^"]*"' 解析 map，带空格（json.dump 默认 ", "/": "）会
#    一个都匹配不到 → htpasswd 被清空（2026-10-23 --apply 实测踩到）。
(bk/'merged-map.json').write_text(
    json.dumps(merged, ensure_ascii=False, separators=(',', ':')))
print(f"   合并结果（待写入）: {len(merged)} 个账号 → {sorted(merged)}")
PY

if [ "$APPLY" = "0" ]; then
  echo "════ 干跑结束（什么都没改）。确认无误后再跑：sh $0 --apply"
  exit 0
fi

# ── 2) 写入合并后的 map（uid 10001 写，避免属主错位）─────────────────────
echo "════ 2) 写入中央 map"
docker exec -i kb-auth /bin/busybox sh -c 'cat > /app/kb-shared/htpasswd.map.json' < "$BK/merged-map.json"
# 顺手把哈希回填进 accounts.json 的 password_hash —— 不回填的话，中央 accounts.json
# 里那些账号仍然"有身份无凭据"，而 math 本地那份是有哈希的（两边会漂）。
# 回填法：把 accounts.json 交给容器里的 kb-auth 自己在下次 CRUD 时同步；这里只校验
# 写进去的 map 能被读回，剩下交给第 3 步重启 + 第 4 步复验。
docker exec kb-auth /bin/busybox cat /app/kb-shared/htpasswd.map.json > "$BK/readback-map.json"
cmp -s "$BK/merged-map.json" "$BK/readback-map.json" || fail "回读不一致，中止（备份在 $BK，可把 central-map.json 拷回去还原）"
say "map 写入并回读一致 ✅"

# ── 3) 重启让 entrypoint 按 map 重建 htpasswd ────────────────────────────
echo "════ 3) 重启 kb-auth（entrypoint 由 map 生成 htpasswd）"
( cd "$KNOWLEDGE/admin" && docker compose restart kb-auth ) >/dev/null 2>&1 || docker restart kb-auth >/dev/null
i=0
while [ "$i" -lt 30 ]; do
  h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' kb-auth 2>/dev/null || echo unknown)"
  [ "$h" = "healthy" ] && break
  i=$((i + 1)); sleep 2
done
[ "$h" = "healthy" ] || fail "kb-auth 没回到 healthy（当前 $h），看 docker logs kb-auth"
say "healthy ✅（等待 $((i * 2))s）"
docker logs --since 2m kb-auth 2>&1 | grep '\[kb-auth\]' | sed 's/^/   日志: /' || true
# ⚠️ 不要把"没看到差值告警"当判据：那句告警是本轮新加进 admin/docker/entrypoint.sh 的，
#    而在线容器仍是旧镜像（--build 还没跑），旧镜像不打印它 ⇒ grep 恒为空。
#    真正的判据是上面的 htpasswd 用户数 == 5。
say "（差值告警那条日志要等你在宿主跑过 docker compose up -d --build 才会出现，勿据此判断）"

# ── 4) 复验：htpasswd 用户数、原口令仍可用 ───────────────────────────────
echo "════ 4) 复验"
users="$(docker exec kb-auth /bin/busybox sh -c 'sed "s/:.*//" /app/kb-shared/htpasswd' | tr '\n' ' ')"
say "htpasswd 现有用户: $users"
n="$(docker exec kb-auth /bin/busybox grep -c ':' /app/kb-shared/htpasswd)"
[ "$n" -ge 5 ] && say "行数 $n ≥ 5 ✅" || say "⚠️ 行数只有 $n，检查上面的用户列表"

# 用 math 现有的学生口令验一条（能过就证明"原口令不变"）：从 math 的 .env 读，不回显
if [ -f "$KNOWLEDGE/math/.env" ]; then
  acct="$(grep -E '^LUME_AUTH_ACCOUNTS=' "$KNOWLEDGE/math/.env" | tail -1 | cut -d= -f2-)"
  if [ -n "$acct" ]; then
    u="$(printf '%s' "$acct" | cut -d, -f1 | cut -d: -f1)"
    p="$(printf '%s' "$acct" | cut -d, -f1 | cut -d: -f2)"
    code="$(printf '%s:%s' "$u" "$p" | { read -r c; curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -u "$c" http://127.0.0.1:10097/api/health || echo ERR; })"
    [ "$code" = "200" ] && say "中央端口用 $u 的原口令登录 → 200 ✅（口令未被改写）" \
                        || say "⚠️ 用 $u 登录返回 $code（若 math 的 .env 不是它的现行口令，属正常，改天在容器里验）"
  fi
fi

if [ "$ROTATE" = "0" ]; then
  echo "════ 完成（未换 admin 口令）。要换口令：sh $0 --rotate —— 或现在手工做，见下面三条命令："
  cat <<'EOT'
    OLDPW=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' kb-auth | sed -n 's/^LUME_AUTH_PASSWORD=//p')
    read -rs NEWPW
    printf '{"password":"%s"}' "$NEWPW" | curl -s --noproxy '*' -u "admin:$OLDPW" -X PUT \
      -H 'content-type: application/json' --data-binary @- http://127.0.0.1:10097/api/accounts/admin
EOT
  exit 0
fi

# ── 5) 换 admin 口令（唯一有效路径：entrypoint 的 seed 分支已被跳过）──────
echo "════ 5) 换中央 admin 口令（全程不回显、不落盘）"
[ -t 0 ] || fail "--rotate 需要交互式终端（read -rs 读口令），请在你的终端里跑"
OLDPW="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' kb-auth \
         | sed -n 's/^LUME_AUTH_PASSWORD=//p')"
if [ -z "$OLDPW" ]; then
  printf '当前 admin 口令（不回显）: ' >&2; read -rs OLDPW; printf '\n' >&2
fi
printf '新 admin 口令（不回显；请立刻存进密码管理器，忘了只能删卷重来）: ' >&2
read -rs NEWPW; printf '\n' >&2
if [ "$OLDPW" = "$NEWPW" ]; then fail "新旧相同，放弃"; fi

rc="$(printf '{"password":"%s"}' "$NEWPW" \
      | curl -s --noproxy '*' -o /tmp/kb-rotate.out -w '%{http_code}' \
        -u "admin:$OLDPW" -X PUT -H 'content-type: application/json' \
        --data-binary @- http://127.0.0.1:10097/api/accounts/admin)"
say "PUT /api/accounts/admin → HTTP $rc  响应: $(cat /tmp/kb-rotate.out 2>/dev/null)"
[ "$rc" = "200" ] || fail "换口令失败（HTTP $rc）。响应体见上；401=旧口令不对，500=crypt_sha512 不可用（容器内需 glibc/busybox cryptpw）。失败时不要重试到第 3 次以上，先 docker logs kb-auth。"

printf '新口令登录: '; curl -s --noproxy '*' -o /dev/null -w '%{http_code}\n' -u "admin:$NEWPW" http://127.0.0.1:10097/api/accounts
printf '旧口令登录（应 401）: '; curl -s --noproxy '*' -o /dev/null -w '%{http_code}\n' -u "admin:$OLDPW" http://127.0.0.1:10097/api/accounts
unset OLDPW NEWPW
say "已 unset 变量，未写入任何文件。compose 里的 LUME_AUTH_PASSWORD 默认值已留空，删卷重来会走随机口令。"
