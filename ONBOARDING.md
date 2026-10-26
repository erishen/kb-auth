# 接入集中 ABAC 管理（kb-auth）

> 整体结构（六成员职责、容器与卷、架构债）见 [`../ARCHITECTURE.md`](../ARCHITECTURE.md)；
> 模型与契约（两层怎么切、`_grant` 为什么必需、导出面、四套测试模式、已知坑）见
> [`../shared/README.md`](../shared/README.md)；本篇只讲**接入步骤、进度和实况**。

`kb-auth`（宿主 `http://127.0.0.1:10097`，容器 healthy）是 `work/knowledge/*`
各 lume 知识库项目的**集中身份（账号 + 角色 + 密码哈希）与审计**服务。它独占读写
具名卷 `kb-auth-shared`；各项目**只读**挂该卷即接入身份，不改各项目代码。

> 本篇 2026-10-23 按「v2 两层模型」重写。旧版写的「挂卷 + 设 `AUTHORITIES_DIR`
> 就接入」在实测中不成立，原因见下一节；旧版还留了一句「设 env `ADMIN_AUTH_URL`
> 则项目 decide 走 /api/authorize」，**该委托从未实现过**，也已删除。

## 两层模型：中央管身份，学段授权留本地

| 层 | 内容 | 权威在哪 | 为什么 |
|---|---|---|---|
| **认证（htpasswd）** | 谁能登录 | ✅ 中央（`kb-auth-shared/htpasswd`） | 与项目无关，可完全共享。`kb-auth` 改账号 → 各项目 agent-httpd 按 **mtime 热重载**，免重启生效（已实测） |
| **身份属性（role）** | student / teacher / admin | ✅ 中央（`kb-auth-shared/accounts.json`） | 角色词表全项目一致 |
| **学段授权（stages）** | 该账号在这个项目能看哪些学段 | ⚠️ **各项目本地** `state/accounts.json` | 词表互斥：math=`primary-math/middle-school/…`，chinese=`primary/junior/senior/univ`。**一份中央表不可能同时驱动两个项目** |
| **资源表（RESOURCES）** | 有哪些资源、动作、最低角色 | 项目 `lib/access.lume` 的 `configure()`；中央 `data/resources.json` 只做跨项目查询用 | 项目本来就是按域设计的 |

实现方式：`shared/abac.lume` 的 `accounts_map()` 在 `AUTHORITIES_DIR` 非空时做两层
合并（**只读时合并，写路径不动**），并按账号合成一个内存态标记 `_grant`：

| 情形 | role 来自 | stages 来自 | `_grant` | 效果 |
|---|---|---|---|---|
| 中央有 + 本地有 | 中央 | 本地 | `local` / `all` | 正常（`stages=[]` 仍是「全库」，沿用 v1 语义） |
| 中央有 + 本地无 | 中央 | — | `central-only` | **学段资源全 DENY**，非学段资源按角色照常 |
| 中央无 + 本地有 | — | — | 丢弃 | 中央 htpasswd 里没这账号，本来登不进来；留着只会让本地残留条目意外参与决策 |

`central-only` 为什么不能用 `stages=[]` 表达：本引擎里 `stages=[]` 的语义是
**全库可见**。要是「没授权」也用空列表表示，那么中央新建任何一个学生账号，都会在
所有接了中央卷的项目里立刻变成全库可见。这是一个静默提权，所以必须显式打标。

未设 `AUTHORITIES_DIR` 时，上述合并分支全部不激活，行为与抽取前逐条一致
（由 `shared/tools/test-abac.lume` 的 85 条断言〔local 17 / central 26 /
corrupt 11，全绿〕+ `math/tools/test-access.lume` 的 20 条既有断言保证）。

## 决策仍在本地（设计边界，别改反）

- 各项目数据端点**不跨进程 HTTP**，仍用 `shared/abac.decide()` 在本地跑（零网络，
  契合单机轻量）。`kb-auth` 的 `POST /api/authorize` 只用于跨项目查询 / 聚合审计 /
  排障回放，**不是**鉴权链路的一环。
- 中央变成鉴权链路的单点，是这套设计明确不要的性质。
- `kb-auth` 自身**绝不能**设 `AUTHORITIES_DIR`：它就是身份权威，设了之后
  `shared/admin.lume` 的写保护会让所有账号 CRUD 变成 501。`admin/server.lume`
  在加载期检测到就直接打错误提示。

## 新项目接入（4 步，含前置迁移）

### 0）前置：把哈希补齐（**不做这步就别挂卷**）

中央卷当前实测：`accounts.json` 有 5 个账号（admin/xiao/zhong/gao/jiao），
但 `htpasswd.map.json` 只有 `admin` 一个 → `htpasswd` 只有 1 行。各项目的学生账号
哈希目前在**它们自己的** `state/htpasswd.map.json` 里（math 5 个、chinese 1 个）。
直接挂中央卷的结果是：math 的 xiao/zhong/gao/jiao 全部登不进去。

补齐方式（**已固化成脚本**，不要手工抄）：

