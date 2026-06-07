# flabs_proxmox

Setup guide + automation tooling for running multiple GPU-sharing Windows VMs on
**Proxmox VE** (for FarmLabs). It covers Proxmox + NVIDIA vGPU installation
(`README.md`), CPU/NUMA pinning scripts that tune VM performance via the Proxmox
`qm` CLI, and a Windows-side watchdog agent installed into VM startup.

There is **no build system** — Bash and PowerShell scripts are run directly; the
`.exe` files are precompiled Windows binaries (no source in this repo).

## Repository layout
- `README.md` — the primary deliverable: a ~769-line step-by-step guide (Proxmox install → vGPU driver stack → Windows VM creation → VirtIO drivers → Docker license server → GPU passthrough → CPU affinity tuning). Includes a Mermaid flowchart and screenshots from `imgs/`.
- `cpu_affinity.sh` — simpler CPU-pinning tool. Assigns N cores per VM round-robin across NUMA nodes and applies them with `qm`.
- `test_cpu_affinity.sh` — enhanced variant of the above. Adds `-s` (sibling/hyperthread-aware assignment) and uses a CPU flag string with security mitigations disabled for performance (carries an explicit warning). This is the staging/experimental version.
- `CpuManager/` — the advanced, config-driven orchestrator (current focus of development):
  - `manager.sh` — multi-phase tool: NUMA discovery → GPU discovery (`lspci` + sysfs `numa_node`, vGPU/mdev slots) → read VM config + disk locality → core/GPU/hugepage assignment → apply via `qm` + systemd CPU pinning → write `manager_state.json`.
  - `test_manager.sh` — testing/staging mirror of `manager.sh`.
  - `config.json` — input config (see below).
  - `get_gpu_numa.sh` — utility that lists each GPU's PCI address + NUMA node.
- `watchdog_install.ps1` — Windows installer: kills/cleans old agents, downloads `watchdog.exe` from GitHub raw into the user's Startup folder, launches it.
- `watchdog.exe`, `popupv2.exe` — precompiled Windows GUI agents (run inside the VMs). `watchdog_version` holds the current version string (currently `6`); the installer treats `popupv2.exe` as a legacy name to remove.
- `imgs/` — screenshots referenced by `README.md` (VM setup, partitioning, GPU passthrough, Windows driver install).

## Running the tools
All scripts run **on the Proxmox host as root** (dry-run works without root). Use `-n` to preview the `qm`/systemd commands before applying.

```bash
# Simple affinity (dry-run, then apply)
bash cpu_affinity.sh -r 100-105 -c 4 -n
sudo bash cpu_affinity.sh -r 100-105 -c 4 -i 105,107   # -i ignores VMs, -x disables host-core reservation

# Sibling-aware variant
bash test_cpu_affinity.sh -r 100-105 -c 4 -s -n

# Config-driven manager
bash CpuManager/manager.sh -f CpuManager/config.json -n      # dry-run
sudo bash CpuManager/manager.sh -f CpuManager/config.json     # apply
#   -a [N] auto-pick host cores consolidated on least-GPU-loaded node
#   -b [N] balance host cores across sockets
#   -g     skip GPU discovery (CPU-only)
#   -r     show host-pinning reset commands
#   -s <hook>  run a hook script after applying

# Utility: list GPU NUMA mapping
bash CpuManager/get_gpu_numa.sh
```

Windows VM agent install (run in the guest):
```powershell
PowerShell -ExecutionPolicy Bypass -File watchdog_install.ps1
```

### `CpuManager/config.json`
- `global_settings`: `cpu_config_string` (the `host,flags=...` passed to `qm -cpu`), `reserve_host_cores`, `host_cores` (logical CPU IDs reserved for the host), `state_file`, and `core_definitions` (physical/logical CPU ID ranges describing SMT layout).
- `gpu_settings`: `required_vram_mb`, `auto_detect_profile`, and `gpu_profile_map` (PCI address → vGPU/mdev profile, e.g. `"0000:04:00.0": "nvidia-47"`).
- `vms`: map of VM ID → core count (e.g. `"101": 4`).

## How the pieces fit together
1. On the Proxmox host, a CPU tool (`manager.sh` for complex setups, `cpu_affinity.sh` for simple ones) detects NUMA topology and GPUs, then pins each VM's vCPUs to physical cores on the NUMA node closest to its GPU/boot disk, configures 1GB hugepages, disables ballooning, and isolates host cores via systemd drop-ins.
2. The configured commands are applied through Proxmox's `qm set` (`-cores`, `-cpu`, `-affinity`, `-numa`/`-numa0`, `-hugepages`, `-balloon`, net queues). `manager.sh` records the full plan in `manager_state.json` for auditing.
3. Inside each Windows VM, `watchdog_install.ps1` installs `watchdog.exe` into the Startup folder so it runs on boot.

## Conventions
- Bash scripts: `#!/bin/bash`; `manager.sh`/`test_manager.sh` use `set -euo pipefail`. Heavy quoting (`"${var}"`), `declare -A` associative arrays for topology maps, and `log()`/`warn()`/`error()` helpers printing `[INFO]`/`[WARN]`/`[ERROR]` to stderr.
- File naming: `*_affinity.sh` = core-assignment tools, `*_manager.sh` = orchestrators, `test_*` = staging/experimental variant of a production script, `get_*.sh` = discovery utilities, `*_install.ps1` = Windows installers.
- The `test_*` scripts are the place to iterate; keep them in sync with their non-`test_` counterparts when changes are proven.
- Prefer dry-run (`-n`) when demonstrating or validating changes; these scripts run privileged `qm`/systemd commands against live VMs.
- `.gitignore` only excludes markdown working drafts (`.old.md`, `.restructured_guide_plan.md`); scripts, config, and binaries are tracked.
- Note the security trade-off: `test_cpu_affinity.sh` and `config.json`'s default `cpu_config_string` disable CPU mitigations (`-spec-ctrl;-ssbd` etc.) for performance — appropriate only for trusted environments.

## Useful host inspection commands
```bash
lscpu -p=CPU,CORE,SOCKET,NODE   # NUMA / SMT topology
lspci -D -nn | grep -E "03(00|02)"  # GPUs (VGA / 3D controller)
qm list                          # VMs
qm config <vmid>                 # one VM's config
```
