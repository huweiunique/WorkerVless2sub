param(
    [string]$CloudflareST = "",
    [Alias("Top")]
    [int]$MaxNodes = 0,
    [double]$MaxLatency = 200,
    [double]$MinSpeed = 5,
    [int]$MinCount = 3,
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

function Resolve-MaxNodes {
    param([int]$Requested)
    if ($Requested -gt 0) { return $Requested }
    $fromEnv = $env:BEST_IP_MAX
    if ($fromEnv -match '^\d+$' -and [int]$fromEnv -gt 0) { return [int]$fromEnv }
    return 30
}

function Get-RowIp {
    param($Row)
    $ip = $Row.'IP 地址'
    if (-not $ip) { $ip = $Row.IP }
    if (-not $ip) { $ip = $Row.'地址' }
    return "$ip".Trim()
}

function Import-SpeedRows {
    param(
        [string]$Path,
        [switch]$AllIps
    )
    if (-not (Test-Path $Path)) { return @() }
    $rows = @(Import-Csv -Path $Path -Encoding UTF8)
    foreach ($row in $rows) {
        $ip = Get-RowIp -Row $row
        if (-not $ip) { continue }
        if ($AllIps) {
            [pscustomobject]@{ Ip = $ip }
            continue
        }
        $speedText = $row.'下载速度(MB/s)'
        if ($null -eq $speedText) { $speedText = $row.'下载速度' }
        $latencyText = $row.'平均延迟'
        $lossText = $row.'丢包率'
        $region = $row.'地区码'
        $speed = 0.0
        $latency = 0.0
        $loss = 1.0
        [void][double]::TryParse("$speedText", [ref]$speed)
        [void][double]::TryParse("$latencyText", [ref]$latency)
        [void][double]::TryParse("$lossText", [ref]$loss)
        if ($ip -and $speed -ge $MinSpeed -and $loss -le 0) {
            [pscustomobject]@{
                Ip        = $ip
                Sent      = $row.'已发送'
                Received  = $row.'已接收'
                Loss      = $loss
                Latency   = $latency
                Speed     = $speed
                Region    = "$region"
            }
        }
    }
}

function Merge-SpeedRows {
    param(
        [object[]]$Rows,
        [int]$Limit
    )
    $best = @{}
    foreach ($row in $Rows) {
        $key = $row.Ip.ToLowerInvariant()
        if (-not $best.ContainsKey($key)) {
            $best[$key] = $row
            continue
        }
        $current = $best[$key]
        if ($row.Speed -gt $current.Speed -or ($row.Speed -eq $current.Speed -and $row.Latency -lt $current.Latency)) {
            $best[$key] = $row
        }
    }
    return @($best.Values |
        Sort-Object -Property @{ Expression = 'Speed'; Descending = $true }, @{ Expression = 'Latency'; Descending = $false } |
        Select-Object -First $Limit)
}

function Export-SpeedRows {
    param(
        [object[]]$Rows,
        [string]$Path
    )
    $exportRows = foreach ($row in $Rows) {
        [pscustomobject]@{
            'IP 地址'          = $row.Ip
            '已发送'           = $row.Sent
            '已接收'           = $row.Received
            '丢包率'           = ('{0:0.00}' -f $row.Loss)
            '平均延迟'         = ('{0:0.00}' -f $row.Latency)
            '下载速度(MB/s)'   = ('{0:0.00}' -f $row.Speed)
            '地区码'           = $row.Region
        }
    }
    $exportRows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workNewCsv = Join-Path $repoRoot "result-new.csv"
$workPrevCsv = Join-Path $repoRoot "result-prev.csv"
$prevIpsFile = Join-Path $repoRoot "prev-ips.txt"
$targetCsv = Join-Path $repoRoot "cloudflare-result.csv"
$maxNodes = Resolve-MaxNodes -Requested $MaxNodes

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
    Write-Host "节点上限: $maxNodes（BEST_IP_MAX）"

    $cfstDir = Split-Path -Parent $CloudflareST
    $cfstExe = Split-Path -Leaf $CloudflareST

    function Invoke-Cfst {
        param(
            [string[]]$Arguments,
            [string]$Label
        )
        Write-Host "测速（$Label）..."
        Push-Location $cfstDir
        try {
            & ".\$cfstExe" @Arguments
            if ($LASTEXITCODE -ne 0) {
                throw "CloudflareSpeedTest 运行失败（$Label），退出码: $LASTEXITCODE"
            }
        }
        finally {
            Pop-Location
        }
    }

    # 第一轮：默认 IP 池，最多测出 MaxNodes 条合格结果
    Invoke-Cfst -Label "默认池" -Arguments @(
        "-httping",
        "-tl", "$MaxLatency",
        "-tlr", "0",
        "-sl", "$MinSpeed",
        "-dn", "$maxNodes",
        "-o", $workNewCsv
    )

    if (-not (Test-Path $workNewCsv)) {
        throw "未生成测速结果: $workNewCsv"
    }

    $newRows = Import-SpeedRows -Path $workNewCsv

    # 第二轮：复测上一轮 cloudflare-result.csv 中的 IP，合格的参与合并
    $prevRows = @()
    $prevIps = @()
    if (Test-Path $targetCsv) {
        $prevIps = @(
            Import-SpeedRows -Path $targetCsv -AllIps |
                ForEach-Object { $_.Ip } |
                Where-Object { $_ } |
                Select-Object -Unique
        )
    }

    if ($prevIps.Count -gt 0) {
        Set-Content -Path $prevIpsFile -Value $prevIps -Encoding UTF8
        try {
            Invoke-Cfst -Label "上一轮 IP 复测" -Arguments @(
                "-httping",
                "-f", $prevIpsFile,
                "-tl", "$MaxLatency",
                "-tlr", "0",
                "-sl", "$MinSpeed",
                "-dn", "$($prevIps.Count)",
                "-o", $workPrevCsv
            )
            if (Test-Path $workPrevCsv) {
                $prevRows = Import-SpeedRows -Path $workPrevCsv
            }
            else {
                Write-Warning "上一轮 IP 复测未生成结果文件，本轮仅保留新测 IP。"
            }
        }
        catch {
            Write-Warning "上一轮 IP 复测失败，本轮仅保留新测 IP。$($_.Exception.Message)"
        }
        finally {
            Remove-Item $prevIpsFile -Force -ErrorAction SilentlyContinue
        }
    }

    $mergedRows = Merge-SpeedRows -Rows @($newRows + $prevRows) -Limit $maxNodes

    if ($mergedRows.Count -lt $MinCount) {
        throw "合并后有效测速结果仅 $($mergedRows.Count) 条，小于最低要求 $MinCount；本次不覆盖旧结果。"
    }

    Export-SpeedRows -Rows $mergedRows -Path $targetCsv

    Remove-Item $workNewCsv -Force -ErrorAction SilentlyContinue
    Remove-Item $workPrevCsv -Force -ErrorAction SilentlyContinue

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
    Write-Host "保留 IP 数量: $($mergedRows.Count) / 上限 $maxNodes（新测 $($newRows.Count) + 复测合格 $($prevRows.Count)）"
}
finally {
    Pop-Location
}
