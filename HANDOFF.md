# 交接书（HANDOFF）：DSH 删除拦截 + 回收站体系

> **给"下一个对话"（或下一个我）看的**：读完这一页就能接着干活，不需要重新摸索。
> 最后更新：**2026-10-25 下午** · 套装位置：**`setup.cmd` 所在的那个 `dsh-trash-kit\` 文件夹**（最初放在桌面上，之后可能被移到别处；脚本与文档全用相对路径，**整体移动不影响功能**）
> 本工作区：`E:\AI\dsh_workplace`

## 0. 一句话现状

**已建成并验证，共六层**：

1. **拦** —— `dsh-trash-guard` 插件（`ctx.tools.guard()` 单调拒绝）：删除类命令 + **回收站调用里的受保护路径**，都在工具派发前拒绝；覆盖 `desktop` / `web` 两个 profile。
2. **搬** —— `trash.ps1` 只 `Move-Item` 到 `<工作区>\待删除\<批次>\<盘符>\<原路径>`，从不删除。
3. **闸** —— 脚本内两道闸门：① 受保护路径**永久拒绝**（盘符根 / 系统·引导·程序目录 / `~\.dsh` / 工作区自身及上级 / 各种写法绕过）；② 工作区之外的东西走**一次性确认码**（先只预演发码，`-ConfirmCode` 才真搬）。
4. **账** —— `_manifest.jsonl`（机器读）+ `_manifest.txt`（人读）+ 各批次 `README.md` + `.trash-archive\<年-月>` 永久流水（按月分片）。
5. **规** —— `~/.dsh/AGENTS.md`（全局，含第 6 节"习惯层"）+ 可选的工作区 `AGENTS.md` 模板。
6. **查/救** —— `doctor.ps1` 七段体检 + 每月计划任务 + `trash-alerts.log` 告警日志 + `offline-restore.ps1`（WinRE / 换机器的离线还原）。

**系统还原点：已开启**（C: 有卷影副本存储关联，已用 1.63 GB / 最大 4 GB）。

## 1. 先读这三个文件（按顺序）

1. `SPEC.md` —— **最重要**：目标、六层职责、15 条硬性不变量、验收清单（含闸门/插件/救援的验收）、宿主升级后怎么适配。
2. `操作手册.md` —— **怎么用**：日常删除、两道闸门、账本、还原、清理「待删除」、体检、套装、排查顺序、命令速查表、已知坑。
3. `~\.dsh\AGENTS.md` —— 全局规则（每个会话自动加载，所以你大概率已经读到了）：唯一通道、四项汇报、闸门与确认码、习惯层。

> 前两份在**套装目录**（`setup.cmd` 所在文件夹）和 **`~\.dsh\tools\`** 各放一份（内容相同，2026-10-25 起）。`~\.dsh\tools\` 那份是给"手上没有套装路径"的会话用的。

## 2. 东西都在哪（速查）

| 什么 | 位置 |
|---|---|
| 唯一删除通道 | `~\.dsh\tools\trash.ps1`（+ `trash.cmd`） |
| 离线救援（只搬不删、绝不覆盖） | `~\.dsh\tools\offline-restore.ps1`（+ `offline-restore.cmd`；把「待删除」文件夹拖上去） |
| 体检 | `~\.dsh\tools\doctor.ps1`（+ `doctor.cmd`）；结论流水 `doctor.log` |
| 告警日志 / 待确认记录 | `~\.dsh\tools\trash-alerts.log` / `trash-pending.json` |
| 拦截插件源码 | `~\.dsh\tools\dsh-trash-guard\`（`lib\index.js` + `install.ps1`） |
| 插件**实际加载**处 | `~\.dsh\profiles\<profile>\node_modules\dsh-trash-guard\` ＋ 该 profile `cordis.patch.yml` 的装载行 |
| 心跳 / 失败标记 | 同上目录 `guard-status.txt`（每次加载写 `OK …` 或 `FAILED …`） |
| 工作区规则模板 | `~\.dsh\tools\templates\AGENTS.workspace.md` + `apply-workspace-rules.ps1` |
| **可搬走套装** | `setup.cmd` 所在的那个文件夹（`dsh-trash-kit\`；可整体移动到任意位置，脚本用相对路径）：`setup.cmd`（中文菜单）/ `setup.ps1` / `SPEC.md` / `操作手册.md` / `README.md` / `HANDOFF.md` / `files\`（18 个文件）/ `kit-manifest.json` |
| 每月体检任务 | Windows 计划任务 `dsh-trash-guard-doctor`（每月 1 号 10:00，异常才弹框） |
| 工作区账本 | `<工作区>\待删除\_manifest.jsonl` + `.txt`、`<工作区>\.trash-archive\<年-月>.jsonl` + `.txt`、各批次 `README.md` |
| 每次覆盖前的备份 | `~\.dsh\tools\backup\<时间戳>-<用途>\` |
| 测试套件（可重跑） | `E:\AI\dsh_workplace\trash-guard-v2\`：脚本闸门 21 项 / 插件 18 项 / `apply()` 回归 11 项 / 离线救援 16 项，外加部署源码暂存 |

## 3. 本轮（2026-10-25）新增了什么 —— 别再用旧知识

- **闸门一（永久拒绝）**：`trash.ps1` 里的 `Get-ProtectedTable` / `Get-BlockReason` / `Get-SafeFullPath` 等函数。禁区：盘符根、各盘符的系统·引导·程序目录（`Windows`、`Program Files*`、`ProgramData`、`Recovery`、`Boot`、`EFI`、`PerfLogs`、`MSOCache`、`Windows.old`、`$Recycle.Bin`、`System Volume Information`、`Config.Msi`、`$WinREAgent`、`Users\Default`）、盘符根上的引导/交换文件、`~\.dsh`、**工作区自身及其上级**。防绕过：`\\?\` 前缀、段尾点/空格、`..`、8.3 短名、UNC、通配符一次命中 >20 项。
- **闸门二（两段式）**：工作区之外必须 `-AllowOutsideRoot`；第一次**只预演、什么都不搬**，打印一次性确认码（`-ConfirmTtlMinutes` 默认 30 分钟、绑定目标集合、用掉即作废，记录在 `trash-pending.json`）；要 `-ConfirmCode` 才真搬；跨卷额外警告"= 复制 + 删除源文件"。
- **插件不再无条件放行**：`checkTrashPaths()` 解析 `-Path` / `-Root`（含逗号多值、裸位置参数写法），命中禁区即在守卫里拒绝。
- **告警 + 体检第 [6] 段**：拦截 / 等待确认 / 已执行都追加进 `trash-alerts.log`；体检把"**已执行的工作区之外搬运**"报成异常（会触发计划任务弹框），拦截只提示。
- **canary**：体检 `[1]` 检查 `trash.ps1` 是否还含 `AllowOutsideRoot` / `ConfirmCode` / `受保护路径` / `trash-alerts.log`；`[2]` / `[4]` 检查插件是否含 `PROTECTED_PATH_RULES` —— 被换回旧版立刻报异常。
- **离线救援**：`offline-restore.ps1|.cmd`：`-List` / `-DryRun` / `-Record` / `-Batch` / `-Map 'C:=D:'`（WinRE 盘符变了），只搬不删、绝不覆盖、坏行报出。
- **离线救援升级（第二轮，2026-10-25 傍晚）**：三种用法 —— 拖「待删除」= 还原全部；**拖某个批次文件夹 = 只还原那一批**（拖得很深也会自动找到批次名）；**不带路径（直接双击）= 只识别、只列路径，绝不搬运**（2026-10-25 用户明确要求去掉"自动还原"）。要还原必须显式给路径。识别顺序：上次用过的位置 → 脚本旁边 → DSH 登记的工作区 → 兜底扫各固定盘 ≤3 层；选过的位置记在脚本旁边的 `offline-restore-last.txt`。还原后剩下的空批次自动加 `【空批次】` 前缀（**只改名、绝不删除**，README 也留着），`trash.ps1 -Restore` 同样会标注；改名失败会**重试 5 次并报出来**（曾经 `catch {}` 静默吞掉，导致一个批次漏标）。新增 `-MarkEmpty` 只做标注、`doctor.ps1` 第 [5] 段会把这些空批次列出来。
  三个踩过的实现坑（改这些文件时注意）：① 函数用 `return , $out` 返回集合时，**调用点不能再套 `@(...)`** —— 会把整个集合当成一个元素，`[string]` 化后变成"一串空格拼接的路径"，候选全废；② 被 `$x = 函数` 捕获的 `Write-Output` 提示语用户根本看不到（会被当成返回值抓走）→ 提示语一律用 `Write-Host`；③ 刚 `Move-Item` 搬完东西就 `Rename-Item` 改名可能瞬时失败（句柄未释放）→ 必须重试 + 报错，不能静默。
- **归档按月分片是设计**：`.trash-archive\<年-月>.jsonl` / `.txt`，每月自动新建一个分片，旧月份可整月删。
- **全局规则**：新增第 6 节"习惯层"（保持 workspace-write、不升权、系统盘交给 Windows 自带工具、canary 不要忽视、离线救援怎么用），并在第 2 节补了"两道闸门"。
- **套装**：`setup.cmd` 菜单改中文且每项带说明（由 `setup.ps1` 的 `$cmdText` 模板生成，**GBK 编码 + 开头 `chcp 936`**，且不能带 BOM）；新增 `操作手册.md`；`-Export` 已把 18 个文件刷到当前状态。
- **顺手修的旧 bug**：PS 5.1 下 `[System.IO.Path]::GetFullPath('...\*')` 会抛 `Illegal characters in path` —— **通配符一直是坏的**；已改成"先展开、后规范化"。

## 4. 硬性不变量（要点；完整表述见 `SPEC.md` 第 2 节）

只搬不删 · 拦截单调 · 失败不静默（心跳 + canary）· `.ps1` 必须 UTF-8 with BOM · JSONL 一行一条且坏行必须报出 · 人读版首次带 BOM · 幂等且覆盖前备份 · 不碰用户数据 · 「待删除」只由用户清理 · **受保护路径清单不得删减** · **工作区之外必须两段式确认** · **告警日志只追加**且"已执行"必须被体检报出 · **离线救援绝不覆盖**。

## 5. 待办 / 未完成

- [ ] **无阻塞项**。可选：
  - [ ] `web` profile 第一次启动时会自己写心跳（在那之前体检显示"还没有 guard-status.txt"属正常）。
  - [ ] 想让插件话术修复在**活进程**里生效 → 下次重启 DSH（拦截本身一直有效，只是话术）。
  - [ ] 想手动建还原点（管理员）：`Checkpoint-Computer -Description "装东西前" -RestorePointType MODIFY_SETTINGS`

## 6. 已知坑（做改动别踩）

- **PowerShell 变量名不区分大小写**：`$record` 与 `[string]$Record` 是同一个变量（赋值会被强制转成字符串）→ 用 `$entry`。
- 经 `powershell -File` 传多个路径：用**裸位置参数** `'a' 'b'`，不要 `-Path 'a','b'`。
- **所有 `.ps1` 必须 UTF-8 with BOM**；**用编辑工具/编辑器改完，BOM 会被剥掉**（本轮因此让套装的 `setup.ps1` 语法错了一次）→ 改完立刻补 BOM，并用 `[System.Management.Automation.Language.Parser]::ParseFile` 验一遍。
- `setup.cmd` 用 **GBK（936）+ 开头 `chcp 936`** 生成，**绝不能加 BOM**（cmd 会把 BOM 当成第一行内容，`@echo off` 直接失效）。
- PS 5.1 的 `GetFullPath` 遇到 `*` 抛异常 → 通配符必须"先展开、后规范化"。
- 插件守卫的返回值有**两种**：删除词命中返回对象（套统一话术），受保护路径返回**字符串**（已是完整话术）——`denyReason()` 必须兼容，否则拒绝话术里会出现 `undefined`（本轮踩过；`test7-guard-apply.mjs` 就是这条的回归测试）。
- **会话日志是多帧 zstd**，Node 的 `zstdDecompressSync` 只解第一帧 → 见 `history\export-session.cjs` 的逐帧解码。
- `desktop` profile 不能用 `dsh plugin` 管理（Electron 持有），只能"复制文件 + patch 装载行"（`install.ps1` 已封装）。
- 宿主走 **nightly 通道**，插件 API 可能随时变 → 心跳文件 + canary + 行为探针三件套必须有。
- 计划任务默认三坑：错过不补跑、电池上禁止启动、时限 72 小时（`setup.ps1` 会自动修正）。
- 在 DSH 沙箱里跑 `setup.ps1` / `doctor.ps1`：查计划任务、写 `~\.dsh` 都可能被拒（doctor 会打印"日志没写成"，不影响结论）→ 请在普通 PowerShell 里跑。
- 搬文件夹时**不能把它作为某个运行进程的当前目录**。
- 拦截只作用于 **DSH 会话里的工具调用**；用户自己在 cmd / 资源管理器里删东西不会被拦，那是设计如此。

## 7. 怎么验证"还好着"（复制粘贴即可）

```powershell
# 体检：结论「正常」即好
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\doctor.ps1"