```sh
sh work/knowledge/admin/tools/migrate-central-auth.sh            # 只读预检 + 干跑
sh work/knowledge/admin/tools/migrate-central-auth.sh --apply    # 合并 + 重启 + 复验
sh work/knowledge/admin/tools/migrate-central-auth.sh --rotate   # 追加：API 换 admin 口令
```

脚本做的事与为什么：

1. **预检**：三个容器在跑；**且没有任何项目已挂中央卷**（迁移中途改 htpasswd 会立刻
   影响在线站点，那是另一个变更窗口）。
2. **合并 map**：取 math/chinese 各自 `state/htpasswd.map.json` 的并集写进中央，
   **同名不覆盖中央**（admin 两边口令不同，中央那份保留）。为什么不走 API：
   API 只能设新密码，会**改动学生正在用的口令**；导入哈希才做得到无感迁移。
3. **校验 `map ⊆ accounts`**：`rebuild_auth()` 以 accounts.json 的账号集为准回写 map，
   map 里多出来的名字会在下一次任意 CRUD 时被**静默丢掉**——预检不过就直接退出。
4. **重启 kb-auth** 让 entrypoint 按 map 重建 htpasswd，然后复验：用户数、
   `docker logs` 里那句差值告警是否消失、以及用 math 现有学生口令登录中央端口仍 200。
5. 写之前把四个文件快照到 `.backup/kb-auth-shared-<时间戳>/`，回读不一致就中止；
   脚本**不做任何删除**，历史备份由你自己清理。

⚠️ 换口令只有 API 这一条路：`entrypoint.sh` 的 seed 分支只在 `htpasswd.map.json`
缺失时执行，所以对已存在的卷，改 compose 里的 `LUME_AUTH_PASSWORD` **完全无效**。

### 手工等价命令（逐步，每步带复验）

想自己敲、不走脚本的话按这个顺序。**第 3 步会改中央卷，第 0 步的备份就是回滚点。**

**第 0 步｜备份 + 看清现状**（只读）

```sh
cd ~/Workspace/CNB/individular-invest/work/knowledge
BK=/tmp/kb-backup-$(date +%Y%m%d-%H%M%S) && mkdir -p "$BK"
docker exec kb-auth    /bin/busybox cat /app/kb-shared/accounts.json     > "$BK/central-accounts.json"
docker exec kb-auth    /bin/busybox cat /app/kb-shared/htpasswd.map.json  > "$BK/central-map.json"
docker exec kb-auth    /bin/busybox cat /app/kb-shared/htpasswd           > "$BK/central-htpasswd"
docker exec math-site  /bin/busybox cat /app/state/htpasswd.map.json      > "$BK/math-map.json"
docker exec chinese-kb /bin/busybox cat /app/state/htpasswd.map.json      > "$BK/chinese-map.json"
echo "$BK" > /tmp/kb-backup-path          # 后面几步都从这儿取备份路径
printf '   中央 map: ';  python3 -c "import json;print(sorted(json.load(open('$BK/central-map.json'))))"
printf '   math  map: '; python3 -c "import json;print(sorted(json.load(open('$BK/math-map.json'))))"
printf '   chinese map: '; python3 -c "import json;print(sorted(json.load(open('$BK/chinese-map.json'))))"
```

预期：中央只有 `['admin']`、math 有 `['admin','gao','jiao','xiao','zhong']`、chinese 只有
`['admin']`。**若中央已经不止 admin，先停下查为什么**（说明这步已经有人做过）。

**第 1 步｜窗口确认**（两条都过才往下）

```sh
# a) 没有任何项目挂着中央卷 —— 挂着做迁移＝中途改在线站点的可登录集合
for c in math-site chinese-kb medical-stats history-kb-history-1; do
  printf "   %-22s 挂载卷: %s\n" "$c" "$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$c" 2>/dev/null)"
done

# b) 要导入的名字必须都在中央 accounts.json 里有记录，否则下次任意 CRUD 会把它们的哈希
#    从 map 里静默丢掉（rebuild_auth 以 accounts.json 的账号集为准回写 map）
python3 - <<'PY'
import json
bk = open('/tmp/kb-backup-path').read().strip()
acc = set(json.load(open(f'{bk}/central-accounts.json'))['accounts'])
inc = set(json.load(open(f'{bk}/math-map.json'))) | set(json.load(open(f'{bk}/chinese-map.json')))
bad = sorted((inc | set(json.load(open(f'{bk}/central-map.json')))) - acc)
print('   ❌ 缺记录，先补 accounts.json 再来:', bad) if bad else print('   ✅ map ⊆ accounts，可安全导入')
PY
```

**第 2 步｜合并 map**（同名**不**覆盖中央：`admin` 在中央与 math 是两套口令）

```sh
BK=$(cat /tmp/kb-backup-path)
python3 -c "
import json
cm = json.load(open('$BK/central-map.json'))
mm = json.load(open('$BK/math-map.json'))
ch = json.load(open('$BK/chinese-map.json'))
m = dict(cm)
for k, v in {**mm, **ch}.items():
    if k not in m: m[k] = v          # 中央已有的键一律保留，只补空缺
json.dump(m, open('$BK/merged-map.json', 'w'), ensure_ascii=False)
print('   合并后:', sorted(m))
"
```

