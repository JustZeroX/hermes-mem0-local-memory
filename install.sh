#!/usr/bin/env bash
# =============================================================================
# install.sh  v0.0.1
#
# 方案说明：
#   - 零源码修改，仅通过配置切换 Hermes 记忆后端为 Mem0 本地 SQLite 模式
#   - 按飞书 user_id 隔离每位用户的记忆，避免多用户共用时的记忆污染
#   - 禁用 session_search，防止跨用户记忆污染
#
# 使用方法：
#   chmod +x install.sh
#   ./install.sh
#
# 回滚：./rollback.sh
# 卸载：./uninstall.sh
# 更新后自愈：./doctor.sh
# =============================================================================

set -euo pipefail

# ══════════════════════════════════════════════
# 路径自动探测（通常无需任何配置）
#
# 推导链：hermes shebang → HERMES_PYTHON → 上4级 → HERMES_HOME
# 如需手动覆盖，执行前 export 即可：
#   export HERMES_HOME=/your/hermes/path
#   export HERMES_PYTHON=/path/to/python3
# ══════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

_detect_hermes_paths() {
    # Step 1: 从 hermes 命令 shebang 读取 HERMES_PYTHON
    if [[ -z "${HERMES_PYTHON:-}" ]]; then
        local _bin _py
        _bin=$(command -v hermes 2>/dev/null || true)
        if [[ -n "$_bin" ]]; then
            _py=$(head -1 "$_bin" 2>/dev/null | sed 's/^#!//' | tr -d '[:space:]')
            [[ "$_py" == *python* && -x "$_py" ]] && HERMES_PYTHON="$_py"
        fi
    fi

    # Step 2: 从 HERMES_PYTHON 推导 HERMES_AGENT_DIR（上3级）和 HERMES_HOME（上4级）
    #   结构：<HERMES_HOME> / <agent-dir> / venv / bin / python3
    if [[ -n "${HERMES_PYTHON:-}" ]]; then
        [[ -z "${HERMES_AGENT_DIR:-}" ]] && \
            HERMES_AGENT_DIR="$(dirname "$(dirname "$(dirname "$HERMES_PYTHON")")")"
        [[ -z "${HERMES_HOME:-}" ]] && \
            HERMES_HOME="$(dirname "$HERMES_AGENT_DIR")"
    fi

    # Step 3: 兜底默认路径
    HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
    HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}"
    HERMES_PYTHON="${HERMES_PYTHON:-$HERMES_AGENT_DIR/venv/bin/python3}"

    # Step 4: 校验
    if [[ ! -d "$HERMES_HOME" ]]; then
        echo "[ERROR] Hermes 主目录不存在：$HERMES_HOME"
        echo "  请手动设置：export HERMES_HOME=/your/hermes/path"
        exit 1
    fi
    if [[ ! -x "$HERMES_PYTHON" ]]; then
        echo "[ERROR] Python 解释器不可执行：$HERMES_PYTHON"
        echo "  请手动设置：export HERMES_PYTHON=/path/to/python3"
        exit 1
    fi
}

_detect_hermes_paths

# 以下路径均基于 HERMES_HOME，一般不需要改动
MEM0_DATA_DIR="$HERMES_HOME/mem0_data"
MEMORIES_DIR="$HERMES_HOME/memories"
CONFIG_FILE="$HERMES_HOME/config.yaml"
ENV_FILE="$HERMES_HOME/.env"
SOUL_FILE="$HERMES_HOME/SOUL.md"
USER_FILE="$MEMORIES_DIR/USER.md"
MEM0_PLUGIN_FILE="$HERMES_AGENT_DIR/plugins/memory/mem0/__init__.py"
MEM0_PLUGIN_CACHE_FILE="$SCRIPT_DIR/mem0_plugin_patch.py"

