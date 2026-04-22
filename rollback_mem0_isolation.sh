#!/usr/bin/env bash
# =============================================================================
# rollback_mem0_isolation.sh  v3.5
# 修订说明：
#   [新增]     与 deploy v4.1 对齐：回滚时将 USER.md 权限恢复为可写（644）
#   [同步]     与 deploy v3.8 对齐：文档中统一使用 config show/list 口径
#   [严重修复] HERMES_HOME 写死为实际路径
#   [中修复]   --yes 只确认回滚流程，--purge-data 才自动确认删除数据
# =============================================================================

set -euo pipefail

# ══════════════════════════════════════════════
# 本地配置区
# ══════════════════════════════════════════════

HERMES_HOME="/Users/p/.hermes"

# 以下路径均基于 HERMES_HOME
CONFIG_FILE="$HERMES_HOME/config.yaml"
ENV_FILE="$HERMES_HOME/.env"
SOUL_FILE="$HERMES_HOME/SOUL.md"
USER_FILE="$HERMES_HOME/memories/USER.md"
MEM0_DATA_DIR="$HERMES_HOME/mem0_data"

# ══════════════════════════════════════════════
# 运行时变量
# ══════════════════════════════════════════════

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PRE_ROLLBACK_BACKUP="$HERMES_HOME/backups/pre_rollback_$TIMESTAMP"

# ─────────────────────────────────────────────
# 参数解析
# --yes         自动确认回滚流程本身
# --purge-data  自动确认删除 Mem0 数据目录
# ─────────────────────────────────────────────

YES_MODE=false
PURGE_DATA=false
MANUAL_BACKUP_DIR=""

for arg in "$@"; do
    case "$arg" in
        --yes|-y)     YES_MODE=true ;;
        --purge-data) PURGE_DATA=true ;;
        --*)          ;;
        *)            MANUAL_BACKUP_DIR="$arg" ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "[INFO]  $*"; }
log_ok()      { echo -e "[OK]    $*"; }
log_warn()    { echo -e "[WARN]  $*"; }
log_error()   { echo -e "[ERROR] $*"; }
log_section() {
    echo -e "\n══════════════════════════════════════"
    echo -e "  $*"
    echo -e "══════════════════════════════════════"
}

