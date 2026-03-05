# p40-lmstudio-idle-patch
Watchdog script that fixes LM Studio's GPU idle regression on NVIDIA cards — kills the stuck CUDA context when idle to restore true P8 (~11W) instead of P0 (~50W), while keeping the LM Studio API server alive for automation tools like n8n.