# ══════════════════════════════════════════════
# 运行时变量（不需要修改）
# ══════════════════════════════════════════════

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="$HERMES_HOME/backups/mem0_isolation_$TIMESTAMP"
PIP_TIMEOUT=120
PIP_RETRIES=10

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "[INFO]  $*"; }
log_ok()      { echo -e "[OK]    $*"; }
log_warn()    { echo -e "[WARN]  $*"; }
log_error()   { echo -e "[ERROR] $*"; }
log_section() {
    echo -e "
══════════════════════════════════════"
    echo -e "  $*"
    echo -e "══════════════════════════════════════"
}

ensure_rg_available() {
    if command -v rg &>/dev/null; then
        return 0
    fi
    log_warn "未检测到 rg（ripgrep），尝试通过 Homebrew 自动安装..."
    if command -v brew &>/dev/null; then
        if brew install ripgrep --quiet; then
            log_ok "ripgrep 安装成功"
        else
            log_error "ripgrep 安装失败，请手动执行：brew install ripgrep"
            exit 1
        fi
    else
        log_error "未找到 rg（ripgrep），且 Homebrew 不可用"
        log_error "请手动安装：brew install ripgrep"
        log_error "或参考：https://github.com/BurntSushi/ripgrep#installation"
        exit 1
    fi
}

ensure_pip_available() {
    local python_bin="$1"
    if "$python_bin" -m pip --version >/dev/null 2>&1; then
        return 0
    fi

    log_warn "当前解释器缺少 pip，尝试自动执行 ensurepip..."
    if "$python_bin" -m ensurepip --upgrade >/dev/null 2>&1; then
        log_ok "pip 已通过 ensurepip 安装"
    else
        log_error "自动安装 pip 失败，请手动执行："
        log_error "  $python_bin -m ensurepip --upgrade"
        exit 1
    fi
}

show_hermes_config() {
    if hermes config show >/dev/null 2>&1; then
        hermes config show
        return 0
    fi
    if hermes config list >/dev/null 2>&1; then
        hermes config list
        return 0
    fi
    return 1
}

ensure_mem0_plugin_local_support() {
    local plugin_file="$1"

    if [[ ! -f "$plugin_file" ]]; then
        log_error "未找到 mem0 插件文件：$plugin_file"
        return 1
    fi

    if rg --quiet "Supports two modes:" "$plugin_file" && \
       rg --quiet "_build_local_memory_config" "$plugin_file" && \
       rg --quiet "_LOCAL_CLIENTS" "$plugin_file"; then
        log_ok "mem0 插件已具备 local 模式支持"
        return 0
    fi

    log_warn "检测到 mem0 插件不是本地增强版，尝试从缓存自动恢复..."
    if [[ ! -f "$MEM0_PLUGIN_CACHE_FILE" ]]; then
        log_error "未找到插件缓存：$MEM0_PLUGIN_CACHE_FILE"
        log_error "请先执行：$SCRIPT_DIR/doctor.sh --patch-only"
        return 1
    fi
    cp "$plugin_file" "$BACKUP_DIR/mem0_plugin.__init__.py.before_restore.bak"
    cp "$MEM0_PLUGIN_CACHE_FILE" "$plugin_file"
    if "$HERMES_PYTHON" -m py_compile "$plugin_file" >/dev/null 2>&1; then
        log_ok "mem0 插件已从缓存恢复并通过语法检查"
        return 0
    fi
    log_error "从缓存恢复后语法检查失败：$plugin_file"
    return 1
}

harden_user_md() {
    mkdir -p "$MEMORIES_DIR"
    if [[ ! -f "$USER_FILE" ]]; then
        : > "$USER_FILE"
    fi
    chmod 444 "$USER_FILE" 2>/dev/null || true
    log_ok "USER.md 已加固为只读（444）：$USER_FILE"
}

# ─────────────────────────────────────────────
# 工具函数：PyYAML 安全写入 config.yaml
# ─────────────────────────────────────────────

