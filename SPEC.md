# SPEC：DSH 删除拦截 + 回收站体系（dsh-trash-kit）

本文件是**规格书**，不是"照着敲的命令清单"。宿主升级后路径与 API 都可能变，请按这里的目标与不变量重新适配，并用第 5 节的验收清单证明结果 —— **不要**盲目照抄旧命令。
操作层面的"怎么用"看 `操作手册.md`；接手看 `HANDOFF.md`。

> 修订：2026-10-25（新增受保护路径闸门、两段式确认码、告警日志与体检第 [6] 段、离线救援、中文套装菜单、插件路径检查）

---

## 0. 一句话目标

让"直接删除文件"在一个 DSH 部署里**不可能发生**：所有删除都必须经过 `trash.ps1` 搬进「待删除」，最终删除由**用户手动**完成；
并且让"把系统盘的东西搬进回收站"同样**不可能发生** —— 受保护路径永久拒搬，工作区之外的搬运必须经用户点头。

## 1. 六层职责（谁负责什么）

| 层 | 承载物 | 位置 | 作用 |
|---|---|---|---|
| **拦** | `dsh-trash-guard` 插件（profile 级） | `~/.dsh/profiles/<p>/node_modules/dsh-trash-guard/` + 该 profile 的 `cordis.patch.yml` 装载行 | 用 `ctx.tools.guard()` 单调拒绝两类调用：删除类命令；**回收站调用里的受保护路径** |
| **搬** | `trash.ps1` | `~/.dsh/tools/trash.ps1` | 只 `Move-Item` 到 `<工作区>\待删除\<批次>\<盘符>\<原路径>` |
| **闸** | `trash.ps1` 内的两道闸门 | 同上 | ① 受保护路径**永久拒绝**；② 工作区之外**先预演发确认码**，`-ConfirmCode` 才真搬 |
| **账** | `_manifest.jsonl` / `.txt`、`.trash-archive\<年-月>.jsonl` / `.txt`、各批次 `README.md` | 工作区内 | 机器读 JSONL、人读 TXT、按月分片永久流水 |
| **规** | `~/.dsh/AGENTS.md`（全局，含"习惯层"）＋ 各工作区 `AGENTS.md`（可选模板） | DSH 家目录 / 工作区 | 让每个会话知道"只能走 trash、搬完四项汇报、闸门与确认码、别关沙箱" |
| **查 / 救** | `doctor.ps1` + 计划任务 + `trash-alerts.log` + `offline-restore.ps1` | `~/.dsh/tools/` + 任务计划程序 | 每月体检（含 canary 与告警段）；进不去系统时按清单离线搬回 |

## 2. 硬性不变量（换实现也必须满足）

1. **只搬不删**：`trash.ps1` / `offline-restore.ps1` 里不得出现任何删除调用（`Remove-Item`、`.Delete(`、`rm`、`rmdir`…）。验收 5.2 会数它。
2. **拦截必须单调**：走 `ctx.tools.guard()`（或等价的 pre-execute 拒绝路径），拒绝后不能被后续监听器翻案。
3. **失败不得静默**：拿不到拦截 API 或注册抛错时必须留下可被 doctor 发现的标记（`guard-status.txt`），**不能**只是放行。
4. **脚本必须 UTF-8 with BOM**：Windows PowerShell 5.1 按 ANSI/GBK 读无 BOM 的 `.ps1`，中文会乱码并直接语法报错。
   （例外：`setup.cmd` 是 `.cmd`，**必须 GBK 且无 BOM**，见第 3 节。）
5. **机器格式单一**：`.jsonl` 必须"一行一条 JSON"；人读内容另写 `.txt` / `README.md`；解析失败的行**必须被报出来**，不许静默丢弃。
6. **人读版带 BOM**：`_manifest.txt`、`<年-月>.txt` 首次写入带 BOM，之后追加不带。
7. **幂等**：所有安装/修复动作可反复执行；覆盖任何文件前先备份到 `~/.dsh/tools/backup/`。
8. **不碰用户数据**：除「待删除」与 `.trash-archive` 外不改工作区里任何东西；备份目录只增不减。
9. **「待删除」只由用户清理**：脚本永不删除、清空、移动其中的内容。
10. **受保护路径清单不得删减**：盘符根、系统/引导/程序目录、引导与交换文件、`~\.dsh`、工作区自身及上级，永远拒绝；拒绝必须发生在**任何搬运动作之前**（一件都不搬），并写一条告警。
11. **工作区之外的搬运必须两段式**：第一次只预演、发一次性确认码（默认 30 分钟、绑定那次的目标集合、用掉即作废），拿到 `-ConfirmCode` 才允许真搬；跨卷必须显式警告"= 复制 + 删除源文件"。
12. **告警日志只追加**：`trash-alerts.log` 每次「拦截 / 等待确认 / 已执行」各追加一条；体检必须把"**已执行的工作区之外搬运**"报成**异常**（拦截/等待只提示）。
13. **插件豁免不再无条件**：回收站调用也要过受保护路径检查；解析路径失败时**宁可拒绝**也不能默默放行。
14. **离线救援绝不覆盖**：原路径已存在就跳过并报告；坏行必须报出行号；任何情况下不删除源清单。
15. **空批次只改名不删除**：还原之后只剩空壳的批次文件夹，由 `trash.ps1 -Restore` 与 `offline-restore` 加上 `【空批次】` 前缀做标注 —— **只改名**，里面的 README 等一个不动；清理永远由用户完成。