**第 3 步｜写入卷 + 回读比对**（走 `docker exec -i` 的 stdin：这样落进去的文件属主是容器内
uid 10001，应用随后才写得动。`docker cp` 会把属主变成 root，应用就写不动了——已实测过
`docker exec -i … cat >` 这条路可用）

```sh
BK=$(cat /tmp/kb-backup-path)
docker exec -i kb-auth /bin/busybox sh -c 'cat > /app/kb-shared/htpasswd.map.json' < "$BK/merged-map.json"
docker exec kb-auth /bin/busybox cat /app/kb-shared/htpasswd.map.json > "$BK/readback.json"
cmp "$BK/merged-map.json" "$BK/readback.json" && echo "   ✅ 回读一致" || echo "   ❌ 不一致，立刻做第 6 步回滚"
```

**第 4 步｜重启让 entrypoint 按 map 重建 htpasswd**

```sh
cd ~/Workspace/CNB/individular-invest/work/knowledge/admin
docker compose restart kb-auth
sleep 8
docker inspect -f '   healthy={{.State.Health.Status}}\n' kb-auth
printf '   htpasswd 用户: '; docker exec kb-auth /bin/busybox sh -c 'sed "s/:.*//" /app/kb-shared/htpasswd' | tr '\n' ' '; echo
docker logs --since 1m kb-auth 2>&1 | grep '\[kb-auth\]' || echo "   （本步日志无输出属正常，见下）"
```

用户列表应是 5 个（`admin gao jiao xiao zhong`）。⚠️ **别把"日志里没有差值告警"当判据**：
那句告警是本轮新加进 `admin/docker/entrypoint.sh` 的，而**在线容器还是 11:27 构建的旧镜像**
（`--build` 被沙箱挡着，需要你在宿主跑），旧镜像根本不打印这行 ⇒ grep 恒为空。这里的
唯一真判据是上面那行**用户列表是否 5 个**；等你 `docker compose up -d --build` 之后，
"账号数 ≠ 可登录数"的告警才会开始发挥作用。若用户列表不足 5 个，先 `docker logs kb-auth`
查原因，别继续。

**第 5 步｜确认学生原口令仍可用**（这一步才证明"迁移是无感的"）

```sh
ACCT=$(grep -E '^LUME_AUTH_ACCOUNTS=' ../math/.env | tail -1 | cut -d= -f2- | cut -d, -f1)
printf '%s' "${ACCT%%:*}:${ACCT#*:}" | { read -r c
  curl -s --noproxy '*' -o /dev/null -w '   学生账号登录中央 → HTTP %{http_code}（期望 200）\n' \
       -u "$c" http://127.0.0.1:10097/api/health; }
```

**第 6 步｜回滚（只在出问题时做）**

```sh
BK=$(cat /tmp/kb-backup-path)
docker exec -i kb-auth /bin/busybox sh -c 'cat > /app/kb-shared/htpasswd.map.json' < "$BK/central-map.json"
docker exec -i kb-auth /bin/busybox sh -c 'cat > /app/kb-shared/accounts.json'     < "$BK/central-accounts.json"
( cd ~/Workspace/CNB/individular-invest/work/knowledge/admin && docker compose restart kb-auth )
printf '   回滚后 htpasswd 用户: '; docker exec kb-auth /bin/busybox sh -c 'sed "s/:.*//" /app/kb-shared/htpasswd' | tr '\n' ' '; echo
```

### API 换中央 admin 口令（放在迁移之后）

**为什么顺序是"先迁移、后换口令"**：换口令走的 `account_update` 内部会调
`rebuild_auth`，它把 map 里的哈希**回填进 `accounts.json` 的 `password_hash`** 并重写
三件套 —— 所以迁移完再换一次口令，正好把"4 个账号有身份无凭据"这个状态一次清掉。
（已实测卷内 `accounts.json` 顶层只有 `accounts`、没有 `"comment"` 键，所以旧镜像里
`save_accounts` 那个抹 comment 的问题在这里不影响卷。）