write_yaml_config() {
    local python_bin="$1"
    local config_path="$2"
    local mem0_data_path="$3"

    log_warn "config.yaml 将被 PyYAML 整文件重写，原有注释和自定义排版会丢失。"
    log_warn "原始文件已备份至：$BACKUP_DIR/config.yaml.bak，如需恢复可从备份还原。"
    log_info "使用 PyYAML 解析并合并 config.yaml..."

    "$python_bin" - "$config_path" "$mem0_data_path" <<'PYEOF'
import sys, os

config_path    = sys.argv[1]
mem0_data_path = sys.argv[2]

try:
    import yaml
except ImportError:
    print("YAML_UNAVAILABLE")
    sys.exit(0)

# 读取现有配置（文件不存在则从空白开始）
if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8") as f:
        try:
            config = yaml.safe_load(f)
        except yaml.YAMLError as e:
            print(f"YAML_PARSE_ERROR: {e}")
            sys.exit(1)
else:
    config = None

# 顶层类型防御：config 必须是 dict
# 若文件为空（None）、列表、字符串等非 dict 类型，直接重置为空 dict
if not isinstance(config, dict):
    config = {}

# ── 写入 memory 配置 ──
# 防御：memory / memory.settings 存在但不是 dict 时直接重置
if not isinstance(config.get("memory"), dict):
    config["memory"] = {}
config["memory"]["provider"] = "mem0"
# 多用户场景下禁用内置用户画像（USER.md 写入），防止全局信息污染
config["memory"]["user_profile_enabled"] = False
if not isinstance(config["memory"].get("settings"), dict):
    config["memory"]["settings"] = {}
config["memory"]["settings"]["storage_mode"] = "local"
config["memory"]["settings"]["storage_path"] = mem0_data_path
config["memory"]["settings"]["embedder"]     = "local"

# ── 写入 tools 配置 ──
# 防御：tools 存在但不是 dict 时直接重置
if not isinstance(config.get("tools"), dict):
    config["tools"] = {}
raw_disabled = config["tools"].get("disabled", [])

# 标准化 disabled 字段，覆盖所有边界情况：
#   None       -> []      （yaml 中写了 disabled: null）
#   str        -> [str]   （yaml 中写了 disabled: session_search）
#   list/tuple -> list()  （正常情况）
#   其他类型   -> []      （未知格式，安全降级）
if raw_disabled is None:
    existing_disabled = []
elif isinstance(raw_disabled, str):
    existing_disabled = [raw_disabled]
elif isinstance(raw_disabled, (list, tuple)):
    existing_disabled = list(raw_disabled)
else:
    existing_disabled = []

# 追加 session_search（如不存在）
if "session_search" not in existing_disabled:
    existing_disabled.append("session_search")

# 保序去重，避免历史重复值越积越多
seen = []
for item in existing_disabled:
    if item not in seen:
        seen.append(item)
existing_disabled = seen

config["tools"]["disabled"] = existing_disabled

# 回写（PyYAML 整文件重写，注释会丢失，这是已知限制）
with open(config_path, "w", encoding="utf-8") as f:
    yaml.dump(config, f,
              allow_unicode=True,
              default_flow_style=False,
              sort_keys=False)

print("YAML_WRITE_OK")
PYEOF
}

# ─────────────────────────────────────────────
# 工具函数：写入 .env（双通道保险）
# ─────────────────────────────────────────────

