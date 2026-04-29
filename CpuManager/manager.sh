#!/bin/bash
set -euo pipefail

# --- HELPER FUNCTIONS ---
log() { echo "[INFO] $@"; }
warn() { echo "[WARN] $@" >&2; }
error() { echo "[ERROR] $@" >&2; exit 1; }

usage() {
    echo "Usage: $0 -f <config.json> [-n][-s <hook_script_path>] [-r] [-a [N]]"
    echo "  -f <config.json>:      Path to the JSON configuration file. Required."
    echo "  -n:                    Dry run mode. Plan changes but do not execute them. Optional."
    echo "  -s <hook_script_path>: Path to hook script for VM isolation. Optional."
    echo "  -r:                    Show commands to reset host core pinning. Optional."
    echo "  -a [N]:                Auto-select host cores. Optional."
    echo "  -g:                    Skip GPU discovery and assignment. Optional."
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
      "assigned_physical_cores":[$(IFS=','; echo "${assigned_cores_array[*]}")]
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
SKIP_GPU=0

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
        -g|--no-gpu) SKIP_GPU=1; shift ;;
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
HOST_CORES_JSON=$(jq -r '.global_settings.host_cores //[]' "$CONFIG_FILE")
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

# --- Auto-select host cores function (CONSOLIDATED TO ONE NODE) ---
auto_select_host_cores() {
    local total_phys_to_reserve=$1
    local target_node=$2
    local auto_host_cores=()

    local node_phys_cores=()
    local node_smt_cores=()

    # Only scan the target node for available cores
    for cpu_id in $(seq 0 $SMT_END); do
        if [[ -v CPU_TO_NODE["$cpu_id"] && "${CPU_TO_NODE[$cpu_id]}" == "$target_node" ]]; then
            if (( cpu_id >= PHYS_START && cpu_id <= PHYS_END )); then
                node_phys_cores+=("$cpu_id")
            elif (( cpu_id >= SMT_START && cpu_id <= SMT_END )); then
                node_smt_cores+=("$cpu_id")
            fi
        fi
    done

    IFS=$'\n' sorted_phys_cores=($(sort -n <<<"${node_phys_cores[*]}")); unset IFS
    IFS=$'\n' sorted_smt_cores=($(sort -n <<<"${node_smt_cores[*]}")); unset IFS

    local phys_cores_added=0
    for core in "${sorted_phys_cores[@]}"; do
        if (( phys_cores_added < total_phys_to_reserve )); then
            auto_host_cores+=("$core")
            phys_cores_added=$((phys_cores_added + 1))
        fi
    done

    local smt_cores_added=0
    for core in "${sorted_smt_cores[@]}"; do
        if (( smt_cores_added < total_phys_to_reserve )); then
            auto_host_cores+=("$core")
            smt_cores_added=$((smt_cores_added + 1))
        fi
    done

    # Format into JSON array
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

    # Pick the highest NUMA node ID available (usually Node 1)
    TARGET_NODE=${NUMA_NODE_IDS[-1]}

    # Calculate total physical cores to reserve (e.g., -a 2 on a 2-node system = 4 total physical)
    TOTAL_PHYS_TO_RESERVE=$(( CORES_PER_NUMA * ${#NUMA_NODE_IDS[@]} ))

    log "Consolidating host cores: Auto-selecting $TOTAL_PHYS_TO_RESERVE physical + $TOTAL_PHYS_TO_RESERVE SMT core(s) strictly on NUMA Node $TARGET_NODE..."

    HOST_CORES_JSON=$(auto_select_host_cores "$TOTAL_PHYS_TO_RESERVE" "$TARGET_NODE")
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
# --- PHASE 1.5: GPU TOPOLOGY & VRAM CAPACITY CHECK ---
# =============================================================================
log "--- PHASE 1.5: Discovering GPUs and MDEV Capacities ---"

declare -A GPU_MAP GPU_MDEV_PROFILE GPU_SLOTS_FREE
declare -a GPU_PCI_IDS

if [[ $SKIP_GPU -eq 1 ]]; then
    log "  GPU assignment skipped (-g flag set)."
fi

discover_gpus() {
    if [[ $SKIP_GPU -eq 1 ]]; then return; fi
    local target_vram=$(jq -r '.gpu_settings.required_vram_mb // 2048' "$CONFIG_FILE")
    local auto_detect=$(jq -r 'if .gpu_settings.auto_detect_profile == false then "false" else "true" end' "$CONFIG_FILE")
    local manual_mdev=$(jq -r '.gpu_settings.mdev_override // "nvidia-47"' "$CONFIG_FILE")

    log "  GPU Strategy: VRAM=${target_vram}MB, AutoDetect=${auto_detect}"

    # Build lspci input: use gpu_pci_ids override if provided, otherwise auto-detect
    local pci_override_count
    pci_override_count=$(jq -r '(.gpu_settings.gpu_pci_ids // []) | length' "$CONFIG_FILE")

    local lspci_input
    if (( pci_override_count > 0 )); then
        log "  Using config gpu_pci_ids override ($pci_override_count GPU(s) specified)"
        # Fake lspci lines: just the PCI slot — the loop only uses field 1
        lspci_input=$(jq -r '(.gpu_settings.gpu_pci_ids // [])[]' "$CONFIG_FILE")
    else
        lspci_input=$(lspci -D -nn | grep -E "\[03[0-9a-fA-F]{2}\]" | grep -i nvidia)
        if [[ -z "$lspci_input" ]]; then
            warn "  No NVIDIA display-class devices found via lspci. Check lspci output or set gpu_settings.gpu_pci_ids in config."
        fi
    fi

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
                            available_instances=$(cat "${mdev_base}/${type_dir}/available_instances")
                            break
                        fi
                    fi
                done
            else
                # Check for per-GPU profile mapping first
                local gpu_specific_mdev=$(jq -r --arg pci "$pci_slot" '.gpu_settings.gpu_profile_map[$pci] // empty' "$CONFIG_FILE")
                if [[ -n "$gpu_specific_mdev" && -d "${mdev_base}/${gpu_specific_mdev}" ]]; then
                    selected_type="$gpu_specific_mdev"
                    available_instances=$(cat "${mdev_base}/${gpu_specific_mdev}/available_instances")
                    log "    Using per-GPU profile mapping: $gpu_specific_mdev"
                elif [[ -d "${mdev_base}/${manual_mdev}" ]]; then
                    selected_type="$manual_mdev"
                    available_instances=$(cat "${mdev_base}/${manual_mdev}/available_instances")
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

    done < <(echo "$lspci_input")
}

discover_gpus


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
    log "  VM $vmid: $cores cores$([ $SKIP_GPU -eq 1 ] && echo '' || echo ' [GPU REQUIRED]')"
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
    if [[ $SKIP_GPU -eq 1 ]]; then
        # No GPU — pick the least-loaded NUMA node
        best_node=""
        max_free_cores=-1
        for node_id in "${NUMA_NODE_IDS[@]}"; do
            avail_phys_list=(${AVAILABLE_PHYS_CORES["$node_id"]:-})
            avail_smt_list=(${AVAILABLE_SMT_CORES["$node_id"]:-})
            total_avail=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))
            if (( cpu_count <= total_avail && total_avail > max_free_cores )); then
                max_free_cores=$total_avail
                best_node=$node_id
            fi
        done
        if [[ -z "$best_node" ]]; then
            error "VM $vmid: no NUMA node has enough free cores!"
        fi
        log "  Assigning VM $vmid to Node $best_node (no GPU, Node Free: $max_free_cores)"
        assign_resources "$vmid" "$best_node" "" ""
    elif [[ -n "$best_pci" ]]; then
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

        if [[ $SKIP_GPU -eq 0 ]]; then
            if [[ -n "$gpu_pci" && -n "$gpu_mdev" ]]; then
                log "  Attaching GPU: $gpu_pci ($gpu_mdev)"
                qm set "$vmid" -hostpci0 "${gpu_pci},mdev=${gpu_mdev},pcie=1,x-vga=1"
            else
                error "Fatal: VM $vmid should have a GPU but plan is missing it."
            fi
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
        [[ -n "$gpu_pci" ]] && log "[DRY RUN] Set GPU: $gpu_pci ($gpu_mdev)"
    fi
done

log "Script finished."
