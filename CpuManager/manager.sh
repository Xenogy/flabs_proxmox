#!/bin/bash
set -euo pipefail

# --- HELPER FUNCTIONS ---
log() { echo "[INFO] $@"; }
warn() { echo "[WARN] $@" >&2; }
error() { echo "[ERROR] $@" >&2; exit 1; }

# Convert a sorted list of CPU IDs to compact range notation (e.g., "2-21,24-43")
cpus_to_ranges() {
    local cpus=($(echo "$@" | tr ' ' '\n' | sort -n))
    local ranges=""
    local start=${cpus[0]}
    local prev=${cpus[0]}
    for ((i=1; i<${#cpus[@]}; i++)); do
        if (( cpus[i] == prev + 1 )); then
            prev=${cpus[i]}
        else
            if (( start == prev )); then
                ranges+="${start},"
            else
                ranges+="${start}-${prev},"
            fi
            start=${cpus[i]}
            prev=${cpus[i]}
        fi
    done
    if (( start == prev )); then
        ranges+="${start}"
    else
        ranges+="${start}-${prev}"
    fi
    echo "$ranges"
}

usage() {
    echo "Usage: $0 -f <config.json> [-n] [-s <hook_script_path>] [-r] [-a [N]]"
    echo "  -f <config.json>:      Path to the JSON configuration file. Required."
    echo "  -n:                    Dry run mode. Plan changes but do not execute them. Optional."
    echo "  -s <hook_script_path>: Path to hook script for VM isolation. Optional."
    echo "  -r:                    Show commands to reset host core pinning. Optional."
    echo "  -a [N]:                Auto-select host cores. Optional."
    exit 1
}

# =============================================================================
# --- STATE MANAGEMENT FUNCTIONS ---
# =============================================================================

create_state_file() {
    local state_file="manager_state.json"
    local timestamp=$(date -Iseconds)

    log "Creating state file: $state_file"
    cat > "$state_file" << STATEEOF
{
  "metadata": {
    "timestamp": "$timestamp",
    "version": "11.3-fix-parsing",
    "config_file": "$CONFIG_FILE",
    "dry_run": $([ $DRY_RUN -eq 1 ] && echo "true" || echo "false")
  },
  "core_assignments": {
STATEEOF

    local vm_count=0
    local total_vms=${#VMS_TO_CONFIGURE[@]}
    local sorted_keys=$(for key in "${!VM_ASSIGNMENTS[@]}"; do echo "$key"; done | sort -n)

    for vmid in $sorted_keys; do
        vm_count=$((vm_count + 1))
        local plan=${VM_ASSIGNMENTS[$vmid]}
        local cpu_count=${VMS_TO_CONFIGURE[$vmid]}

        # [FIX] Changed delimiter from ':' to '|' to handle PCI IDs correctly
        local assigned_cores_str=$(echo "$plan" | sed -n 's/.*cores=\([^|]*\).*/\1/p')
        local assigned_node=$(echo "$plan" | sed -n 's/.*node=\([0-9]*\).*/\1/p')
        local gpu_info=$(echo "$plan" | sed -n 's/.*gpu_pci=\([^|]*\).*/\1/p')
        local mdev_info=$(echo "$plan" | sed -n 's/.*mdev=\([^|]*\).*/\1/p')

        IFS=',' read -ra assigned_cores_array <<< "$assigned_cores_str"

        cat >> "$state_file" << VMSTATEEOF
    "$vmid": {
      "name": "vm-${vmid}",
      "cores": $cpu_count,
      "numa_node": $assigned_node,
      "gpu_assigned": $([ -n "$gpu_info" ] && echo "\"$gpu_info ($mdev_info)\"" || echo "null"),
      "assigned_physical_cores": [$(IFS=','; echo "${assigned_cores_array[*]}")]
    }$([ $vm_count -lt $total_vms ] && echo "," || echo "")
VMSTATEEOF
    done

    cat >> "$state_file" << STATEEOF2
  }
}
STATEEOF2
}

# --- ARGUMENT PARSING ---
CONFIG_FILE=""
DRY_RUN=0
HOOK_SCRIPT_PATH=""
RESET_HOST_PINNING=0
AUTO_HOST_CORES=0
CORES_PER_NUMA=1

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--config) CONFIG_FILE="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -s|--hook-script) HOOK_SCRIPT_PATH="$2"; shift 2 ;;
        -r|--reset-host-pinning) RESET_HOST_PINNING=1; shift ;;
        -a|--auto-host-cores)
            AUTO_HOST_CORES=1
            if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then CORES_PER_NUMA="$2"; shift 2; else shift; fi
            ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1" ;;
    esac
done

if [[ -z "$CONFIG_FILE" ]]; then error "Configuration file (-f) is required."; fi
if [[ ! -f "$CONFIG_FILE" ]]; then error "Configuration file not found."; fi
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then error "Run as root or use dry-run."; fi
for cmd in qm lscpu jq bc lspci; do
    if ! command -v "$cmd" &> /dev/null; then error "Required command '$cmd' not found."; fi
done

# Handle host core pinning reset
if [[ $RESET_HOST_PINNING -eq 1 ]]; then
    log "Resetting all host core pinning..."
    echo ""
    echo "  # Reset AllowedCPUs on slices"
    echo "  systemctl set-property system.slice AllowedCPUs=\"\""
    echo "  systemctl set-property user.slice AllowedCPUs=\"\""
    echo "  systemctl set-property init.scope AllowedCPUs=\"\""
    echo ""
    echo "  # Remove CPUAffinity drop-in for PID 1 (systemd manager)"
    echo "  rm -f /etc/systemd/system.conf.d/99-host-cores.conf"
    echo ""
    echo "  # Remove CPUAffinity drop-in for machine.slice (VMs)"
    echo "  rm -f /etc/systemd/system/machine.slice.d/99-vm-cores.conf"
    echo ""
    echo "  # Reload systemd to apply changes"
    echo "  systemctl daemon-reexec"
    echo ""
    log "Run the above commands manually as root to reset all pinning."
    exit 0
fi


# =============================================================================
# --- PHASE 1: TOPOLOGY DISCOVERY (CPU) ---
# =============================================================================
log "--- PHASE 1: Discovering CPU Topology ---"

CPU_CONFIG_STRING=$(jq -r '.global_settings.cpu_config_string // "host"' "$CONFIG_FILE")
HOST_CORES_JSON=$(jq -r '.global_settings.host_cores // []' "$CONFIG_FILE")
RESERVE_HOST_CORES=$(jq -r '.global_settings.reserve_host_cores' "$CONFIG_FILE")

unique_cores=($(lscpu -p=CPU,CORE,SOCKET,NODE | grep -v '^#' | awk -F',' '{print $2}' | sort -n | uniq))
max_core_id=${unique_cores[$(( ${#unique_cores[@]} - 1 ))]}
total_cpus=$(lscpu -p=CPU,CORE | grep -v '^#' | wc -l)

PHYS_START=0
PHYS_END=$max_core_id
SMT_START=$((max_core_id + 1))
SMT_END=$((total_cpus - 1))

log "  Physical: $PHYS_START-$PHYS_END | SMT: $SMT_START-$SMT_END"

declare -A CPU_TO_CORE CPU_TO_NODE CPU_TO_SOCKET SOCKET_IDS MIN_CORE_PER_SOCKET CORES_TO_RESERVE_MAP
declare -a NUMA_NODE_IDS CORES_TO_RESERVE

lscpu_output=$(lscpu -p=CPU,CORE,SOCKET,NODE 2>&1)
while IFS= read -r line; do
    [[ "$line" =~ ^# || -z "$line" ]] && continue
    IFS=',' read -r cpu core socket node <<<"$line"
    node=${node:-0}; socket=${socket:-0}
    CPU_TO_CORE["$cpu"]=$core; CPU_TO_NODE["$cpu"]=$node; CPU_TO_SOCKET["$cpu"]=$socket
    SOCKET_IDS["$socket"]=1
    if [[ ! " ${NUMA_NODE_IDS[*]} " =~ " ${node} " ]]; then NUMA_NODE_IDS+=("$node"); fi
    if [[ -z "$core" ]]; then continue; fi
    if [[ ! -v MIN_CORE_PER_SOCKET["$socket"] || "$core" -lt "${MIN_CORE_PER_SOCKET["$socket"]}" ]]; then
        MIN_CORE_PER_SOCKET["$socket"]=$core
    fi
done <<< "$lscpu_output"
IFS=$'\n' NUMA_NODE_IDS=($(sort -n <<<"${NUMA_NODE_IDS[*]}")); unset IFS


# =============================================================================
# --- PHASE 1.5: GPU TOPOLOGY & VRAM CAPACITY CHECK ---
# =============================================================================
log "--- PHASE 1.5: Discovering GPUs and MDEV Capacities ---"

declare -A GPU_MAP GPU_MDEV_PROFILE GPU_SLOTS_FREE
declare -a GPU_PCI_IDS

discover_gpus() {
    local target_vram=$(jq -r '.gpu_settings.required_vram_mb // 2048' "$CONFIG_FILE")
    local auto_detect=$(jq -r 'if .gpu_settings.auto_detect_profile == false then "false" else "true" end' "$CONFIG_FILE")
    local manual_mdev=$(jq -r '.gpu_settings.mdev_override // "nvidia-47"' "$CONFIG_FILE")

    log "  GPU Strategy: VRAM=${target_vram}MB, AutoDetect=${auto_detect}"

    while read -r line; do
        pci_slot=$(echo "$line" | cut -d ' ' -f 1)

        local numa_path="/sys/bus/pci/devices/${pci_slot}/numa_node"
        local numa_node="0"
        if [[ -f "$numa_path" ]]; then
            val=$(cat "$numa_path")
            if [[ "$val" != "-1" ]]; then numa_node=$val; fi
        fi

        local mdev_base="/sys/bus/pci/devices/${pci_slot}/mdev_supported_types"
        local selected_type=""
        local available_instances=0

        if [[ -d "$mdev_base" ]]; then
            if [[ "$auto_detect" == "true" ]]; then
                for type_dir in $(ls -1v "$mdev_base"); do
                    desc_file="${mdev_base}/${type_dir}/description"
                    if [[ -f "$desc_file" ]]; then
                        if grep -q "framebuffer=${target_vram}M" "$desc_file"; then
                            selected_type="$type_dir"
                            available_instances=$(grep -o 'max_instance=[0-9]*' "$desc_file" | cut -d= -f2)
                            available_instances=${available_instances:-0}
                            break
                        fi
                    fi
                done
            else
                # Check for per-GPU profile mapping first
                local gpu_specific_mdev=$(jq -r --arg pci "$pci_slot" '.gpu_settings.gpu_profile_map[$pci] // empty' "$CONFIG_FILE")
                if [[ -n "$gpu_specific_mdev" && -d "${mdev_base}/${gpu_specific_mdev}" ]]; then
                    selected_type="$gpu_specific_mdev"
                    local desc_file="${mdev_base}/${gpu_specific_mdev}/description"
                    available_instances=$(grep -o 'max_instance=[0-9]*' "$desc_file" | cut -d= -f2)
                    available_instances=${available_instances:-0}
                    log "    Using per-GPU profile mapping: $gpu_specific_mdev"
                elif [[ -d "${mdev_base}/${manual_mdev}" ]]; then
                    selected_type="$manual_mdev"
                    local desc_file="${mdev_base}/${manual_mdev}/description"
                    available_instances=$(grep -o 'max_instance=[0-9]*' "$desc_file" | cut -d= -f2)
                    available_instances=${available_instances:-0}
                fi
            fi
        else
            log "  GPU $pci_slot: No MDEV support found."
            continue
        fi

        if [[ -n "$selected_type" && $available_instances -gt 0 ]]; then
            if command -v nvidia-smi &> /dev/null; then
                local total_mem_mb=$(nvidia-smi --id="$pci_slot" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "0")
                if [[ "$total_mem_mb" -gt 0 ]]; then
                    local calculated_slots=$(( total_mem_mb / target_vram ))
                    if (( calculated_slots < available_instances )); then
                        log "  [Override] GPU $pci_slot: Sysfs reports $available_instances slots, but VRAM ($total_mem_mb MB) limits to $calculated_slots."
                        available_instances=$calculated_slots
                    fi
                fi
            fi

            if (( available_instances > 0 )); then
                GPU_PCI_IDS+=("$pci_slot")
                GPU_MAP["$pci_slot"]=$numa_node
                GPU_MDEV_PROFILE["$pci_slot"]=$selected_type
                GPU_SLOTS_FREE["$pci_slot"]=$available_instances
                log "  Registered GPU $pci_slot: Profile $selected_type | Slots Available: $available_instances | Node: $numa_node"
            else
                warn "  GPU $pci_slot ignored: $selected_type valid, but 0 slots available after VRAM check."
            fi
        fi

    done < <(lspci -D -nn | grep -E "\[03(00|02)\]" | grep -i nvidia)
}

discover_gpus


# --- Auto-select host cores function (GPU-aware) ---
auto_select_host_cores() {
    local auto_host_cores=()
    local total_host_cores=$((CORES_PER_NUMA * ${#NUMA_NODE_IDS[@]}))

    # Count GPU slots per node to determine demand
    declare -A node_gpu_slots
    for node_id in "${NUMA_NODE_IDS[@]}"; do node_gpu_slots["$node_id"]=0; done
    for pci in "${GPU_PCI_IDS[@]}"; do
        local n=${GPU_MAP[$pci]}
        node_gpu_slots["$n"]=$(( ${node_gpu_slots[$n]} + ${GPU_SLOTS_FREE[$pci]} ))
    done

    # Sort nodes by GPU slots ascending (least GPU demand first = best for host cores)
    local sorted_nodes=($(for n in "${NUMA_NODE_IDS[@]}"; do echo "${node_gpu_slots[$n]} $n"; done | sort -n | awk '{print $2}'))

    log "  GPU slots per node: $(for n in "${NUMA_NODE_IDS[@]}"; do echo -n "Node $n=${node_gpu_slots[$n]} "; done)" >&2

    # Build per-node core lists
    declare -A node_phys_list node_smt_list
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        node_phys_list["$node_id"]=""
        node_smt_list["$node_id"]=""
    done
    for cpu_id in $(seq 0 $SMT_END); do
        if [[ -v CPU_TO_NODE["$cpu_id"] ]]; then
            local nid=${CPU_TO_NODE[$cpu_id]}
            if (( cpu_id >= PHYS_START && cpu_id <= PHYS_END )); then
                node_phys_list["$nid"]+="$cpu_id "
            elif (( cpu_id >= SMT_START && cpu_id <= SMT_END )); then
                node_smt_list["$nid"]+="$cpu_id "
            fi
        fi
    done

    # Allocate host cores starting from node with fewest GPU slots
    local phys_remaining=$total_host_cores
    local smt_remaining=$total_host_cores
    for node_id in "${sorted_nodes[@]}"; do
        IFS=$'\n' sorted_phys=($(echo "${node_phys_list[$node_id]}" | tr ' ' '\n' | grep -v '^$' | sort -n)); unset IFS
        IFS=$'\n' sorted_smt=($(echo "${node_smt_list[$node_id]}" | tr ' ' '\n' | grep -v '^$' | sort -n)); unset IFS

        local phys_cores_added=0
        for core in "${sorted_phys[@]}"; do
            if (( phys_remaining > 0 )); then
                auto_host_cores+=("$core")
                phys_cores_added=$((phys_cores_added + 1))
                phys_remaining=$((phys_remaining - 1))
            fi
        done
        local smt_cores_added=0
        for core in "${sorted_smt[@]}"; do
            if (( smt_remaining > 0 && smt_cores_added < phys_cores_added )); then
                auto_host_cores+=("$core")
                smt_cores_added=$((smt_cores_added + 1))
                smt_remaining=$((smt_remaining - 1))
            fi
        done
    done

    local json_cores="["
    local first=true
    for core in "${auto_host_cores[@]}"; do
        if [[ "$first" == "true" ]]; then
            json_cores+="$core"
            first=false
        else
            json_cores+=",$core"
        fi
    done
    json_cores+="]"
    echo "$json_cores"
}

# Handle -a auto-select host cores (after topology discovery)
if [[ $AUTO_HOST_CORES -eq 1 ]]; then
    log "Auto-selection requested, overriding config host_cores..."
    log "Auto-selecting $((CORES_PER_NUMA * ${#NUMA_NODE_IDS[@]})) physical + SMT host core pairs (GPU-aware placement)..."
    HOST_CORES_JSON=$(auto_select_host_cores)
    log "Auto-selected host cores: $HOST_CORES_JSON"

    if [[ $DRY_RUN -eq 0 ]]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        log "  Created backup: ${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        if jq --argjson host_cores "$HOST_CORES_JSON" '.global_settings.host_cores = $host_cores' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
            mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            log "  Updated host_cores in config file: $CONFIG_FILE"
        else
            error "Failed to update config file with auto-selected host cores"
        fi
    else
        log "  DRY RUN: Would update host_cores in config file: $CONFIG_FILE"
    fi

    while IFS= read -r core_id; do
        if [[ "$core_id" =~ ^[0-9]+$ ]]; then
            node_id=""
            for cpu in $(seq 0 $SMT_END); do
                if [[ -v CPU_TO_NODE["$cpu"] && "$cpu" == "$core_id" ]]; then
                    node_id=${CPU_TO_NODE["$cpu"]}; break
                fi
            done
            log "  NUMA node $node_id: Selected core $core_id"
        fi
    done < <(echo "$HOST_CORES_JSON" | jq -r '.[]')
fi

# =============================================================================
# --- DEVICE IRQ CONFINEMENT ---
# Pinning vCPU threads, the systemd slices, and the boot-time GRUB isolcpus
# params is still not enough at RUNTIME: non-managed device hardware IRQs (and
# their NET_RX/NET_TX softirq chains) default to a broad affinity mask that
# includes VM-dedicated cores. A busy single-queue NIC can then park its whole
# interrupt load on one VM's core, starving that VM relative to its siblings.
# These helpers steer movable device IRQs onto the reserved host cores -- the
# same place the CPUAffinity drop-ins send host work. (The isolcpus=managed_irq
# GRUB param set below handles *managed* IRQs, e.g. NVMe blk-mq, but only after
# a reboot; this handles the rest, live.)
# =============================================================================

# irq_mask_hits_vm_core <cpulist>
#   Returns 0 (true)  if the smp_affinity_list (e.g. "0-43" or "6-8,28-30")
#                     includes any CPU that is NOT a reserved host core.
#   Returns 1 (false) if every listed CPU is a host core (already confined).
irq_mask_hits_vm_core() {
    local list="$1"
    local token lo hi cpu
    local -a tokens
    IFS=',' read -ra tokens <<< "$list"
    for token in "${tokens[@]}"; do
        if [[ -z "$token" ]]; then continue; fi
        if [[ "$token" == *-* ]]; then
            lo=${token%%-*}; hi=${token##*-}
        else
            lo=$token; hi=$token
        fi
        # Only reason about plain numeric ranges; skip anything exotic.
        if [[ ! "$lo" =~ ^[0-9]+$ || ! "$hi" =~ ^[0-9]+$ ]]; then continue; fi
        for (( cpu=lo; cpu<=hi; cpu++ )); do
            if [[ ! -v CORES_TO_RESERVE_MAP["$cpu"] ]]; then
                return 0   # a VM core is in the mask
            fi
        done
    done
    return 1   # entirely host cores
}

# confine_device_irqs
#   Rewrites /proc/irq/<N>/smp_affinity_list of every movable device IRQ that
#   currently overlaps a VM core, steering it onto the reserved host cores, then
#   re-reads to verify the write took. Idempotent (IRQs already on host cores are
#   skipped), honors DRY_RUN, and reports managed IRQs (e.g. NVMe blk-mq, which
#   reject affinity writes with -EIO) as "not movable" rather than failing the
#   run. Opt out with global_settings.confine_device_irqs=false.
confine_device_irqs() {
    # `== false` idiom (not `// true`): jq's // coalesces a real boolean false,
    # which would silently ignore an explicit opt-out.
    local confine
    confine=$(jq -r 'if .global_settings.confine_device_irqs == false then "false" else "true" end' "$CONFIG_FILE")
    if [[ "$confine" != "true" ]]; then
        log "  Device IRQ confinement disabled (global_settings.confine_device_irqs=false); skipping."
        return 0
    fi

    if [[ ${#CORES_TO_RESERVE[@]} -eq 0 ]]; then
        warn "  No reserved host cores; skipping device IRQ confinement."
        return 0
    fi

    # Sorted, de-duplicated, comma-separated host-core cpulist (e.g. "0,22,44,66").
    local host_list
    host_list=$(printf '%s\n' "${CORES_TO_RESERVE[@]}" | sort -nu | tr '\n' ',')
    host_list=${host_list%,}

    # irqbalance would dynamically undo this static placement.
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        warn "  irqbalance is ACTIVE and will likely undo static IRQ placement."
        warn "    Consider: systemctl disable --now irqbalance   (or set IRQBALANCE_BANNED_CPUS)"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [DRY RUN] Would confine movable device IRQs overlapping VM cores onto host cores: $host_list"
    else
        log "  Confining movable device IRQs onto host cores: $host_list"
    fi

    # Overridable base purely for testing against a fake /proc/irq tree.
    local base="${IRQ_PROC_BASE:-/proc/irq}"
    local path irq af list after eff dev_name sub bn
    local considered=0 moved=0 skipped=0 managed_ok=0 stuck=0
    local -A stuck_by_dev   # base device name -> count of IRQs stuck on VM cores

    for path in "$base"/[0-9]*; do
        if [[ ! -d "$path" ]]; then continue; fi
        irq=${path##*/}

        # Identify device IRQs by their /proc/irq/<N>/<device> subdir (kernel 6.8
        # has no 'actions' file); fall back to the 'actions' file on older kernels.
        dev_name=""
        for sub in "$path"/*/; do
            if [[ ! -d "$sub" ]]; then continue; fi
            dev_name=${sub%/}; dev_name=${dev_name##*/}
            break
        done
        if [[ -z "$dev_name" && -r "$path/actions" ]]; then
            dev_name=$(<"$path/actions")
        fi
        # No device association -> not a device IRQ; leave it untouched.
        if [[ -z "$dev_name" ]]; then continue; fi

        af="$path/smp_affinity_list"
        if [[ ! -r "$af" ]]; then continue; fi
        list=$(<"$af")
        considered=$((considered + 1))

        # Idempotent: mask already constrained to host cores -> nothing to do.
        if ! irq_mask_hits_vm_core "$list"; then
            skipped=$((skipped + 1))
            continue
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
            log "    [plan] IRQ $irq ($dev_name): $list -> $host_list"
            moved=$((moved + 1))
            continue
        fi

        # Try to constrain the mask. Managed IRQs (NVMe blk-mq) reject the write
        # with -EIO. 2>/dev/null precedes the redirect so an open-time EACCES/EPERM
        # is suppressed too (it would otherwise leak past a trailing 2>/dev/null).
        if echo "$host_list" 2>/dev/null > "$af"; then
            after=$(<"$af")
            if ! irq_mask_hits_vm_core "$after"; then
                log "    IRQ $irq ($dev_name): $list -> $after"
                moved=$((moved + 1))
                continue
            fi
            # Wrote but it did not take (rare) -> fall through to the stuck check.
            warn "    IRQ $irq ($dev_name): write did not stick (still '$after')."
        fi

        # Could not constrain the mask (managed IRQ, or write ignored). What
        # actually matters is where it RUNS: effective_affinity_list. If the
        # kernel already keeps it on host cores (e.g. via isolcpus=managed_irq),
        # it is fine; only the ones genuinely landing on a VM core are a problem.
        # These are not per-IRQ warnings (NVMe alone can be dozens) -- summarized
        # in aggregate below.
        eff=""
        if [[ -r "$path/effective_affinity_list" ]]; then eff=$(<"$path/effective_affinity_list"); fi
        if [[ -n "$eff" ]] && ! irq_mask_hits_vm_core "$eff"; then
            managed_ok=$((managed_ok + 1))
        else
            stuck=$((stuck + 1))
            bn=${dev_name%%q[0-9]*}                                  # nvme1q25 -> nvme1
            stuck_by_dev["$bn"]=$(( ${stuck_by_dev["$bn"]:-0} + 1 ))
        fi
    done

    # --- Summary. Managed IRQs that cannot be steered are reported in aggregate,
    #     not one alarming line each. ---
    local verb="moved"
    if [[ $DRY_RUN -eq 1 ]]; then verb="to move"; fi
    local extra=""
    if [[ $managed_ok -gt 0 ]]; then extra=" (incl. $managed_ok managed, kernel-steered)"; fi
    log "  IRQ confinement: $moved $verb, $((skipped + managed_ok)) already on host cores${extra}, $stuck not steerable (of $considered device IRQs)."
    if [[ $stuck -gt 0 ]]; then
        local breakdown=""
        for bn in "${!stuck_by_dev[@]}"; do breakdown+="${bn} (${stuck_by_dev[$bn]}), "; done
        breakdown=${breakdown%, }
        warn "    $stuck managed IRQ(s) effectively on VM cores, not steerable at runtime: ${breakdown}."
        warn "    These rely on boot-time isolation (isolcpus=managed_irq, already in GRUB); queues whose"
        warn "    affinity mask is entirely VM cores cannot be relocated even then (inherent kernel limit)."
    fi
    return 0
}

if [[ "$RESERVE_HOST_CORES" == "true" ]]; then
    if [[ "$HOST_CORES_JSON" != "[]" && "$HOST_CORES_JSON" != "null" ]]; then
        while IFS= read -r core_id; do
            CORES_TO_RESERVE+=("$core_id"); CORES_TO_RESERVE_MAP["$core_id"]=1
        done < <(echo "$HOST_CORES_JSON" | jq -r '.[]')
    else
        for socket_id in "${!SOCKET_IDS[@]}"; do
            min_core_id=${MIN_CORE_PER_SOCKET["$socket_id"]}
            for cpu_id in $(seq 0 $SMT_END); do
                if [[ "${CPU_TO_SOCKET[$cpu_id]}" == "$socket_id" && "${CPU_TO_CORE[$cpu_id]}" == "$min_core_id" ]]; then
                    CORES_TO_RESERVE+=("$cpu_id"); CORES_TO_RESERVE_MAP["$cpu_id"]=1
                fi
            done
        done
    fi

    # Apply/output host core pinning
    if [[ ${#CORES_TO_RESERVE[@]} -gt 0 ]]; then
        host_cores_string=$(IFS=' '; echo "${CORES_TO_RESERVE[*]}")

        # Build the inverse set (all non-reserved cores) for machine.slice
        vm_cores_list=()
        for cpu_id in $(seq 0 $SMT_END); do
            if [[ ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then
                vm_cores_list+=("$cpu_id")
            fi
        done
        vm_cores_string=$(IFS=' '; echo "${vm_cores_list[*]}")

        if [[ $DRY_RUN -eq 0 ]]; then
            log "Applying host core pinning..."

            # 1. AllowedCPUs via systemctl set-property
            log "  Setting AllowedCPUs on system.slice, user.slice, init.scope..."
            systemctl set-property system.slice AllowedCPUs="$host_cores_string"
            systemctl set-property user.slice AllowedCPUs="$host_cores_string"
            systemctl set-property init.scope AllowedCPUs="$host_cores_string"

            # 2. CPUAffinity drop-in for PID 1 (systemd manager)
            log "  Writing /etc/systemd/system.conf.d/99-host-cores.conf..."
            mkdir -p /etc/systemd/system.conf.d
            cat > /etc/systemd/system.conf.d/99-host-cores.conf << EOF
[Manager]
CPUAffinity=$host_cores_string
EOF

            # 3. CPUAffinity drop-in for machine.slice (pin VMs to non-host cores)
            log "  Writing /etc/systemd/system/machine.slice.d/99-vm-cores.conf..."
            mkdir -p /etc/systemd/system/machine.slice.d
            cat > /etc/systemd/system/machine.slice.d/99-vm-cores.conf << EOF
[Slice]
CPUAffinity=$vm_cores_string
EOF

            # 4. Reload systemd to pick up the drop-in files
            log "  Reloading systemd (daemon-reexec)..."
            systemctl daemon-reexec

            log "Host core pinning applied successfully."
        else
            log "[DRY RUN] Host core pinning commands:"
            echo ""
            echo "  # AllowedCPUs on slices"
            echo "  systemctl set-property system.slice AllowedCPUs=\"$host_cores_string\""
            echo "  systemctl set-property user.slice AllowedCPUs=\"$host_cores_string\""
            echo "  systemctl set-property init.scope AllowedCPUs=\"$host_cores_string\""
            echo ""
            echo "  # CPUAffinity drop-in for PID 1 (systemd manager)"
            echo "  mkdir -p /etc/systemd/system.conf.d"
            echo "  cat > /etc/systemd/system.conf.d/99-host-cores.conf << EOF"
            echo "  [Manager]"
            echo "  CPUAffinity=$host_cores_string"
            echo "  EOF"
            echo ""
            echo "  # CPUAffinity drop-in for machine.slice (pin VMs to non-host cores)"
            echo "  mkdir -p /etc/systemd/system/machine.slice.d"
            echo "  cat > /etc/systemd/system/machine.slice.d/99-vm-cores.conf << EOF"
            echo "  [Slice]"
            echo "  CPUAffinity=$vm_cores_string"
            echo "  EOF"
            echo ""
            echo "  # Reload systemd"
            echo "  systemctl daemon-reexec"
            echo ""
        fi

        # --- GRUB kernel isolation parameters ---
        vm_cores_ranges=$(cpus_to_ranges "${vm_cores_list[@]}")
        grub_file="/etc/default/grub"

        # Build the three kernel params
        isolcpus_val="managed_irq,domain,${vm_cores_ranges}"
        nohz_val="${vm_cores_ranges}"
        rcu_val="${vm_cores_ranges}"

        if [[ -f "$grub_file" ]]; then
            current_line=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" || true)
            current_isolcpus=$(echo "$current_line" | grep -oP 'isolcpus=[^\s"]+' || true)
            current_nohz=$(echo "$current_line" | grep -oP 'nohz_full=[^\s"]+' || true)
            current_rcu=$(echo "$current_line" | grep -oP 'rcu_nocbs=[^\s"]+' || true)

            new_isolcpus="isolcpus=${isolcpus_val}"
            new_nohz="nohz_full=${nohz_val}"
            new_rcu="rcu_nocbs=${rcu_val}"

            needs_update=false
            if [[ "$current_isolcpus" != "$new_isolcpus" || "$current_nohz" != "$new_nohz" || "$current_rcu" != "$new_rcu" ]]; then
                needs_update=true
            fi

            if [[ "$needs_update" == "true" ]]; then
                # Build updated line: replace existing params or append
                updated_line="$current_line"
                if [[ -n "$current_isolcpus" ]]; then
                    updated_line="${updated_line//$current_isolcpus/$new_isolcpus}"
                else
                    updated_line="${updated_line%\"} ${new_isolcpus}\""
                fi
                if [[ -n "$current_nohz" ]]; then
                    updated_line="${updated_line//$current_nohz/$new_nohz}"
                else
                    updated_line="${updated_line%\"} ${new_nohz}\""
                fi
                if [[ -n "$current_rcu" ]]; then
                    updated_line="${updated_line//$current_rcu/$new_rcu}"
                else
                    updated_line="${updated_line%\"} ${new_rcu}\""
                fi

                if [[ $DRY_RUN -eq 0 ]]; then
                    log "Updating GRUB kernel isolation parameters..."
                    cp "$grub_file" "${grub_file}.backup.$(date +%Y%m%d_%H%M%S)"
                    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${updated_line}|" "$grub_file"
                    log "  Updated $grub_file"
                    log "  Run 'update-grub' and reboot for changes to take effect."
                else
                    log "[DRY RUN] GRUB isolation parameters need updating:"
                    echo ""
                    echo "  # Current:"
                    echo "  $current_isolcpus $current_nohz $current_rcu"
                    echo ""
                    echo "  # New:"
                    echo "  $new_isolcpus $new_nohz $new_rcu"
                    echo ""
                fi
            else
                log "GRUB isolation parameters already correct."
            fi
        else
            warn "GRUB config $grub_file not found, skipping kernel param update."
        fi

        # IRQs are host work: steer movable device IRQs off VM cores onto the
        # reserved host cores at RUNTIME, complementing the boot-time
        # isolcpus=managed_irq/nohz_full/rcu_nocbs GRUB params set above.
        # CAVEAT: /proc/irq affinity is NOT persistent across reboot or NIC
        # driver/link reset -- re-run after device init or such events. (The
        # systemd drop-ins and GRUB params above persist; this placement does not.)
        confine_device_irqs
    fi
fi

declare -A AVAILABLE_PHYS_CORES AVAILABLE_SMT_CORES
for node_id in "${NUMA_NODE_IDS[@]}"; do
    AVAILABLE_PHYS_CORES["$node_id"]=""; AVAILABLE_SMT_CORES["$node_id"]=""
done
for cpu_id in $(seq "$PHYS_START" "$PHYS_END"); do
    if [[ -v CPU_TO_NODE["$cpu_id"] && ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then
        AVAILABLE_PHYS_CORES["${CPU_TO_NODE[$cpu_id]}"]+="$cpu_id "
    fi
done
for cpu_id in $(seq "$SMT_START" "$SMT_END"); do
    if [[ -v CPU_TO_NODE["$cpu_id"] && ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then
        AVAILABLE_SMT_CORES["${CPU_TO_NODE[$cpu_id]}"]+="$cpu_id "
    fi
done


# =============================================================================
# --- PHASE 2: READ CONFIG ---
# =============================================================================
log "--- PHASE 2: Reading VM Configurations ---"
declare -A VMS_TO_CONFIGURE
TOTAL_CORES_REQUESTED=0

for vmid in $(jq -r '.vms | keys[]' "$CONFIG_FILE"); do
    cores=$(jq -r --arg vmid "$vmid" '.vms[$vmid]' "$CONFIG_FILE")
    VMS_TO_CONFIGURE["$vmid"]="$cores"
    TOTAL_CORES_REQUESTED=$((TOTAL_CORES_REQUESTED + cores))
    log "  VM $vmid: $cores cores [GPU REQUIRED]"
done


# =============================================================================
# --- PHASE 3: PLANNING & ASSIGNMENT ---
# =============================================================================
log "--- PHASE 3: Planning Resources (Load Balanced) ---"
declare -A VM_ASSIGNMENTS CORES_ASSIGNED_PER_NODE
for node_id in "${NUMA_NODE_IDS[@]}"; do CORES_ASSIGNED_PER_NODE["$node_id"]=0; done

TOTAL_PHYS_AVAIL=0; for n in "${AVAILABLE_PHYS_CORES[@]}"; do TOTAL_PHYS_AVAIL=$((TOTAL_PHYS_AVAIL + $(echo $n | wc -w))); done
PHYSICAL_CORE_RATIO="1.0"
USE_SMT_CORES=false
if (( TOTAL_CORES_REQUESTED > TOTAL_PHYS_AVAIL )); then
    PHYSICAL_CORE_RATIO=$(echo "scale=4; $TOTAL_PHYS_AVAIL / $TOTAL_CORES_REQUESTED" | bc)
    USE_SMT_CORES=true
fi

sorted_vmids=$(for vmid in "${!VMS_TO_CONFIGURE[@]}"; do echo "${VMS_TO_CONFIGURE[$vmid]} $vmid"; done | sort -rn | awk '{print $2}')

assign_resources() {
    local vmid=$1
    local forced_node=$2
    local gpu_pci=$3
    local gpu_mdev=$4
    local cpu_count=${VMS_TO_CONFIGURE[$vmid]}

    local target_node=$forced_node
    local avail_phys=(${AVAILABLE_PHYS_CORES["$target_node"]:-})
    local avail_smt=(${AVAILABLE_SMT_CORES["$target_node"]:-})

    local phys_needed=$cpu_count
    local smt_needed=0

    if [[ "$USE_SMT_CORES" == true ]]; then
        phys_needed=$(echo "$cpu_count * $PHYSICAL_CORE_RATIO / 1" | bc)
        if (( phys_needed > ${#avail_phys[@]} )); then phys_needed=${#avail_phys[@]}; fi
        smt_needed=$(( cpu_count - phys_needed ))
    fi

    if (( (phys_needed + smt_needed) > (${#avail_phys[@]} + ${#avail_smt[@]}) )); then
        error "VM $vmid: Node $target_node has insufficient cores! (GPU Locked)"
    fi

    local assigned_cores=( "${avail_phys[@]:0:$phys_needed}" "${avail_smt[@]:0:$smt_needed}" )

    # [FIX] Changed delimiter from ':' to '|' to handle PCI IDs correctly
    local plan="cores=$(IFS=,; echo "${assigned_cores[*]}")|node=${target_node}"
    if [[ -n "$gpu_pci" ]]; then plan="$plan|gpu_pci=${gpu_pci}|mdev=${gpu_mdev}"; fi

    VM_ASSIGNMENTS["$vmid"]="$plan"
    CORES_ASSIGNED_PER_NODE["$target_node"]=$(( ${CORES_ASSIGNED_PER_NODE[$target_node]} + cpu_count ))

    for core in "${assigned_cores[@]}"; do
        AVAILABLE_PHYS_CORES["$target_node"]=$(echo "${AVAILABLE_PHYS_CORES[$target_node]}" | sed "s/\b${core}\b\s*//g")
        AVAILABLE_SMT_CORES["$target_node"]=$(echo "${AVAILABLE_SMT_CORES[$target_node]}" | sed "s/\b${core}\b\s*//g")
    done
}

# --- MAIN ASSIGNMENT LOOP ---
for vmid in $sorted_vmids; do
    cpu_count=${VMS_TO_CONFIGURE[$vmid]}
    best_pci=""
    max_free_cores=-1

    # 1. SCAN for Best Candidate
    for pci in "${GPU_PCI_IDS[@]}"; do
        if [[ ${GPU_SLOTS_FREE[$pci]} -gt 0 ]]; then
            node=${GPU_MAP[$pci]}

            # Count free cores on this node (Global Vars used, NO LOCAL)
            avail_phys_list=(${AVAILABLE_PHYS_CORES["$node"]:-})
            avail_smt_list=(${AVAILABLE_SMT_CORES["$node"]:-})
            total_avail=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))

            if (( cpu_count <= total_avail )); then
                # Load Balancing: Pick the node with the MOST free cores
                if (( total_avail > max_free_cores )); then
                    max_free_cores=$total_avail
                    best_pci=$pci
                fi
            fi
        fi
    done

    # 2. ASSIGN if candidate found
    if [[ -n "$best_pci" ]]; then
        pci=$best_pci
        node=${GPU_MAP[$pci]}
        mdev=${GPU_MDEV_PROFILE[$pci]}

        log "  Assigning GPU $pci ($mdev) on Node $node to VM $vmid (Node Free: $max_free_cores)"
        assign_resources "$vmid" "$node" "$pci" "$mdev"
        GPU_SLOTS_FREE[$pci]=$(( ${GPU_SLOTS_FREE[$pci]} - 1 ))
    else
        error "VM $vmid needs a GPU/CPU pair, but no valid slot/core combination was found!"
    fi
done

create_state_file
log "Planning Complete."


# =============================================================================
# --- PHASE 4: EXECUTION ---
# =============================================================================
log "--- PHASE 4: Executing Configuration ---"
if [[ $DRY_RUN -eq 1 ]]; then warn "*** DRY RUN MODE ***"; fi

for vmid in "${!VMS_TO_CONFIGURE[@]}"; do
    log "--- Configuring VM $vmid ---"
    plan=${VM_ASSIGNMENTS[$vmid]}

    # [FIX] Updated sed delimiters to match new plan format '|'
    affinity=$(echo "$plan" | sed -n 's/.*cores=\([^|]*\).*/\1/p')
    node=$(echo "$plan" | sed -n 's/.*node=\([0-9]*\).*/\1/p')
    gpu_pci=$(echo "$plan" | sed -n 's/.*gpu_pci=\([^|]*\).*/\1/p')
    gpu_mdev=$(echo "$plan" | sed -n 's/.*mdev=\([^|]*\).*/\1/p')
    cpu_count=${VMS_TO_CONFIGURE[$vmid]}

    if [[ $DRY_RUN -eq 0 ]]; then
        qm set "$vmid" -cores "$cpu_count" -cpu "$CPU_CONFIG_STRING" -affinity "$affinity"
        vm_mem=$(qm config "$vmid" | grep '^memory:' | awk '{print $2}')
        qm set "$vmid" -numa 1 -numa0 "cpus=0-$((cpu_count-1)),hostnodes=$node,memory=$vm_mem,policy=bind" -hugepages 1024 -balloon 0

        if [[ -n "$gpu_pci" && -n "$gpu_mdev" ]]; then
            log "  Attaching GPU: $gpu_pci ($gpu_mdev)"
            qm set "$vmid" -hostpci0 "${gpu_pci},mdev=${gpu_mdev},pcie=1,x-vga=1"
        else
            error "Fatal: VM $vmid should have a GPU but plan is missing it."
        fi

        while read -r line; do
             iface=$(echo "$line" | cut -d: -f1)
             qm set "$vmid" -"$iface" "$(echo "$line" | cut -d' ' -f2 | sed -E 's/,?queues=[0-9]+//g'),queues=$cpu_count"
        done < <(qm config "$vmid" | grep -E '^net[0-9]+:.*virtio')

        boot_disk=$(qm config "$vmid" | grep '^boot:' | sed -e 's/.*order=//' -e 's/;.*//' || true)
        if [[ -n "$boot_disk" ]]; then
            if [[ "$boot_disk" =~ ^(scsi|virtio) ]]; then
                disk_line=$(qm config "$vmid" | grep "^${boot_disk}:" || true)
                if [[ -n "$disk_line" && "$disk_line" != *"iothread=1"* ]]; then
                     disk_opts=$(echo "$disk_line" | cut -d' ' -f2 | cut -d',' -f2-)
                     disk_path=$(echo "$disk_line" | cut -d' ' -f2 | cut -d',' -f1)
                     log "  Enabling IO Thread on $boot_disk"
                     qm set "$vmid" -"$boot_disk" "${disk_path},${disk_opts},iothread=1"
                fi
            else
                log "  Skipping IO Thread for bus: $boot_disk (not supported)"
            fi
        fi

        if [[ -n "$HOOK_SCRIPT_PATH" ]]; then qm set "$vmid" --hookscript "$HOOK_SCRIPT_PATH"; fi
    else
        log "  [DRY RUN] Set Affinity: $affinity (Node $node)"
        [[ -n "$gpu_pci" ]] && log "  [DRY RUN] Set GPU: $gpu_pci ($gpu_mdev)"
    fi
done

log "Script finished."
