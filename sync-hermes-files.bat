@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo ============================================
echo   Hermes Files 同步脚本 (Windows版)
echo ============================================
echo.

:: 设置仓库路径（默认为E:\hermes-files）
set "REPO_PATH=E:\hermes-files"

:: 检查目录是否存在
if not exist "%REPO_PATH%" (
    echo [错误] 仓库目录不存在: %REPO_PATH%
    echo 请先克隆仓库: git clone https://github.com/tsaohanyun/hermes-files.git E:\hermes-files
    pause
    exit /b 1
)

:: 切换到仓库目录
cd /d "%REPO_PATH%"
if errorlevel 1 (
    echo [错误] 无法切换到目录: %REPO_PATH%
    pause
    exit /b 1
)

echo [信息] 当前目录: %cd%
echo [信息] 正在检查Git仓库...
git status >nul 2>&1
if errorlevel 1 (
    echo [错误] 当前目录不是Git仓库
    pause
    exit /b 1
)

echo [信息] 正在获取最新更新...
git fetch origin
if errorlevel 1 (
    echo [错误] 获取更新失败，请检查网络连接
    pause
    exit /b 1
)

echo [信息] 正在拉取更改...
git pull origin master
if errorlevel 1 (
    echo [警告] 拉取时出现错误，可能有冲突需要解决
    echo [提示] 请手动运行 'git status' 查看状态
    pause
    exit /b 1
)

echo.
echo [完成] 同步成功！
echo [信息] 仓库已更新到最新版本
echo.
pause