# WhistleYoo MCP

WhistleYoo exposes its dedicated Whistle instance to local AI agents through
the Model Context Protocol. MCP is disabled by default and the HTTP server only
binds to `127.0.0.1`.

For a step-by-step Chinese setup and usage guide, see
[WhistleYoo MCP 使用指南](mcp-usage.zh-CN.md).

## Requirements

- WhistleYoo's ordinary app features require Whistle 2.9 or later.
- MCP tools require Whistle 2.10.7 or later because they use Whistle's official
  Local Agent API.

Open the **MCP** tab to enable the server, choose an access mode, and copy a
ready-to-use connection configuration.

## Transports and authentication

Bearer token authentication is enabled by default. With authentication enabled,
the HTTP transport uses:

```text
http://127.0.0.1:8901/mcp
Authorization: Bearer <generated-token>
```

The token is generated locally, stored separately from the portable app
configuration, and protected with owner-only (`0600`) permissions. Rotating it
immediately restarts the HTTP server and invalidates the previous token.

Authentication can be disabled explicitly in the MCP tab. In that mode the server
continues to bind only to `127.0.0.1`, skips authorization checks entirely, and
accepts requests whether the `Authorization` header is missing, valid, invalid,
or contains an arbitrary string. Any process on the Mac can then call the MCP
endpoint, so Bearer token authentication remains the recommended default.

The MCP tab displays the active HTTP connection configuration as JSON. When
authentication is enabled it includes the current Bearer token; use the Copy
button beside the configuration to copy it.

## Access modes

- **Read Only** allows inspection tools and safe app status/start operations.
- **Full Access** additionally allows requests, rule/value/plugin mutations,
  system proxy changes, engine stop/restart, and other tools marked as
  destructive.

Network results redact authorization, cookie, and token-like fields by default.
Large strings are truncated to 32 KiB by default and can be raised to at most
256 KiB with `maxBodyBytes`. In Full Access mode, a caller can explicitly pass
`includeSensitive: true`.

## Naming contract

Tool names are mechanically derived from Whistle's official JavaScript API,
while argument names retain Whistle's camelCase spelling:

| Whistle API | MCP tool |
| --- | --- |
| `api.getRootCA()` | `get_root_ca` |
| `api.network.getSessions(options)` | `network_get_sessions` |
| `api.rules.setMultiSelect(multiSelect)` | `rules_set_multi_select` |
| `api.values.add(name, value)` | `values_add` |
| `api.plugins.getList()` | `plugins_get_list` |

WhistleYoo-only capabilities use the separate `app_*` namespace, including
`app_get_status`, `app_start_engine`, `app_stop_engine`,
`app_restart_engine`, `app_get_system_proxy_status`, and
`app_set_system_proxy`.

`app_get_status` also reports the detected `nodeVersion`, `nodeExecutable`,
`whistleVersion`, `whistleExecutable`, and `mcpMinimumWhistleVersion`. If the
detected Whistle version is too old, MCP refreshes the environment once before
rejecting the request, then includes the detected version and executable path
in the error response.

The complete exposed official surface follows Whistle's namespaces:

- top level: `get_root_ca`, `is_enabled_https`, `set_enable_https`,
  `create_file`, `get_file`
- network: `network_get_status`, `network_get_sessions`,
  `network_save_sessions`, `network_get_saved_sessions`,
  `network_get_frames`, `network_request`, `network_abort`
- rules: `rules_get_status`, `rules_turn_off`, `rules_turn_on`,
  `rules_is_multi_select`, `rules_set_multi_select`,
  `rules_set_later_first`, `rules_get_list`, `rules_add`, `rules_get`,
  `rules_select`, `rules_unselect`, `rules_move_to_top`
- values: `values_get_list`, `values_get`, `values_add`
- plugins: `plugins_get_status`, `plugins_turn_off`, `plugins_turn_on`,
  `plugins_get_list`, `plugins_get`, `plugins_select`, `plugins_unselect`

WhistleYoo intentionally does not invent `delete` or `rename` tools when the
official Local Agent API does not expose corresponding methods.

## Resources

- `whistle://network/status`
- `whistle://root-ca`
- `whistle://network/sessions/{id}`
- `whistle://rules/{name}`
- `whistle://values/{name}`
