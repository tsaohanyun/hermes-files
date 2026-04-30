# Hermes Files 同步脚本 (PowerShell版)
# 使用方法: 右键点击脚本 -> "使用 PowerShell 运行"

# 设置仓库路径
$RepoPath = "E:\hermes-files"

# 设置控制台编码为UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Hermes Files 同步脚本 (PowerShell版)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 检查目录是否存在
if (-not (Test-Path $RepoPath)) {
    Write-Host "[错误] 仓库目录不存在: $RepoPath" -ForegroundColor Red
    Write-Host "请先克隆仓库: git clone https://github.com/tsaohanyun/hermes-files.git $RepoPath"
    Read-Host "按Enter键退出"
    exit 1
}

# 切换到仓库目录
try {
    Set-Location $RepoPath
    Write-Host "[信息] 当前目录: $(Get-Location)" -ForegroundColor Green
} catch {
    Write-Host "[错误] 无法切换到目录: $RepoPath" -ForegroundColor Red
    Read-Host "按Enter键退出"
    exit 1
}

# 检查是否为Git仓库
Write-Host "[信息] 正在检查Git仓库..." -ForegroundColor Yellow
try {
    git status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "不是Git仓库"
    }
} catch {
    Write-Host "[错误] 当前目录不是Git仓库" -ForegroundColor Red
    Read-Host "按Enter键退出"
    exit 1
}

# 获取最新更新
Write-Host "[信息] 正在获取最新更新..." -ForegroundColor Yellow
git fetch origin
if ($LASTEXITCODE -ne 0) {
    Write-Host "[错误] 获取更新失败，请检查网络连接" -ForegroundColor Red
    Read-Host "按Enter键退出"
    exit 1
}

# 拉取更改
Write-Host "[信息] 正在拉取更改..." -ForegroundColor Yellow
git pull origin master
if ($LASTEXITCODE -ne 0) {
    Write-Host "[警告] 拉取时出现错误，可能有冲突需要解决" -ForegroundColor Magenta
    Write-Host "[提示] 请手动运行 'git status' 查看状态" -ForegroundColor Magenta
    Read-Host "按Enter键退出"
    exit 1
}

Write-Host ""
Write-Host "[完成] 同步成功！" -ForegroundColor Green
Write-Host "[信息] 仓库已更新到最新版本" -ForegroundColor Green
Write-Host ""
Read-Host "按Enter键退出"