```sh
# ① 取当前口令：从容器 env 读，不回显、不写文件
OLDPW=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' kb-auth | sed -n 's/^LUME_AUTH_PASSWORD=//p')
[ -n "$OLDPW" ] && echo "   口令来源: 容器 env（值未打印）" || { printf '当前 admin 口令（不回显）: ' >&2; read -rs OLDPW; printf '\n' >&2; }

# ② 读新口令 —— 先存进密码管理器再执行；忘了只能重建卷（哈希不可逆）
printf '新 admin 口令（不回显）: ' >&2; read -rs NEWPW; printf '\n' >&2
if [ "$OLDPW" = "$NEWPW" ]; then echo "新旧相同，放弃"; unset OLDPW NEWPW; else

# ③ PUT：口令经 stdin 进 body，不出现在命令行参数里（ps 看不到）
printf '{"password":"%s"}' "$NEWPW" | curl -s --noproxy '*' -o /tmp/kb-rotate.out -w '   PUT → HTTP %{http_code}\n' \
  -u "admin:$OLDPW" -X PUT -H 'content-type: application/json' \
  --data-binary @- http://127.0.0.1:10097/api/accounts/admin
echo "   响应: $(cat /tmp/kb-rotate.out)   （期望 {\"ok\":true}）"

# ④ 复验（紧接着 ③，变量还在）
curl -s --noproxy '*' -o /dev/null -w '   新口令 → %{http_code}（期望 200）\n' -u "admin:$NEWPW" http://127.0.0.1:10097/api/accounts
curl -s --noproxy '*' -o /dev/null -w '   旧口令 → %{http_code}（期望 401）\n' -u "admin:$OLDPW" http://127.0.0.1:10097/api/accounts
unset OLDPW NEWPW
fi

# ⑤ 确认四个学生账号没被这次重写弄丢，且哈希已回填进 accounts.json
printf '   htpasswd 用户: '; docker exec kb-auth /bin/busybox sh -c 'sed "s/:.*//" /app/kb-shared/htpasswd' | tr '\n' ' '; echo
docker exec kb-auth /bin/busybox cat /app/kb-shared/accounts.json | python3 -c "
import json,sys; d=json.load(sys.stdin)['accounts']
print('   有 password_hash 的账号:', sorted(k for k,v in d.items() if v.get('password_hash')))"
```

**换口令不用重启容器**：`rebuild_auth` 重写 `htpasswd` 后，agent-httpd 按 **mtime
热重载**，下一次请求就生效。④ 若两个都返回 200，才说明没生效，去查 `docker logs kb-auth`。

**三件别顺手做的事**：① 不要靠改 compose 的 `LUME_AUTH_PASSWORD` 换口令（seed 分支只在
map 缺失时执行，对已存在的卷完全无效）；② 不要用 `docker volume rm kb-auth-shared` 来
"重置"——那会把刚导入的 4 个学生哈希一起清掉，回到"只有 admin 能登录"；③ 换完不要把口令
新建到 `admin/.env` 里存着（`admin/` 无 git 仓，将来建仓时极容易被顺手带进去），放密码管理器。

验收：`docker logs kb-auth | grep kb-auth` 里那句差值告警消失，变成
`账号表与 htpasswd 一致（N 个账号可登录）`。

### 1）资源表登记

`admin/data/resources.json` 的 `projects` 加一条（资源类型 + 动作 + 最低角色），
并在 `stage_resource` 里加该项目的学段资源名。**改 JSON 即时生效**（`/api/authorize`
每次请求重读），不用重建镜像；`admin/server.lume` 里那份同名表只是读不到 JSON 时的
兜底，改完 JSON 记得同步或用 `GET /api/resources` 核对 `source` 字段。

### 2）挂只读卷 + 设 env（以 `history` 为例）

```yaml
services:
  history:
    volumes:
      - kb-auth-shared:/app/kb-shared:ro   # 只读挂中央身份卷
    environment:
      HTPASSWD_FILE: /app/kb-shared/htpasswd   # 框架认证指向中央 htpasswd（mtime 热重载）
      # ⚠️ 不设 AUTHORITIES_DIR：学段词表按项目不同，见上表
volumes:
  kb-auth-shared:
    name: kb-auth-shared              # 必须同名，才与 kb-auth 共享同一份身份
```

### 3）让位本地 htpasswd 生成（math / chinese 已做，history / medical-stats 待做）

四个项目的 entrypoint 原本都会**无条件**把 `HTPASSWD_FILE` 覆盖成自己生成的本地文件，
所以在 compose 里注入的中央路径会被直接吃掉（math 的 else 分支甚至明写「即使外部误注入
`HTPASSWD_FILE` 也 unset」，那在没有中央服务时是对的，接了卷之后就成了静默失效）。
改前的实测位置：

| 项目 | 覆盖点 | 行为 |
|---|---|---|
| `chinese` | `docker/entrypoint.sh:113` / `:122` | 自己生成后 export；无密码则 unset |
| `math` | `docker/entrypoint.sh:54-86` | 优先用本地 `state/htpasswd.map.json` 重建，**注释里明确写了要把 HTPASSWD_FILE 变成动态量** |
| `history` | `docker/entrypoint.sh:51` | 无条件 `export HTPASSWD_FILE="$AUTH_DIR/htpasswd"` |
| `medical-stats` | `entrypoint.sh:46` | 同上 |

现在已按同一套习语改掉 `math` 与 `chinese` 两个（10-23），判定条件统一为：

- **`HTPASSWD_FILE` 已由外部注入且非空** → 让位：不读本地 map、不生成、不覆盖，
  原样保留注入值；realm 轮换计数与本站 `AUTH_PUBLIC_PATHS` 策略仍按本项目设
  （中央只管"谁能登录"，不管本站登出缓存和哪些页面公开）。
- **注入了但文件读不到**（卷没挂上 / 名字写错）→ **退出码 1 拒绝启动**，绝不静默
  回落到本地生成。回落的后果是「以为接了中央、其实各管各的」，表现成"在 kb-auth
  改了账号本站不生效"而不是报错，是最难查的一类状态。