write_env_config() {
    local env_path="$1"
    local mem0_data_path="$2"

    log_info "同步写入 .env 文件（Mem0 环境变量双通道）..."

    local keys="MEM0_STORAGE_MODE MEM0_STORAGE_PATH MEM0_EMBEDDER MEM0_API_KEY"

    for key in $keys; do
        local val
        case "$key" in
            MEM0_STORAGE_MODE) val="local" ;;
            MEM0_STORAGE_PATH) val="$mem0_data_path" ;;
            MEM0_EMBEDDER)     val="local" ;;
            MEM0_API_KEY)      val="local-placeholder" ;;
        esac

        # 对 val 中的 & 转义为 \&，避免 sed 将其解释为"匹配文本"引用
        local escaped_val
        escaped_val=$(printf '%s' "$val" | sed 's/&/\\&/g')

        # 同时匹配 KEY=... 和 export KEY=... 两种写法
        if [[ -f "$env_path" ]] && \
           grep -qE "^(export )?$key=" "$env_path" 2>/dev/null; then
            local tmpfile
            tmpfile=$(mktemp)
            sed -E "s|^(export )?$key=.*|$key=$escaped_val|" "$env_path" > "$tmpfile"
            mv "$tmpfile" "$env_path"
            log_ok ".env 已更新：$key=$val"
        else
            echo "$key=$val" >> "$env_path"
            log_ok ".env 已追加：$key=$val"
        fi
    done

    if ! grep -q "# MEM0_ISOLATION_MARKER" "$env_path" 2>/dev/null; then
        echo "# MEM0_ISOLATION_MARKER: 由 install.sh v0.0.1 写入于 $TIMESTAMP" \
            >> "$env_path"
    fi
}

# ─────────────────────────────────────────────
# 工具函数：Mem0 库级 smoke test
# ─────────────────────────────────────────────

smoke_test_mem0_isolation() {
    local python_bin="$1"
    local hermes_root="$2"

    PYTHONPATH="$hermes_root:${PYTHONPATH:-}" "$python_bin" - <<'PYEOF'
import sys

try:
    from plugins.memory.mem0 import Mem0MemoryProvider
except ImportError:
    print("SKIP: 无法导入 mem0 插件（请确认 PYTHONPATH 指向 hermes-agent）")
    sys.exit(0)

try:
    p = Mem0MemoryProvider()
    p.initialize("smoke-session", user_id="__smoke_user_a__")
    c = p._get_client()
except Exception as e:
    print(f"SKIP: mem0 local 初始化失败：{e}")
    sys.exit(0)

TEST_A = "__smoke_test_user_a__"
TEST_B = "__smoke_test_user_b__"

try:
    c.add([{"role": "user", "content": "我喜欢喝咖啡，我叫测试用户A"}], user_id=TEST_A, agent_id="hermes", infer=False)
    results_b = c.search(query="咖啡 测试用户A", filters={"user_id": TEST_B}, top_k=5)

    try:
        all_a = c.get_all(filters={"user_id": TEST_A}, top_k=20)
        if isinstance(all_a, dict):
            all_a = all_a.get("results", [])
        for mem in (all_a or []):
            mid = mem.get("id") if isinstance(mem, dict) else None
            if mid:
                c.delete(mid)
    except Exception:
        pass

    if isinstance(results_b, dict):
        results_b = results_b.get("results", [])
    if results_b and len(results_b) > 0:
        print("SMOKE_FAIL: 本地模式隔离异常，用户 B 能检索到用户 A 的数据")
        print(f"  泄露内容：{results_b}")
        sys.exit(2)
    else:
        print("SMOKE_PASS: 本地模式 user_id 过滤有效（注意：仍需飞书端验收）")
        sys.exit(0)

except Exception as e:
    print(f"SKIP: 测试执行异常：{e}")
    sys.exit(0)
PYEOF
}

# ═════════════════════════════════════════════
# 主流程
# ═════════════════════════════════════════════

# ─────────────────────────────────────────────
# 步骤 1 / 7：前置检查
# ─────────────────────────────────────────────

log_section "步骤 1 / 7：前置环境检查"

log_info "HERMES_HOME   = $HERMES_HOME"
log_info "HERMES_PYTHON = $HERMES_PYTHON"

if [[ ! -d "$HERMES_HOME" ]]; then
    log_error "Hermes 主目录不存在：$HERMES_HOME"
    log_error "请检查脚本顶部「本地配置区」的 HERMES_HOME 值。"
    exit 1
fi
log_ok "Hermes 主目录存在"

if [[ ! -x "$HERMES_PYTHON" ]]; then
    log_error "Python 解释器不存在或不可执行：$HERMES_PYTHON"
    log_error "修复方法："
    log_error "  执行 which hermes && head -1 \$(which hermes)"
    log_error "  将输出的解释器路径更新到脚本顶部「本地配置区」的 HERMES_PYTHON"
    exit 1
