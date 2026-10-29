# dsh-trash-guard

DSH 插件：**单调拒绝**一切直接删除命令，把删除逼进 `trash.ps1`（只搬进「待删除」，从不真正删除）。

## 它拦什么

工具调用的命令文本里出现下列词就拒绝（不区分大小写，命中即拒绝，没有放行开关）：

`Remove-Item` `Clear-Content` `Clear-Disk` `del` `erase` `rmdir` `rd /s` `rd /q` `rm` `unlink`
`shred` `sdelete` `rimraf` `fs.rm/rmSync/rmdir/unlink/remove` `rmSync` `unlinkSync` `removeSync`
`.Delete(` `os.remove/unlink/rmdir` `shutil.rmtree` `.unlink(` `git clean` `git rm`
`robocopy /MIR` `rsync --delete` `truncate -s 0` `Clear-RecycleBin` `Format-Volume` `format C:` `diskpart`

检查的字段：`command`、`input`、`code`、`args[]`（即 shell 类工具的命名字段）。
**不**检查 `write`/`edit` 的正文，所以正常写文件、写含"rm -rf"字样的文档不受影响（除非该文本出现在 shell 命令里）。

唯一豁免：整条命令**只调用** `trash.ps1` / `trash.cmd` 且不含 `;` `|` `&` 反引号 `$(`（防止 `trash.ps1 ...; Remove-Item ...` 这种拼接）。因为 trash 脚本本身只有 `Move-Item`。

## 为什么这样设计

`ctx.tools.guard()` 是 `@deepseek-ai/dsh-tools` 执行流水线里 `tools/pre-execute` 之后的**单调守卫**：返回理由即拒绝，后续监听器无法翻案，工具主体根本不会派发。所以这是硬拦截，不是"提示模型别删"。

> 注意：profile 里 `dsh-hooks` 插件**做不到**这件事——它是 emit-only 事件通知插件，不支持 `PreToolUse`/`permissionDecision` 这类拦停字段（那份配置一直没生效）。真正能拦停的是 `ctx.tools.guard()` / `tools/pre-execute`。

## 装在哪（本机现状）

| 东西 | 位置 |
|---|---|
| 插件源码（权威副本） | `%USERPROFILE%\.dsh\tools\dsh-trash-guard\` ← **不在任何工作区里** |
| 已装载的插件 | `~\.dsh\profiles\desktop\node_modules\dsh-trash-guard\`、`~\.dsh\profiles\web\node_modules\dsh-trash-guard\` |
| 装载行 | 各 profile 自己的 `cordis.patch.yml`（见下） |
| 回收站脚本 | `~\.dsh\tools\trash.ps1`（`-Root` 默认取命令执行时的当前目录，「待删除」因此落在干活的那个工作区） |
| 全局规则 | `~\.dsh\AGENTS.md`（源：`staging\global-AGENTS.md`） |
| 备份 | `~\.dsh\tools\backup\`（改 patch 前的原件） |

```yaml
- insert:
    - id: trash-guard
      name: dsh-trash-guard
```

**没有任何一处依赖工作区**：插件零 import、不读文件；路径常量只是提示文案里的字符串。删掉任何工作区，拦截与恢复能力都不受影响（在押的「待删除」内容当然随该工作区一起没）。

DSH 的配置 HMR 会监视 profile patch 文件，改完通常无需重启（本机实测：追加装载行后立刻生效，未重启）；插件**代码**本身的改动需要重启（HMR 的 `root` 默认为空，只热重载配置）。web profile 的改动在下次 `dsh web` 启动时生效。

## 验证

任选一条（应当被拒绝，且工具不会派发）：

```
Remove-Item "$env:USERPROFILE\nope.txt" -ErrorAction SilentlyContinue
rm -rf /tmp/nope
```

应当放行的：

```
Get-ChildItem "$env:USERPROFILE\.dsh\tools"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\trash.ps1" -Path '...' -Purpose '...' -Reason '...'
```

拒绝提示会给出权威脚本路径，并说明「待删除」默认落在当前目录、必要时用 `-Root` 指定。

## 关掉它

只有用户能决定关掉：把对应 profile 的 `cordis.patch.yml` 里那一行改成 `disabled: true`，或整段删掉。

## 被插件更新冲掉 / 换新 profile

`node_modules/dsh-trash-guard` 是手工放进去的目录，不是 pnpm 依赖：一旦用 DSH 的插件管理（或 `pnpm install`）更新某个 profile 的依赖，它可能被清掉，拦截就静默失效了。`~\.dsh\tools\dsh-trash-guard\` 就是源，重放一遍即可（幂等，重复运行安全；每个 profile 各跑一次）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\dsh-trash-guard\install.ps1" -ProfileName desktop
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\dsh-trash-guard\install.ps1" -ProfileName web
```

参数：`-ProfileName <名字>`（默认 desktop）、`-DryRun`（只看不动）。它会刷新插件文件、在缺少装载行时补上（并先把 patch 备份到 `~\.dsh\tools\backup\`）。