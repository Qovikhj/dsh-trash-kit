# 维护者须知（HANDOFF）

> 写给要改这套东西的人 / agent：**只讲结构与铁律，不含任何本机环境信息**。
> 面向使用者 → [`README.md`](README.md)；规格与验收 → [`SPEC.md`](SPEC.md)；日常操作 → [`操作手册.md`](操作手册.md)。

## 1. 六层职责

| 层 | 承载物 | 作用 |
|---|---|---|
| **拦** | `files\dsh-trash-guard\`（插件） | `ctx.tools.guard()` 单调拒绝：删除类命令 + **回收站调用里的禁区路径**，都在工具派发前拒绝 |
| **搬** | `files\trash.ps1` | 只 `Move-Item` 到 `<工作区>\待删除\<批次>\<盘符>\<原路径>`，**从不删除** |
| **闸** | `trash.ps1` 内置 | ① 受保护路径**永久拒绝** ② 工作区之外**两段式确认码** |
| **账** | `_manifest.jsonl` / `_manifest.txt` / 批次 `README.md` / `.trash-archive\<年-月>.*` | 机器读 + 人读（带 BOM）+ 批次报告（含还原命令）+ 按月永久归档 |
| **规** | `~\.dsh\AGENTS.md` + `files\templates\` | 每个会话自动加载：唯一通道、四项汇报、两道闸门、习惯层 |
| **查/救** | `files\doctor.ps1`、`files\offline-restore.ps1` | 六段体检 + 心跳 + 告警日志；不依赖 DSH 的离线还原 |

## 2. 文件地图

```
dsh-trash-kit\
├─ setup.cmd / setup.ps1      总装入口（安装/修复 · -DryRun · -Export · -NoTask · -ForceRules）
├─ kit-manifest.json          生成时间 / 宿主版本指纹 / 每个文件的 SHA256
├─ README.md / SPEC.md / 操作手册.md / HANDOFF.md
└─ files\                     要铺到 ~\.dsh\tools\ 的 18 个文件
   ├─ trash.ps1 / trash.cmd           唯一删除通道 + 两道闸门
   ├─ doctor.ps1 / doctor.cmd          六段体检
   ├─ offline-restore.ps1 / .cmd       离线救援（只搬不删、绝不覆盖）
   ├─ dsh-trash-guard\                 插件源码 + 幂等安装器 + 规则素材
   └─ templates\                       工作区级规则模板 + 一键安装