fi
log_ok "Python 解释器可执行"
log_ok "Python 版本：$("$HERMES_PYTHON" --version 2>&1)"

if ! command -v hermes &>/dev/null; then
    log_error "未找到 hermes 命令，请确认 Hermes Agent 已安装。"
    exit 1
fi
ensure_rg_available
log_ok "Hermes 已安装：$(hermes --version 2>/dev/null || echo '版本未知')"
# 提前创建备份目录，供插件自动恢复时落盘备份
mkdir -p "$BACKUP_DIR"
ensure_mem0_plugin_local_support "$MEM0_PLUGIN_FILE" || exit 1

for f in "$CONFIG_FILE" "$SOUL_FILE"; do
    [[ -f "$f" ]] \
        && log_ok "已确认存在：$(basename "$f")" \
        || log_warn "不存在（将创建）：$(basename "$f")"
done

if [[ -f "$HERMES_HOME/state.db" ]]; then
    log_ok "检测到 state.db（Hermes 自身 SQLite）"
    log_info "Mem0 将使用独立目录 ${MEM0_DATA_DIR}，与 state.db 完全不冲突。"
fi

# ─────────────────────────────────────────────
# 步骤 2 / 7：备份现有配置
# ─────────────────────────────────────────────

log_section "步骤 2 / 7：备份现有配置"

mkdir -p "$BACKUP_DIR"
log_info "备份目录：$BACKUP_DIR"

for target in "$CONFIG_FILE" "$SOUL_FILE" "$ENV_FILE" "$MEM0_PLUGIN_FILE"; do
    fname=$(basename "$target")
    if [[ -f "$target" ]]; then
        cp "$target" "$BACKUP_DIR/$fname.bak"
        log_ok "已备份：$fname"
    else
        log_warn "$fname 不存在，跳过备份"
    fi
done

if [[ -f "$USER_FILE" ]]; then
    cp "$USER_FILE" "$BACKUP_DIR/USER.md.bak"
    log_warn "USER.md 已备份至 $BACKUP_DIR/USER.md.bak"
    log_warn "USER.md 在多用户场景下会导致全局信息污染，建议移除。"
    read -rp "确认移除 USER.md？(y/N): " CONFIRM_USER
    if [[ "$CONFIRM_USER" == "y" || "$CONFIRM_USER" == "Y" ]]; then
        rm -f "$USER_FILE"
        log_ok "USER.md 已移除（备份保留）"
    else
        log_info "已跳过 USER.md 移除，请部署后手动处理。"
    fi
else
    log_info "USER.md 不存在，无需处理"
fi
harden_user_md

echo "$BACKUP_DIR" > "$HERMES_HOME/.last_backup_path"
log_ok "备份路径已记录：$HERMES_HOME/.last_backup_path"

# ─────────────────────────────────────────────
# 步骤 3 / 7：安装依赖到 Hermes Python 环境
# ─────────────────────────────────────────────

log_section "步骤 3 / 7：安装依赖到 Hermes Python 环境"

log_info "目标解释器：$HERMES_PYTHON"
ensure_pip_available "$HERMES_PYTHON"

if "$HERMES_PYTHON" -m pip install \
       "mem0ai>=0.1.0" \
       "fastembed>=0.8.0" \
       "PyYAML>=6.0" \
       --timeout "$PIP_TIMEOUT" \
       --retries "$PIP_RETRIES" \
       --quiet; then
    MEM0_VER=$("$HERMES_PYTHON" -m pip show mem0ai 2>/dev/null \
        | grep "^Version" | awk '{print $2}' || echo "版本未知")
    log_ok "mem0ai 安装成功：$MEM0_VER"
    log_ok "PyYAML 安装成功"
    log_ok "fastembed 安装成功（local embedder）"
