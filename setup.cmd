@echo off
chcp 936 >nul
rem ============================================================
rem  dsh-trash-kit —— 删除拦截 + 回收站 套装（双击入口，不需要管理员）
rem
rem  本文件由 setup.ps1 -Export 自动生成：GBK 编码 + 开头 chcp 936，
rem  这样在中文 Windows 上双击就能正常显示中文。改完模板记得跑一次 -Export。
rem
rem  无参数 = 显示下面的菜单；带参数 = 直接透传给 setup.ps1，例如：
rem    setup.cmd -DryRun        只预演，不改任何东西
rem    setup.cmd -Export        把当前状态导出回套装
rem    setup.cmd -NoTask        跳过计划任务那一步
rem    setup.cmd -ForceRules    允许覆盖已存在的全局规则文件
rem    setup.cmd -ProfileName desktop,web
rem ============================================================
setlocal
title dsh-trash-kit 删除拦截 + 回收站
cd /d "%~dp0"

if not "%~1"=="" goto run

:menu
cls
echo ============================================================
echo   dsh-trash-kit   删除拦截 + 回收站 套装
echo ============================================================
echo.
echo   [1] 安装 / 修复（默认）
echo       把工具铺到 %USERPROFILE%\.dsh\tools，逐个 profile 装拦截插件，
echo       检查全局规则和每月体检的计划任务，最后跑一次完整体检。
echo       已存在的文件会先备份到 tools\backup\setup-^<时间^>\ 再覆盖。
echo.
echo   [2] 预演：只报告，不改任何东西
echo       想先看看会动哪些文件、会跳过什么，就选这个（等于 setup.ps1 -DryRun）。
echo.
echo   [3] 把当前状态导出回套装（改过 tools 之后记得跑）
echo       反向同步：把本机已部署的 tools 文件刷进本目录 files\，
echo       并刷新 kit-manifest.json（哈希清单）和本入口文件。
echo.
echo   [4] 只做体检（doctor）
echo       检查脚本 / 插件 / 心跳 / 全局规则 / 各工作区账本 / 闸门告警日志；
echo       有问题会给出修复命令，结论「正常」即可。
echo.
echo   [0] 退出
echo.
set "ARGS="
set "CH=1"
set /p "CH=请选择 [1]: "
if "%CH%"=="" set "CH=1"
rem [1] 安装 / 修复：不带参数执行 setup.ps1
if "%CH%"=="1" goto run
rem [2] 预演：透传 -DryRun，什么都不改
if "%CH%"=="2" set "ARGS=-DryRun" & goto run
rem [3] 导出：透传 -Export，把本机现状刷回套装
if "%CH%"=="3" set "ARGS=-Export" & goto run
rem [4] 只体检：直接调用 tools 里的 doctor.ps1，不跑安装
if "%CH%"=="4" goto doctor
rem [0] 退出：什么都不做
if "%CH%"=="0" exit /b 0
echo 输入无效："%CH%"（请输入 0 到 4 之间的数字）
goto menu

:doctor
echo.
rem 只跑体检，不安装任何东西；退出码 0=正常，1=有异常
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.dsh\tools\doctor.ps1"
set "RC=%ERRORLEVEL%"
goto done

:run
echo.
rem 带参数就原样透传；否则用菜单里选好的 ARGS
if defined ARGS (powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %ARGS%) else (powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*)
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" goto ok
echo [!] 没有全部成功：退出码 %RC%（请看上面的报告）
echo     常见原因：在受限环境里跑（写不了 ~\.dsh、查不了计划任务）——请在普通 PowerShell 里重跑。
goto done

:ok
echo [OK] 全部完成。
goto done

:done
echo.
echo 按任意键关闭本窗口...
pause >nul
exit /b %RC%
