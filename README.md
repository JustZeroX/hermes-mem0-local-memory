# hermes-mem0-local

> 为 [Hermes Agent](https://github.com/nikitavoloboev/hermes) 接入飞书机器人时，提供**多用户记忆隔离**的本地部署工具包。

---

## 背景

Hermes Agent 的默认记忆机制是全局共享的。当多个用户共用同一个飞书机器人时，用户 A 的偏好、身份、历史会被用户 B 读取到，造成隐私泄露。

本项目通过以下方式解决这个问题：

- 将 Hermes 的记忆后端切换为 **Mem0 本地模式**（SQLite + Qdrant local + FastEmbed）
- 按飞书 `open_id` 映射为 Mem0 `user_id`，实现每位用户的记忆完全隔离
- 禁用内置的 `session_search` 工具，切断跨用户记忆污染来源
- 在 `SOUL.md` 中注入多用户隔离行为约束作为第二道防线

**方案特点：零源码修改、纯本地运行、可一键回滚。**

---

## 适用场景

- 少于 10 人共用 1 个飞书机器人
- 部署在本地，不希望引入 Docker 或云服务
- 希望保留 Hermes 主要能力，同时避免用户间记忆污染

---

## 文件说明

| 文件 | 说明 |
|---|---|
| `deploy_mem0_isolation.sh` | 一键部署：安装依赖、写入配置、加固安全、验证隔离 |
| `rollback_mem0_isolation.sh` | 回滚至部署前状态（还原配置、恢复权限） |
| `uninstall_mem0_isolation.sh` | 完整卸载：卸载依赖、清理配置、可选删除数据 |
| `mem0_post_update_selfheal.sh` | Hermes 更新后自愈：检测漂移、自动修复配置和插件 |
| `mem0_plugin_local.cached.py` | 本地增强版 mem0 插件缓存（供自愈脚本恢复使用） |

---

## 快速开始

### 1. 前置条件

- macOS / Linux
- 已安装并配置好 [Hermes Agent](https://github.com/nikitavoloboev/hermes)
- 已启动飞书机器人（`hermes gateway run`）
- `rg`（ripgrep）已安装

### 2. 部署

```bash
cd /path/to/hermes-mem0-local
chmod +x *.sh
./deploy_mem0_isolation.sh
```

脚本会自动完成：

1. 检查 mem0 插件是否已打本地模式补丁
2. 备份现有配置（`config.yaml` / `SOUL.md` / `.env` / 插件）
3. 安装依赖：`mem0ai` + `fastembed` + `PyYAML`
4. 写入 `config.yaml`：切换记忆后端、禁用 `session_search`、关闭内置用户画像
5. 写入 `.env`：Mem0 本地模式环境变量（双通道保险）
6. 增强 `SOUL.md`：注入多用户隔离行为约束
7. 执行 smoke test 验证 `user_id` 过滤有效性

### 3. 修改脚本顶部路径

首次使用前，请根据你的实际环境修改脚本顶部「本地配置区」：

```bash
HERMES_HOME="/Users/你的用户名/.hermes"
HERMES_PYTHON="/Users/你的用户名/.hermes/hermes-agent/venv/bin/python3"
```

### 4. 验证部署

```bash
hermes config show
```

必须看到：

```
memory.provider = mem0
tools.disabled  = [session_search]
```

---

## 上线前验收用例

| 用例 | 操作 | 预期 |
|---|---|---|
| 1 | 飞书账号 A 发："我叫小明，我喜欢喝咖啡" | 机器人确认记住 |
| 2 | 飞书账号 B 发："你知道我叫什么吗？" | 机器人不知道 |
| 3 | 飞书账号 B 发："我叫小红，我喜欢喝茶" | 机器人确认记住 |
| 4 | 飞书账号 A 发："你知道其他人叫什么吗？" | 机器人不知道 |
| 5 | 重启 Gateway 后重复用例 2 和 4 | 隔离仍然有效 |

---

## 回滚

```bash
./rollback_mem0_isolation.sh
```

还原 `config.yaml`、`SOUL.md`、`.env`、`USER.md` 权限至部署前状态。Mem0 数据目录默认保留，加 `--purge-data` 参数可自动删除。

---

## Hermes 更新后自愈

Hermes 自身更新可能覆盖 mem0 插件或重置配置，执行以下命令一键检测并修复：

```bash
./mem0_post_update_selfheal.sh
```

可选参数：

- `--check-only`：仅检查状态，不做任何修改
- `--patch-only`：仅恢复 mem0 插件，不动其他配置

---

## 数据存储位置

| 内容 | 路径 |
|---|---|
| Qdrant 向量数据 | `$HERMES_HOME/mem0_data/collection/` |
| 对话历史 DB | `$HERMES_HOME/mem0_data/history.db` |
| 配置备份 | `$HERMES_HOME/backups/mem0_isolation_<时间戳>/` |

定期备份：

```bash
cp -r ~/.hermes/mem0_data ~/hermes_mem0_backup_$(date +%Y%m%d)/
```

---

## 技术实现说明

- **记忆隔离**：Mem0 在写入（`add`）和查询（`search` / `get_all`）时均携带 `user_id` 过滤条件，Qdrant 在 payload 层过滤，不同用户的向量物理上存在同一个 collection 但查询结果完全隔离。
- **无 LLM 抽取**：本地模式使用 `infer=False`，对话原文直接存入向量库，不依赖 OpenAI API。
- **Qdrant 文件锁**：本地 Qdrant 单进程持锁，插件通过进程级单例（`_LOCAL_CLIENTS`）复用同一个客户端实例，避免多协程并发时的锁冲突。
- **FastEmbed**：使用 `BAAI/bge-small-en-v1.5`（384 维），纯本地推理，无需联网。

---

## License

MIT