else
    log_error "依赖安装失败，请手动执行："
    log_error "  $HERMES_PYTHON -m pip install mem0ai PyYAML"
    exit 1
fi

if "$HERMES_PYTHON" -c \
       "import mem0; print('mem0 可导入，版本：', mem0.__version__)" \
       2>/dev/null; then
    log_ok "mem0 可导入性验证通过"
else
    log_error "mem0 安装后仍无法导入，请检查 Python 环境：$HERMES_PYTHON"
    exit 1
fi

# ─────────────────────────────────────────────
# 步骤 4 / 7：写入 config.yaml
# ─────────────────────────────────────────────

log_section "步骤 4 / 7：写入 config.yaml（PyYAML 安全合并）"

mkdir -p "$MEM0_DATA_DIR"
log_ok "Mem0 数据目录：$MEM0_DATA_DIR"

YAML_RESULT=$(write_yaml_config \
    "$HERMES_PYTHON" "$CONFIG_FILE" "$MEM0_DATA_DIR" 2>&1)

case "$YAML_RESULT" in
    *"YAML_WRITE_OK"*)
        log_ok "config.yaml 写入成功" ;;
    *"YAML_UNAVAILABLE"*)
        log_error "PyYAML 不可用，请手动安装后重试：$HERMES_PYTHON -m pip install PyYAML"
        exit 1 ;;
    *"YAML_PARSE_ERROR"*)
        log_error "config.yaml 语法错误：$YAML_RESULT"
        log_error "请修复后重试，或备份后删除 config.yaml 让脚本重建。"
        exit 1 ;;
    *)
        log_error "config.yaml 写入未知错误：$YAML_RESULT"
        exit 1 ;;
esac

log_info "── 写入后 config.yaml 关键配置（请人工核对）──"
grep -A 8 '^memory:' "$CONFIG_FILE" 2>/dev/null \
    || log_warn "无法读取 memory 块，请手动检查 config.yaml"
grep -A 4 '^tools:' "$CONFIG_FILE" 2>/dev/null \
    || log_warn "无法读取 tools 块，请手动检查 config.yaml"

# ─────────────────────────────────────────────
# 步骤 5 / 7：同步写入 .env
# ─────────────────────────────────────────────

log_section "步骤 5 / 7：同步写入 .env（环境变量双通道）"

write_env_config "$ENV_FILE" "$MEM0_DATA_DIR"

log_info "── 写入后 .env 中的 Mem0 变量 ──"
grep "^MEM0_" "$ENV_FILE" 2>/dev/null \
    || log_warn "无法读取 MEM0_ 变量，请手动检查 .env"

# ─────────────────────────────────────────────
# 步骤 6 / 7：增强 SOUL.md 多用户隔离约束
# ─────────────────────────────────────────────

log_section "步骤 6 / 7：增强 SOUL.md 多用户隔离约束"

if grep -q 'MULTI_USER_ISOLATION' "$SOUL_FILE" 2>/dev/null; then
    log_warn "SOUL.md 中已存在多用户隔离指令，跳过写入。"
else
    cat >> "$SOUL_FILE" <<'SOUL_CONTENT'

---

<!-- MULTI_USER_ISOLATION: 由 install.sh v0.0.1 写入，请勿删除此标记 -->

## 多用户隔离行为约束（第二道防线）

你运行在多用户共享环境中。以下规则具有最高优先级：

1. **严格按当前对话用户的身份读写记忆**。每位用户的偏好、身份、历史完全独立，绝不混用。
2. **禁止将用户 A 的任何信息透露给用户 B**，包括姓名、职位、偏好、历史问题、任务进度。
3. **当你不确定某条记忆属于哪位用户时，不要使用它**，直接向当前用户重新询问。
4. **不要主动提及"还有其他用户在使用这个机器人"**，也不透露系统中存在其他用户的信息。
5. **公共知识（MEMORY.md 中的团队公共信息）对所有用户开放**；个人记忆（Mem0 存储的用户偏好）仅限当前用户可见。

