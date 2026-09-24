param(
    [string]$CloudflareST = "",
    [int]$Top = 10,
    [double]$MaxLatency = 200,
    [double]$MinSpeed = 5,
    [int]$MinCount = 3,
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workCsv = Join-Path $repoRoot "result.csv"
$targetCsv = Join-Path $repoRoot "cloudflare-result.csv"

if ([string]::IsNullOrWhiteSpace($CloudflareST)) {
    $candidates = @(
        (Join-Path $repoRoot "tools\CloudflareSpeedTest\cfst.exe"),
        (Join-Path $repoRoot "cfst.exe"),
        (Join-Path $repoRoot "CloudflareST.exe"),
        (Join-Path $PSScriptRoot "cfst.exe"),
        (Join-Path $PSScriptRoot "CloudflareST.exe")
    )
    $CloudflareST = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $CloudflareST -or -not (Test-Path $CloudflareST)) {
    throw "找不到 CloudflareSpeedTest。请把 cfst.exe 放到仓库根目录，或使用 -CloudflareST 指定路径。"
}

Push-Location $repoRoot
try {
    Write-Host "运行 CloudflareSpeedTest: $CloudflareST"

    $cfstDir = Split-Path -Parent $CloudflareST
    $cfstExe = Split-Path -Leaf $CloudflareST

    Push-Location $cfstDir
    try {
        & ".\$cfstExe" -tl $MaxLatency -tlr 0 -sl $MinSpeed -dn $Top -o $workCsv
        if ($LASTEXITCODE -ne 0) {
            throw "CloudflareSpeedTest 运行失败，退出码: $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path $workCsv)) {
        throw "未生成测速结果: $workCsv"
    }

    $rows = @(Import-Csv $workCsv)
    if ($rows.Count -lt $MinCount) {
        throw "有效测速结果仅 $($rows.Count) 条，小于最低要求 $MinCount；本次不覆盖旧结果。"
    }

    Copy-Item $workCsv $targetCsv -Force
    Remove-Item $workCsv -Force

    git add -- cloudflare-result.csv
    git diff --cached --quiet

    if ($LASTEXITCODE -eq 0) {
        Write-Host "优选 IP 无变化，无需提交。"
        exit 0
    }

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    git commit -m "chore: update Cloudflare best IPs $stamp"
    if ($LASTEXITCODE -ne 0) {
        throw "git commit 失败"
    }

    git push origin $Branch
    if ($LASTEXITCODE -ne 0) {
        throw "git push 失败"
    }

    Write-Host ""
    Write-Host "完成：cloudflare-result.csv 已更新并推送到 GitHub。"
    Write-Host "有效 IP 数量: $($rows.Count)"
}
finally {
    Pop-Location
}