- **完全没注入** → 旧行为原样保留（math 走本地 map/凭据生成，chinese 无配置时仍
  生成随机密码），所以本机 `make dev` 和未接入项目都不受影响。

验证：`sh work/knowledge/admin/tools/test-central-yield.sh math`（或 `chinese`），
它拿新脚本 ro 挂进各自镜像里跑 A/B/C 三组 8 条断言，**不需要重建镜像**。
对照过旧版（`git show HEAD:docker/entrypoint.sh`）：A1–A4 与 B2 全红，
所以这套断言有判别力、不是恒绿。`history` **已做**（10-24：让位分支 + `lib/access.lume`
shim 一并落地，见下方进度表）；`medical-stats` 尚未改——它目前根本不是 ABAC 消费方
（仓里没有 `lib/access.lume`），让位分支要和建 shim 一起做，免得单独改认证路径却没人消费。

学段授权（`stages`）留在本项目 `state/accounts.json`，由项目自己维护；中央模式下
`shared/admin.lume` 的账号写操作会返回 501 指回 `kb-auth`，所以本地只剩「改授权」
这一件事——它还没有对应的写端点（见待办）。

## 当前进度（2026-10-23 实测）

| 项 | 状态 |
|---|---|
| `kb-auth` 服务（10097，容器 healthy） | ✅ 在跑 |
| 引擎抽到 `shared/{abac,admin,json}.lume` | ✅ math / chinese 已改成薄 shim（未提交） |
| 两层模型（中央身份 + 本地学段） | ✅ 本轮落在 `shared/abac.lume`，85 条断言四套环境全绿 |
| 中央模式下的本地写保护 | ✅ 本轮落在 `shared/admin.lume`（CRUD → 501） |
| 账号表读不到时 fail-closed | ✅ 本轮改（原来是「警告 + 不限制」＝放行，见下） |
| 四个项目挂 `kb-auth-shared` | 🟡 `math`/`chinese`/`history` **已挂**（10-23 深夜接入：ro 挂载 + `HTPASSWD_FILE=/app/kb-shared/htpasswd`，四个容器已 `--build` 重建，日志确认「使用中央认证文件」）；`medical-stats` 未挂 |
| 中央哈希补齐 | ✅ **已 --apply**（10-23：中央 htpasswd 5 个账号 admin/xiao/zhong/gao/jiao，迁移脚本 + kb-auth 日志「账号表与 htpasswd 一致」；学生原口令登录中央 200） |
| 项目 entrypoint 让位分支 | ✅ `math`/`chinese`/`history` 已做；`medical-stats` 待做（它还没接 ABAC） |
| 本地学段授权写端点 | ✅ 本轮落在 `shared/admin.lume`（`grant_update`/`grant_revoke`/`grants_list`）+ `math`/`chinese` 的 `/api/admin/grants*` 路由，宿主冷跑已验 |
| history / medical-stats 接 ABAC | 🟡 `history` ✅ 10-24 已建 `lib/access.lume` + `/api/perm` + `/api/admin/audit`（无学段，stageResource=""；15 条单测 + 冷跑/容器两轮 HTTP 矩阵已验，未提交）；`medical-stats` ❌ 仍无 `lib/access.lume` |

## 本轮改掉的一个静默放行

`shared/abac.lume` 原来是「账号表读不到 → 打警告 + 返回 null → decide 第 4 步整体
跳过 → **PERMIT**」。也就是 `state/accounts.json` 损坏、被误删，或中央卷挂上但里面
没文件时，认证开着、账号却全部放行。现在改成 fail-closed DENY 并写审计（`corrupt`
用例覆盖）。认证关闭（本机 `make dev`，`user == null`）仍在第 1 步短路放行，
开发体验不变。

## 口令与暴露面

`kb-auth` 的宿主端口默认只绑回环（`HOST_BIND` 默认 `127.0.0.1`）——它管全族账号，
且全仓没有任何局域网消费方（grep `10097` 只有本仓文档自己）。

中央 `htpasswd` 的 admin 口令由 entrypoint 首启 bootstrap：

| 情形 | 行为 |
|---|---|
| 卷里**没有** `htpasswd.map.json`（首启 / 删卷后） | 用 `LUME_AUTH_PASSWORD`；compose 默认值**已改为空** → 空则自动生成随机密码并打印到 `docker logs kb-auth` |
| 卷里**已有** map（现网就是这种） | `LUME_AUTH_PASSWORD` 被完全忽略 —— 改 compose 默认值**改不动已存在的口令** |

所以改现存口令只有两条路：

- **API 改密（推荐）**：不删卷、不丢审计，`shared/admin.lume` 会同时重写
  `accounts.json` 的 `password_hash` + `htpasswd.map.json` + `htpasswd`，
  agent-httpd 按 mtime 热重载即时生效。
- **删卷重来**：`docker volume rm kb-auth-shared` 后再 `up -d`，账号回到
  `admin/data/accounts.json` 种子（那 4 个无哈希账号本来就登不进来，无损失），
  代价是丢掉卷里的 `abac-audit.jsonl`。

