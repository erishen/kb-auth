# knowledge/admin —— 集中 ABAC 管理服务（kb-auth）
#
# 依赖：
#   共享引擎 ../shared/*.lume（与 math/chinese 同一事实源；公开克隆需 shared 仓同级或 submodule）
#   lume 工具链（bin/lume）—— 见下方 LUME_DIR 解析逻辑
#
# 常用：
#   make dev       宿主起服务 → http://127.0.0.1:8097（需 lume 工具链）
#   make check     宿主 type-check server.lume + 共享引擎单测
#   make test      共享引擎单测 + 容器内 entrypoint 行为测（后者要 docker）
#   make docker    容器化构建 + 后台启动 → http://127.0.0.1:10097
#   make docker-stop  停容器（卷 kb-auth-shared 保留）
#
# lume 工具链位置（构建 / 运行 / 单测都需要）。解析优先级：
#   ① 环境变量或命令行 LUME_DIR（如 `make dev LUME_DIR=/abs/path/to/lume`）；
#   ② 默认的相对路径 ../../lume/lume 指向「与 lume 源码树同级」的本地布局（维护者开箱即用）；
#   ③ 若默认路径不存在，自动回退到 PATH 上的 `lume`（公开克隆装好 lume 即可零配置）。
# 因此无需把 LUME_DIR 写进 .env（make 不读 .env）；覆盖方式请用环境变量或命令行。
LUME_DIR  ?= ../../lume/lume
ifeq ($(wildcard $(LUME_DIR)/bin/lume),)
  LUME      := $(if $(shell command -v lume 2>/dev/null),lume,$(LUME_DIR)/bin/lume)
else
  LUME      := $(LUME_DIR)/bin/lume
endif
SCRIPT    := server.lume
SHARED_DIR ?= ../shared

.PHONY: dev check test engine-test entrypoint-test yield-test docker docker-stop

dev:
	@echo "==> 集中 ABAC 管理服务启动于 http://127.0.0.1:8097"
	@$(LUME) $(SCRIPT)

# 引擎是被本项目和 math/chinese 共用的一份实现，改这里必须过它的单测：
# local / central / corrupt / grants 四套环境各跑一遍（见 ../shared/Makefile 头注释）。
engine-test:
	@$(MAKE) --no-print-directory -C $(SHARED_DIR) test

# entrypoint 跑在 scratch+busybox 里，宿主 macOS 复现不了，只能进容器测。
entrypoint-test:
	@sh tools/test-entrypoint.sh

# 验「项目 entrypoint 的集中身份让位分支」（默认 math；用法：make yield-test PROJ=chinese）。
# 拿新脚本 ro 挂进各自镜像跑，不重建镜像、不碰在线容器。
# ⚠️ 故意**不**挂进 check，也暂时进不了 CI：它要 math:latest / chinese:latest 镜像在本地，
#    而那两个镜像在当前仓结构下 CI 里构建不出来（chinese 仓不含 shared/，见
#    ../REPO-TOPOLOGY.md）。所以它是"本地巡逻"项，不是 CI 项——别为了跑它去给 check 加容器前置。
PROJ ?= math
yield-test:
	@sh tools/test-central-yield.sh $(PROJ)

check: engine-test
	@echo "==> type-check server.lume + 共享引擎"
	@$(LUME) --check $(SCRIPT)
	@$(LUME) --check $(SHARED_DIR)/abac.lume
	@$(LUME) --check $(SHARED_DIR)/admin.lume

# make test = 不需要 docker 的部分 + 需要 docker 的部分都跑一遍
test: check entrypoint-test

docker:
	@cd $(CURDIR) && docker compose -f docker-compose.yml up -d --build
	@echo "==> http://127.0.0.1:$${DOCKER_PORT:-10097}/ （集中账号/审计/跨项目决策；healthcheck 约 5s 就绪）"

docker-stop:
	@cd $(CURDIR) && docker compose -f docker-compose.yml down
