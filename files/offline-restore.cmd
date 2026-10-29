@echo off
chcp 936 >nul
rem ============================================================
rem  offline-restore —— 离线救援入口（双击即可，不需要管理员）
rem
rem  作用：把某个工作区「待删除」文件夹里的东西，按里面的清单
rem        （_manifest.jsonl，纯文本）搬回它们原来的位置。
rem  特点：只搬不删；原位置已有东西时跳过，绝不覆盖。
rem        ^*它不会自作主张^*：必须由你把「待删除」（或某个批次）拖上来，
rem        或用 -TrashRoot 指定路径；不给路径时它只识别、只列路径。
rem  什么时候用：DSH 起不来、系统进不去、换机器，或只是想在资源管理器里点两下。
rem
rem  三种用法（都不需要 DSH、不需要管理员）：
rem    1) 把某个工作区的「待删除」文件夹拖到本文件上        -^> 还原里面全部
rem    2) 把「待删除」里的某个批次文件夹拖上来（拖深也行）  -^> 只还原那一批
rem    3) 什么都不给，直接双击                             -^> 只识别：列出本机的「待删除」路径，不搬任何东西
rem  还原完，空掉的批次文件夹会被加「【空批次】」前缀做标注（只改名，里面的东西一个不动）。
rem
rem  命令行用法（下面每行都可以直接复制到 PowerShell 里用；
rem  "..\待删除" 是占位符，换成你自己的路径，例如 "E:\AI\dsh_workplace\待删除"）：
rem    ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd"                                   只识别并列出「待删除」路径
rem    ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除"                        还原这个工作区的全部
rem    ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -List                  只列清单，不搬
rem    ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -DryRun                只预演，不搬
rem    ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除\20261025-122557"        只还原这一个批次
rem    ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -MarkEmpty             只给空批次加标注
rem    ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -Map "C:=D:"           盘符变了（WinRE 里常见）
rem
rem  在 cmd 里也可以（不要前面的 ^&）："%USERPROFILE%\.dsh\tools\offline-restore.cmd" "..\待删除"
rem  本文件用 GBK 编码 + 开头 chcp 936，中文才不会乱码（不要给它加 BOM）。
rem ============================================================
setlocal
title offline-restore 离线救援（把「待删除」里的东西搬回原位）
if "%~1"=="" goto identify
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0offline-restore.ps1" -TrashRoot "%~1" %2 %3 %4 %5 %6
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" goto ok
echo [!] 有需要你注意的地方：退出码 %RC%（请看上面的报告）
echo     常见情况：原位置已被别的文件占用（本工具不会覆盖）、或清单里有坏行。
goto done

:ok
echo [OK] 完成：该搬回去的都已经回到原来的位置上了。
goto done

:identify
echo ============================================================
echo   offline-restore 离线救援（不依赖 DSH，也不需要管理员）
echo ============================================================
echo.
echo   作用：把「待删除」文件夹里的东西，按里面的清单搬回原来的位置。
echo         只搬不删；原位置已经有东西时跳过，绝不覆盖。
echo         还原完，空掉的批次文件夹会被加「【空批次】」前缀标注（只改名，不删东西）。
echo.
echo   这个工具不会自作主张 —— 要还原哪一个，必须由你指定：
echo     [1] 把某个工作区的「待删除」文件夹拖到本文件上      -^> 还原里面全部
echo     [2] 把「待删除」里的某个批次文件夹拖上来            -^> 只还原那一批
echo     [3] 什么都不给（就是现在这样）                      -^> 只识别、只列路径，不搬任何东西
echo.
echo   现在替你识别一下本机的「待删除」（只识别，不会搬东西）：
echo   ----------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0offline-restore.ps1"
echo   ----------------------------------------------------------
echo.
echo   命令行用法（下面每行都可以直接复制到 PowerShell 里用）
echo   （"..\待删除" 是占位符，换成你自己的路径，例如 "E:\AI\dsh_workplace\待删除"）
echo.
echo     ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd"
echo         只识别并列出「待删除」路径（不还原）
echo.
echo     ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除"
echo         还原这个工作区的全部
echo.
echo     ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -List
echo         只列清单，不搬
echo.
echo     ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -DryRun
echo         只预演，不搬
echo.
echo     ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除\20261025-122557"
echo         只还原这一个批次（把批次名换成你自己的）
echo.
echo     ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -MarkEmpty
echo         只给空批次加标注
echo.
echo     ^& "$env:USERPROFILE\.dsh\tools\offline-restore.cmd" "..\待删除" -Map "C:=D:"
echo         盘符变了（WinRE 里常见）
echo.
echo   在 cmd 窗口里用的话不要前面的 ^& ："%USERPROFILE%\.dsh\tools\offline-restore.cmd" "..\待删除"
echo.
echo 按任意键关闭本窗口...
pause >nul
exit /b 0

:done
echo.
echo 按任意键关闭本窗口...
pause >nul
exit /b %RC%