confirm_rollback() {
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
# 确定原始备份目录
# ─────────────────────────────────────────────

log_section "Hermes Mem0 隔离方案回滚 v3.3"
log_info "HERMES_HOME = $HERMES_HOME"

if [[ -n "$MANUAL_BACKUP_DIR" ]]; then
    BACKUP_DIR="$MANUAL_BACKUP_DIR"
    log_info "使用指定备份目录：$BACKUP_DIR"
elif [[ -f "$HERMES_HOME/.last_backup_path" ]]; then
    BACKUP_DIR=$(cat "$HERMES_HOME/.last_backup_path")
    log_info "自动读取最近备份目录：$BACKUP_DIR"
else
    log_error "未找到备份路径记录，请手动指定备份目录："
    log_error "  ./rollback_mem0_isolation.sh \$HERMES_HOME/backups/mem0_isolation_<timestamp>"
    exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
    log_error "备份目录不存在：$BACKUP_DIR"
    exit 1
fi
log_ok "原始备份目录：$BACKUP_DIR"

# ─────────────────────────────────────────────
# 回滚前：强制二次备份当前文件
# ─────────────────────────────────────────────

log_section "回滚前二次备份（保护观察期内的手工修改）"

mkdir -p "$PRE_ROLLBACK_BACKUP"
log_info "二次备份目录：$PRE_ROLLBACK_BACKUP"
log_warn "回滚将用原始备份整文件覆盖当前配置，观察期内的手工修改会被覆盖。"
log_warn "已将当前文件保存到二次备份目录，可手动恢复。"

for target in "$CONFIG_FILE" "$SOUL_FILE" "$ENV_FILE"; do
    fname=$(basename "$target")
    if [[ -f "$target" ]]; then
        cp "$target" "$PRE_ROLLBACK_BACKUP/$fname.current"
        log_ok "已二次备份：$fname"
    fi
done

echo ""
if ! confirm_rollback "确认继续回滚？"; then
    log_info "已取消回滚。当前文件未做任何修改。"
    log_info "二次备份已保留在：$PRE_ROLLBACK_BACKUP（可手动删除）"
    exit 0
fi

# ─────────────────────────────────────────────
# 还原配置文件
# ─────────────────────────────────────────────

log_section "还原配置文件"

if [[ -f "$BACKUP_DIR/config.yaml.bak" ]]; then
    cp "$BACKUP_DIR/config.yaml.bak" "$CONFIG_FILE"
    log_ok "config.yaml 已还原"
else
    log_warn "备份中无 config.yaml.bak，跳过"
fi

if [[ -f "$BACKUP_DIR/SOUL.md.bak" ]]; then
    cp "$BACKUP_DIR/SOUL.md.bak" "$SOUL_FILE"
    log_ok "SOUL.md 已还原"
else
    log_warn "备份中无 SOUL.md.bak，跳过"
fi

if [[ -f "$BACKUP_DIR/USER.md.bak" ]]; then
    mkdir -p "$(dirname "$USER_FILE")"
    cp "$BACKUP_DIR/USER.md.bak" "$USER_FILE"
    log_ok "USER.md 已还原"
else
    log_info "备份中无 USER.md.bak（部署前本就不存在），跳过"
fi

# 与 deploy v4.1 对齐：部署时会将 USER.md 加固为 444。
# 回滚后恢复为 644，避免后续人工编辑受阻。
if [[ -f "$USER_FILE" ]]; then
    chmod 644 "$USER_FILE" 2>/dev/null || true
    log_ok "USER.md 权限已恢复为可写（644）"
fi

# ─────────────────────────────────────────────
# 清理 .env 中的 Mem0 变量
# ─────────────────────────────────────────────

log_section "清理 .env 中的 Mem0 变量"

if [[ -f "$BACKUP_DIR/.env.bak" ]]; then
    cp "$BACKUP_DIR/.env.bak" "$ENV_FILE"
    log_ok ".env 已还原至部署前状态"
elif [[ -f "$ENV_FILE" ]]; then
    log_info "无 .env 原始备份，仅移除 Mem0 相关变量..."
    local_tmpfile=$(mktemp)
    grep -v '^MEM0_' "$ENV_FILE" \
        | grep -v '# MEM0_ISOLATION_MARKER' \
        > "$local_tmpfile" || true
    mv "$local_tmpfile" "$ENV_FILE"
    log_ok ".env 中的 Mem0 变量已清除"
else
    log_info ".env 不存在，跳过"
fi

# ─────────────────────────────────────────────
# 处理 Mem0 数据目录
# 只有显式传入 --purge-data 才会自动删除
# ─────────────────────────────────────────────

log_section "Mem0 数据目录处理"

if [[ -d "$MEM0_DATA_DIR" ]]; then
    DATA_SIZE=$(du -sh "$MEM0_DATA_DIR" 2>/dev/null | awk '{print $1}' || echo "未知")
    echo ""
    log_info "检测到 Mem0 数据目录：$MEM0_DATA_DIR（占用：$DATA_SIZE）"
    log_warn "建议保留（重新部署时数据仍可继续使用）。"
    log_warn "如需自动删除，请使用 --purge-data 参数显式声明。"

    if confirm_destructive "是否删除 Mem0 数据目录？"; then
        MEM0_SNAPSHOT="$PRE_ROLLBACK_BACKUP/mem0_data_snapshot"
        cp -r "$MEM0_DATA_DIR" "$MEM0_SNAPSHOT"
        log_ok "Mem0 数据已快照至：$MEM0_SNAPSHOT"
        rm -rf "$MEM0_DATA_DIR"
        log_ok "Mem0 数据目录已删除"
    else
        log_info "已保留 Mem0 数据目录：$MEM0_DATA_DIR"
    fi
fi

# ─────────────────────────────────────────────
# 回滚完成
# ─────────────────────────────────────────────

echo ""
echo -e "╔══════════════════════════════════════════════════════╗"
echo -e "║                    回滚完成！                        ║"
echo -e "╚══════════════════════════════════════════════════════╝"

cat <<ROLLBACK_SUMMARY

✅ 已还原：config.yaml、SOUL.md、USER.md（如备份中存在）
✅ 已恢复：USER.md 权限为 644（可写）
✅ 已处理：.env 中的 Mem0 变量（还原或清除）
📁 二次备份：$PRE_ROLLBACK_BACKUP
   ├── config.yaml.current   （回滚前的 config.yaml）
   ├── SOUL.md.current        （回滚前的 SOUL.md）
   ├── .env.current           （回滚前的 .env）
   └── mem0_data_snapshot/    （如选择删除数据，此处有快照）

ℹ️  未卸载：mem0ai / PyYAML
   如需卸载，请运行：./uninstall_mem0_isolation.sh

下一步：重启 Hermes Gateway 使配置生效
  hermes gateway stop
  hermes gateway run

如需确认当前生效配置，优先使用：
  hermes config show
（旧版本 Hermes 可改用：hermes config list）

ROLLBACK_SUMMARY
