/**
 * dsh-trash-guard —— 让「直接删除文件」在这个 DSH 部署里变成不可能。
 *
 * 用 ctx.tools.guard() 注册一个单调守卫：返回理由即拒绝该工具调用，之后的
 * 监听器无法把拒绝重新变成允许（见 @deepseek-ai/dsh-tools 的 tools/pre-execute
 * → 单调守卫流水线）。因此这不是"提示模型别删"，而是调用根本不会派发。
 *
 * 规则：
 *   - 只检查工具调用里的命令文本字段（command / input / code / args[]），
 *     不检查 write/edit 的内容字段，正常写文件不受影响；
 *   - 命中任一删除词即拒绝，并给出唯一的正确做法（trash.ps1）；
 *   - 唯一的豁免是「只调用 trash 脚本、且不含命令拼接符」的调用——因为
 *     trash.ps1 本身只做 Move-Item，从不删除任何东西；
 *   - 但这份豁免不再无条件：回收站调用里的 -Path / -Root 若落在受保护路径上
 *     （系统/引导/程序目录、盘符根、DSH 家目录、UNC、8.3 短名…），照样拒绝，
 *     与 trash.ps1 内部的闸门互为备份（见 checkTrashPaths）；
 *   - 故意不匹配中文「删除」二字：汇报和理由里到处都有它。
 *
 * 只 import Node 内置模块（node:fs / os / path / url）：内置模块不依赖 profile 的
 * 依赖树，所以任何机器上都不会因为解析失败而加载不了。
 */

import { writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const name = 'trash-guard';
export const inject = ['tools'];

/** 权威回收站脚本：住在 DSH 家目录，跟着用户走（换机器/换用户名都不用改代码）。 */
const TRASH_SCRIPT = join(homedir(), '.dsh', 'tools', 'trash.ps1');

/**
 * 心跳 / 失败标记：写在本插件自己的目录里（lib 的上一级），doctor.ps1 每次体检都会读。
 * 这样"插件装了但没挂上"（例如宿主 nightly 更新改了 ctx.tools.guard）就不再是静默失效。
 */
const PACKAGE_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const STATUS_FILE = join(PACKAGE_ROOT, 'guard-status.txt');

function writeStatus(ok, detail) {
  const line = new Date().toISOString() + '  ' + (ok ? 'OK' : 'FAILED') + '  ' + detail + '\n';
  try {
    writeFileSync(STATUS_FILE, line, 'utf8');
  } catch {
    // 状态文件写不进去也不能影响插件加载本身。
  }
}

/** [正则, 标签] —— 命令文本命中任一即拒绝。 */
const RULES = [
  [/\bRemove-Item(Property)?\b/i, 'PowerShell 删除命令 Remove-Item'],
  [/\bClear-Content\b/i, 'PowerShell 清空文件内容 Clear-Content'],
  [/\bClear-Disk\b/i, 'PowerShell 擦除磁盘 Clear-Disk'],
  [/\bdel\b/i, '删除命令 del'],
  [/\berase\b/i, '删除命令 erase'],
  [/\brmdir\b/i, '删除目录命令 rmdir'],
  [/\brd\s+\/[sq]/i, '删除目录命令 rd /s | rd /q'],
  [/\brm\b/i, '删除命令 rm'],
  [/\bunlink\b/i, '删除命令 unlink'],
  [/\bshred\b/i, '粉碎命令 shred'],
  [/\bsdelete\b/i, '粉碎命令 sdelete'],
  [/\brimraf\b/i, '删除库 rimraf'],
  [/\b(fs|fsp|fse|fsExtra|fsPromises)\.(rm|rmdir|unlink|remove)(Sync)?\b/i, 'Node 删除 API'],
  [/\b(rmSync|rmdirSync|unlinkSync|removeSync)\b/i, 'Node 删除 API'],
  [/(::|\.)\s*Delete\s*\(/i, '.NET Delete() 调用'],
  [/\bos\.(remove|unlink|rmdir)\b/i, 'Python 删除 API os.remove/unlink/rmdir'],
  [/\bshutil\.rmtree\b/i, 'Python 删除目录 shutil.rmtree'],
  [/\.unlink\s*\(/i, 'Python unlink() 调用'],
  [/\bgit\s+clean\b/i, 'git clean（删除未跟踪文件）'],
  [/\bgit\s+rm\b/i, 'git rm'],
  [/\brobocopy\b[^\r\n]*\/MIR\b/i, 'robocopy /MIR（镜像会删除目标端多余文件）'],
  [/\brsync\b[^\r\n]*--delete\b/i, 'rsync --delete'],
  [/\btruncate\b[^\r\n]*-s\s*0\b/i, 'truncate -s 0（清空文件）'],
  [/\bClear-RecycleBin\b/i, 'Clear-RecycleBin'],
  [/\bFormat-Volume\b/i, 'Format-Volume 格式化卷'],
  [/\bformat\s+[A-Za-z]:/i, 'format <盘符>: 格式化'],
  [/\bdiskpart\b/i, 'diskpart（可清空磁盘）'],
];

/** 只调用回收站脚本的调用放行（两个脚本自己从不删除东西）。 */
const TRASH_CALL = /trash\.(ps1|cmd)\b/i;
/** 命令拼接符：出现任何一个就不算"只调用 trash"。 */
const CHAINING = /[;|&`]|\$\(/;

/** ---------------------------------------------------------------
 * 方法 2：受保护路径（纵深防御）。
 *
 * trash.ps1 里已经有一道闸门（方法 1），插件这一层的作用是让这种调用
 * "根本发不出去"：回收站调用不再无条件放行 —— 只要 -Path / -Root 的值落在
 * 系统/引导/程序目录、盘符根、DSH 家目录、UNC 或 8.3 短名上，就直接拒绝派发。
 * 两边各拦一次，任何一边单独失效都还有另一边。
 */
const PROTECTED_PATH_RULES = [
  [/[A-Za-z]:[\\/](?:Windows|Program\ Files(?:\ \(x86\)|\ \(ARM\))?|ProgramData|Recovery|Boot|EFI|PerfLogs|MSOCache|Windows\.old|\$Recycle\.Bin|System\ Volume\ Information|Config\.Msi|\$WinREAgent)(?:[\\/]|['"]|,|\s|$)/i, '系统/引导/程序目录'],
  [/[\\/]Users[\\/](?:Default|All\ Users)(?:[\\/]|['"]|,|\s|$)/i, '系统默认用户目录'],
  [/[A-Za-z]:[\\/](?:bootmgr|BOOTNXT|boot\.ini|ntldr|pagefile\.sys|swapfile\.sys|hiberfil\.sys|DumpStack\.log\.tmp)(?:['"]|,|\s|$)/i, '引导/交换文件'],
  [/\.dsh[\\/](?:tools|profiles|sessions|storages|AGENTS\.md)(?:[\\/]|['"]|,|\s|$)/i, 'DSH 家目录（工具/会话/工作区注册表）'],
  [/[A-Za-z]:[\\/][^\\/'"\s,]*~\d/i, '8.3 短名（请写完整长路径）'],
  [/\\\\\?\\/, '\\\\?\\ 前缀路径'],
  [/%SystemRoot%|\$env:SystemRoot/i, '系统目录变量 SystemRoot'],
  [/^[A-Za-z]:[\\/]?['"]?$/, '盘符根目录'],
  [/^[A-Za-z]:[\\/]?\*/, '盘符根通配符'],
  [/^\\\\/, 'UNC/网络路径'],
];

function stripQuotes(token) {
  let t = String(token).trim();
  if (t.length >= 2) {
    const first = t[0];
    const last = t[t.length - 1];
    if ((first === "'" && last === "'") || (first === '"' && last === '"')) t = t.slice(1, -1);
  }
  return t.trim();
}

/**
 * 取出这次回收站调用里"会被当成路径用"的值：-Path / -Root 的值（含逗号分隔的多值），
 * 以及脚本名后面的裸位置参数（trash.ps1 'a' 'b' -Purpose … 那种写法）。
 */
function pathValues(text) {
  const values = [];
  const re = /-(?:Path|Root)\s+((?:'[^']*'|"[^"]*"|[^\s,;|&]+)(?:\s*,\s*(?:'[^']*'|"[^"]*"|[^\s,;|&]+))*)/gi;
  let m;
  while ((m = re.exec(text)) !== null) {
    for (const piece of m[1].split(',')) {
      const v = stripQuotes(piece);
      if (v) values.push(v);
    }
  }
  const tail = text.split(/trash\.(?:ps1|cmd)\b/i).slice(1).join(' ');
  const tokens = tail.match(/'[^']*'|"[^"]*"|\S+/g) || [];
  for (const token of tokens) {
    if (token.charAt(0) === '-') break;
    const v = stripQuotes(token);
    if (v) values.push(v);
  }
  return values;
}

/** 回收站调用命中受保护路径就返回拒绝理由，否则返回 null。 */
export function checkTrashPaths(text) {
  if (typeof text !== 'string' || text === '') return null;
  for (const value of pathValues(text)) {
    for (const rule of PROTECTED_PATH_RULES) {
      const hit = rule[0].exec(value);
      if (hit) {
        return [
          '【回收站通道：受保护路径】这次调用里的路径落在禁区（' + rule[1] + '）：' + value,
          '系统/引导/程序目录、盘符根、DSH 家目录不许用回收站通道搬运 —— trash.ps1 自己会拒绝，插件这一步先拦下。',
          '真要清理系统盘，请用 Windows 自带方式（磁盘清理 / DISM / 应用卸载），或由用户自己在资源管理器里动手。',
          '工作区之外（但不是禁区）的路径：先不加 -ConfirmCode 跑一次拿确认码，用户确认后再加 -ConfirmCode 重跑。',
        ].join('\n');
      }
    }
  }
  return null;
}

/** 取出这次工具调用里可能是"命令"的文本字段。 */
function textsOf(exec) {
  const out = [];
  const args = exec && exec.arguments;
  if (!args || typeof args !== 'object') return out;
  if (typeof args.command === 'string') out.push(args.command);
  if (typeof args.input === 'string') out.push(args.input);
  if (typeof args.code === 'string') out.push(args.code);
  if (Array.isArray(args.args)) {
    for (const token of args.args) {
      if (typeof token === 'string') out.push(token);
    }
  }
  return out;
}

/** 命中一条删除规则就返回它，否则返回 null。 */
function inspect(text) {
  if (typeof text !== 'string' || text === '') return null;
  if (TRASH_CALL.test(text) && !CHAINING.test(text)) {
    // 回收站调用不再无条件放行：先做方法 2 的受保护路径检查。
    return checkTrashPaths(text);
  }
  for (const rule of RULES) {
    const match = rule[0].exec(text);
    if (match) return { label: rule[1], snippet: match[0] };
  }
  return null;
}

function denyReason(hit) {
  // inspect 有两种命中：删除词（对象 {label, snippet}）与回收站禁区路径（已经是完整话术的字符串）。
  // 字符串直接返回——否则会拼出「命令里出现「undefined」」这种废话（2026-10-25 真踩过）。
  if (typeof hit === 'string') return hit;
  const label = hit && hit.label ? hit.label : '禁用的删除写法';
  const snippet = hit && hit.snippet ? hit.snippet : String(hit);
  return [
    '【删除已被本机策略禁用】命令里出现「' + label + '」：' + snippet,
    '本机不允许任何直接删除命令。唯一允许的通道是回收站脚本（只搬家、不删除）：',
    "powershell -NoProfile -ExecutionPolicy Bypass -File '" + TRASH_SCRIPT + "' -Path '<目标>' -Purpose '<这文件是做什么用的>' -Reason '<为什么要删>'",
    "「待删除」默认落在命令执行时的当前目录（通常就是会话工作区）；当前目录不是会话工作区时，加 -Root '<会话工作区>' 指定。",
    '脚本会写清单（原始路径/新路径/大小/用途/原因/时间）。搬完必须向用户汇报：原始路径、待删除路径、用途、删除原因；最终删除由用户手动完成。',
    '若命令只是“提到”删除词（搜索文档、commit message 等），请改写措辞后重试；不要尝试拼接命令或写脚本绕过拦截。',
  ].join('\n');
}

export function apply(ctx) {
  try {
    if (!ctx || !ctx.tools || typeof ctx.tools.guard !== 'function') {
      throw new Error('ctx.tools.guard 不可用（宿主 API 可能已变）');
    }
    ctx.tools.guard((exec) => {
      try {
        for (const text of textsOf(exec)) {
          const hit = inspect(text);
          // 字符串 = 回收站禁区路径的完整话术，直接用；对象 = 删除词命中，套统一话术。
          if (typeof hit === 'string') return hit;
          if (hit) return denyReason(hit);
        }
      } catch {
        // 守卫自身出错时不阻断正常工作流；规则本身仍是单调拒绝。
      }
      return undefined;
    });
    writeStatus(true, '守卫已注册：删除类命令会被拒绝；回收站调用的受保护路径同样被拒绝');
    ctx.logger?.info?.('dsh-trash-guard: 守卫已注册');
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    writeStatus(false, detail);
    ctx.logger?.error?.('dsh-trash-guard: 守卫注册失败：' + detail);
  }
}