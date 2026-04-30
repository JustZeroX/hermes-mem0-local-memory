#!/usr/bin/env bash
# =============================================================================
# doctor.sh
#
# 作用：
#   1) Hermes 更新后，一键自检本地 Mem0 方案是否仍生效
#   2) 自动修复常见漂移：
#      - 依赖缺失（mem0ai/fastembed/PyYAML）
#      - config.yaml/.env 偏离
#      - mem0 插件被更新覆盖（从本地缓存恢复）
#
# 用法：
#   ./doctor.sh
#   ./doctor.sh --patch-only
#   ./doctor.sh --check-only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 路径自动探测：hermes shebang → HERMES_PYTHON → 上4级 → HERMES_HOME ──
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
        echo "  请手动设置：export HERMES_HOME=/your/hermes/path"; exit 1
    fi
    if [[ ! -x "$HERMES_PYTHON" ]]; then
        echo "[ERROR] Python 解释器不可执行：$HERMES_PYTHON"
        echo "  请手动设置：export HERMES_PYTHON=/path/to/python3"; exit 1
    fi
}

_detect_hermes_paths

CONFIG_FILE="$HERMES_HOME/config.yaml"
ENV_FILE="$HERMES_HOME/.env"
PLUGIN_FILE="$HERMES_AGENT_DIR/plugins/memory/mem0/__init__.py"
PLUGIN_CACHE_FILE="$SCRIPT_DIR/mem0_plugin_patch.py"
BACKUP_DIR="$HERMES_HOME/backups/mem0_selfheal_$(date +%Y%m%d_%H%M%S)"
MEM0_DATA_DIR="$HERMES_HOME/mem0_data"
DEFAULT_EMBEDDER_MODEL="BAAI/bge-small-zh-v1.5"
RESOLVED_EMBEDDER_MODEL="$DEFAULT_EMBEDDER_MODEL"
PERSISTENT_EMBEDDER_MODEL_DIR="$HERMES_HOME/mem0_models/bge-small-zh-v1.5"

PIP_TIMEOUT=120
PIP_RETRIES=10

PATCH_ONLY=false
CHECK_ONLY=false

ensure_rg_available() {
    if command -v rg &>/dev/null; then
        return 0
    fi
    echo "[WARN]  未检测到 rg（ripgrep），尝试通过 Homebrew 自动安装..."
    if command -v brew &>/dev/null; then
        if brew install ripgrep --quiet; then
            echo "[OK]    ripgrep 安装成功"
        else
            echo "[ERROR] ripgrep 安装失败，请手动执行：brew install ripgrep"
            exit 1
        fi
    else
        echo "[ERROR] 未找到 rg（ripgrep），且 Homebrew 不可用"
        echo "[ERROR] 请手动安装：brew install ripgrep"
        echo "[ERROR] 或参考：https://github.com/BurntSushi/ripgrep#installation"
        exit 1
    fi
}

for arg in "$@"; do
  case "$arg" in
    --patch-only) PATCH_ONLY=true ;;
    --check-only) CHECK_ONLY=true ;;
  esac
done

log_info()  { echo "[INFO]  $*"; }
log_ok()    { echo "[OK]    $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*"; }

resolve_embedder_model() {
  if [[ -n "${MEM0_EMBEDDER_MODEL:-}" ]]; then
    RESOLVED_EMBEDDER_MODEL="$MEM0_EMBEDDER_MODEL"
    log_info "检测到外部 MEM0_EMBEDDER_MODEL：$RESOLVED_EMBEDDER_MODEL"
    return 0
  fi

  local candidates=(
    "$PERSISTENT_EMBEDDER_MODEL_DIR"
    "$HOME/.hermes/mem0_models/bge-small-zh-v1.5"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "$c" ]]; then
      RESOLVED_EMBEDDER_MODEL="$c"
      log_ok "检测到本地模型目录：$RESOLVED_EMBEDDER_MODEL"
      return 0
    fi
  done

  RESOLVED_EMBEDDER_MODEL="$DEFAULT_EMBEDDER_MODEL"
  log_warn "未检测到本地中文模型目录，回退为在线模型：$RESOLVED_EMBEDDER_MODEL"
}

