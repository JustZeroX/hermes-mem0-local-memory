"""Mem0 记忆插件 — MemoryProvider 接口实现。

支持两种模式：
1) cloud：通过 MemoryClient 调用 Mem0 Platform API（需要真实的 MEM0_API_KEY）
2) local：通过 Memory 使用本地向量库 + 本地 Embedder

环境变量配置：
  MEM0_STORAGE_MODE  — local|cloud（默认：cloud）
  MEM0_STORAGE_PATH  — 本地存储路径（默认：~/.hermes/mem0_data）
  MEM0_EMBEDDER      — local/fastembed/openai/...（默认：local）
  MEM0_EMBEDDER_MODEL — FastEmbed 模型名或本地模型目录（默认：BAAI/bge-small-zh-v1.5）
  MEM0_API_KEY       — Mem0 Platform API Key（cloud 模式必填）
  MEM0_USER_ID       — 用户标识（默认：hermes-user）
  MEM0_AGENT_ID      — Agent 标识（默认：hermes）

仍支持通过 $HERMES_HOME/mem0.json 覆盖单个配置项。
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any, Dict, List

from agent.memory_provider import MemoryProvider
from tools.registry import tool_error

logger = logging.getLogger(__name__)

# 熔断器：连续失败次数超过阈值后，暂停 API 调用一段时间，避免持续打挂服务。
_BREAKER_THRESHOLD = 5
_BREAKER_COOLDOWN_SECS = 120

# 进程级本地客户端缓存。
# Qdrant 本地存储同一时刻只允许一个进程/路径组合持有锁，
# 通过复用同一个客户端实例避免并发时的文件锁冲突。
_LOCAL_CLIENTS: Dict[str, Any] = {}
_LOCAL_CLIENTS_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# 配置加载
# ---------------------------------------------------------------------------

def _load_config() -> dict:
    """从环境变量加载配置，$HERMES_HOME/mem0.json 中的值可覆盖单个字段。

    以环境变量为基础默认值，mem0.json（如存在）只覆盖其中有值的字段，
    避免 JSON 文件存在但缺少 api_key 等字段时发生静默失败。
    """
    from hermes_constants import get_hermes_home

    hermes_home = get_hermes_home()
    default_local_path = str((hermes_home / "mem0_data").resolve())

    config = {
        "storage_mode": os.environ.get("MEM0_STORAGE_MODE", "cloud"),
        "storage_path": os.environ.get("MEM0_STORAGE_PATH", default_local_path),
        "embedder": os.environ.get("MEM0_EMBEDDER", "local"),
        "embedder_model": os.environ.get("MEM0_EMBEDDER_MODEL", "BAAI/bge-small-zh-v1.5"),
        "api_key": os.environ.get("MEM0_API_KEY", ""),
        "user_id": os.environ.get("MEM0_USER_ID", "hermes-user"),
        "agent_id": os.environ.get("MEM0_AGENT_ID", "hermes"),
        "rerank": True,
        "keyword_search": False,
    }
    # 尽力从 config.yaml 的 memory.settings 读取本地模式配置项
    config_yaml = hermes_home / "config.yaml"
    if config_yaml.exists():
        try:
            import yaml

            parsed = yaml.safe_load(config_yaml.read_text(encoding="utf-8")) or {}
            mem = parsed.get("memory", {}) if isinstance(parsed, dict) else {}
            settings = mem.get("settings", {}) if isinstance(mem, dict) else {}
            if isinstance(settings, dict):
                if settings.get("storage_mode"):
                    config["storage_mode"] = settings["storage_mode"]
                if settings.get("storage_path"):
                    config["storage_path"] = settings["storage_path"]
                if settings.get("embedder"):
                    config["embedder"] = settings["embedder"]
                if settings.get("embedder_model"):
                    config["embedder_model"] = settings["embedder_model"]
        except Exception:
            pass

    config_path = hermes_home / "mem0.json"
    if config_path.exists():
        try:
            file_cfg = json.loads(config_path.read_text(encoding="utf-8"))
            config.update({k: v for k, v in file_cfg.items()
                           if v is not None and v != ""})
        except Exception:
            pass

    return config


# ---------------------------------------------------------------------------
# 工具 Schema 定义（description 保留英文，供 LLM 理解）
# ---------------------------------------------------------------------------

PROFILE_SCHEMA = {
    "name": "mem0_profile",
    "description": (
        "Retrieve all stored memories about the user — preferences, facts, "
        "project context. Fast, no reranking. Use at conversation start."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}

SEARCH_SCHEMA = {
    "name": "mem0_search",
    "description": (
        "Search memories by meaning. Returns relevant facts ranked by similarity. "
        "Set rerank=true for higher accuracy on important queries."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "What to search for."},
            "rerank": {"type": "boolean", "description": "Enable reranking for precision (default: false)."},
            "top_k": {"type": "integer", "description": "Max results (default: 10, max: 50)."},
        },
        "required": ["query"],
    },
}

CONCLUDE_SCHEMA = {
    "name": "mem0_conclude",
    "description": (
        "Store a durable fact about the user. Stored verbatim (no LLM extraction). "
        "Use for explicit preferences, corrections, or decisions."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "conclusion": {"type": "string", "description": "The fact to store."},
        },
        "required": ["conclusion"],
    },
}


# ---------------------------------------------------------------------------
# MemoryProvider 实现
# ---------------------------------------------------------------------------

class Mem0MemoryProvider(MemoryProvider):
    """基于 Mem0 的记忆 Provider，支持本地模式和云端模式。"""

    def __init__(self):
        self._config = None
        self._client = None
        self._client_lock = threading.Lock()
        self._api_key = ""
        self._storage_mode = "cloud"
        self._storage_path = ""
        self._embedder = "local"
        self._embedder_model = "BAAI/bge-small-zh-v1.5"
        self._user_id = "hermes-user"
        self._agent_id = "hermes"
        self._rerank = True
        self._prefetch_result = ""
        self._prefetch_lock = threading.Lock()
        self._prefetch_thread = None
        self._sync_thread = None
        # 熔断器状态
        self._consecutive_failures = 0
        self._breaker_open_until = 0.0

    @property
    def name(self) -> str:
        return "mem0"

    def is_available(self) -> bool:
        cfg = _load_config()
        return cfg.get("storage_mode", "cloud") == "local" or bool(cfg.get("api_key"))

    def save_config(self, values, hermes_home):
        """将配置写入 $HERMES_HOME/mem0.json。"""
        import json
        from pathlib import Path
        config_path = Path(hermes_home) / "mem0.json"
        existing = {}
        if config_path.exists():
            try:
                existing = json.loads(config_path.read_text())
            except Exception:
                pass
        existing.update(values)
        config_path.write_text(json.dumps(existing, indent=2))

    def get_config_schema(self):
        return [
            {"key": "api_key", "description": "Mem0 Platform API key（仅 cloud 模式需要）", "secret": True, "required": False, "env_var": "MEM0_API_KEY", "url": "https://app.mem0.ai"},
            {"key": "user_id", "description": "用户标识", "default": "hermes-user"},
            {"key": "agent_id", "description": "Agent 标识", "default": "hermes"},
            {"key": "rerank", "description": "是否启用重排序提升召回精度", "default": "true", "choices": ["true", "false"]},
        ]

    def _get_client(self):
        """线程安全的客户端访问器，延迟初始化。"""
        with self._client_lock:
            if self._client is not None:
                return self._client
            try:
                if self._storage_mode == "local":
                    self._client = self._get_or_create_shared_local_client()
                else:
                    from mem0 import MemoryClient

                    self._client = MemoryClient(api_key=self._api_key)
                return self._client
            except ImportError:
                if self._storage_mode == "local":
                    raise RuntimeError(
                        "本地模式依赖缺失，请执行：pip install mem0ai fastembed"
                    )
                raise RuntimeError("mem0 包未安装，请执行：pip install mem0ai")
            except Exception as e:
                if self._storage_mode == "local":
                    if "already accessed by another instance" in str(e):
                        raise RuntimeError(
                            "Mem0 本地存储已被另一个进程锁定。"
                            "请确保只运行一个 Hermes Gateway 实例，"
                            "或切换到 Qdrant Server 模式以支持多进程并发。"
                        )
                    raise RuntimeError(f"Mem0 本地模式初始化失败：{e}")
                raise

    def _local_client_cache_key(self) -> str:
        """生成本地进程级客户端复用的稳定缓存 Key。"""
        path = str(Path(self._storage_path).resolve())
        embedder = (self._embedder or "local").lower()
        return f"{path}|{embedder}"

    def _get_or_create_shared_local_client(self):
        """每个进程/路径组合只创建一个本地 Memory 客户端，避免文件锁冲突。"""
        key = self._local_client_cache_key()
        with _LOCAL_CLIENTS_LOCK:
            cached = _LOCAL_CLIENTS.get(key)
            if cached is not None:
                return cached

            from mem0 import Memory

            # 提前创建存储目录，避免运行时报晦涩的路径错误
            Path(self._storage_path).mkdir(parents=True, exist_ok=True)
            client = Memory.from_config(self._build_local_memory_config())
            _LOCAL_CLIENTS[key] = client
            return client

    def _build_local_memory_config(self) -> Dict[str, Any]:
        """根据插件配置构建 local Memory() 初始化参数。"""
        # mem0 的 'local' 不是有效的 embedder provider，映射为 fastembed（纯本地推理）
        embedder_provider = (self._embedder or "local").lower()
        if embedder_provider == "local":
            embedder_provider = "fastembed"

        embedder_cfg: Dict[str, Any] = {"provider": embedder_provider, "config": {}}
        if embedder_provider == "fastembed":
            embedder_model = (self._embedder_model or "BAAI/bge-small-zh-v1.5").strip()
            embedder_cfg["config"] = {"model": embedder_model}

        qdrant_config: Dict[str, Any] = {
            "path": self._storage_path,
            "collection_name": "hermes_mem0_local",
        }
        if embedder_provider == "fastembed":
            # 常用模型维度映射；未知模型（含本地目录）交由框架自动推断。
            dims_by_model = {
                "BAAI/bge-small-en-v1.5": 384,
                "BAAI/bge-small-zh-v1.5": 512,
            }
            model_dims = dims_by_model.get(embedder_cfg["config"]["model"])
            if model_dims:
                qdrant_config["embedding_model_dims"] = model_dims

        return {
            "vector_store": {
                "provider": "qdrant",
                "config": qdrant_config,
            },
            "embedder": embedder_cfg,
            # 本地模式写入使用 infer=False，不需要真实 LLM Key；
            # 但 Memory 初始化时仍要求 llm 配置存在，用 placeholder 绕过。
            "llm": {
                "provider": "openai",
                "config": {"api_key": self._api_key or "local-placeholder"},
            },
            "history_db_path": str(Path(self._storage_path) / "history.db"),
        }

    def _is_breaker_open(self) -> bool:
        """熔断器是否已打开（连续失败次数超过阈值）。"""
        if self._consecutive_failures < _BREAKER_THRESHOLD:
            return False
        if time.monotonic() >= self._breaker_open_until:
            # 冷却期结束，重置计数，允许重试
            self._consecutive_failures = 0
            return False
        return True

    def _record_success(self):
        self._consecutive_failures = 0

    def _record_failure(self):
        self._consecutive_failures += 1
        if self._consecutive_failures >= _BREAKER_THRESHOLD:
            self._breaker_open_until = time.monotonic() + _BREAKER_COOLDOWN_SECS
            logger.warning(
                "Mem0 熔断器触发：连续失败 %d 次，暂停 API 调用 %d 秒。",
                self._consecutive_failures, _BREAKER_COOLDOWN_SECS,
            )

    def initialize(self, session_id: str, **kwargs) -> None:
        self._config = _load_config()
        self._storage_mode = str(self._config.get("storage_mode", "cloud")).lower()
        self._storage_path = str(self._config.get("storage_path", "")).strip()
        self._embedder = str(self._config.get("embedder", "local")).strip()
        self._embedder_model = str(
            self._config.get("embedder_model", "BAAI/bge-small-zh-v1.5")
        ).strip()
        self._api_key = self._config.get("api_key", "")
        # 优先使用 Gateway 传入的 user_id 实现多用户隔离；
        # CLI 单用户场景降级为配置/环境变量中的默认值。
        self._user_id = kwargs.get("user_id") or self._config.get("user_id", "hermes-user")
        self._agent_id = self._config.get("agent_id", "hermes")
        self._rerank = self._config.get("rerank", True)
        if self._storage_mode != "local" and not self._api_key:
            logger.warning("Mem0 cloud 模式已激活，但 MEM0_API_KEY 为空。")

    def _read_filters(self) -> Dict[str, Any]:
        """查询过滤器：仅返回当前用户的记忆，实现跨会话召回。"""
        return {"user_id": self._user_id}

    def _write_filters(self) -> Dict[str, Any]:
        """写入过滤器：按用户 + Agent 归因存储。"""
        return {"user_id": self._user_id, "agent_id": self._agent_id}

    @staticmethod
    def _unwrap_results(response: Any) -> list:
        """统一 Mem0 API 响应格式——v2 版本将结果包在 {"results": [...]} 中。"""
        if isinstance(response, dict):
            return response.get("results", [])
        if isinstance(response, list):
            return response
        return []

    def system_prompt_block(self) -> str:
        return (
            "# Mem0 Memory\n"
            f"Active. User: {self._user_id}.\n"
            "Use mem0_search to find memories, mem0_conclude to store facts, "
            "mem0_profile for a full overview."
        )

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if self._prefetch_thread and self._prefetch_thread.is_alive():
            self._prefetch_thread.join(timeout=3.0)
        with self._prefetch_lock:
            result = self._prefetch_result
            self._prefetch_result = ""
        if not result:
            return ""
        return f"## Mem0 Memory\n{result}"

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        if self._is_breaker_open():
            return

        def _run():
            try:
                client = self._get_client()
                results = self._unwrap_results(client.search(
                    query=query,
                    filters=self._read_filters(),
                    rerank=self._rerank,
                    top_k=5,
                ))
                if results:
                    lines = [r.get("memory", "") for r in results if r.get("memory")]
                    with self._prefetch_lock:
                        self._prefetch_result = "\n".join(f"- {l}" for l in lines)
                self._record_success()
            except Exception as e:
                self._record_failure()
                logger.debug("Mem0 预取失败：%s", e)

        self._prefetch_thread = threading.Thread(target=_run, daemon=True, name="mem0-prefetch")
        self._prefetch_thread.start()

    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "") -> None:
        """将当前轮对话异步同步到 Mem0（非阻塞）。"""
        if self._is_breaker_open():
            return

        def _sync():
            try:
                client = self._get_client()
                messages = [
                    {"role": "user", "content": user_content},
                    {"role": "assistant", "content": assistant_content},
                ]
                client.add(
                    messages,
                    **self._write_filters(),
                    infer=(self._storage_mode != "local"),
                )
                self._record_success()
            except Exception as e:
                self._record_failure()
                logger.warning("Mem0 同步失败：%s", e)

        # 等待上一次同步完成后再开始新的
        if self._sync_thread and self._sync_thread.is_alive():
            self._sync_thread.join(timeout=5.0)

        self._sync_thread = threading.Thread(target=_sync, daemon=True, name="mem0-sync")
        self._sync_thread.start()

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        return [PROFILE_SCHEMA, SEARCH_SCHEMA, CONCLUDE_SCHEMA]

    def handle_tool_call(self, tool_name: str, args: dict, **kwargs) -> str:
        if self._is_breaker_open():
            return json.dumps({
                "error": "Mem0 API 暂时不可用（连续多次失败），稍后将自动重试。"
            })

        try:
            client = self._get_client()
        except Exception as e:
            return tool_error(str(e))

        if tool_name == "mem0_profile":
            try:
                memories = self._unwrap_results(client.get_all(filters=self._read_filters()))
                self._record_success()
                if not memories:
                    return json.dumps({"result": "暂无存储的记忆。"})
                lines = [m.get("memory", "") for m in memories if m.get("memory")]
                return json.dumps({"result": "\n".join(lines), "count": len(lines)})
            except Exception as e:
                self._record_failure()
                return tool_error(f"获取记忆失败：{e}")

        elif tool_name == "mem0_search":
            query = args.get("query", "")
            if not query:
                return tool_error("缺少必填参数：query")
            rerank = args.get("rerank", False)
            top_k = min(int(args.get("top_k", 10)), 50)
            try:
                results = self._unwrap_results(client.search(
                    query=query,
                    filters=self._read_filters(),
                    rerank=rerank,
                    top_k=top_k,
                ))
                self._record_success()
                if not results:
                    return json.dumps({"result": "未找到相关记忆。"})
                items = [{"memory": r.get("memory", ""), "score": r.get("score", 0)} for r in results]
                return json.dumps({"results": items, "count": len(items)})
            except Exception as e:
                self._record_failure()
                return tool_error(f"搜索失败：{e}")

        elif tool_name == "mem0_conclude":
            conclusion = args.get("conclusion", "")
            if not conclusion:
                return tool_error("缺少必填参数：conclusion")
            try:
                client.add(
                    [{"role": "user", "content": conclusion}],
                    **self._write_filters(),
                    infer=False,
                )
                self._record_success()
                return json.dumps({"result": "记忆已存储。"})
            except Exception as e:
                self._record_failure()
                return tool_error(f"存储失败：{e}")

        return tool_error(f"未知工具：{tool_name}")

    def shutdown(self) -> None:
        for t in (self._prefetch_thread, self._sync_thread):
            if t and t.is_alive():
                t.join(timeout=5.0)
        with self._client_lock:
            self._client = None


def register(ctx) -> None:
    """将 Mem0 注册为记忆 Provider 插件。"""
    ctx.register_memory_provider(Mem0MemoryProvider())
