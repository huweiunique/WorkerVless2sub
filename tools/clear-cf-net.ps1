# 清理 CloudflareSpeedTest 跑完后的网络残留，降低本机连接阻塞概率。
# 只处理：残留 cfst 进程、进程已退出的死连接统计、DNS 缓存。
# TIME_WAIT 需系统自行老化，本脚本不会改注册表或重置网卡。
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"

function Get-TcpSummary {
    $conns = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
    $byState = $conns | Group-Object State | Sort-Object Count -Descending
    [pscustomobject]@{
        Total = $conns.Count
        TimeWait = @($conns | Where-Object State -eq 'TimeWait').Count
        CloseWait = @($conns | Where-Object State -eq 'CloseWait').Count
        FinWait = @($conns | Where-Object { $_.State -in 'FinWait1','FinWait2','LastAck' }).Count
        Established = @($conns | Where-Object State -eq 'Established').Count
        ByState = $byState
    }
}

function Stop-LeftoverCfst {
    $procs = @(Get-Process -Name 'cfst','CloudflareST' -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        if (-not $Quiet) { Write-Host "结束残留进程 $($p.ProcessName) pid=$($p.Id)" }
        try { Stop-Process -Id $p.Id -Force } catch { Write-Warning "无法结束 $($p.Id): $($_.Exception.Message)" }
    }
    return $procs.Count
}

function Get-OrphanSockets {
    # 进程已退出但连接仍在（含 TimeWait/CloseWait），说明靠系统回收
    $rows = @()
    foreach ($c in Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if (-not $p -and $c.State -ne 'TimeWait' -and $c.OwningProcess -ne 0) {
            $rows += [pscustomobject]@{
                State = $c.State
                Local = "$($c.LocalAddress):$($c.LocalPort)"
                Remote = "$($c.RemoteAddress):$($c.RemotePort)"
                Pid = $c.OwningProcess
            }
        }
    }
    return $rows
}

$before = Get-TcpSummary
if (-not $Quiet) {
    Write-Host "=== 清理前 TCP ==="
    Write-Host ("Total={0}  TimeWait={1}  CloseWait={2}  FinWait/LastAck={3}  Established={4}" -f `
        $before.Total, $before.TimeWait, $before.CloseWait, $before.FinWait, $before.Established)
}

$stopped = Stop-LeftoverCfst
$orphans = Get-OrphanSockets

try { ipconfig /flushdns | Out-Null } catch { }

# 给内核一点时间回收已断开的套接字
Start-Sleep -Seconds 2

$after = Get-TcpSummary
if (-not $Quiet) {
    Write-Host "=== 清理后 TCP ==="
    Write-Host ("Total={0}  TimeWait={1}  CloseWait={2}  FinWait/LastAck={3}  Established={4}" -f `
        $after.Total, $after.TimeWait, $after.CloseWait, $after.FinWait, $after.Established)
    Write-Host "结束残留 cfst 进程数: $stopped"
    if ($orphans.Count -gt 0) {
        Write-Host "进程已退出的异常连接（依赖系统回收）: $($orphans.Count)"
        $orphans | Select-Object -First 15 | Format-Table -AutoSize | Out-String | Write-Host
    }
    if ($after.TimeWait -gt 2000) {
        Write-Warning "TimeWait 仍偏高（$($after.TimeWait)），动态端口可能紧张。可稍后再跑一次本脚本，或重启后再测速。"
    }
}

[pscustomobject]@{
    StoppedCfst = $stopped
    Before = $before
    After = $after
    OrphanSockets = $orphans.Count
}
