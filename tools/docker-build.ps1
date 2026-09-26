param(
    [string]$Image = "worker-vless2sub:local"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Push-Location $repoRoot
try {
    docker build -t $Image .
    if ($LASTEXITCODE -ne 0) {
        throw "docker build 失败，退出码: $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host "构建完成: $Image"
    Write-Host "本地构建不需要 Docker 登录。"
    Write-Host "启动示例: docker compose up -d --build"
}
finally {
    Pop-Location
}