```

安装后：`~\.dsh\tools\`（脚本 + 4 份文档）、`~\.dsh\profiles\<profile>\node_modules\dsh-trash-guard\`（插件**实际加载处**，`guard-status.txt` 是心跳）、`~\.dsh\AGENTS.md`（全局规则）。

## 3. 五条铁律

1. **只搬不删**：`trash.ps1` / `offline-restore.ps1` 里不得出现任何删除调用（`Remove-Item`、`.Delete(`、`rm`…）。体检 `[1]` 与验收会核对这一点。
2. **拦截单调 + 唯一通道**：删除类命令在派发前被拒；插件豁免只给"**纯** trash 调用"（命令里不能有 `;` `|` `&` 反引号 `$(`）。
3. **两道闸门**：① 受保护路径（盘符根、系统/引导/程序目录、`~\.dsh`、工作区自身及上级）**永久拒绝、没有开关**；② 工作区之外必须 `-AllowOutsideRoot`，且第一次只预演、发一次性确认码（默认 30 分钟、绑定目标集合），拿到 `-ConfirmCode` 才真搬。
4. **失败不静默**：搬运/改名失败要重试并**报出来**，禁止 `catch {}` 吞掉（曾经因此漏标一个空批次）。
5. **台账只追加**：搬运/还原都写 `_manifest.*`，并追加 `.trash-archive\<年-月>.*`；告警写 `trash-alerts.log`，"已执行的工作区之外搬运"必须被体检报成异常。

## 4. 编码与换行（踩过就懂）

| 文件 | 必须 | 否则 |
|---|---|---|
| `.ps1` | **UTF-8 with BOM** | PS 5.1 按 GBK 读中文 → 语法错 |
| `.cmd` | **GBK(936) + 开头 `chcp 936` + 无 BOM** | 中文乱码；带 BOM 会让 `cmd` 解析首行失败 |
| `.md` / `.json` | UTF-8 无 BOM | — |
| 仓库 | `.gitattributes` 已设 `* -text` + `*.cmd binary` | `core.autocrlf=true` 会改坏 GBK 批处理 |

改完 `.ps1` 立刻补 BOM，并用 `[System.Management.Automation.Language.Parser]::ParseFile` 验一遍（编辑工具常会把 BOM 剥掉）。

## 5. 已知坑

1. **多路径传参**：经 `powershell -File` 传 `-Path 'a','b'` 会被拆坏 → 用**裸位置参数** `'a' 'b'`。
2. **集合返回塌缩**：函数 `return , $out` 时，调用点**不能**再套 `@(...)` —— 整个集合会变成一个元素。
3. **被捕获的提示语**：`$x = 函数` 会把函数里的 `Write-Output` 当返回值抓走 → 提示语一律用 `Write-Host`。
4. **改名竞态**：刚 `Move-Item` 搬完就 `Rename-Item` 可能瞬时失败（句柄未释放）→ 重试 3~5 次并报告。
5. **`GetFullPath` 遇通配符**：PS 5.1 上 `[IO.Path]::GetFullPath('*')` 抛错 → 通配符必须"先展开、后规范化"。
6. **守卫返回值有两种类型**：删除词命中返回对象，禁区路径返回**字符串**（已是完整话术）——`denyReason()` 必须兼容，否则话术里出现 `undefined`。
7. **变量名不区分大小写**：`$record` 与 `[string]$Record` 是同一个变量（赋值会被强制转字符串）→ 换个名字。
8. **计划任务三坑**：错过不补跑、电池上禁止启动、时限 72 小时 —— `setup.ps1` 会自动修正。
9. **`desktop` profile 不能用 `dsh plugin`** 管理（Electron 持有），只能"复制文件 + patch 装载行"（`install.ps1` 已封装）。
10. **宿主走 nightly**：插件 API 可能变 → 心跳 + canary + 行为探针三件套必须有。

## 6. 改动流程

1. 改 `~\.dsh\tools\` 里的**权威副本**（不是套装里的）；
2. 在项目根跑 `setup.ps1 -Export` → 刷新 `files\` + `kit-manifest.json` + `setup.cmd`；
3. 按第 7 节自测；
4. 提交。

> 文档以套装根目录那几份为准：要改就改根目录，装机时 `setup.ps1` 会把它们铺到 `~\.dsh\tools\`。

## 7. 怎么验证"还好着"

```powershell
# 体检：结论「正常」即好
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\doctor.ps1"

# 心跳（重启 DSH 之后看；应以 OK 开头）
Get-Content "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-trash-guard\guard-status.txt"

# 闸门告警日志
Get-Content "$env:USERPROFILE\.dsh\tools\trash-alerts.log"
```

**两条行为探针**（只能在 DSH 会话里做，是唯一能证明"真的还拦得住"的手段）：

1. 让代理执行 `cmd /c del "C:\nope-does-not-exist.txt"` → 期望被拒绝并打印「【删除已被本机策略禁用】…」。
2. 让代理跑一条**纯**回收站调用（命令里不要有 `;` `|` `&` 反引号 `$(`）：`… trash.ps1 -Path 'C:\Windows' -Purpose x -Reason y` → 期望被**插件**拒绝（话术「【回收站通道：受保护路径】…」），且 `trash-alerts.log` **不新增**记录（说明脚本根本没跑）。

自测套件（开发工作区里，不随本仓库发布）：`test3-gate-final.ps1`（闸门/还原/历史）、`test5-plugin.mjs`（路径判定）、`test7-guard-apply.mjs`（守卫整链路与话术）、`test8-rescue-v2.ps1`（离线救援）。它们都在带时间戳的临时实验室目录里折腾，不碰真实文件。

## 8. 换机器 / 重装

1. 把 `dsh-trash-kit` **整个文件夹**拷过去（`files\` 与 `kit-manifest.json` 必须齐）；
2. 新机器上**先让 DSH 启动一次**（否则 `~\.dsh\profiles\` 还不存在，插件无处可装）；
3. **双击 `setup.cmd` → 选 1**（不需要管理员）：铺 `~\.dsh\tools` → 装插件 → 检查/写全局规则 → 修正计划任务 → 全量体检 + 验收清单；
4. 按屏幕清单逐条过（重点是"重启后看心跳"与两条行为探针）。

## 9. 适配宿主升级

- 插件用 `ctx.tools.guard()`；若宿主改名/改签名，先看 `cordis.patch.yml` 的装载行有没有报错，再看 `guard-status.txt` 是否以 `OK` 开头。
- 升级后必做：`doctor.ps1` + 两条行为探针；canary 报"闸门缺失"说明脚本或插件被换回旧版，先重装再干活。
- `doctor.ps1` 的 `[1]` 会核对 `trash.ps1` 是否含 `AllowOutsideRoot` / `ConfirmCode` / `受保护路径` / `trash-alerts.log`；`[2]` `[4]` 核对插件是否含禁区规则。