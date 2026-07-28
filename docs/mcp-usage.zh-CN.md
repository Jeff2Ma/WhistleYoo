# WhistleYoo MCP 使用指南

WhistleYoo 可以把内置 Whistle 实例通过 Model Context Protocol（MCP）提供给
本机 AI Agent。Agent 可以查看抓包会话、读取或修改 Rules 和 Values、发起请求，
也可以控制 WhistleYoo 的代理引擎与系统代理。

MCP 默认关闭，仅监听本机地址 `127.0.0.1`。MCP 工具依赖 Whistle 官方 Local
Agent API，因此需要 Whistle 2.10.7 或更高版本。

## 1. 开启 MCP

1. 打开 WhistleYoo。
2. 点击主窗口左侧、位于“更多设置”之前的 **MCP** 标签页。
3. 勾选 **启用本地 MCP 服务**。
4. 保持 **启用 HTTP 鉴权** 开启，或按需关闭鉴权。
5. 选择访问权限：
   - **只读**：适合日常查询和分析。
   - **完全访问**：允许修改 Rules、Values、插件状态、系统代理及代理引擎。
6. 确认 MCP HTTP 端口，默认地址为 `http://127.0.0.1:8901/mcp`。
7. 点击 **应用**。

如果修改了端口、访问权限或鉴权设置，需要再次点击 **应用** 才会生效。

## 2. 获取 HTTP 配置

MCP 标签页会默认展示当前 HTTP MCP JSON。端口或鉴权开关变化时，展示内容会
实时更新；点击配置右上角的 **复制** 按钮即可复制完整内容。

### HTTP（开启鉴权）

HTTP 鉴权默认开启。页面展示的配置会包含当前 Token：

```json
{
  "url": "http://127.0.0.1:8901/mcp",
  "headers": {
    "Authorization": "Bearer <WhistleYoo 生成的 Token>"
  }
}
```

客户端必须发送完全匹配的 `Authorization: Bearer <Token>`。未传 Header、Token
错误或使用其他认证字符串时，服务端会返回 `401 Unauthorized`。

点击 **更新 Token** 会立即生成新 Token 并重启 HTTP MCP 服务，旧 Token 随即
失效。Token 只保存在本机，并使用仅当前用户可读写的文件权限。

### HTTP（关闭鉴权）

取消勾选 **启用 HTTP 鉴权**，再点击 **应用** 后，展示的配置不再
包含 Header：

```json
{
  "url": "http://127.0.0.1:8901/mcp"
}
```

关闭鉴权时，服务端会完全忽略 `Authorization` 字段。因此以下请求都会被接受：

- 不传 `Authorization`；
- 传入任意认证字符串；
- 传入错误的 Bearer Token。

服务仍只监听 `127.0.0.1`，但本机任意进程都可以调用。除非客户端无法配置
Header，否则建议保持鉴权开启。

## 3. 推荐使用方式

首次接入时，建议先使用 **只读**，让 Agent 完成连接检查：

```text
调用 WhistleYoo 的 app_get_status，确认 MCP、Whistle 引擎和系统代理状态。
然后调用 network_get_status，告诉我当前抓包服务是否正常。
```

`app_get_status` 会同时返回实际检测到的 Node、Whistle 版本和可执行文件路径，
以及 MCP 要求的最低 Whistle 版本。版本不满足要求时，错误响应也会包含检测版本
和路径，便于判断是否命中了旧的 `w2` 或另一套 Node 环境。

分析抓包记录时可以这样描述：

```text
使用 WhistleYoo MCP 获取最近的网络会话，找出状态码为 4xx 或 5xx 的请求，
按域名汇总，并分析失败原因。不要修改 Rules 或 Values。
```

需要修改规则时，再切换到 **完全访问**，并明确要求 Agent 先读取后修改：

```text
先调用 rules_get_list 检查现有规则。新增一条名为 debug-api 的规则，
内容为 api.example.com log://，启用它，并再次读取规则确认结果。
```

完成修改后，建议把访问权限切回 **只读**。

## 4. 权限与数据保护

**只读** 允许读取数据，以及安全的应用状态查询和启动操作。标记为破坏性
或会改变配置的工具会被拒绝。

**完全访问** 额外允许：

- 发起或中止网络请求；
- 新增、启用、停用和调整 Rules；
- 新增 Values；
- 修改插件启用状态；
- 开关系统代理；
- 停止或重启代理引擎；
- 调用其他会改变 Whistle 状态的工具。

返回结果默认会隐藏 Authorization、Cookie、Token 等敏感字段。较大的字符串
默认截断为 32 KiB，可通过 `maxBodyBytes` 调整，最大为 256 KiB。只有在
**完全访问** 下显式传入 `includeSensitive: true`，才会返回未隐藏的敏感内容。

## 5. 常用工具

工具名称与 Whistle 官方 JavaScript API 对齐，并转换为 MCP 常用的
snake_case 格式。例如：

| 使用场景 | MCP 工具 | 对应 Whistle API |
| --- | --- | --- |
| 查看应用状态 | `app_get_status` | WhistleYoo 扩展能力 |
| 查看网络状态 | `network_get_status` | `api.network.getStatus()` |
| 获取抓包会话 | `network_get_sessions` | `api.network.getSessions(options)` |
| 获取 Rules 列表 | `rules_get_list` | `api.rules.getList()` |
| 新增 Rule | `rules_add` | `api.rules.add(name, value)` |
| 获取 Values 列表 | `values_get_list` | `api.values.getList()` |
| 新增 Value | `values_add` | `api.values.add(name, value)` |
| 获取插件列表 | `plugins_get_list` | `api.plugins.getList()` |

完整工具和资源清单见 [MCP 接口说明](mcp.md)。

## 6. 可读取资源

除工具外，Agent 还可以读取以下 MCP Resource：

- `whistle://network/status`
- `whistle://root-ca`
- `whistle://network/sessions/{id}`
- `whistle://rules/{name}`
- `whistle://values/{name}`

## 7. 常见问题

### 客户端无法连接 HTTP MCP

依次检查：

1. **启用本地 MCP 服务** 是否已开启并点击 **应用**；
2. 客户端 URL 与 MCP 标签页显示的端口是否一致；
3. 开启鉴权时是否完整复制了 `Authorization` Header；
4. Token 是否在点击 **Rotate token** 后已经变化；
5. 端口是否被其他本机程序占用。

### 返回 `401 Unauthorized`

HTTP 鉴权已开启，但客户端没有携带当前 Bearer Token。重新点击
页面右侧的 **复制** 按钮，使用复制出的完整配置覆盖客户端旧配置。

### 工具提示需要 Full Access

当前处于 **只读**。确认操作风险后，在 WhistleYoo MCP 标签页中切换到
**完全访问** 并点击 **应用**。

### Agent 已连接但无法获取网络数据

先调用 `app_get_status` 和 `network_get_status`，确认 Whistle 引擎正在运行。
如果需要捕获浏览器或其他应用的流量，还要确认相应应用已经使用 Whistle 代理，
或 WhistleYoo 的系统代理已经开启。
