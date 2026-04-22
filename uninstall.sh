#!/usr/bin/env bash
# =============================================================================
# uninstall.sh  v0.0.1
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

_detect_hermes_paths() {
    if [[ -z "${HERMES_PYTHON:-}" ]]; then
        local _bin _py
        _bin=$(command -v hermes 2>/dev/null || true)
        if [[ -n "$_bin" ]]; then
            _py=$(head -1 "$_bin" 2>/dev/null | sed 's/^#!//' | tr -d '[:space:]')
            [[ "$_py" == *python* && -x "$_py" ]] && HERMES_PYTHON="$_py"
        fi
    fi
    if [[ -n "${HERMES_PYTHON:-}" ]]; then
        [[ -z "${HERMES_AGENT_DIR:-}" ]] && \
            HERMES_AGENT_DIR="$(dirname "$(dirname "$(dirname "$HERMES_PYTHON")")")"
        [[ -z "${HERMES_HOME:-}" ]] && \
            HERMES_HOME="$(dirname "$HERMES_AGENT_DIR")"
    fi
    HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
    HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}"
    HERMES_PYTHON="${HERMES_PYTHON:-$HERMES_AGENT_DIR/venv/bin/python3}"
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

# 以下路径均基于 HERMES_HOME
MEM0_DATA_DIR="$HERMES_HOME/mem0_data"
BACKUP_ROOT="$HERMES_HOME/backups"
ENV_FILE="$HERMES_HOME/.env"

# ══════════════════════════════════════════════
# 运行时变量
# ══════════════════════════════════════════════

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLLBACK_SCRIPT="$SCRIPT_DIR/rollback.sh"
CACHED_PLUGIN_FILE="$SCRIPT_DIR/mem0_plugin_patch.py"

# ─────────────────────────────────────────────
# 参数解析
# --yes                   自动确认卸载流程本身
# --purge-data            自动确认删除数据目录和历史备份
# --uninstall-pyyaml      自动确认卸载 PyYAML（默认跳过）
# --uninstall-fastembed   自动确认卸载 fastembed（默认跳过）
# ─────────────────────────────────────────────

YES_MODE=false
PURGE_DATA=false
UNINSTALL_PYYAML=false
UNINSTALL_FASTEMBED=false

for arg in "$@"; do
    case "$arg" in
        --yes|-y)           YES_MODE=true ;;
        --purge-data)       PURGE_DATA=true ;;
        --uninstall-pyyaml) UNINSTALL_PYYAML=true ;;
        --uninstall-fastembed) UNINSTALL_FASTEMBED=true ;;
    esac
done

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