ensure_default_embedder_model_download() {
  if [[ -n "${MEM0_EMBEDDER_MODEL:-}" ]]; then
    return 0
  fi
  if [[ "$RESOLVED_EMBEDDER_MODEL" != "$DEFAULT_EMBEDDER_MODEL" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$PERSISTENT_EMBEDDER_MODEL_DIR")"
  if [[ -d "$PERSISTENT_EMBEDDER_MODEL_DIR" ]]; then
    RESOLVED_EMBEDDER_MODEL="$PERSISTENT_EMBEDDER_MODEL_DIR"
    return 0
  fi

  log_info "未检测到本地 embedding 模型，尝试默认下载到：$PERSISTENT_EMBEDDER_MODEL_DIR"
  ensure_pip

  if ! "$HERMES_PYTHON" -m pip show modelscope >/dev/null 2>&1; then
    log_info "安装 modelscope（用于下载模型）..."
    if ! "$HERMES_PYTHON" -m pip install \
      "modelscope>=1.20.0" \
      --timeout "$PIP_TIMEOUT" \
      --retries "$PIP_RETRIES" \
      --quiet; then
      log_warn "modelscope 安装失败，保持在线模型名模式。"
      return 1
    fi
  fi

  if "$HERMES_PYTHON" -m modelscope download \
    --model "$DEFAULT_EMBEDDER_MODEL" \
    --local_dir "$PERSISTENT_EMBEDDER_MODEL_DIR" >/dev/null 2>&1; then
    if [[ -d "$PERSISTENT_EMBEDDER_MODEL_DIR" ]]; then
      RESOLVED_EMBEDDER_MODEL="$PERSISTENT_EMBEDDER_MODEL_DIR"
      log_ok "embedding 模型已下载到：$RESOLVED_EMBEDDER_MODEL"
      return 0
    fi
  fi

  log_warn "模型下载失败，保持在线模型名模式：$DEFAULT_EMBEDDER_MODEL"
  return 1
}

plugin_is_local_ready() {
  local f="$1"
  rg --quiet "Supports two modes:" "$f" \
    && rg --quiet "_build_local_memory_config" "$f" \
    && rg --quiet "_LOCAL_CLIENTS" "$f" \
    && rg --quiet "_get_or_create_shared_local_client" "$f"
}

ensure_pip() {
  if "$HERMES_PYTHON" -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  log_warn "检测到 pip 缺失，尝试 ensurepip..."
  "$HERMES_PYTHON" -m ensurepip --upgrade >/dev/null
  log_ok "pip 安装完成"
}

install_deps() {
  ensure_pip
  "$HERMES_PYTHON" -m pip install \
    "mem0ai>=0.1.0" \
    "fastembed>=0.8.0" \
    "PyYAML>=6.0" \
    --timeout "$PIP_TIMEOUT" \
    --retries "$PIP_RETRIES" \
    --quiet
  log_ok "依赖已就绪：mem0ai / fastembed / PyYAML"
}

sync_config_yaml() {
  "$HERMES_PYTHON" - "$CONFIG_FILE" "$MEM0_DATA_DIR" "$RESOLVED_EMBEDDER_MODEL" <<'PY'
import os, sys
import yaml
path, mem0_path, embedder_model = sys.argv[1], sys.argv[2], sys.argv[3]
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
else:
    cfg = {}
if not isinstance(cfg, dict):
    cfg = {}
if not isinstance(cfg.get("memory"), dict):
    cfg["memory"] = {}
cfg["memory"]["provider"] = "mem0"
cfg["memory"]["user_profile_enabled"] = False
if not isinstance(cfg["memory"].get("settings"), dict):
    cfg["memory"]["settings"] = {}
cfg["memory"]["settings"]["storage_mode"] = "local"
cfg["memory"]["settings"]["storage_path"] = mem0_path
cfg["memory"]["settings"]["embedder"] = "local"
cfg["memory"]["settings"]["embedder_model"] = embedder_model
if not isinstance(cfg.get("tools"), dict):
    cfg["tools"] = {}
disabled = cfg["tools"].get("disabled", [])
if disabled is None:
    disabled = []
elif isinstance(disabled, str):
    disabled = [disabled]
elif not isinstance(disabled, list):
    disabled = []
if "session_search" not in disabled:
    disabled.append("session_search")
cfg["tools"]["disabled"] = list(dict.fromkeys(disabled))
with open(path, "w", encoding="utf-8") as f:
    yaml.dump(cfg, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
print("ok")
PY
  log_ok "config.yaml 已对齐为本地 Mem0 配置"
}

sync_env() {
  touch "$ENV_FILE"
  for kv in \
    "MEM0_STORAGE_MODE=local" \
    "MEM0_STORAGE_PATH=$MEM0_DATA_DIR" \
    "MEM0_EMBEDDER=local" \
    "MEM0_EMBEDDER_MODEL=$RESOLVED_EMBEDDER_MODEL" \
    "MEM0_API_KEY=local-placeholder"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    esc="$(printf '%s' "$val" | sed 's/&/\\&/g')"
    if grep -qE "^(export )?$key=" "$ENV_FILE"; then
      tmp="$(mktemp)"
      sed -E "s|^(export )?$key=.*|$key=$esc|" "$ENV_FILE" > "$tmp"
      mv "$tmp" "$ENV_FILE"
    else
      echo "$key=$val" >> "$ENV_FILE"
    fi
  done
  log_ok ".env 已对齐为本地 Mem0 配置"
}

cache_or_restore_plugin() {
  mkdir -p "$BACKUP_DIR"
  if [[ ! -f "$PLUGIN_FILE" ]]; then
    log_error "插件文件不存在：$PLUGIN_FILE"
    return 1
  fi

  if plugin_is_local_ready "$PLUGIN_FILE"; then
    log_ok "当前 mem0 插件已是本地增强版"
    if [[ ! -f "$PLUGIN_CACHE_FILE" ]]; then
      cp "$PLUGIN_FILE" "$PLUGIN_CACHE_FILE"
      log_ok "已创建插件缓存：$PLUGIN_CACHE_FILE"
    else
      log_info "插件缓存已存在：$PLUGIN_CACHE_FILE"
    fi
    return 0
  fi

  log_warn "检测到插件被更新覆盖（非本地增强版）"
  if [[ ! -f "$PLUGIN_CACHE_FILE" ]]; then
    log_error "缺少缓存文件：$PLUGIN_CACHE_FILE"
    log_error "请先在已修复状态下执行一次本脚本，建立缓存。"
    return 1
  fi

  cp "$PLUGIN_FILE" "$BACKUP_DIR/mem0_plugin.__init__.py.before_restore.bak"
  cp "$PLUGIN_CACHE_FILE" "$PLUGIN_FILE"
  "$HERMES_PYTHON" -m py_compile "$PLUGIN_FILE"
  log_ok "已从缓存恢复本地增强插件"
}

check_status() {
  local ok=true
  if plugin_is_local_ready "$PLUGIN_FILE"; then
    log_ok "插件检查：local + 并发单例补丁存在"
  else
    log_warn "插件检查：未检测到 local/并发补丁"
    ok=false
  fi

  if rg "provider: mem0" "$CONFIG_FILE" >/dev/null 2>&1; then
    log_ok "config.yaml：memory.provider=mem0"
  else
    log_warn "config.yaml：未看到 memory.provider=mem0"
    ok=false
  fi

  if rg "^MEM0_STORAGE_MODE=local$" "$ENV_FILE" >/dev/null 2>&1; then
    log_ok ".env：MEM0_STORAGE_MODE=local"
  else
    log_warn ".env：MEM0_STORAGE_MODE 非 local"
    ok=false
  fi

  if "$HERMES_PYTHON" -c "import mem0, fastembed, yaml; print(mem0.__version__)" >/dev/null 2>&1; then
    log_ok "依赖检查：mem0/fastembed/PyYAML 可导入"
  else
    log_warn "依赖检查失败"
    ok=false
  fi

  if [[ "$ok" == "true" ]]; then
    return 0
  fi
  return 1
}

main() {
  log_info "开始 Mem0 更新后自检/自愈"
  log_info "HERMES_HOME=$HERMES_HOME"
  log_info "HERMES_PYTHON=$HERMES_PYTHON"
  resolve_embedder_model
  log_info "MEM0_EMBEDDER_MODEL(预解析)=$RESOLVED_EMBEDDER_MODEL"

  [[ -d "$HERMES_HOME" ]] || { log_error "目录不存在：$HERMES_HOME"; exit 1; }
  [[ -x "$HERMES_PYTHON" ]] || { log_error "解释器不可执行：$HERMES_PYTHON"; exit 1; }
  ensure_rg_available

  if [[ "$CHECK_ONLY" == "true" ]]; then
    check_status && exit 0 || exit 1
  fi

  cache_or_restore_plugin
  if [[ "$PATCH_ONLY" == "true" ]]; then
    log_ok "仅插件修复模式完成"
    exit 0
  fi

  install_deps
  ensure_default_embedder_model_download || true
  resolve_embedder_model
  log_info "MEM0_EMBEDDER_MODEL(最终)=$RESOLVED_EMBEDDER_MODEL"
  sync_config_yaml
  sync_env
  check_status

  log_ok "自愈完成。建议重启 Gateway："
  echo "  hermes gateway stop"
  echo "  hermes gateway run"
}

main "$@"