## 3. 关键实现要点（踩过的坑，别再踩）

- `$record` 与 `[string]$Record` **是同一个变量**（PowerShell 变量名不区分大小写）→ 用 `$entry`。
- 经 `powershell -File` 传多路径时 `-Path 'a','b'` 会被外层拆坏 → 用**裸位置参数** `'a' 'b'`。
- `-DryRun` 不得创建任何目录/文件（连「待删除」根目录也不建）；**闸门不过时同样什么都不建**。
- 日志/报告写入失败**不能**吞掉主输出或改变退出码（尽力而为 + 打印一条注意）。
- **路径判定的顺序**：先 `Get-SafeFullPath` 规范化（剥 `\\?\`/`\\.\`、逐段去尾部点与空格、拒 8.3 短名与 UNC、`GetFullPath` 解析 `..`），再做前缀比较；比较用大小写不敏感 + `\` 边界。
- **PS 5.1 的 `[System.IO.Path]::GetFullPath` 遇到 `*` 会抛 `Illegal characters in path`** → 通配符必须"先展开、后规范化"。
- **守卫返回值有两种形态**：删除词命中 → 对象（套统一话术）；受保护路径 → 字符串（已是完整话术）。`denyReason()` 必须兼容，否则话术出现 `undefined`。
- `setup.cmd` 由 `setup.ps1 -Export` 生成：**GBK(936) 编码 + 开头 `chcp 936`**，且**不能带 BOM**（cmd 会把 BOM 当第一行内容，`@echo off` 失效）。
- 用编辑工具/编辑器改 `.ps1` 会**丢掉 BOM** → 改完必须补 BOM 并用 `Parser::ParseFile` 验一遍。
- `desktop` profile 是 Electron 持有的：CLI 拒绝针对它的 `dsh plugin` 管理请求 → 只能"复制文件 + patch 装载行"。
- 宿主是 **nightly 通道**，插件 API 可能随时变 → 心跳文件 + canary + 行为探针是必须的。
- 计划任务默认三坑：`StartWhenAvailable=False`（错过不补跑）、电池上禁止启动、时限 72 小时。

## 4. 安装（双击，或一条命令）

**双击**：`setup.cmd`（中文菜单：1 安装/修复、2 预演、3 导出回套装、4 只体检；不需要管理员）。

**命令行**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\setup.ps1
```

可选参数：`-DryRun`、`-ProfileName desktop,web`、`-NoTask`、`-ForceRules`、`-Export`（反向：把当前状态刷回套装，并顺带重新生成 `setup.cmd`）。

> 不要直接双击 `.ps1`：资源管理器对它的默认动作是"用记事本打开"，执行策略也不允许直接跑未签名脚本。

**新机器注意**：先让 DSH 启动一次（否则 `~\.dsh\profiles\` 不存在，插件无处可装），或在插件步骤之后带 `-ProfileName` 重跑。

## 5. 验收清单（逐条过）

```powershell
# 5.1 体检全绿（退出码 0）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\doctor.ps1"

# 5.2 只搬不删：脚本里的删除调用数应为 0（两个脚本都要 0）
(Select-String -LiteralPath "$env:USERPROFILE\.dsh\tools\trash.ps1" -Pattern 'Remove-Item|\.Delete\(|rmdir' -AllMatches).Count
(Select-String -LiteralPath "$env:USERPROFILE\.dsh\tools\offline-restore.ps1" -Pattern 'Remove-Item|\.Delete\(|rmdir' -AllMatches).Count

# 5.3 BOM 在：应输出 239,187,191
(([System.IO.File]::ReadAllBytes("$env:USERPROFILE\.dsh\tools\trash.ps1"))[0..2]) -join ','

# 5.4 计划任务
schtasks /Query /TN dsh-trash-guard-doctor /V /FO LIST | Select-String 'Next Run Time|Last Result|下次运行时间|上次运行的结果'