> 此约束是行为层防线，真正的隔离由 Mem0 按 user_id 的存储查询条件保证。

<!-- END MULTI_USER_ISOLATION -->
SOUL_CONTENT
    log_ok "SOUL.md 多用户隔离约束已写入"
fi

# ─────────────────────────────────────────────
# 步骤 7 / 7：部署后验证
# ─────────────────────────────────────────────

log_section "步骤 7 / 7：部署后验证"

echo ""
log_info "── Python 环境确认 ──"
echo "  解释器路径：$HERMES_PYTHON"
MEM0_IMPORT=$("$HERMES_PYTHON" -c \
    "import mem0; print('✅ 是，版本 ' + mem0.__version__)" \
    2>/dev/null || echo "❌ 否，请手动排查")
echo "  mem0 可导入：$MEM0_IMPORT"

echo ""
log_info "── Mem0 本地模式 smoke test（PASS 不代表生产链路已生效）──"
SMOKE_RESULT=$(smoke_test_mem0_isolation "$HERMES_PYTHON" "$HERMES_AGENT_DIR" 2>&1)
echo "  $SMOKE_RESULT"
if echo "$SMOKE_RESULT" | grep -q "^SMOKE_FAIL"; then
    log_error "mem0 本地模式隔离异常，请检查插件与依赖后重新部署。"
    exit 1
elif echo "$SMOKE_RESULT" | grep -q "^SMOKE_PASS"; then
    log_ok "mem0 库级 smoke test 通过"
else
    log_warn "smoke test 跳过（SKIP），请通过飞书端验收用例确认生产隔离效果"
fi

echo ""
log_info "── Hermes 运行时配置（生产隔离硬证据，必须人工确认）──"
echo ""
echo "  \$ hermes config show   (旧版本可能使用 hermes config list)"
show_hermes_config || log_warn "hermes config show/list 执行失败，请手动运行"
echo ""
log_warn "请在上方输出中确认以下两项，缺一不可："
log_warn "  1. memory.provider = mem0"
log_warn "  2. tools.disabled 包含 session_search"
log_warn "如果看不到，说明 config.yaml 字段名未被当前 Hermes 版本识别，"
log_warn "需执行 hermes config set --help 查阅正确字段名。"
log_warn "Hermes 更新后若插件被覆盖，可执行：$SCRIPT_DIR/doctor.sh"

echo ""
echo -e "╔══════════════════════════════════════════════════════╗"
echo -e "║              部署完成！请执行以下验收步骤             ║"
echo -e "╚══════════════════════════════════════════════════════╝"

cat <<SUMMARY

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【上线前必过项 0】hermes config show/list 硬证据确认
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  执行：hermes config show
      （若版本较旧再试：hermes config list）
  必须看到：
    memory.provider = mem0
    tools.disabled  = [session_search]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【上线前必过项 1】open_id → user_id 映射链路确认
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  hermes gateway run --log-level debug 2>&1 \
      | grep -i "user_id\|open_id\|mem0"
  预期：飞书 open_id（ou_xxxxxxx）被映射为 Mem0 user_id

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【上线前必过项 2～6】飞书端对端隔离验收用例
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  用例 1：飞书账号 A 发："我叫小明，我喜欢喝咖啡" → 机器人确认记住
  用例 2：飞书账号 B 发："你知道我叫什么吗？"      → 机器人应不知道
  用例 3：飞书账号 B 发："我叫小红，我喜欢喝茶"   → 机器人确认记住
  用例 4：飞书账号 A 发："你知道其他人叫什么吗？"  → 机器人应不知道
  用例 5：重启 Gateway 后重复用例 2 和 4            → 隔离仍然有效

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【定期备份】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  cp -r ${MEM0_DATA_DIR} ~/hermes_mem0_backup_\$(date +%Y%m%d)/

【回滚】./rollback.sh
【卸载】./uninstall.sh
【更新后自愈】./doctor.sh
【加固说明】USER.md 已自动设置为只读（chmod 444）

SUMMARY
