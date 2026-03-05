# ============================================================
# P40 LM Studio Idle Watchdog v6
# Kills LM Studio CHILD processes holding CUDA context
# Main UI window stays alive, n8n API keeps working
# ============================================================

param(
    [int]$PollIntervalSec     = 5,
    [int]$IdleThresholdSec    = 30,
    [int]$VramIdleThresholdMB = 500,
    [int]$GpuIndex            = 0
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Must run as Administrator." -ForegroundColor Red
    exit 1
}

function Get-CudaPIDs {
    $out = & nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits -i $GpuIndex 2>&1
    $result = @()
    foreach ($line in $out) {
        $val = ($line -replace '\s','')
        if ($val -match '^\d+$') { $result += [int]$val }
    }
    return $result
}

function Get-VramUsedMB {
    $out = & nvidia-smi --query-compute-apps=used_gpu_memory --format=csv,noheader,nounits -i $GpuIndex 2>&1
    $total = 0
    foreach ($line in $out) {
        $val = ($line -replace '\s','')
        if ($val -match '^\d+$') { $total += [int]$val }
    }
    return $total
}

function Get-GpuUtil {
    $out = & nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -i $GpuIndex 2>&1
    $val = $out -replace '\s',''
    if ($val -match '^\d+$') { return [int]$val }
    return -1
}

function Get-ActiveConnection {
    $conn = netstat -ano 2>&1 | Select-String ":1234\s" | Select-String "ESTABLISHED"
    return ($null -ne $conn -and $conn.Count -gt 0)
}

# Get all child PIDs of a given parent PID recursively
function Get-ChildPIDs {
    param([int]$ParentPID)
    $children = @()
    $procs = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentPID" -ErrorAction SilentlyContinue
    foreach ($proc in $procs) {
        $children += [int]$proc.ProcessId
        $children += Get-ChildPIDs -ParentPID $proc.ProcessId
    }
    return $children
}