confirm_step() {
    local prompt="$1"
    if [[ "$YES_MODE" == "true" ]]; then
        log_info "(--yes) 自动确认：$prompt"; return 0
    fi
    read -rp "$prompt (y/N): " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

confirm_destructive() {
    local prompt="$1"
    if [[ "$PURGE_DATA" == "true" ]]; then
        log_info "(--purge-data) 自动确认删除：$prompt"; return 0
    fi
    read -rp "$prompt (y/N): " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ─────────────────────────────────────────────
# 步骤 0：硬校验本地配置区的路径
# 修复：HERMES_PYTHON 失效时立即退出，不再"假成功"跳过卸载
# ─────────────────────────────────────────────

log_section "步骤 0 / 6：校验本地配置区路径"

log_info "HERMES_HOME   = $HERMES_HOME"
log_info "HERMES_PYTHON = $HERMES_PYTHON"

if [[ ! -d "$HERMES_HOME" ]]; then
    log_error "Hermes 主目录不存在：$HERMES_HOME"
    log_error "请检查脚本顶部「本地配置区」的 HERMES_HOME 值。"
    exit 1
fi
log_ok "HERMES_HOME 存在"

if [[ ! -x "$HERMES_PYTHON" ]]; then
    log_error "Python 解释器不存在或不可执行：$HERMES_PYTHON"
    log_error "可能原因："
    log_error "  1. Hermes venv 路径已变更（重装后路径不同）"
    log_error "  2. venv 尚未创建（Hermes 未完成初始化）"
    log_error "修复方法："
    log_error "  执行 which hermes && head -1 \$(which hermes)"
    log_error "  将输出的解释器路径更新到脚本顶部「本地配置区」的 HERMES_PYTHON"
    exit 1
fi
log_ok "HERMES_PYTHON 可执行"
log_ok "Python 版本：$("$HERMES_PYTHON" --version 2>&1)"

# ─────────────────────────────────────────────
# 卸载确认
# ─────────────────────────────────────────────

log_section "Hermes Mem0 隔离方案完整卸载 v0.0.1"

echo ""
log_warn "此操作将执行以下步骤："
echo "  1. 调用回滚脚本，还原所有配置文件"
echo "  2. 从 Hermes Python 环境卸载 mem0ai"
echo "  3. （需 --uninstall-pyyaml）卸载 PyYAML"
echo "  4. （需 --uninstall-fastembed）卸载 fastembed"
echo "  5. （需 --purge-data）删除 Mem0 数据目录 $MEM0_DATA_DIR"
echo "  6. （需 --purge-data）删除所有历史备份 $BACKUP_ROOT"
echo "  7. 清理辅助文件（.last_backup_path / 插件缓存）"
echo ""

if ! confirm_step "确认继续卸载？"; then
    log_info "已取消卸载。"
    exit 0
fi

# ─────────────────────────────────────────────
# 步骤 1：调用回滚脚本，透传参数
# ─────────────────────────────────────────────

log_section "步骤 1 / 6：还原配置文件（调用回滚脚本）"

if [[ -x "$ROLLBACK_SCRIPT" ]]; then
    log_info "调用：$ROLLBACK_SCRIPT"

    ROLLBACK_ARGS=""
    [[ "$YES_MODE"   == "true" ]] && ROLLBACK_ARGS="$ROLLBACK_ARGS --yes"
    [[ "$PURGE_DATA" == "true" ]] && ROLLBACK_ARGS="$ROLLBACK_ARGS --purge-data"

    # shellcheck disable=SC2086
    bash "$ROLLBACK_SCRIPT" $ROLLBACK_ARGS
    log_ok "配置文件还原完成"
else
    log_warn "未找到回滚脚本：$ROLLBACK_SCRIPT"
    log_warn "跳过配置还原。如需手动还原，请从 $BACKUP_ROOT 中找到备份目录，"
    log_warn "手动复制 config.yaml.bak / SOUL.md.bak / .env.bak 到 $HERMES_HOME。"
fi

# ─────────────────────────────────────────────
# 步骤 2：卸载 mem0ai
# 步骤 0 已确认 HERMES_PYTHON 可执行，此处不会"假成功"
# ─────────────────────────────────────────────

log_section "步骤 2 / 6：卸载 mem0ai"

if "$HERMES_PYTHON" -m pip show mem0ai &>/dev/null 2>&1; then
    "$HERMES_PYTHON" -m pip uninstall mem0ai -y --quiet \
        && log_ok "已卸载：mem0ai" \
        || log_warn "卸载 mem0ai 失败，请手动执行：$HERMES_PYTHON -m pip uninstall mem0ai"
else
    log_info "mem0ai 未安装，跳过"
fi

# ─────────────────────────────────────────────
# 步骤 3：可选卸载 PyYAML
# 语义与 --purge-data 分离，需 --uninstall-pyyaml 显式声明
# ─────────────────────────────────────────────

log_section "步骤 3 / 7：处理 PyYAML"

if "$HERMES_PYTHON" -m pip show PyYAML &>/dev/null 2>&1; then
    if [[ "$UNINSTALL_PYYAML" == "true" ]]; then
        "$HERMES_PYTHON" -m pip uninstall PyYAML -y --quiet \
            && log_ok "已卸载：PyYAML" \
            || log_warn "卸载 PyYAML 失败，请手动执行：$HERMES_PYTHON -m pip uninstall PyYAML"
    else
        log_info "PyYAML 是常用库，默认跳过卸载。"
        log_info "如需卸载，请使用 --uninstall-pyyaml 参数显式声明。"
    fi
else
    log_info "PyYAML 未安装，跳过"
fi

# ─────────────────────────────────────────────
# 步骤 4：可选卸载 fastembed
# fastembed 是本地 embedder 依赖，随 install.sh 一起安装
# ─────────────────────────────────────────────

log_section "步骤 4 / 7：处理 fastembed"

if "$HERMES_PYTHON" -m pip show fastembed &>/dev/null 2>&1; then
    if [[ "$UNINSTALL_FASTEMBED" == "true" ]]; then
        "$HERMES_PYTHON" -m pip uninstall fastembed -y --quiet \
            && log_ok "已卸载：fastembed" \
            || log_warn "卸载 fastembed 失败，请手动执行：$HERMES_PYTHON -m pip uninstall fastembed"
    else
        log_info "fastembed 为本地模式依赖，默认跳过卸载。"
        log_info "如需卸载，请使用 --uninstall-fastembed 参数显式声明。"
    fi
else
    log_info "fastembed 未安装，跳过"
fi

# ─────────────────────────────────────────────
# 步骤 5：可选删除 Mem0 数据目录
# ─────────────────────────────────────────────

log_section "步骤 5 / 7：处理 Mem0 数据目录"

if [[ -d "$MEM0_DATA_DIR" ]]; then
    DATA_SIZE=$(du -sh "$MEM0_DATA_DIR" 2>/dev/null | awk '{print $1}' || echo "未知")
    echo ""
    log_warn "Mem0 数据目录：$MEM0_DATA_DIR（占用：$DATA_SIZE）"
    log_warn "其中包含所有用户的记忆数据，删除后不可恢复。"
    log_warn "如需自动删除，请使用 --purge-data 参数显式声明。"

    if confirm_destructive "是否删除 Mem0 数据目录？"; then
        FINAL_SNAPSHOT="$HOME/hermes_mem0_final_snapshot_$TIMESTAMP"
        cp -r "$MEM0_DATA_DIR" "$FINAL_SNAPSHOT"
        log_ok "最终快照已保存至：$FINAL_SNAPSHOT"
        rm -rf "$MEM0_DATA_DIR"
        log_ok "Mem0 数据目录已删除"
    else
        log_info "已保留 Mem0 数据目录：$MEM0_DATA_DIR"
    fi
else
    log_info "Mem0 数据目录不存在，跳过"
fi

# ─────────────────────────────────────────────
# 步骤 6：可选删除历史备份
# ─────────────────────────────────────────────

log_section "步骤 6 / 7：处理历史备份目录"

if [[ -d "$BACKUP_ROOT" ]]; then
    BACKUP_SIZE=$(du -sh "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}' || echo "未知")
    echo ""
    log_info "历史备份目录：$BACKUP_ROOT（占用：$BACKUP_SIZE）"
    log_warn "如需自动删除，请使用 --purge-data 参数显式声明。"

    if confirm_destructive "是否删除所有历史备份？"; then
        rm -rf "$BACKUP_ROOT"
        log_ok "历史备份目录已删除"
    else
        log_info "已保留历史备份目录：$BACKUP_ROOT"
    fi
else
    log_info "历史备份目录不存在，跳过"
fi

# ─────────────────────────────────────────────
# 步骤 7：清理辅助文件
# ─────────────────────────────────────────────

log_section "步骤 7 / 7：清理辅助文件"

if [[ -f "$HERMES_HOME/.last_backup_path" ]]; then
    rm -f "$HERMES_HOME/.last_backup_path"
    log_ok "已清理：.last_backup_path"
else
    log_info "不存在，跳过：.last_backup_path"
fi

if [[ -f "$CACHED_PLUGIN_FILE" ]]; then
    rm -f "$CACHED_PLUGIN_FILE"
    log_ok "已清理：$(basename "$CACHED_PLUGIN_FILE")"
else
    log_info "不存在，跳过：$(basename "$CACHED_PLUGIN_FILE")"
fi

# ─────────────────────────────────────────────
# 卸载完成
# ─────────────────────────────────────────────

echo ""
echo -e "╔══════════════════════════════════════════════════════╗"
echo -e "║                    卸载完成！                        ║"
echo -e "╚══════════════════════════════════════════════════════╝"

cat <<UNINSTALL_SUMMARY

✅ 配置文件已还原（config.yaml / SOUL.md / USER.md / .env）
✅ mem0ai 已从 Hermes Python 环境卸载
✅ 辅助文件已清理（.last_backup_path / 插件缓存）

如果你保留了 Mem0 数据目录或历史备份，可在确认无需后手动删除：
  rm -rf $MEM0_DATA_DIR
  rm -rf $BACKUP_ROOT

下一步：重启 Hermes Gateway 使配置生效
  hermes gateway stop
  hermes gateway run

如需确认当前生效配置，优先使用：
  hermes config show
（旧版本 Hermes 可改用：hermes config list）

UNINSTALL_SUMMARY
