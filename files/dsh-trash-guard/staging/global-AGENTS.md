# 全局规则：删除只能走 trash（本机所有 DSH 会话适用）

## 1. 直接删除命令会被硬拦截

本机装了拦截插件 `dsh-trash-guard`（`ctx.tools.guard()` 单调守卫：拒绝后无法翻案、工具根本不会派发）。命令里出现这些词即被拒绝：

`Remove-Item` `del` `erase` `rd /s` `rmdir` `rm` `unlink` `shred` `rimraf` `fs.rm*` `rmSync` `unlinkSync`
`.Delete(` `os.remove` `shutil.rmtree` `git clean` `git rm` `robocopy /MIR` `rsync --delete` `Clear-RecycleBin` `diskpart` …

被拒绝不是故障，是策略：改用下面的 trash 脚本，不要改写命令绕过它。

插件代码装在 profile 自己的 `node_modules` 里（**不依赖任何工作区**），目前覆盖 `desktop` 与 `web` 两个 profile。换新 profile（headless / tui / 新建的）会没有硬拦截，先装一次再干活：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\dsh-trash-guard\install.ps1" -ProfileName <profile名>
```

新建工作区时想要那份"更具体"的规则（多目标传参的坑、`-RepairManifest`、插件失效 canary），把 `~\.dsh\tools\templates\AGENTS.workspace.md` 放到该工作区根目录并命名为 `AGENTS.md`；也可以用同目录的 `apply-workspace-rules.ps1` 一键安装。

## 2. 唯一允许的删除通道

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\trash.ps1" -Path '<目标>' -Purpose '<用途>' -Reason '<为什么删>'
```

- 权威脚本住在 `~/.dsh/tools/`，**任何工作区里都没有副本**；在哪个工作区干活，「待删除」就落在哪个工作区（`-Root` 默认取命令执行时的当前目录）。
- 当前目录不是会话工作区时（例如临时 `cd` 去了别处），加 `-Root '<会话工作区>'` 明确指定。
- 脚本只 `Move-Item`，不删除任何东西；`-Purpose` 与 `-Reason` 必填，会写进 `<Root>\待删除\_manifest.jsonl` 和该批次 `README.md`。
- 一次调用里只搬东西：不要用 `;` `|` `&` 反引号 `$(` 拼接别的命令（拦截器的豁免只给"纯 trash 调用"）。
- 清单 / 还原 / 预演：`-List`、`-Restore -Record <号>`（都跟随同一个 `-Root`）、`-DryRun`；搬运流水按月分片永久归档在 `<Root>\.trash-archive\<年-月>.jsonl`（在「待删除」之外，清空文件夹不丢、旧月份可整月删），用 `-History` 查看（默认当月最近 50 条；`-All` 全部分片、`-Tail 0` 不限条数）。记事本直接看用同名的「人读版」：`待删除\_manifest.txt`（当前在押）与 `.trash-archive\<年-月>.txt`（永久流水），块状排版、带 BOM，中文不乱码。
- **两道闸门**（2026-10-25 起，脚本与拦截插件各拦一次）：① 系统/引导/程序目录、盘符根、`~\.dsh`、以及工作区自身或它的任何上级目录 —— **永久拒绝，没有开关**；② 工作区之外的任何目标 —— 必须加 `-AllowOutsideRoot`，而且**第一次只预演、什么都搬不走**，会打印一次性确认码（默认 30 分钟有效、只对那次的目标集合有效）；把目标念给用户、用户确认后，再加 `-ConfirmCode '<码>'` 重跑才真搬。通配符命中超过 20 项同样拒绝（要显式列出路径）。每次「拦截 / 等待确认 / 已执行」都追加到 `~\.dsh\tools\trash-alerts.log`，体检 `doctor.ps1` 第 [6] 段会读它（"已执行的工作区之外搬运"会报成异常）。

## 3. 搬完必须向用户汇报

表格四项，缺一不可：**原始路径、待删除路径、用途、删除原因**，并说明"最终删除由用户手动完成"。

## 4. 「待删除」只由用户清理

不得删除、清空、移动、覆盖其中的内容，也不得把它当工作文件继续使用（需要就先 `-Restore` 并告知用户）。

## 5. 关掉拦截只有用户能做

改 `~/.dsh/profiles/<profile>/cordis.patch.yml` 里 `trash-guard` 那行为 `disabled: true`，或整段删掉。不要自己改这个文件。

## 6. 习惯层：别把最硬的那道防护关掉

- 日常会话**保持 workspace-write**：工作区之外的写入连 DSH 沙箱都过不去（改文件权限、写告警日志都要单独批准「完全权限」）。只在确知要做什么时一次性批准，用完即回到受限——沙箱是唯一不依赖"脚本守规矩"的一层。
- 不要右键「以管理员身份运行」`trash.cmd` / `doctor.cmd`，也不要给这些脚本常驻管理员权限：闸门管的是"经过本通道"的动作，提权会让系统目录自身的文件权限限制形同虚设。
- 系统盘清理交给 Windows 自带渠道（磁盘清理、`DISM /Online /Cleanup-Image`、应用卸载）——`trash.ps1` 的定位是**工作区专用回收站**，它的受保护路径清单永久拒绝系统/引导/程序目录。
- 体检报「闸门缺失」或「插件是旧版本」不要忽视：护栏被换回旧版了，先按提示重装（`install.ps1 -ProfileName <profile>`）再干活。
- 进不去系统、或 DSH 起不来时的还原：`~\.dsh\tools\offline-restore.ps1`（双击 `offline-restore.cmd`，把「待删除」文件夹拖上去即可）。只搬不删、绝不覆盖；WinRE 里盘符变了就加 `-Map 'C:=D:'`。