历史坑（本轮已修）：compose 原来写死 `${LUME_AUTH_PASSWORD:-admin123}`，且端口绑
`0.0.0.0`，实测 `curl -u admin:<ADMIN_PASSWORD> http://192.168.x.x:10097/api/accounts`
返回 200 并列出全部账号，而写端点与读端点共用同一道 `admin_guard`。

`/api/health` 已在 entrypoint 里通过 `AUTH_PUBLIC_PATHS` 放行（此前只有注释声称
放行、实际返回 401，而容器健康检查用 `busybox nc` 只看端口，所以 healthy 把这事
盖住了）。**这是本服务唯一放开的公开路径。**

## 10-23 落地实况（代码 vs 线上，别混）

> **23:30 更新（math/chinese/history/kb-auth 四个容器已 `--build` 重建）**：下表原样保留
> 重建前的对照（它讲的是「为什么不能只改代码」，仍有方法论价值）；重建后已实测生效的项
> 在行内注明。`--build` 之后，engine 相关行为（两层合并 / fail-closed / 差值诊断 /
> /api/health 放行）已由死代码变为线上行为。

| 项 | 代码里 | 线上容器 | 证据 |
|---|---|---|---|
| 端口只绑回环 | ✅ | ✅ **已生效** | `lsof` 只剩 `127.0.0.1:10097`；`192.168.x.x:10097` → `000`；`docker port` = `8097/tcp -> 127.0.0.1:10097` |
| `compose` 口令默认值留空 | ✅ | ✅（env 层面） | `docker compose config` 显示 `LUME_AUTH_PASSWORD: ""` |
| 中央 admin 实际口令 | — | ❌ **未改**（仍是原口令） | 卷里已有 `htpasswd.map.json` → entrypoint 的 seed 分支被跳过，**改 compose 改不动已存在的口令**，必须走 API |
| `/api/health` 免认证 | ✅ | ⚠️ 重建前未生效（实测无凭据 401）；**23:30 重建后已生效**（entrypoint 导出 `AUTH_PUBLIC_PATHS=/api/health`） | 重建前镜像未重建：容器内 `/app/entrypoint.sh` md5 = 改动前备份的 md5 |
| 「有账号登不进来」差值诊断 | ✅ | ✅ **23:30 重建后已生效** | 重建后日志实测：`[kb-auth] 账号表与 htpasswd 一致（5 个账号可登录）` |
| 资源表单一事实源（`stage_for` 读 JSON、`/api/resources` 回有效表） | ✅ | ❌ **未生效** | 带凭据 `GET /api/resources` 回的是旧形状 `{projects, stage}`、**没有 `from_file` 键**；新版是 `projects.<p>.{resources,stage_resource,source}` + 顶层 `from_file` |
| 决策行为（`decide_with` 两层合并 / fail-closed） | ✅ | ✅ **23:30 重建后已生效**（math/chinese 镜像已含 44 行新 shim，`/shared` 绑定可用；math `/api/perm` 实测：`primary-math` PERMIT、`university` DENY，`/api/me` 回 xiao 主体属性） | 重建前实测：`math-site:/app/lib/access.lume` 是 **245 行的抽取前旧单体**（`grep -c shared` = 0），宿主那份 shim 只有 44 行——`lib/` 烧在镜像里、只有 `shared/` 靠绑定进容器，而镜像构建早于 shim 落地 ⇒ 容器既没在用新 shim、也没在用新引擎。加上四站都没挂 `kb-auth-shared`、没设 `AUTHORITIES_DIR`，中央模式分支当然是死代码。**结论：引擎类改动必须 `--build` 才生效，光有 `../shared:/shared:ro` 不够**（23:30 已重建验证） |

要拿最后两行：`cd work/knowledge/admin && docker compose up -d --build`
（QoderWork 沙箱里 buildx 要写 `~/.docker/buildx/activity` 会被拒，得在宿主终端跑）。

> ⚠️ 排查时别踩这个坑：用 `grep -c AUTH_PUBLIC_PATHS /app/entrypoint.sh` 判断新
> entrypoint 有没有进容器会**误报**——旧版那行注释「`AUTH_PUBLIC_PATHS` 由 server
> 默认放行健康端点」里也含这个词，计数同样是 1。要用 `grep 'export AUTH_PUBLIC_PATHS'`
> 或直接比 md5，再不然看功能（无凭据 `/api/health` 是不是 200）。

## 验证手段

```sh
make -C work/knowledge/shared check        # 引擎单测：local / central / corrupt / grants 四套（85 条）
make -C work/knowledge/admin  check        # 上面的 + admin server.lume type-check
make -C work/knowledge/admin  entrypoint-test   # 容器内跑 kb-auth entrypoint 副本（要 docker）
make -C work/knowledge/admin  yield-test  math  # 验项目 entrypoint 的让位分支（要 docker）
make -C work/knowledge/math   access-test  # 既有 20 条回归：证明本地模式没变
```

`entrypoint-test` 的判定网也能被反向验证（断言用的固定串可被环境覆盖）：

```sh
WARN='不可能出现的串' make -C work/knowledge/admin entrypoint-test   # 必须变红、退出非 0
```