# 5.5 心跳（重启 DSH 之后看；应以 OK 开头）
Get-Content "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-trash-guard\guard-status.txt"
```

**5.6 行为探针 A（删除词）**：在 DSH 会话里让代理执行 `cmd /c del "C:\nope-does-not-exist.txt"`
→ 期望被拒绝并打印「【删除已被本机策略禁用】…」。被放行 = 拦截没生效，先看 5.5 的心跳。

**5.7 行为探针 B（受保护路径，必须是"纯回收站调用"：命令里不要有 `;` `|` `&` 反引号 `$(`）**：
让代理执行 `... trash.ps1 -Path 'C:\Windows' -Purpose x -Reason y`
→ 期望**在脚本运行之前**就被插件拒绝，话术为「【回收站通道：受保护路径】…」；
并且 `~\.dsh\tools\trash-alerts.log` **不新增**记录（新增了就说明是脚本拦的，插件那层没生效）。

**5.8 端到端**：在任意工作区造一个测试文件，让代理用 `trash.ps1` 清理，确认该工作区下出现
`待删除\<批次>\…`、`_manifest.txt` 多一条、`.trash-archive\<年-月>.txt` 多一条；再用 `-Restore` 搬回。

**5.9 闸门验收（离线可做，不依赖 DSH）**：在工作区里造一个假根目录，分别用
`-Path 'C:\Windows'`、`-Path 'C:\'`、`-Path '<工作区上级>'`、`-Path '<工作区>\x' -Root '<假根>'`，
期望分别得到：受保护路径 / 盘符根 / 工作区自身或上级 / 工作区之外（缺 `-AllowOutsideRoot`）四种拒绝，
且**目标一个都没动**；再加 `-AllowOutsideRoot` 应只预演并发码。

**5.10 离线救援验收**：造一个含 `_manifest.jsonl` 的假「待删除」，把记录里的东西搬回去；
期望：`-List` 能列、`-DryRun` 不动、真跑能还原、原路径被占用时**跳过而不覆盖**、`-Map 'C:=D:'` 生效、坏行被报出行号。
再验三条新行为：① 把**某个批次文件夹**当参数（或拖上去）→ 只还原那一批，别的批次纹丝不动；
② **不给路径**（直接双击）→ **只识别并打印候选路径，绝不搬运**（识别顺序：上次用过 → 脚本旁边 → DSH 登记的工作区 → 兜底扫固定盘 ≤3 层）；
③ 还原后空掉的批次文件夹被改名成 `【空批次】<原名>`，**README 等内容仍在**（只改名不删除），改名失败会重试并报出来，且重复跑不会二次改名。

> **注意：用户自己在 cmd / PowerShell / 资源管理器里删东西永远不会被拦**，那是设计如此，不是故障。

## 6. 宿主升级后如何适配

1. 跑 `doctor.ps1`：看 `[4]` 里 `guard-status.txt` 是 `OK`、`FAILED` 还是缺失；再看 `[1]`/`[2]` 的 canary 是否变红。
2. `FAILED` 或缺失 → 大概率是 `ctx.tools.guard` 改名或语义变了。
3. 定位新 API：在 `resources/app.asar` 里搜（用 `@vscode/ripgrep` 的 `rg.exe -a`）`tools/pre-execute`、`guard`；或读 `node_modules/@deepseek-ai/dsh-tools/README.zh.md`。
4. 改 `files\dsh-trash-guard\lib\index.js` → 重跑 `setup.ps1` → 重启 DSH → 重做 5.6 / 5.7 两条探针。
5. 适配完成后跑一次 `setup.ps1 -Export`，让套装等于**新的已验证状态**。

## 7. 关闭 / 卸载

- 临时关闭某个 profile 的拦截：把该 profile `cordis.patch.yml` 里 `trash-guard` 那行改成 `disabled: true`。
- 删除每月体检：`schtasks /Delete /TN dsh-trash-guard-doctor /F`
- 彻底移除：删 `~/.dsh/tools`、各 profile 的 `node_modules\dsh-trash-guard`、各 `cordis.patch.yml` 里的装载行、`~/.dsh/AGENTS.md`。
- 只想停用闸门（不推荐）：不要改代码，改用 Windows 自带工具清系统盘 —— 闸门是永久不变量（第 2 节第 10 条）。

## 8. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 首版：拦截插件 + trash.ps1 + 账本 + 规则 + 体检 + 套装 |
| 2026-10-25 | 闸门一（受保护路径永久拒绝）+ 闸门二（工作区之外两段式确认码）+ 插件路径检查 + 告警日志与体检第 [6] 段 + canary + 离线救援 + 全局"习惯层"规则 + 中文套装菜单 + `操作手册.md`；修 PS 5.1 通配符 bug 与守卫话术 `undefined` bug |