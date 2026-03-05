# LM Studio GPU Idle Fix — Tesla P40 / NVIDIA CUDA Runtime
Note: I'm sick and tired of constant upgrade and downgrade lm studio just to fix this before scaling up fallback inferrence system, so many user report the same thing but the dev just don't care. And here I am, publishing this, this is developed around P40 in mind so you may need to try something else for your own gpu.
## Problem

LM Studio (v0.3.10+) fails to release the CUDA context when no model is loaded, keeping the GPU permanently stuck at **P0 / ~50W** instead of dropping to **P8 / ~11W** at idle.

### Root Cause

LM Studio's background process holds an active CUDA compute context (`Type: C` in `nvidia-smi`) even with no model loaded. As long as any process holds a CUDA context, the NVIDIA driver **cannot** allow the GPU to transition to a low P-state. This is not a driver bug — it is by design.

```
+------------------------------------------------------------------------------+
| Processes:                                                                   |
|  GPU   GI   CI   PID   Type   Process name                        GPU Memory |
|==============================================================================|
|    0   N/A  N/A  19704   C    [LMstudio path]\LM Studio.exe           148MiB |
+------------------------------------------------------------------------------+
```

### Scope

Affects **all NVIDIA GPUs** using the CUDA runtime in LM Studio — not just Tesla/datacenter cards. The impact is more severe on:
- **Tesla P40 / TCC mode** — no display output, no WDDM to mask it. Stuck at P0 / 50W every single time.
- **Headless / secondary GPUs** — same reason, no display driver intervention.
- **Consumer GPUs** — affected on secondary cards or after extended sessions.

### Confirmed Affected Versions
- LM Studio **0.3.10 through 0.4.x** with CUDA runtime selected
- NVIDIA Driver **582.16** (CUDA 13.0) broke the downgrade workaround (previously LM Studio 0.3.9 on older drivers worked)

### Tracking
- [LM Studio Bug Tracker #1403](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1403)
- [LM Studio Bug Tracker #450](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/450)
- [llama.cpp #12958](https://github.com/ggml-org/llama.cpp/issues/12958)

---

## Why Simple Workarounds Don't Work

| Approach | Why It Fails |
|---|---|
| Rollback LM Studio to 0.3.9 | Driver 582.16 / CUDA 13.0 broke this too |
| Switch to Vulkan runtime | Tesla P40 has no graphics pipeline — Vulkan not supported |
| Process Lasso / priority tools | Cannot force a process to release a CUDA context |
| `--lock-memory-clocks` / `--lock-gpu-clocks` | Ignored or ineffective while CUDA context is held on Pascal/TCC |
| Forcing P-state via nvidia-smi | Driver owns P-state — cannot override while context is held |

---

## Solution — P40 Idle Watchdog

A PowerShell watchdog that detects true idle state and kills the CUDA-holding process, forcing the GPU back to **P8 / ~11W**. LM Studio's main window and API server remain alive — n8n and other API automations continue working uninterrupted.

### How It Works

1. Polls VRAM usage every 5 seconds via `nvidia-smi`
2. **True idle** = VRAM `< 500 MiB` + GPU util `0%` + no TCP `ESTABLISHED` on port 1234
3. After 30s of confirmed idle → identifies CUDA-holding child processes via `Win32_Process` parent-child tree
4. If main process is the CUDA holder → attempts `NtSuspendProcess` / `NtResumeProcess` to force context release
5. CUDA context drops → GPU returns to **P8 / ~11W**
6. TCP connection on port 1234 detected (incoming n8n call) → clocks released before inference starts
7. LM Studio respawns CUDA backend automatically on next inference request

### Verified Output

```
[00:31:47] TRUE IDLE | P8 | 11.01W | No CUDA context      ← 11W restored
[00:31:52] IDLE   | P0 | 50.94W | VRAM: 148MiB | PIDs: 19704 | KillIn: 25s
[00:32:20] Killing child process: LM Studio (PID 19704)
[00:32:25] TRUE IDLE | P8 | 11.01W | No CUDA context      ← back to 11W
[00:20:57] ACTIVE | P0 | 84.26W | VRAM: 21788MiB | GPU: 100%  ← full inference
```

---

## Usage

### Requirements
- Windows 10/11
- NVIDIA drivers with `nvidia-smi` in PATH
- PowerShell 5.1+
- Run as **Administrator**

### Run

```powershell
# Allow script execution for this session
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# Run with defaults
.\P40_idle_watchdog.ps1

# Custom parameters
.\P40_idle_watchdog.ps1 -IdleThresholdSec 20 -VramIdleThresholdMB 500 -PollIntervalSec 5
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `PollIntervalSec` | `5` | How often to check GPU state (seconds) |
| `IdleThresholdSec` | `30` | How long idle before killing CUDA process |
| `VramIdleThresholdMB` | `500` | VRAM threshold below which no model is considered loaded |
| `GpuIndex` | `0` | Target GPU index from nvidia-smi |

### Auto-start with Windows

1. Open **Task Scheduler**
2. Create Task → **Run whether user is logged on or not**
3. Check **Run with highest privileges**
4. Trigger: **At log on**
5. Action: `powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\P40_idle_watchdog.ps1"`

---

## Diagnosis Commands

```powershell
# Check P-state and power draw
nvidia-smi --query-gpu=index,name,pstate,power.draw --format=csv

# Check which process holds CUDA context
nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv

# Live monitor (refresh every 1s)
nvidia-smi dmon -s pc -d 1

# Full diagnostic snapshot
nvidia-smi -q > gpu_diag.txt
```

### What to Look For

| State | P-State | Power | VRAM |
|---|---|---|---|
| True idle (no CUDA context) | P8 | ~11W | 0 MiB |
| LM Studio open, no model | P0 | ~50W | 148 MiB |
| Model loaded | P0 | ~50-85W | Hundreds–thousands MiB |
| Inference active | P0 | ~85-250W | Model size |

---

## Hardware Tested

- **GPU:** NVIDIA Tesla P40 (24GB, TCC mode, Pascal architecture)
- **OS:** Windows 10 Pro x64
- **Driver:** 582.16 / CUDA 13.0
- **LM Studio:** 0.4.x with CUDA runtime

---

## Status

LM Studio bug is **open and unresolved** as of March 2026. This watchdog is a workaround until an official fix is shipped. Upvote the issue on the LM Studio bug tracker to help prioritize it.