两点注意：① 别拿 `IMAGE=caddy:2-alpine` 当负例——Alpine 自带 `/bin/busybox` 且以
root 跑、`/app` 建得出来，entrypoint 在它里面照样跑通（这反而说明该逻辑不依赖 lume
基座）；② 只写"不该出现 X"这一类断言是拦不住的（把 X 改歪，该用例照样绿），所以
每个用例都配一条"必须出现"的正断言。

10-23 本轮实测结果：宿主（lume 0.7.3）与**镜像基座 lume 0.8.1** 两侧都跑过——
基座侧用「只读挂载宿主源码 + 本地已有 `kb-admin:latest` 里的 0.8.1 二进制」，
不需要重建镜像：

```sh
cd work/knowledge
docker run --rm -v "$PWD:/k" -w /k/shared/tools --entrypoint /bin/sh kb-admin:latest \
  -c 'ABAC_MODE=central STATE_DIR=/k/shared/tools/fixtures/local-grant-chinese \
      AUTHORITIES_DIR=/k/shared/tools/fixtures/central ABAC_AUDIT_PATH=/tmp/a.jsonl \
      /app/bin/lume test-abac.lume'
```

| 环境 | 结果 |
|---|---|
| 宿主 lume 0.7.3 | 85 条断言（local 17 / central 26 / corrupt 11 / grants 31）全绿；`math` 既有 20 条全绿；`admin`/`math`/`chinese` 三份 `server.lume` `parse OK`；`math`/`chinese` 两个 entrypoint 的 `sh -n` + 容器内 8 条断言全绿 |
| 容器基座 lume 0.8.1 | 同样 85 条全绿（local 17 / central 26 / corrupt 11 / grants 31）；三份 `server.lume` + 三份引擎 `parse OK`。⚠️ 挂源码进容器时 `STATE_DIR` 要写**容器内**的挂载点（踩过：把宿主 `/tmp/fin/g` 原样传进去，容器里只挂了 `/tmpfin`，于是 grants 模式假红 6 条——不是引擎差异，是路径不存在）|

基座版本仍分裂且 **tag 名不可信**（10-23 逐容器 `--version` 实测：`chinese` 跑 0.6.2、`medical-stats` 跑 0.8.1，两者 Dockerfile 都写 `FROM lume:v0.6.3` 但用源码现构建的二进制覆盖；`lume:v0.6.3` tag 内实测也是 0.6.2。详见 [`../ARCHITECTURE.md`](../ARCHITECTURE.md) 债 5），
且 **四个在线容器都没有重建**，所以线上跑的仍是改动前的镜像 —— 生效要等下一次
`docker build` + `up -d`。宿主 `docker build` 在 QoderWork 沙箱里会因
`~/.docker/buildx/activity` 写入被拒而失败，需要在宿主终端构建。

## CI（草案已写，尚未生效）

[`admin/.github/workflows/check.yml`](.github/workflows/check.yml) 按约定拆成两个 job：

| job | 依赖 docker | 跑什么 |
|---|---|---|
| `engine` | ❌ | `make -C shared check`（85 条断言）+ `make -C admin check`（3 份 `--check`） |
| `entrypoint` | ✅ | 先 build `lume:vX` 基座（tag 从 `admin/docker/Dockerfile` 的 `FROM` 反推，与 `entrypoint-test` 同源），再 `make -C admin entrypoint-test` |

`make check` 全程不碰 docker，所以能直接进 CI；依赖 docker 的 entrypoint 测试单开 job。
配套改了一处：`tools/test-entrypoint.sh` 的基座 tag 不再写死 `lume:v0.8.1`，而是从
Dockerfile 的 `FROM` 行反推（与 `../math/Makefile` 的 `BASE_IMAGE` 同一套做法）——
否则升级 `FROM` 之后测试还在拿旧基座跑，绿得没有意义。顺带发现：同一套用例在
`lume:v0.8.1`、`v0.6.3` 甚至 `caddy:2-alpine` 里都能跑通，说明 entrypoint 逻辑其实
不依赖 lume 基座（只依赖 busybox applet 集合）。

**⚠️ 这份 workflow 现在是惰性的**：`admin/` 与 `shared/` 都还不是 git 仓，没有远端
就没有 Actions。而且它假设 repo 根同时有 `shared/` 和 `admin/` 两个兄弟目录——因为
`admin/server.lume` 写的是 `import "../shared/abac.lume"`，把 admin 单独抽一个仓这句
就找不到文件。**CI 要真跑起来，先决条件是建仓拓扑**（待办 5）。

本机已验证：`env -i`（PATH 只有 `/usr/bin:/bin`）+ `LUME_DIR=<abs>` 覆盖下，
`make -C shared check` 与 `make -C admin check` 都是 54 PASS、退 0，子 make 能继承
命令行变量。仍属 CI 推断（workflow 头部逐条标注）：apt 包清单与 `make -j4` 借自
`erishen/lume` 的 `release.yml`；runner 是 amd64 而本机基座是 arm64。
`erishen/lume` 与 `erishen/lume-core` 都是 **public**，所以 CI 里 checkout 它构建
`bin/lume` 不需要任何凭据。

