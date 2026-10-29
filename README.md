# dsh-trash-kit —— DSH 的「删除拦截 + 回收站」套装

> **一句话**：让 AI 代理在这台机器上**删不掉东西** —— 它只能把文件搬进工作区的「待删除」，最终删除永远由你手动完成；
> 系统盘、引导文件、程序目录、DSH 自身目录**永久拒搬**；工作区之外的东西要走**一次性确认码**。
>
> 最后更新：2026-10-29 · 适用：Windows 10/11 · Windows PowerShell 5.1 · DSH（nightly 通道）

---

## 1. 解决什么问题

AI 代理帮你干活时，"删除文件"是最危险的一类操作。真实会发生的三种事故：

| 事故 | 后果 |
|---|---|
| 代理直接执行 `rm` / `del` / `Remove-Item` | 文件当场消失，没有账、找不回 |
| 模型理解偏了，把 `C:\Windows`、`C:\Program Files`、盘符根当成"垃圾目录"搬走 | **系统可能开不了机** |
| 删了没记录，事后不知道谁删的、为什么删、还能不能救 | 无法复盘、无法追责 |

这套东西的答案不是"prompt 里叮嘱它别删"（那只是提示，模型可以不听），而是**把删除能力本身拿掉**：

- **直接删除命令根本发不出去**（拦截插件在工具派发前就拒绝）；
- 唯一允许的"删除"是 `trash.ps1`，它**只 `Move-Item`、从不删除**；
- 系统/引导/程序目录**永久拒搬**，没有开关；
- 工作区之外的路径必须**先预演、拿到确认码、再由人确认**才搬；
- 每一次搬运/还原都有台账（机器读 + 人读 + 按月永久归档），随时可 **`-Restore` 搬回原位**；
- 就算系统进不去，还有**离线救援工具**按台账把东西搬回去。

---

## 2. 主要功能

