# GPU Setup Guide

InferHaven supports NVIDIA (CUDA), AMD (ROCm), and AMD/Intel (Vulkan) GPUs for AI inference. Follow the section that matches your hardware.

 **Not sure which section applies?**

> - NVIDIA GeForce / RTX / Quadro / Tesla → [NVIDIA CUDA](#nvidia-cuda)
> - AMD Radeon RX / Radeon Pro / Instinct → [AMD ROCm](#amd-rocm)
> - Intel or AMD not listed in ROCm → [Vulkan (experimental)](#vulkan-amd--intel)

---

## NVIDIA CUDA

### Requirements

- NVIDIA GPU with compute capability 5.0 or newer
- Host driver **531 or newer**
- [NVIDIA Container Toolkit](https://github.com/NVIDIA/nvidia-container-toolkit)

[Check your GPU's compute capability](https://developer.nvidia.com/cuda-gpus)

### Step 1: Install NVIDIA drivers

Install the latest stable NVIDIA driver for your distro. On Ubuntu/Debian:

```bash
sudo apt update
sudo ubuntu-drivers install
sudo reboot
```

Or install a specific version:

```bash
sudo apt install -y nvidia-driver-570
sudo reboot
```

**Verify:**

```bash
nvidia-smi
```

### Step 2: Install NVIDIA Container Toolkit

Follow the [official NVIDIA Container Toolkit install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) for your distro. The essential steps on Ubuntu/Debian:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

**Verify:**

```bash
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

### Step 3: Configure `docker-compose.yml`

Uncomment NVIDIA specific sections of the `ollama` docker service, shown below:

```yaml
    environment:
      - OLLAMA_HOST=0.0.0.0
      - OLLAMA_ORIGINS=*
      - DEFAULT_MODEL=${DEFAULT_MODEL:-qwen2.5-coder:7b}
      - NVIDIA_VISIBLE_DEVICES=all
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

### Step 4: Start InferHaven

```bash
docker compose up -d
```

### Selecting specific GPUs (NVIDIA)

Set `CUDA_VISIBLE_DEVICES` in the `ollama` service to limit which GPUs Ollama uses. UUIDs are more reliable than numeric IDs when you have multiple GPUs:

```bash
# Find UUIDs
nvidia-smi -L
```

```yaml
# docker-compose.yml — ollama service
environment:
  - CUDA_VISIBLE_DEVICES=GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Use `-1` to force CPU (disables all GPUs).

### Linux suspend/resume issue

After a suspend/resume cycle, Ollama may fall back to CPU. Reload the NVIDIA UVM driver to fix it without rebooting:

```bash
sudo rmmod nvidia_uvm && sudo modprobe nvidia_uvm
```

---

## AMD ROCm

### Requirements

- AMD GPU supported by ROCm v7, [full card list](https://docs.ollama.com/gpu#linux-support)
- ROCm v7 driver installed on the host

Supported families include Radeon RX 5700 and newer, Radeon Pro W-series, Ryzen AI, and Instinct accelerators. Check the full list at the link above before proceeding.

### Step 1: Install ROCm drivers

Install ROCm using AMD's `amdgpu-install` utility. Follow the [official AMD ROCm install guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/) for your distro, the exact package URL changes with each release.

The key commands after downloading `amdgpu-install`:

```bash
sudo apt install ./amdgpu-install_*.deb
sudo amdgpu-install --usecase=rocm
sudo usermod -a -G render,video $USER
sudo reboot
```

**Verify:**

```bash
rocm-smi
```

### Step 2: Configure `docker-compose.yml`

AMD ROCm uses device passthrough. Edit the `ollama` service in `docker-compose.yml`. Remove the NVIDIA `deploy.resources.reservations` block if present, it is not used with ROCm.

```yaml
  ollama:
    image: ollama/ollama:latest
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    group_add:
      - "44"    # video
      - "103"   # render
```

> `group_add` must use numeric GIDs, the Ollama image has no `/etc/group` entries for `video` or `render`, so name-based lookup fails. The defaults above match Ubuntu/Debian. Verify yours with:
>
> ```bash
> getent group video render
> ```

### Step 3: Start InferHaven

```bash
docker compose up -d
```

**Verify GPU is in use:**

```bash
watch -n 1 rocm-smi
```

### Unsupported GPUs (HSA override)

If your AMD GPU is not officially listed but uses a compatible architecture, you can override the LLVM target. For example, if your card is `gfx1034` but ROCm only supports `gfx1030`:

```yaml
# docker-compose.yml — ollama service environment
environment:
  - HSA_OVERRIDE_GFX_VERSION=10.3.0
```

See [Ollama's GPU docs](https://docs.ollama.com/gpu#overrides-on-linux) for the full list of known LLVM targets.

### Selecting specific GPUs (AMD)

```yaml
environment:
  - ROCR_VISIBLE_DEVICES=<UUID from rocminfo>
```

Use `-1` to force CPU.

### SELinux (some distros)

If containers cannot access AMD GPU devices, enable the required SELinux boolean on the host:

```bash
sudo setsebool container_use_devices=1
```

---

## Vulkan (AMD / Intel)

> **Vulkan support is experimental in Ollama.** Performance and compatibility vary. It is primarily useful for AMD or Intel GPUs not covered by ROCm.

### Requirements

- AMD or Intel GPU with Vulkan-capable drivers
- Linux: Mesa or vendor Vulkan packages (see below)
- Windows: Vulkan support is bundled with most vendor drivers, no extra setup needed

**Linux AMD:** [AMD Vulkan driver install](https://amdgpu-install.readthedocs.io/en/latest/install-script.html#specifying-a-vulkan-implementation)

**Linux Intel:** [Intel GPU driver install](https://dgpu-docs.intel.com/driver/client/overview.html)

### Step 1: Verify Vulkan is available

```bash
# Install vulkan-tools if needed: sudo apt install vulkan-tools
vulkaninfo --summary
```

### Step 2: Configure `docker-compose.yml`

```yaml
  ollama:
    image: ollama/ollama:latest
    environment:
      - OLLAMA_VULKAN=1
    devices:
      - /dev/kfd
      - /dev/dri
    group_add:
      - "44"    # video
      - "103"   # render
```

> - Remove or comment the NVIDIA `deploy.resources.reservations` block if present.
>
> - `group_add` must use numeric GIDs, the Ollama image has no `/etc/group` entries for `video` or `render`. The defaults above match Ubuntu/Debian. Verify yours with: `getent group video render`
>

### Step 3: Start InferHaven

```bash
docker compose up -d
```

Check Ollama logs to confirm Vulkan is active:

```bash
docker compose logs ollama | grep -i vulkan
```

### Selecting specific GPUs (Vulkan)

```yaml
environment:
  - GGML_VK_VISIBLE_DEVICES=0   # numeric ID
```

Use `-1` to disable all Vulkan GPUs.

### Vulkan on AMD iGPU (Ryzen APU / Radeon Graphics)

AMD integrated GPUs share system RAM via GTT (Graphics Translation Table). This introduces two hard limits not present on discrete cards:

1. **Per-allocation cap.** Vulkan `maxMemoryAllocationSize` on AMD iGPU is typically ~4 GiB. Any single tensor or KV buffer larger than this will fail with `ErrorOutOfDeviceMemory` regardless of free host RAM. There is no in-Ollama workaround, use a smaller quant or a smaller model.
2. **GTT heap ceiling.** The amount of system RAM the iGPU can address is capped by the `amdgpu.gttsize` kernel parameter (in MiB). The kernel default is often half of system RAM, but capped low on many distros. Large models that fit in your RAM still fail to load if they exceed this ceiling.

**Symptom (OOM):**

```text
ggml_vulkan: Device memory allocation of size <N> failed.
ggml_vulkan: Requested buffer size exceeds device buffer size limit: ErrorOutOfDeviceMemory
ggml_gallocr_reserve_n_impl: failed to allocate Vulkan0 buffer of size <M>
```

Followed by the model loading entirely on CPU (`offloaded 0/N layers to GPU`).

**Tuning steps (host-level, require reboot):**

```bash
# 1. Edit /etc/default/grub — raise GTT to e.g. 32 GiB on a 64 GiB host.
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amdgpu.gttsize=32768"/' /etc/default/grub
sudo update-grub
sudo reboot

# 2. After reboot, verify:
dmesg | grep -i 'amdgpu.*gtt'
```

**Container-level tuning** (no reboot, lower peak memory):

```bash
# .env
OLLAMA_NUM_PARALLEL=1          # one request slot — shrinks KV ringbuffer
OLLAMA_KEEP_ALIVE=0            # unload model between calls
# Pick smaller quant — q3_K_M / q4_K_S instead of default q4_K_M
```

After editing `.env`: `docker compose up -d ollama` (not `restart`, `restart` keeps the old env vars).

`haven doctor` flags:

- iGPU detected (parses `uma: 1` from Ollama init logs)
- Recent OOM markers in Ollama logs
- Gemma3/4 installed alongside Vulkan (known incompatible, see compat matrix below)

### Vulkan model compatibility (AMD)

Verified on AMD Vulkan backend (Ryzen 780M iGPU, Ollama 0.5.x). Upstream Vulkan support is experimental, table reflects current known state, not a long-term contract.

| Family | Status | Notes |
| -------- | -------- | ------- |
| Qwen2.5 / Qwen2.5-Coder | works | full GPU offload at q4/q5 within iGPU heap |
| Qwen3 / Qwen3-Coder | works | tool calls verified |
| Llama 3 / 3.1 / 3.2 / 3.3 | works | |
| Mistral 7B / Nemo / Small | works | |
| Phi-4 | works | |
| DeepSeek-R1 / Coder / Coder-V2 | works | |
| CodeLlama | works | |
| **Gemma 2** | works | older arch (no sliding-window attention) |
| **Gemma 3** | **broken** | corrupted output / partial offload, Vulkan SWA bug |
| **Gemma 4** | **broken** | same SWA path, same symptom |
| **Mixtral / Devstral 24B+** | broken on iGPU | exceeds per-allocation cap; falls fully to CPU |
| Heavy-quant HF GGUFs (`hf.co/…`) | varies | size + cap-dependent; try Q3/Q4_K_S variants first |

If your card runs the [ROCm v7 GPU list](https://docs.ollama.com/gpu#linux-support), prefer the ROCm path, it has none of these limits.

### Known issues on AMD / Vulkan

> **Upstream Ollama bug, Vulkan + flash attention + Gemma3.** On AMD GPUs running the Vulkan backend, enabling `OLLAMA_FLASH_ATTENTION=1` can cause Gemma3 (and some heavy-quant models) to load with partial offload (~33 %) and emit corrupted or nonsense output. The same model loads correctly on NVIDIA/CUDA. **This is an upstream Ollama/Vulkan issue, not InferHaven tuning**. `haven tune` is GPU-agnostic and never sets `num_gpu`.
>
> **What to try:**
>
> 1. Run `haven doctor`, the **Ollama backend** section flags `OLLAMA_FLASH_ATTENTION=1` and non-`f16` KV cache when an AMD/Vulkan host is detected.
> 2. Set `OLLAMA_FLASH_ATTENTION=0` in `.env` and `docker compose restart ollama`.
> 3. If you also have `OLLAMA_KV_CACHE_TYPE=q4_0`/`q8_0`, revert to `f16` for affected models, quantised KV cache can break partial-offload on Vulkan.
> 4. ROCm is the supported path on AMD when your card is on the [ROCm v7 GPU list](https://docs.ollama.com/gpu#linux-support). Vulkan is the fallback for cards not covered by ROCm.

---

## Monitoring GPU usage

**NVIDIA:**

```bash
watch -n 1 nvidia-smi
```

**AMD:**

```bash
watch -n 1 rocm-smi
```

---

## Troubleshooting

### NVIDIA: GPU not found / falling back to CPU

- Check driver version is 531+: `nvidia-smi`
- Container Toolkit not configured: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`
- After suspend/resume: `sudo rmmod nvidia_uvm && sudo modprobe nvidia_uvm`

### AMD: GPU not detected

- **`Unable to find group render`**: `group_add` must use numeric GIDs, not names, the Ollama image has no `/etc/group` entries. Use `"44"` (video) and `"103"` (render). Confirm your host's GIDs with `getent group video render`.
- Groups not applied on host: log out and back in, or reboot, after `sudo usermod -a -G render,video $USER`
- Missing devices: confirm `/dev/kfd` and `/dev/dri` are in the `devices` block, Docker Desktop specifically cannot support true device passthrough
- SELinux: `sudo setsebool container_use_devices=1`
- Unsupported GPU: try `HSA_OVERRIDE_GFX_VERSION`, see [Overrides section](#unsupported-gpus-hsa-override)

### Vulkan: GPU not used

- Confirm `OLLAMA_VULKAN=1` is set in the compose environment
- Confirm `/dev/dri` is in the `devices` block
- Check logs: `docker compose logs ollama | grep -i vulkan`

### Model runs on CPU despite GPU present

- Model is too large for VRAM, Ollama falls back to CPU automatically
- Try a smaller or quantised variant: `haven pull qwen2.5-coder:7b-q4_K_M`
- Check VRAM usage during inference with `nvidia-smi` or `rocm-smi`

---

Run `haven doctor` for automated checks of your environment:

```bash
./scripts/haven doctor
```