## 待办（按依赖顺序）

1. ~~**步骤 0 的哈希迁移**~~ → **已完成（10-23 23:30）**：`--apply` 后中央 htpasswd 5 账号（admin/xiao/zhong/gao/jiao），学生原口令登录中央 200。⚠️ 迁移脚本曾因 `json.dump` 默认带空格写出 map，与 entrypoint 的紧凑解析不匹配导致 htpasswd 被清空——已修（脚本 `separators=(',', ':')` + entrypoint grep/sed 容忍空白），这是本步踩过的真坑。
2. ~~四个 entrypoint 的让位分支~~ → **剩 `medical-stats` 一个**：`math`/`chinese`/`history` 已做
   （习语与判别式断言见步骤 3；history 为 node 运行时版，中央模式下跳过本地凭据生成、
   SSR 预取不带 Basic 头）。`medical-stats` 要先建 `lib/access.lume` 才值得改认证路径。
3. ~~本地授权表的写端点~~ **已完成**：`shared/admin.lume` 的 `grant_update`/`grant_revoke`/
   `grants_list` + `math`/`chinese` 的 `/api/admin/grants*` 三条路由。仍待做的是**前端**：
   管理页还没有授权编辑器，只能 curl；另外 `grant: "central-only"` 这个状态要在 UI 上
   显眼提示（否则管理员看不出"有身份没授权"）。
4. ~~两个 shim 补 re-export~~ **已完成**（`central_mode` / `central_dir` / `state_dir` /
   `grant_of` / `grants_list` / `grant_update` / `grant_revoke`）。顺带修掉一处数据保真问题：
   `save_accounts()` 原来写死 `{accounts: ...}`，第一次经 API 改账号就会把人维护的
   `"comment"` 顶层说明字段整个抹掉（冷跑实测到），现在保留非 `accounts` 的顶层键。
5. **`shared/` 与 `admin/` 没有 git 仓** —— 连带后果是
   `admin/.github/workflows/check.yml` 目前是死文件（无远端 ⇒ 无 Actions），且引擎的
   全部改动没有回滚点。**拓扑三选一的决策表已单独整理：
   [`../REPO-TOPOLOGY.md`](../REPO-TOPOLOGY.md)**（每条判据都带实测证据，另含推荐方案
   与采纳后的最小落地步骤）。这里只留结论摘要：推荐 **① `shared`+`admin` 合一个新
   private 仓**——`admin/docker-compose.yml` 的 context 本来就是 `work/knowledge/`、
   CI 草案写的也是 `-C shared`/`-C admin`，所以零路径改动、合仓即生效。
   跑不掉的两个实测事实：① **单独 clone `erishen/chinese` 现在 build 不出镜像**
   （`chinese/docker/Dockerfile:74` 要 `COPY knowledge/shared/`，而该仓跟踪的 shared
   文件数 = 0），② 站点 shim 写的是 `../../shared/abac.lume`，**只有方案②（整族
   monorepo，仓根 = `knowledge/`）能让这句在 clone 里也成立**。①两个问题都治不了，
   它的定位是"先用最小代价拿到回滚点 + 让 CI 活起来"，拓扑统一留到接入收尾后再定。
6. **共享引擎交付方式不一致**：chinese 是镜像内 `COPY knowledge/shared → /app/shared`，
   math 是宿主 `../shared:/shared:ro` 绑定。改引擎对 math 即时生效、对 chinese 必须
   重建镜像。要么统一到 ro 绑定（热更新，牺牲镜像自足性），要么统一到 COPY。
7. `chinese/data/accounts.json` 未 gitignore（math 第 10 行已 ignore）→ 既可能被
   `git add -A` 卷进仓库，也可能连本地副本都不留。
8. history / medical-stats 接 ABAC：**10-24 更新**——history **已建 shim**
   （`lib/access.lume` + `/api/perm` + `/api/admin/audit`，无学段故 `stageResource=""`，
   15 条单测 + 冷跑/容器两轮 HTTP 矩阵已验）；内容读接口仍全站公开（decide 只管
   管理面），与 `resources.json` 的 history 条目一致。
   `medical-stats` 仍未接（无 shim、无让位分支、没挂卷）。
9. 基座镜像版本分裂**且不可追溯**：chinese/medical-stats 的 Dockerfile 写 `FROM
   lume:v0.6.3`，但会用源码现构建的 `bin/lume` 覆盖基座 ⇒ 容器里实测分别是
   **0.6.2 / 0.8.1**；连 `lume:v0.6.3` 这个 tag 里装的也是 0.6.2。共享引擎按新版本
   演进，所以「改完在 0.6.x 上会不会红」这个问题现在无法靠看 Dockerfile 回答。
10. `work/knowledge/rebuild-auth.sh` 的验收期望（`/`=200、`/api/health`=401）与
    chinese/medical-stats/history 三个站点的现配置都不符，照跑必报 ⚠️。
11. `corrupt` 模式下每次决策都 `print` 一行警告（单测里 6 次调用刷 6 行）——真实
    流量下会淹日志，可以改成限流或只在加载期报一次。