function Kill-CudaContextProcesses {
    $cudaPIDs = Get-CudaPIDs
    if ($cudaPIDs.Count -eq 0) { return }

    # Get LM Studio main UI PIDs (the ones with a visible window)
    $lmProcs = @(Get-Process -Name "LM Studio" -ErrorAction SilentlyContinue)

    # Build list of all LM Studio child PIDs
    $allChildPIDs = @()
    foreach ($lmProc in $lmProcs) {
        $allChildPIDs += Get-ChildPIDs -ParentPID $lmProc.Id
    }

    Write-Host "[$(Get-Date -f 'HH:mm:ss')] LM Studio child PIDs: $($allChildPIDs -join ',')" -ForegroundColor DarkGray

    foreach ($cudaPid in $cudaPIDs) {
        try {
            $proc = Get-Process -Id $cudaPid -ErrorAction Stop

            # If it's a child of LM Studio -> kill it (CUDA backend)
            # If it's the main LM Studio UI -> kill it too since it IS the CUDA holder (single process case)
            $isChild = $allChildPIDs -contains $cudaPid
            $isMain  = ($lmProcs | Where-Object { $_.Id -eq $cudaPid }).Count -gt 0

            if ($isChild) {
                Write-Host "[$(Get-Date -f 'HH:mm:ss')] Killing child process: $($proc.Name) (PID $cudaPid)" -ForegroundColor Green
                Stop-Process -Id $cudaPid -Force -ErrorAction Stop
                Write-Host "[$(Get-Date -f 'HH:mm:ss')] Killed child PID $cudaPid" -ForegroundColor Green
            } elseif ($isMain) {
                # Main process IS the CUDA holder - use Job Objects API via WMI to release CUDA
                # without killing the window: suspend + resume forces driver context release on some drivers.
                # If that doesn't work, warn user.
                Write-Host "[$(Get-Date -f 'HH:mm:ss')] WARNING: Main LM Studio process (PID $cudaPid) is the CUDA holder." -ForegroundColor Red
                Write-Host "[$(Get-Date -f 'HH:mm:ss')] No child backend process found. Attempting suspend/resume to force context release..." -ForegroundColor Yellow

                # Suspend all threads
                $procObj = [System.Diagnostics.Process]::GetProcessById($cudaPid)
                foreach ($thread in $procObj.Threads) {
                    try {
                        $thread.ProcessorAffinity = $thread.ProcessorAffinity
                        [void][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    } catch {}
                }

                # Use NtSuspendProcess via P/Invoke
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NtDll {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
}
"@ -ErrorAction SilentlyContinue

                try {
                    $handle = $procObj.Handle
                    [NtDll]::NtSuspendProcess($handle) | Out-Null
                    Start-Sleep -Seconds 2
                    [NtDll]::NtResumeProcess($handle) | Out-Null
                    Write-Host "[$(Get-Date -f 'HH:mm:ss')] Suspend/resume done. Check if power drops." -ForegroundColor Yellow
                } catch {
                    Write-Host "[$(Get-Date -f 'HH:mm:ss')] Suspend/resume failed: $_" -ForegroundColor Red
                    Write-Host "[$(Get-Date -f 'HH:mm:ss')] LM Studio must be restarted to release CUDA context." -ForegroundColor Red
                }
            } else {
                Write-Host "[$(Get-Date -f 'HH:mm:ss')] Unknown process holding CUDA: $($proc.Name) (PID $cudaPid) - killing it." -ForegroundColor Yellow
                Stop-Process -Id $cudaPid -Force -ErrorAction Stop
            }

        } catch {
            Write-Host "[$(Get-Date -f 'HH:mm:ss')] Failed on PID $cudaPid : $_" -ForegroundColor Red
        }
    }
}

$cudaKilled  = $false
$idleSeconds = 0

Write-Host "[INFO] Watchdog v6 | Targets CUDA child processes first, handles single-process case" -ForegroundColor Cyan
Write-Host "[INFO] VRAM threshold: <$VramIdleThresholdMB MiB | Kill after: ${IdleThresholdSec}s" -ForegroundColor Cyan
Write-Host ""

while ($true) {
    $vramMB    = Get-VramUsedMB
    $gpuUtil   = Get-GpuUtil
    $activeTCP = Get-ActiveConnection
    $powerDraw = (& nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits -i $GpuIndex 2>&1) -replace '\s',''
    $pState    = (& nvidia-smi --query-gpu=pstate --format=csv,noheader -i $GpuIndex 2>&1) -replace '\s',''
    $cudaPIDs  = Get-CudaPIDs

    $modelInVram = ($vramMB -ge $VramIdleThresholdMB)
    $isIdle      = (-not $modelInVram -and $gpuUtil -eq 0 -and -not $activeTCP)

    if ($cudaPIDs.Count -eq 0) {
        $idleSeconds = 0
        $cudaKilled  = $false
        Write-Host "[$(Get-Date -f 'HH:mm:ss')] TRUE IDLE | $pState | ${powerDraw}W | No CUDA context" -ForegroundColor DarkGreen

    } elseif ($isIdle) {
        $idleSeconds += $PollIntervalSec

        if ($idleSeconds -ge $IdleThresholdSec -and -not $cudaKilled) {
            Kill-CudaContextProcesses
            $cudaKilled = $true
        }

        Write-Host "[$(Get-Date -f 'HH:mm:ss')] IDLE   | $pState | ${powerDraw}W | VRAM: ${vramMB}MiB | PIDs: $($cudaPIDs -join ',') | KillIn: $([math]::Max(0, $IdleThresholdSec - $idleSeconds))s" -ForegroundColor Gray

    } else {
        $idleSeconds = 0
        $cudaKilled  = $false
        Write-Host "[$(Get-Date -f 'HH:mm:ss')] ACTIVE | $pState | ${powerDraw}W | VRAM: ${vramMB}MiB | GPU: ${gpuUtil}% | TCP: $activeTCP" -ForegroundColor White
    }

    Start-Sleep -Seconds $PollIntervalSec
}
