# knowledge/admin —— 集中 ABAC 管理服务（kb-auth）
#
# 依赖：
#   共享引擎 ../shared/*.lume（与 math/chinese 同一事实源）
#   ../../lume/lume 的 bin/lume（未构建：cd ../../lume/lume && make）
#
# 常用：
#   make dev       宿主起服务 → http://127.0.0.1:8097（需 ../../lume/lume/bin/lume）
#   make check     宿主 type-check server.lume + 共享引擎单测
#   make test      共享引擎单测 + 容器内 entrypoint 行为测（后者要 docker）
#   make docker    容器化构建 + 后台启动 → http://127.0.0.1:10097
#   make docker-stop  停容器（卷 kb-auth-shared 保留）
#
LUME_DIR  ?= ../../lume/lume
LUME      := $(LUME_DIR)/bin/lume
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