| 能力 | 实现 | 说明 |
|---|---|---|
| **拦截（硬）** | `dsh-trash-guard` 插件（装在每个 DSH profile 的 `node_modules` 里） | 用 `ctx.tools.guard()` 单调拒绝：删除类命令 + **回收站调用里的禁区路径**，都在工具派发前拒绝，拒绝后不可翻案 |
| **唯一删除通道** | `trash.ps1` | 只 `Move-Item` 到 `<工作区>\待删除\<批次>\<盘符>\<原路径>`；`-Purpose`/`-Reason` 必填；**脚本里没有任何删除调用** |
| **闸门一：永久拒绝** | `trash.ps1` 内置 | 盘符根、系统/引导/程序目录、盘符根上的引导与交换文件、`~\.dsh`、**工作区自身及其上级目录**；并挡住 `\\?\` 前缀、段尾点/空格、`..`、8.3 短名（`PROGRA~1`）、UNC 等写法绕过；通配符一次命中 >20 项也拒 |
| **闸门二：两段式确认** | `trash.ps1` 内置 | 工作区之外的路径必须加 `-AllowOutsideRoot`；第一次只预演、打印**一次性确认码**（默认 30 分钟有效、绑定那次的目标集合），拿到 `-ConfirmCode` 才真搬；跨卷额外警告"= 复制 + 删除源文件" |
| **台账** | `_manifest.jsonl` / `_manifest.txt` / 批次 `README.md` / `.trash-archive\<年-月>.jsonl` + `.txt` | 机器读 JSONL、人读 TXT（带 BOM）、批次报告含还原命令、按月分片永久归档（清空「待删除」也不丢） |
| **还原** | `trash.ps1 -Restore` · `offline-restore.ps1` | 前者适合系统能进；后者**不依赖 DSH**，可在 WinRE / 另一台机器上按台账搬回，只搬不删、**绝不覆盖** |
| **空批次标注** | `-Restore` / `offline-restore` 结束时 | 还原后只剩空壳的批次文件夹会被改名成 `【空批次】<原名>` —— **只改名，绝不删除**，清不清由你决定 |
| **体检** | `doctor.ps1`（六段 + 结论）+ 计划任务 `dsh-trash-guard-doctor` | 脚本可解析/BOM/**闸门 canary**、插件源码、全局规则、各 profile 装载与**心跳**、各工作区账本体积、**闸门告警日志**、结论；每月 1 号 10:00 自动跑，异常才弹框 |
| **告警留痕** | `~\.dsh\tools\trash-alerts.log` + `trash-pending.json` | 每次「拦截 / 等待确认码 / 已执行」都追加一条；体检把**"已执行的工作区之外搬运"报成异常**（要你过目），拦截只提示 |
| **规则** | `~\.dsh\AGENTS.md`（全局，每个会话自动加载） | 唯一通道、四项汇报、两道闸门与确认码、"习惯层"（别把沙箱关掉等） |
| **套装化** | `setup.cmd` / `setup.ps1` / `files\` / `kit-manifest.json` | 一条命令在新机器复现整套状态；`-Export` 反向把现状刷回套装 |

> 只搬不删是**硬性不变量**：这两个脚本从出现到现在，代码里没有任何 `Remove-Item`、`.Delete(`、`rm`、`rmdir` 调用（体检 `[1]`、SPEC 验收 5.2 都会数它）。

---

## 3. 安装方法

### 前提

- Windows 10/11，Windows PowerShell 5.1（不需要 PowerShell 7、**不需要管理员**）；
- **DSH 已安装并启动过至少一次**（否则 `~\.dsh\profiles\` 还不存在，插件无处可装）；
- 在**普通**窗口跑（不要放在 DSH 沙箱里跑：写 `~\.dsh`、查/改计划任务都可能被拒）。

### 双击安装（最省事）

把整个 `dsh-trash-kit` 文件夹拷到目标机器 → **双击 `setup.cmd`** → 选 `1`：

```
  [1] 安装 / 修复（默认）
      把工具铺到 C:\Users\<你>\.dsh\tools，逐个 profile 装拦截插件，
      检查全局规则和每月体检的计划任务，最后跑一次完整体检。
      已存在的文件会先备份到 tools\backup\setup-<时间>\ 再覆盖。
  [2] 预演：只报告，不改任何东西
  [3] 把当前状态导出回套装（改过 tools 之后记得跑）
  [4] 只做体检（doctor）
  [0] 退出
```

### 命令行安装

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

| 参数 | 作用 |
|---|---|
| `-DryRun` | 只报告将要做什么，不改任何东西 |
| `-Export` | **反向**：把本机已部署状态刷回套装（`files\` + `kit-manifest.json`），并重新生成 `setup.cmd` |
| `-ProfileName desktop,web` | 只处理指定 profile（缺省自动探测 `~\.dsh\profiles` 下全部） |
| `-NoTask` | 不创建/不修改计划任务 |
| `-ForceRules` | 允许覆盖已存在的 `~\.dsh\AGENTS.md`（覆盖前备份） |

### 它到底装了什么

1. **校验**套装：`files\` 里 18 个文件 + 根目录 4 份文档（`SPEC.md` / `操作手册.md` / `HANDOFF.md` / `README.md`）；
2. **铺** `~\.dsh\tools\`：上述 18 个文件 + 4 份文档（逐个报 `[新增]/[更新]/[不变]`，覆盖前备份到 `~\.dsh\tools\backup\setup-<时间>\`）；
3. **逐 profile 装拦截插件**（复制文件 + 确认 `cordis.patch.yml` 装载行；`desktop` profile 不能用 `dsh plugin` 管理，脚本已封装）；
4. **检查全局规则** `~\.dsh\AGENTS.md`：不存在才写；已存在则检查"唯一通道 / 拦截插件 / 两道闸门 / 习惯层"四样，缺了会提示 `-ForceRules`；
5. **建/修计划任务** `dsh-trash-guard-doctor`（每月 1 号 10:00，`-Quiet -Notify`；顺带修正"错过不补跑 / 电池禁止启动 / 时限 72 小时"三坑）；
6. **跑全量体检**并打印**验收清单**（含两条行为探针与离线救援自检）。

### 装完请过一遍验收清单

- [ ] 体检结论「正常」（`[1][2][4]` 段的**闸门 canary** 全绿）；
- [ ] **重启一次 DSH**，`~\.dsh\profiles\<profile>\node_modules\dsh-trash-guard\guard-status.txt` 应以 `OK` 开头；
- [ ] 在 DSH 会话里做**行为探针 A**：让代理执行 `cmd /c del "C:\nope-does-not-exist.txt"` → 应被拒绝；
- [ ] 在 DSH 会话里做**行为探针 B**（纯回收站调用，命令里不要有 `;` `|` `&`）：
      `… trash.ps1 -Path 'C:\Windows' -Purpose x -Reason y` → 应**在脚本运行前**被插件拒绝，话术是「【回收站通道：受保护路径】…」；
- [ ] 双击 `~\.dsh\tools\offline-restore.cmd` → 应只"识别并列出「待删除」路径"，**不搬任何东西**。

---

## 4. 使用方法

### 4.1 让代理删东西（它只能用这一条通道）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\trash.ps1" `
  -Path '<目标>' -Purpose '<这文件是做什么用的>' -Reason '<为什么要删>'
```

- 多目标用**裸位置参数**：`-Path 'a.txt' 'b.log'`（别写 `-Path 'a','b'`，经 `-File` 会被拆坏）；
- 不加 `-Root` 时「待删除」落在**命令执行时的当前目录**（代理的工作目录通常是会话工作区）；临时 `cd` 到别处必须带 `-Root '<工作区>'`；
- 加 `-DryRun` 只预演（连「待删除」目录都不建）。

**代理搬完必须给你四项**：原始路径、待删除路径、用途、删除原因，并说明"最终删除由你手动完成"。

### 4.2 你自己删东西

- 你自己的删除命令**不会被拦**（cmd / 资源管理器 / 普通 PowerShell 都一样）——拦截器只作用于 DSH 会话里的工具调用，这是设计如此；
- 想记进同一套台账：双击 `~\.dsh\tools\trash.cmd`，或 `trash.cmd -Path "…" -Purpose "…" -Reason "…"`；
- 系统盘清理**别用**这条通道（会被闸门挡），用磁盘清理 / `DISM /Online /Cleanup-Image` / 应用自带卸载。

### 4.3 什么时候会被"不让搬"

**闸门一（永久拒绝，没有开关）**：盘符根；各盘符下的 `Windows`、`Program Files`、`Program Files (x86)`、`Program Files (ARM)`、`ProgramData`、`Recovery`、`Boot`、`EFI`、`PerfLogs`、`MSOCache`、`Windows.old`、`$Recycle.Bin`、`System Volume Information`、`Config.Msi`、`$WinREAgent`、`Users\Default`；
盘符根上的 `bootmgr`、`BOOTNXT`、`boot.ini`、`ntldr`、`pagefile.sys`、`swapfile.sys`、`hiberfil.sys`、`DumpStack.log.tmp`；
**整个 `~\.dsh`**；以及**本工作区自身或它的任何上级目录**。

**闸门二（两段式）**：目标不在 `-Root` 之下时 —— 不加 `-AllowOutsideRoot` 直接拒；加了也**只预演**，打印确认码：

```text
有 1 个目标在工作区之外 —— 本次只预演，什么都没搬：
  E:\AI\没用  ->  E:\AI\dsh_workplace\待删除\20261026-221335\E\AI\没用
确认码：A1B2-C3D4   （30 分钟内有效，且只对这次的目标集合有效）
请先把上面的目标给用户确认；用户同意后，用同一条命令加 -ConfirmCode 'A1B2-C3D4' 重跑才会真正搬运。
```

把目标清单给人看一眼 → 人点头 → 再用 `-ConfirmCode` 重跑，才真的搬。

### 4.4 看台账

```powershell
# 当前在押（还在「待删除」里的）
… trash.ps1 -Root '<工作区>' -List

# 永久流水（按月分片；默认当月最近 50 条）
… trash.ps1 -Root '<工作区>' -History            # 当月
… trash.ps1 -Root '<工作区>' -History -All        # 所有月份
… trash.ps1 -Root '<工作区>' -History -All -Tail 0   # 不限条数
```

| 文件 | 作用 |
|---|---|
| `<工作区>\待删除\_manifest.jsonl` | 机器读：一行一条 JSON |
| `<工作区>\待删除\_manifest.txt` | 人读版快照（带 BOM，记事本直接看） |
| `<工作区>\待删除\<批次>\README.md` | 批次报告（用途/原因/**现成的还原命令**） |
| `<工作区>\.trash-archive\<年-月>.jsonl` / `.txt` | 永久流水（在「待删除」之外；文件名就是年月，**每月自动新建一个分片**；旧月份可整月删） |

### 4.5 还原

**A. 系统能进 → `trash.ps1 -Restore`**

```powershell
… trash.ps1 -Root '<工作区>' -Restore -Record 23          # 还原 1 条
… trash.ps1 -Root '<工作区>' -Restore -Record 20,21,22    # 多条
… trash.ps1 -Root '<工作区>' -Restore -Batch 20261025-180601  # 整批
```

原路径已被占用会**跳过**（绝不覆盖），并告诉你东西还在哪儿。

**B. 进不去系统 / DSH 起不来 / 换机器 → 离线救援**（不依赖 DSH、不需要管理员）

| 你怎么做 | 结果 |
|---|---|
| 把工作区的**「待删除」文件夹拖到 `offline-restore.cmd` 上** | 还原里面全部 |
| 把「待删除」里的**某个批次文件夹拖上去**（拖得更深也行） | **只还原那一批** |
| **什么都不给，直接双击** | **只识别、只列路径**，不搬任何东西 |
| 命令行（每行都可直接粘进 PowerShell） | 见下方示例 |

```powershell
& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd"                            # 只识别
& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "<工作区>\待删除" -List          # 只列清单
& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "<工作区>\待删除" -DryRun        # 只预演
& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "<工作区>\待删除\<批次>"         # 只还原这一批
& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "D:\待删除" -Map "C:=D:"         # WinRE 里盘符变了
& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "<工作区>\待删除" -MarkEmpty     # 只给空批次加标注
```

> 为什么前面有 `&`：PowerShell 执行"带引号的完整路径"必须用调用运算符 `&`；而且它**不会**在当前目录/PATH 之外找命令，直接敲 `offline-restore.cmd` 会报"无法识别为 cmdlet…"。

### 4.6 清理「待删除」（只有你能做）

代理被规则禁止碰它。建议流程：

1. `-List` 或打开 `待删除\_manifest.txt` 核对；
2. 进 `待删除\<批次>\` 看东西、读同目录 `README.md`；
3. 确认没用后 → **你自己**删掉该批次（或整个「待删除」）；
4. 事后仍可查 `.trash-archive\<年-月>.txt`。

> 看到 **`【空批次】xxx`** 前缀 = 东西都已还原走的空壳（工具只改名、绝不删除），可以直接删。

### 4.7 体检与告警

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\doctor.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\doctor.ps1" -Quiet -Notify   # 计划任务用的
```

六段 + 结论：`[1]` 脚本（可解析/BOM/**闸门 canary**）· `[2]` 插件源码（含路径检查 canary）· `[3]` 全局规则（含"两道闸门/习惯层"canary）· `[4]` 各 profile 装载 + **心跳** · `[5]` 各工作区「待删除」体积与归档 · `[6]` **告警日志与待确认请求** · 结论。
结论「正常」= 都好；任何 `[异常]` 都会让退出码为 1，计划任务会弹框。

### 4.8 改过工具之后：把套装刷回现状

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Export
```

`-Export` 只刷 `files\` 那 18 个文件 + `kit-manifest.json` + `setup.cmd`。**文档以套装根目录那几份为准**（要改就改根目录，装机时会铺到 tools）。

---

## 5. 输入输出示例（均为真实输出节选，你的机器上路径/批次号会不同）

### 5.1 正常搬运

```powershell
> … trash.ps1 -Path 'E:\AI\dsh_workplace\build\old.log' -Purpose '旧构建日志' -Reason '已无参考价值'

已搬入「待删除」（未真正删除），批次 20261029-101500：
「待删除」根目录：E:\AI\dsh_workplace\待删除（不是这里，下次带 -Root）

| # | 原始路径 | 待删除路径 | 类型 | 大小 | 用途 | 删除原因 |
|---|---|---|---|---|---|---|
| 25 | E:\AI\dsh_workplace\build\old.log | E:\AI\dsh_workplace\待删除\20261029-101500\E\AI\dsh_workplace\build\old.log | file | 12.4 KB | 旧构建日志 | 已无参考价值 |

清单：E:\AI\dsh_workplace\待删除\_manifest.jsonl
清单（人读版，记事本直接看）：E:\AI\dsh_workplace\待删除\_manifest.txt
批次报告：E:\AI\dsh_workplace\待删除\20261029-101500\README.md
历史归档：E:\AI\dsh_workplace\.trash-archive\2026-10.jsonl（人读版是同名 .txt）—— 用 -History 查看
```

### 5.2 禁区被脚本拒绝（闸门一）

```powershell
> … trash.ps1 -Path 'C:\Windows' -Purpose 测试 -Reason 测试

拒绝搬运（受保护路径，永久生效、没有开关）：
  受保护路径：C:\Windows（系统目录（Windows）：C:\Windows）

盘符根、系统/引导/程序目录、DSH 家目录永远不由本通道处理。真要清理系统盘，请用 Windows 自带方式
（磁盘清理 / DISM / 应用卸载），或由用户自己在资源管理器里动手。
```

同时会往 `~\.dsh\tools\trash-alerts.log` 追加一条「已拦截」记录。

### 5.3 插件层直接拒绝（命令根本发不出去）

在 DSH 会话里让代理执行 `cmd /c del "C:\nope-does-not-exist.txt"`：

```text
【删除已被本机策略禁用】命令里出现「删除命令 del」：del
本机不允许任何直接删除命令。唯一允许的通道是回收站脚本（只搬家、不删除）：
powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Users\<你>\.dsh\tools\trash.ps1' -Path '<目标>' -Purpose '…' -Reason '…'
…
```

让代理执行一条**纯**回收站调用 `… trash.ps1 -Path 'C:\Windows' -Purpose x -Reason y`：

```text
【回收站通道：受保护路径】这次调用里的路径落在禁区（系统/引导/程序目录）：C:\Windows
系统/引导/程序目录、盘符根、DSH 家目录不许用回收站通道搬运 —— trash.ps1 自己会拒绝，插件这一步先拦下。
真要清理系统盘，请用 Windows 自带方式（磁盘清理 / DISM / 应用卸载），或由用户自己在资源管理器里动手。
工作区之外（但不是禁区）的路径：先不加 -ConfirmCode 跑一次拿确认码，用户确认后再加 -ConfirmCode 重跑。
```

注意区别：这条**不会**在 `trash-alerts.log` 新增记录 —— 说明脚本根本没跑，是插件拦的。

### 5.4 工作区之外：两段式确认（真实历史记录）

```text
[2026-10-26 22:13:18] 等待确认码（工作区之外）
  工作区：E:\AI\dsh_workplace
  结果：只预演，未搬运
  目标：
  - E:\AI\没用
[2026-10-26 22:13:35] 已执行（工作区之外，带确认码）
  工作区：E:\AI\dsh_workplace
  结果：搬运 1 件工作区之外的路径
  明细：
  - E:\AI\没用  ->  E:\AI\dsh_workplace\待删除\20261026-221335\E\AI\没用
```

这次搬运之后，体检 `[6]` 段会把「已执行 1 次」报成**异常**（结论变成 `发现 1 项异常`，退出码 1）—— 这是故意的：

```text
[6] 受保护路径闸门：告警日志与待确认请求
  [OK]   告警日志：拦截 1 次 / 等待确认码 1 次 / 已执行 1 次（…\trash-alerts.log）
  [异常] 有 1 次"工作区之外的搬运"被执行过 —— 请打开日志确认是不是你要的：…\trash-alerts.log
```

看过、确认是你自己要的，就忽略；不确认就按 5.5 还原。

### 5.5 账本与还原

```text
> … trash.ps1 -Root 'E:\AI\dsh_workplace' -List

待删除清单（共 24 条）：E:\AI\dsh_workplace\待删除\_manifest.jsonl

| # | 时间 | 状态 | 原始路径 | 待删除路径 | 大小 | 用途 | 原因 |
|---|---|---|---|---|---|---|---|
| 1 | 2026-10-25 00:30:47 | 已不在待删除（可能已被用户手动清理） | E:\AI\dsh_workplace\trash-test-empty-folder | …\待删除\20261025-003047\E\AI\dsh_workplace\trash-test-empty-folder | 0 B | 通道功能试验 | … |
```

```text
> … trash.ps1 -Root 'E:\AI\dsh_workplace' -Restore -Record 23

已还原：E:\AI\dsh_workplace\待删除\20261025-180601\E\AI\dsh_workplace\rescue-lab2  ->  E:\AI\dsh_workplace\rescue-lab2
清单已更新，记录已标记为「已还原」：E:\AI\dsh_workplace\待删除\_manifest.jsonl
已标注 1 个空批次文件夹（只改名、不删东西）：
  【空批次】20261025-180601
确认没用之后，由你自己删掉这些文件夹。
```

### 5.6 离线救援：只识别（不给路径时绝不搬运）

```text
> & "$env:USERPROFILE\.dsh\tools\offline-restore.cmd"

没有给「待删除」路径 —— 只做识别，不会搬运任何东西。

识别到 2 个「待删除」：
  E:\AI\dsh_workplace\待删除
  E:\AI\dsh_workspace\待删除

要还原：把上面某个文件夹（或它里面的某个批次文件夹）拖到 offline-restore.cmd 上；
或用 -TrashRoot '<路径>' 明确指定。本工具不会自己决定还原什么。
```

### 5.7 体检

```text
== DSH 删除拦截体检   2026-10-25 19:12:58
   工具目录：C:\Users\<你>\.dsh\tools

[1] 权威回收站脚本
  [OK]   trash.ps1 可解析，48166 字节，SHA256 987717FBDC01824F
  [OK]   UTF-8 BOM 在（PowerShell 5.1 读中文必需）
  [OK]   闸门在：提到了 AllowOutsideRoot
  [OK]   闸门在：提到了 ConfirmCode
  [OK]   闸门在：提到了 受保护路径
  [OK]   闸门在：提到了 trash-alerts.log
…
[4] 各 profile 的拦截插件装载
  [OK]   desktop：插件文件在，装载行在
  [OK]   desktop：上次加载正常 —— 2026-10-25T06:49:52.727Z  OK  守卫已注册：删除类命令会被拒绝；回收站调用的受保护路径同样被拒绝
…
== 结论：正常
```

---

## 6. 目录结构

### 套装（`dsh-trash-kit\`，可整体移动，脚本全用相对路径）

```
dsh-trash-kit\
├─ setup.cmd            双击入口（中文菜单，GBK 编码 + chcp 936，不带 BOM）
├─ setup.ps1            总装脚本：安装/修复 · -DryRun · -Export · -NoTask · -ForceRules · -ProfileName
├─ kit-manifest.json    生成时间 / 宿主版本指纹 / 每个文件的 SHA256
├─ README.md            本文件
├─ SPEC.md              规格书：目标、六层职责、15 条硬性不变量、验收清单、宿主升级后如何适配
├─ 操作手册.md           操作层面的一切（两道闸门、台账、还原、体检、套装、排查、速查表、已知坑）
├─ HANDOFF.md           交接书（给"下一个对话"看的一页地图）
└─ files\               要铺到 ~\.dsh\tools\ 的 18 个文件
   ├─ trash.ps1 / trash.cmd                 唯一删除通道（只搬不删）+ 两道闸门
   ├─ doctor.ps1 / doctor.cmd               六段体检 + 双击入口
   ├─ offline-restore.ps1 / offline-restore.cmd  离线救援（只搬不删、绝不覆盖）
   ├─ dsh-trash-guard\                      拦截插件源码 + 幂等安装器 + 规则/校验素材
   └─ templates\                            工作区级规则模板 + 一键安装
```

> `files\` 里只该有上面这 18 项（`setup.ps1` 会按清单校验）。如果看到 `offline-restore-last.txt` 这类**运行时产物**混进来，可以直接删掉，不影响安装 —— 它本来只该出现在 `~\.dsh\tools\`。

### 安装后（`~\.dsh\`）

```
~\.dsh\
├─ AGENTS.md                       全局规则（每个会话自动加载）
├─ tools\
│  ├─ trash.ps1 / trash.cmd        唯一删除通道
│  ├─ doctor.ps1 / doctor.cmd      体检（+ doctor.log）
│  ├─ offline-restore.ps1 / .cmd   离线救援
│  ├─ trash-alerts.log             拦截/等待确认/已执行 的告警日志
│  ├─ trash-pending.json           待确认的搬运请求（一次性确认码）
│  ├─ dsh-trash-guard\             插件源码（install.ps1 用于装到 profile）
│  ├─ templates\                   工作区规则模板
│  ├─ SPEC.md / 操作手册.md / HANDOFF.md / README.md   文档（安装时从套装铺过来）
│  └─ backup\                      每次覆盖前的备份
└─ profiles\<profile>\
   └─ node_modules\dsh-trash-guard\  ← 插件实际加载处（guard-status.txt = 心跳）
```

工作区里新增两样东西：`<工作区>\待删除\`（在押）与 `<工作区>\.trash-archive\`（永久流水）。

---

## 7. 与其它文档的关系

| 文档 | 什么时候看 |
|---|---|
| `README.md`（本文件） | 第一次接触：它解决什么问题、怎么装、怎么用 |
| `操作手册.md` | 日常操作细节：什么时候会被拒、确认码怎么走、怎么还原、怎么排查、速查表 |
| `SPEC.md` | 要改代码/适配新宿主版本时：六层职责、15 条不变量、验收清单 |
| `HANDOFF.md` | 换对话/换人接手时：一页地图（现状、位置、本轮变更、坑） |
| `~\.dsh\AGENTS.md` | 每个 DSH 会话自动加载的规则（不需要人读，但要保证它在） |

---

## 8. 已知限制（避免误解）

- **只拦 DSH 会话里的工具调用**。你自己在 cmd / 资源管理器 / 普通 PowerShell 里删东西**不会**被拦 —— 那是设计如此，不是故障。
- **硬拦截是 DSH 专属**：插件依赖 DSH 的 `ctx.tools.guard()` 与 profile 装载机制。换别的 agent（Claude Code、Cursor、Codex…）时，`trash.ps1` / 台账 / 体检 / 离线救援都能照用，但"命令发不出去"这层要按那个工具的 hook 机制重写，或改用系统权限把它关起来。
- **插件改动要重启 DSH 才生效**（脚本改动立即生效）。
- **回收站调用的豁免是"纯调用"**：命令里出现 `;` `|` `&` 反引号 `$(` 就不算纯调用，可能被删除词规则误伤 → 一次调用只搬东西。
- **跨卷搬运 = 复制 + 删除源文件**（`Move-Item` 的语义），中途失败可能两头不完整；`-AllowOutsideRoot` 预演时会警告。
- **`.ps1` 必须 UTF-8 with BOM**（PS 5.1 否则按 GBK 读中文，直接语法错）；`setup.cmd` / `offline-restore.cmd` 反过来必须 **GBK + 无 BOM**。
- **栅栏不是加密**：确认码是流程闸门（防手滑、强制人点头、留痕），不是密码学屏障；真正的硬拦是闸门一 + 插件 + DSH 沙箱。
- **不会替你清理「待删除」**：只有你能删；`【空批次】` 只是标注。
- 宿主走 **nightly** 通道，插件 API 可能变 —— 所以有心跳、canary 和行为探针三件套（体检会先发现）。

---

## 9. 备份与回滚

| 你想要的 | 怎么做 |
|---|---|
| 撤销一次覆盖（工具文件） | `~\.dsh\tools\backup\<时间戳>-<用途>\` 里就是被覆盖前的原件，拷回原位即可 |
| 把某次搬运的东西搬回原位 | `trash.ps1 -Root '<工作区>' -Restore -Record <号>`，或离线救援（见 4.5） |
| 系统进不去时救文件 | WinRE / 另一台机器 + `offline-restore.cmd`（把 `.cmd` 和 `.ps1` 一起拷到 U 盘） |
| 系统本身坏了 | 系统还原点 / WinRE 的"系统还原"（本工具只保证"文件被搬走"可还原） |
| 拦截层被改坏了 | `doctor.ps1` 的 canary 会报；重跑 `setup.cmd` 选 1 即可修复 |

---

## 10. 自测（开发者）

`~\.dsh\tools` 之外的自测套件在开发机工作区里（不属于套装载荷，换机器不需要带）：

| 套件 | 覆盖内容 |
|---|---|
| `test3-gate-final.ps1` | 闸门一/二、正常搬运、通配符闸门、防绕过写法、`-List`/`-Restore`/`-History` |
| `test5-plugin.mjs` | 插件路径判定（`checkTrashPaths`）：禁区命中、合法放行、不误伤理由文本 |
| `test7-guard-apply.mjs` | 守卫整链路（`apply()` 注册 → 假 `exec`）：拒绝话术完整、不出现 `undefined` |
| `test8-rescue-v2.ps1` | 离线救援：拖批次、只识别、绝不覆盖、空批次标注与幂等、盘符映射 |

它们都在**带时间戳的临时实验室目录**里折腾（`test3` / `test8`），或干脆不碰文件（`test5` / `test7` 是纯逻辑单元测试），**不碰工作区里的真实文件**；最近一次运行全部通过。

---

## 11. 许可证

[MIT](LICENSE) © 2026 dsh-trash-kit contributors

简单说：随你怎么用、改、再发布（商业也行），**唯一要求是保留版权声明与许可声明**，且**不提供任何担保**。
如果你要把这份东西装到别人的机器上，把本目录整套拷过去即可（`LICENSE` 会一起带走）。