# 心跳（重启 DSH 之后看；应以 OK 开头）
Get-Content "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-trash-guard\guard-status.txt"

# 闸门告警日志（谁试过搬工作区之外的东西）
Get-Content "$env:USERPROFILE\.dsh\tools\trash-alerts.log"
```

**两条行为探针**（只能在 DSH 会话里做，唯一能证明"真的还拦得住"）：

1. 让代理执行 `cmd /c del "C:\nope-does-not-exist.txt"` → 期望被拒绝并打印「【删除已被本机策略禁用】…」。
2. 让代理跑一条**纯**回收站调用（命令里不要有 `;` `|` `&` 反引号 `$(`）：
   `... trash.ps1 -Path 'C:\Windows' -Purpose x -Reason y`
   → 期望被**插件**拒绝，话术是「【回收站通道：受保护路径】…」，并且 `trash-alerts.log` **不会**新增记录（说明根本没跑到脚本，插件就拦住了）。

## 8. 重装 / 换机器怎么办

1. 把 `dsh-trash-kit` **整个文件夹**拷到新机器（`files\` 与 `kit-manifest.json` 必须齐）。
2. 新机器上**先让 DSH 启动一次**（否则 `~\.dsh\profiles\` 还不存在，插件无处可装；也可以之后带 `-ProfileName` 重跑）。
3. **双击 `setup.cmd` → 选 1**（不需要管理员；菜单与每项说明都是中文）。它会：铺 `~\.dsh\tools` → **把套装根目录的 4 份文档（SPEC / 操作手册 / HANDOFF / README）也铺到 `~\.dsh\tools`** → 逐 profile 装插件 → 写全局规则（不存在才写；已存在则检查"唯一通道 / 插件 / 两道闸门 / 习惯层"四样，缺了会提示 `-ForceRules`）→ 修正计划任务 → 跑完整体检并打印验收清单（含两条行为探针与离线救援自检）。
4. 按屏幕上的验收清单逐条过（重点是"重启 DSH 后看心跳"与两条行为探针）。
5. 之后只要改过 `~\.dsh\tools` 里的东西，就跑一次 **选 3（`-Export`）**，让套装追上现状（否则重装会铺回旧版本；体检 canary 会立刻报「闸门缺失」，不会静默）。

## 9. 把一个对话的上下文带进另一个对话（三条路）

1. **DSH 原生：分叉会话** —— 会话菜单「分叉会话」（`Ctrl+Alt+F`，备用 `Ctrl+Shift+F`），新会话继承本会话上下文。
2. **本交接书**（最省 token）—— 新对话读这一页 + `SPEC.md` + `操作手册.md` 即可接手。
3. **完整记录** —— 会话导出工具 `export-session.cjs` / `export-session.cmd` 原本放在套装的 `history\` 子目录。
   **注意：`history\` 目录与三个搬迁工具（`搬进去.cmd`、`修复工作区路径.cmd`、`move-into-dsh.ps1`）已被用户于 2026-10-25 主动清理** —— 用户确认"没啥用"，**不需要找回、也不要重建**。
   真要导出会话记录时现写一个即可（不复杂：`~\.dsh\sessions\<目录>\<会话id>\session.v4.jsonl.zstd` 是**多帧 zstd**，要逐帧解压再排版）。

> 三者不冲突：**分叉**给你同一个对话接着聊；**交接书**给新对话一份地图；**记录**给不可复现的原始细节。

## 10. 本对话的完整记录

- 上一轮：`history\对话记录-1e788c10-2026-10-24.md`（会话 `session-1e788c10-…`，分叉自 `session-8760a747-…`）。
- 本轮（受保护路径闸门 + 两段式确认 + 离线救援 + 中文菜单 + 操作手册）：导出工具已随 `history\` 一起被清理（需要时按第 9 节现写）；原始日志在 `~\.dsh\sessions\<工作区对应的目录>\<会话id>\session.v4.jsonl.zstd`。