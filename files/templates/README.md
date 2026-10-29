# templates/

给"每个工作区"用的东西。

| 文件 | 用途 |
|---|---|
| `AGENTS.workspace.md` | 工作区级删除规则模板：比全局 `~\.dsh\AGENTS.md` 更具体（多目标传参的坑、`-RepairManifest`、插件被冲掉时的 canary、末尾留了"本工作区补充"栏位） |
| `apply-workspace-rules.ps1` | 把模板装进某个工作区根目录，命名为 `AGENTS.md` |

## 用法

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\templates\apply-workspace-rules.ps1" -Workspace 'D:\proj'
```

- 目标已有 `AGENTS.md` 时**默认拒绝覆盖**；加 `-Force` 会先把它备份成 `AGENTS.md.bak-<时间戳>` 再覆盖。
- 也可以手动拷贝：把 `AGENTS.workspace.md` 复制成 `<工作区>\AGENTS.md`，然后把末尾"本工作区补充"填上。

## 为什么要有它

全局规则（`~\.dsh\AGENTS.md`）保证**任何**工作区都知道"删除只能走 trash、搬完要汇报"；这份模板是给具体工作区加更细的约定用的。不装也不影响功能——拦截是 profile 级的硬拦截，与工作区无关。