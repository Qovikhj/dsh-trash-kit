# 工作区规则：删除只能走 trash

> 把本文件拷到工作区根目录并改名为 `AGENTS.md` 即可（DSH 会自动加载"项目根 → 会话目录"链上的 AGENTS.md）。
> 工具本体**不在工作区**：权威脚本住在 `~\.dsh\tools\`，拦截插件装在 profile 的 `node_modules` 里——所以删掉本工作区也不会让拦截或删除通道失效。
> 全局那份简版规则在 `~\.dsh\AGENTS.md`，任何工作区都会加载；本文件是它的"更具体版本"。

## 1. 任何直接删除命令都会被硬拦截

`dsh-trash-guard` 插件（`ctx.tools.guard()` 单调守卫：拒绝后无法翻案、工具根本不会派发）会拒绝命令里出现这些词的调用：

`Remove-Item` `del` `erase` `rd /s` `rmdir` `rm` `unlink` `shred` `rimraf` `fs.rm*` `rmSync` `unlinkSync`
`.Delete(` `os.remove` `shutil.rmtree` `git clean` `git rm` `robocopy /MIR` `rsync --delete` `Clear-RecycleBin` `diskpart` …

被拒绝不是故障，是策略：**改用下面的 trash 脚本**，不要试着改写命令绕过它。

如果哪天删除命令**没**被拦（说明插件被 profile 的插件更新冲掉了）：先停止一切删除动作，把这件事告诉用户，并用 `~\.dsh\tools\dsh-trash-guard\install.ps1 -ProfileName <名字>` 放回去（写 profile 需要用户授权）。

## 2. 唯一允许的删除通道：把目标搬进本工作区的「待删除」

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\trash.ps1" `
  -Path '<目标文件或文件夹>' -Purpose '<这东西原本是干什么用的>' -Reason '<为什么要删除>'
```

- 脚本只 `Move-Item`，不删除任何东西；`-Root` 默认取命令执行时的当前目录，所以在本工作区干活时目标自动落进 `<本工作区>\待删除\<批次>\<盘符>\<原始路径>`。
- `-Purpose` 与 `-Reason` 必填，会写进 `<本工作区>\待删除\_manifest.jsonl` 和该批次 `README.md`。
- 一次调用里**只**搬东西，不要用 `;` `|` `&` 反引号 `$(` 拼接别的命令——拦截器的豁免只给"纯 trash 调用"。
- 多目标：给多个位置参数（`... -File trash.ps1 'a.log' 'b.tmp' -Purpose ... -Reason ...`）。注意：只有**直接在当前 PowerShell 进程里调用**才能写 `-Path 'a.log','b.tmp'`；经 `powershell -File` 桥接时，逗号列表会被外层拆坏，必须逐个位置传入。
- 通配符可用，但会被逐个列出。
- 看清单：`-List`（带状态列：在待删除 / 已还原 / 已不在）；搬错了还原：`-Restore -Record <号>` 或 `-Restore -Batch <批次>`；只预演：`-DryRun`；清单格式自检修复：`-RepairManifest`；搬运流水按月分片永久归档在 `<本工作区>\.trash-archive\<年-月>.jsonl`（在「待删除」之外，清空文件夹不丢、旧月份可整月删），用 `-History` 查看（默认当月最近 50 条；`-All` 全部分片、`-Tail 0` 不限条数）。记事本直接看用同名的「人读版」：`待删除\_manifest.txt`（当前在押）与 `.trash-archive\<年-月>.txt`（永久流水），块状排版、带 BOM，中文不乱码。
- 临时 `cd` 到别处、或要给别的工作区落账时，加 `-Root '<那个工作区>'`。

## 3. 搬完必须向用户汇报（这是用户明确要的产出）

用表格给出四项，缺一不可：

| # | 原始路径 | 待删除路径 | 用途 | 删除原因 |
|---|---|---|---|---|
| 1 | `<本工作区>\x.log` | `<本工作区>\待删除\<批次>\<盘符>\...\x.log` | 某次调试留下的日志 | 已无用，且已归档到 … |

另外简要说明：搬运已核验（待删除里在、原位置已空），以及"最终删除由你手动完成"。

## 4. 「待删除」文件夹只由用户清理

- 不得删除、清空、移动、覆盖 `待删除` 里的任何内容（拦截器也会拒绝这类命令）。
- 不得把 `待删除` 里的东西当工作文件继续使用；需要它就先 `-Restore` 搬回去，并告知用户。

## 5. 命令里"提到"删除词也会被拦

例如搜索含 `Remove-Item` 的文档、写含 `rm -rf` 的提交信息。正确做法：改用别的措辞（"移除/清理/归档"），或先问用户；不要拼接命令、不要写个脚本再执行去绕过拦截。

## 6. 真要彻底删除

只有用户能做：他自己在资源管理器里删「待删除」里的内容；或者把 `~\.dsh\profiles\<profile>\cordis.patch.yml` 里 `trash-guard` 那一行改成 `disabled: true` / 删掉该行。**不要**自己改这个文件——拦截的开关只属于用户。

## 7. 本工作区补充（按需填写）

- 这个项目是什么：
- 常用命令（构建 / 测试 / 运行）：
- 其他约定：