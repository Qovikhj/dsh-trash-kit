# staging/ 是什么

这里放**需要原样写进 DSH 配置目录**的文件，以及一个校验小工具。它们不是运行时依赖，插件运行只需要上一级的 `package.json` 与 `lib\index.js`。

| 文件 | 用途 | 写到哪 |
|---|---|---|
| `global-AGENTS.md` | 全局删除规则（所有 profile、所有工作区自动加载） | `%USERPROFILE%\.dsh\AGENTS.md` |
| `web-cordis.patch.yml` | web profile 的整套 patch：清理掉那份从未生效的 `PreToolUse` 配置（改成 schema 合法的 `hooks: []`），并加上 `trash-guard` 装载行 | `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml` |
| `check-yaml.cjs` | 解析并汇报任一 `cordis.patch.yml` 的结构（条目、是否含 `trash-guard` 行）；运行时自动定位 `yaml`（`DSH_YAML_DIR` → 当前 profile → 兜底 `require('yaml')`） | 只读校验，不写入 |

## 校验

```powershell
node "`$env:USERPROFILE\.dsh\tools\dsh-trash-guard\staging\check-yaml.cjs" ``
  "$env:USERPROFILE\.dsh\tools\dsh-trash-guard\staging\check-yaml.cjs" `
  "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml" "$env:USERPROFILE\.dsh\profiles\web\cordis.patch.yml"
```

（`.cjs` 后缀是必须的：这个目录在 `"type": "module"` 的包里，`.js` 会被当成 ESM，`require` 不可用。）

安装/恢复只用上一级的 `install.ps1`（幂等，逐 profile 运行）。权威副本全部住在 `~/.dsh/tools/`，工作区里不留任何副本。