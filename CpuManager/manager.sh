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
    echo "  -a [N]:                Auto-select host cores, consolidated on least GPU-loaded NUMA node. Optional."
    echo "  -b [N]:                Auto-select host cores, balanced across physical sockets (N phys + N SMT per socket). Optional."
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
        "version": "11.4-disk-locality",
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
        local assigned_node=$(echo "$plan" | sed -n 's/.*|node=\([^|]*\).*/\1/p')
        local gpu_info=$(echo "$plan" | sed -n 's/.*gpu_pci=\([^|]*\).*/\1/p')
        local mdev_info=$(echo "$plan" | sed -n 's/.*mdev=\([^|]*\).*/\1/p')
                local disk_node=$(echo "$plan" | sed -n 's/.*disk_node=\([^|]*\).*/\1/p')
                local disk_source=$(echo "$plan" | sed -n 's/.*disk_source=\([^|]*\).*/\1/p')
                local disk_match=$(echo "$plan" | sed -n 's/.*disk_match=\([^|]*\).*/\1/p')

        IFS=',' read -ra assigned_cores_array <<< "$assigned_cores_str"

        cat >> "$state_file" << VMSTATEEOF
    "$vmid": {
      "name": "vm-${vmid}",
      "cores": $cpu_count,
      "numa_node": $assigned_node,
            "disk_preference_node": $([ -n "$disk_node" ] && echo "$disk_node" || echo "null"),
            "disk_preference_source": $([ -n "$disk_source" ] && echo "\"$disk_source\"" || echo "null"),
            "disk_locality_matched": $([ -n "$disk_match" ] && echo "$disk_match" || echo "null"),
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

socket_to_node() {
    local socket_id=$1
    local cpu_id

    for cpu_id in $(seq 0 "$SMT_END"); do
        if [[ -v CPU_TO_SOCKET["$cpu_id"] && "${CPU_TO_SOCKET[$cpu_id]}" == "$socket_id" ]]; then
            echo "${CPU_TO_NODE[$cpu_id]}"
            return 0
        fi
    done

    return 1
}

resolve_locality_value_to_node() {
    local locality_value=$1
    local resolved_node=""

    [[ -z "$locality_value" || "$locality_value" == "null" ]] && return 1

    if [[ "$locality_value" =~ ^node:([0-9]+)$ ]]; then
        resolved_node=${BASH_REMATCH[1]}
    elif [[ "$locality_value" =~ ^socket:([0-9]+)$ ]]; then
        resolved_node=$(socket_to_node "${BASH_REMATCH[1]}" 2>/dev/null || true)
    elif [[ "$locality_value" =~ ^[0-9]+$ ]]; then
        if [[ " ${NUMA_NODE_IDS[*]} " =~ " ${locality_value} " ]]; then
            resolved_node=$locality_value
        else
            resolved_node=$(socket_to_node "$locality_value" 2>/dev/null || true)
        fi
    fi

    [[ -n "$resolved_node" ]] || return 1
    echo "$resolved_node"
}

get_vm_boot_disk_device() {
    local vm_config=$1
    local boot_value boot_entry disk_line

    boot_value=$(echo "$vm_config" | sed -n 's/^boot:.*order=//p' | tr -d ' ')
    if [[ -n "$boot_value" ]]; then
        IFS=';' read -ra boot_entries <<< "$boot_value"
        for boot_entry in "${boot_entries[@]}"; do
            if [[ "$boot_entry" =~ ^(scsi|virtio|sata|ide)[0-9]+$ ]]; then
                disk_line=$(echo "$vm_config" | grep -m1 "^${boot_entry}:" || true)
                if [[ -n "$disk_line" && "$disk_line" != *"media=cdrom"* ]]; then
                    echo "$boot_entry"
                    return 0
                fi
            fi
        done
    fi

    echo "$vm_config" | grep -E '^(scsi|virtio|sata|ide)[0-9]+:' | grep -v 'media=cdrom' | head -n1 | cut -d: -f1
}

get_vm_disk_locator() {
    local vm_config=$1
    local boot_disk disk_line

    boot_disk=$(get_vm_boot_disk_device "$vm_config")
    [[ -n "$boot_disk" ]] || return 1

    disk_line=$(echo "$vm_config" | grep -m1 "^${boot_disk}:" || true)
    [[ -n "$disk_line" ]] || return 1

    echo "$disk_line" | awk '{print $2}' | cut -d',' -f1
}

resolve_block_device_node() {
    local device_path=$1
    local device_name parent_name candidate numa_path numa_node sysfs_path current_path

    [[ -n "$device_path" ]] || return 1
    device_name=$(basename "$device_path")
    parent_name="$device_name"

    if command -v lsblk &> /dev/null; then
        parent_name=$(lsblk -ndo PKNAME "$device_path" 2>/dev/null | head -n1)
        [[ -n "$parent_name" ]] || parent_name="$device_name"
    fi

    for candidate in "$parent_name" "$device_name"; do
        [[ -n "$candidate" ]] || continue
        numa_path="/sys/class/block/${candidate}/device/numa_node"
        if [[ -f "$numa_path" ]]; then
            numa_node=$(cat "$numa_path" 2>/dev/null || echo "")
            if [[ "$numa_node" =~ ^[0-9]+$ ]]; then
                echo "$numa_node"
                return 0
            fi
        fi

        sysfs_path=$(readlink -f "/sys/class/block/${candidate}/device" 2>/dev/null || true)
        current_path="$sysfs_path"
        while [[ -n "$current_path" && "$current_path" != "/" ]]; do
            numa_path="${current_path}/numa_node"
            if [[ -f "$numa_path" ]]; then
                numa_node=$(cat "$numa_path" 2>/dev/null || echo "")
                if [[ "$numa_node" =~ ^[0-9]+$ ]]; then
                    echo "$numa_node"
                    return 0
                fi
            fi
            current_path=$(dirname "$current_path")
        done
    done

    return 1
}

resolve_lvm_path_node() {
    local lvm_path=$1
    local vg_name pv_path resolved_node

    command -v lvs &> /dev/null || return 1
    command -v vgs &> /dev/null || return 1

    vg_name=$(lvs --noheadings -o vg_name "$lvm_path" 2>/dev/null | xargs)
    [[ -n "$vg_name" ]] || return 1

    while IFS= read -r pv_path; do
        pv_path=$(echo "$pv_path" | xargs)
        [[ -n "$pv_path" && "$pv_path" == /dev/* ]] || continue
        resolved_node=$(resolve_block_device_node "$pv_path" 2>/dev/null || true)
        if [[ -n "$resolved_node" ]]; then
            echo "$resolved_node"
            return 0
        fi
    done < <(vgs --noheadings -o pv_name "$vg_name" 2>/dev/null)

    return 1
}

resolve_storage_id_node() {
    local storage_id=$1
    local vg_name resolved_node pv_path

    [[ -n "$storage_id" ]] || return 1

    # Local-LVM style: storage ID matches VG name (e.g., VMs8)
    if command -v vgs &> /dev/null; then
        vg_name=$(vgs --noheadings -o vg_name "$storage_id" 2>/dev/null | xargs)
        if [[ -n "$vg_name" ]]; then
            while IFS= read -r pv_path; do
                pv_path=$(echo "$pv_path" | xargs)
                [[ -n "$pv_path" && "$pv_path" == /dev/* ]] || continue
                resolved_node=$(resolve_block_device_node "$pv_path" 2>/dev/null || true)
                if [[ -n "$resolved_node" ]]; then
                    echo "$resolved_node"
                    return 0
                fi
            done < <(vgs --noheadings -o pv_name "$vg_name" 2>/dev/null)
        fi
    fi

    return 1
}

resolve_path_node() {
    local target_path=$1
    local resolved_path source_device lvm_node

    [[ -n "$target_path" ]] || return 1

    resolved_path=$(readlink -f "$target_path" 2>/dev/null || echo "$target_path")
    if [[ -b "$resolved_path" ]]; then
        resolve_block_device_node "$resolved_path"
        if [[ $? -eq 0 ]]; then
            return 0
        fi

        lvm_node=$(resolve_lvm_path_node "$target_path" 2>/dev/null || true)
        if [[ -z "$lvm_node" && "$resolved_path" != "$target_path" ]]; then
            lvm_node=$(resolve_lvm_path_node "$resolved_path" 2>/dev/null || true)
        fi
        if [[ -n "$lvm_node" ]]; then
            echo "$lvm_node"
            return 0
        fi
    fi

    if [[ -e "$resolved_path" ]] && command -v df &> /dev/null; then
        source_device=$(df --output=source "$resolved_path" 2>/dev/null | tail -n1 | xargs)
        if [[ "$source_device" == /dev/* ]]; then
            resolve_block_device_node "$source_device"
            return $?
        fi
    fi

    return 1
}

detect_vm_disk_preference() {
    local vmid=$1
    local configured_value configured_node vm_config disk_locator storage_id storage_node resolved_path resolved_node

    configured_value=$(jq -r --arg vmid "$vmid" '
        .disk_settings.vm_node_map[$vmid]
        // .vm_disk_node_map[$vmid]
        // .storage_settings.vm_node_map[$vmid]
        // empty
    ' "$CONFIG_FILE")
    if [[ -n "$configured_value" ]]; then
        configured_node=$(resolve_locality_value_to_node "$configured_value" 2>/dev/null || true)
        if [[ -n "$configured_node" ]]; then
            echo "$configured_node|config:vm_node_map"
            return 0
        fi
    fi

    vm_config=$(qm config "$vmid" 2>/dev/null || true)
    [[ -n "$vm_config" ]] || return 1

    disk_locator=$(get_vm_disk_locator "$vm_config")
    [[ -n "$disk_locator" ]] || return 1

    if [[ "$disk_locator" != /* ]]; then
        storage_id=${disk_locator%%:*}
        configured_value=$(jq -r --arg storage "$storage_id" '
            .disk_settings.storage_node_map[$storage]
            // .storage_node_map[$storage]
            // .storage_settings.node_map[$storage]
            // empty
        ' "$CONFIG_FILE")
        if [[ -n "$configured_value" ]]; then
            storage_node=$(resolve_locality_value_to_node "$configured_value" 2>/dev/null || true)
            if [[ -n "$storage_node" ]]; then
                echo "$storage_node|config:storage_node_map:${storage_id}"
                return 0
            fi
        fi

        # Offline-safe fallback: infer NUMA node from storage ID via LVM VG->PV mapping.
        storage_node=$(resolve_storage_id_node "$storage_id" 2>/dev/null || true)
        if [[ -n "$storage_node" ]]; then
            echo "$storage_node|storage:${storage_id}"
            return 0
        fi
    fi

    resolved_path=""
    if [[ "$disk_locator" == /* ]]; then
        resolved_path=$disk_locator
    elif command -v pvesm &> /dev/null; then
        resolved_path=$(pvesm path "$disk_locator" 2>/dev/null || true)
    fi

    if [[ -n "$resolved_path" ]]; then
        resolved_node=$(resolve_path_node "$resolved_path" 2>/dev/null || true)
        if [[ -n "$resolved_node" ]]; then
            echo "$resolved_node|path:${resolved_path}"
            return 0
        fi
    fi

    return 1
}

# --- ARGUMENT PARSING ---
CONFIG_FILE=""
DRY_RUN=0
HOOK_SCRIPT_PATH=""
RESET_HOST_PINNING=0
AUTO_HOST_CORES=0
BALANCE_SOCKETS=0
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
        -b|--balance-sockets)
            AUTO_HOST_CORES=1
            BALANCE_SOCKETS=1
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

# Handle -a / -b auto-select host cores (after topology discovery)
if [[ $AUTO_HOST_CORES -eq 1 ]]; then
    log "Auto-selection requested, overriding config host_cores..."
    
    if [[ $BALANCE_SOCKETS -eq 1 ]]; then
        # -b: pick CORES_PER_NUMA phys + CORES_PER_NUMA SMT per physical socket
        log "Socket-balanced selection: Auto-selecting $CORES_PER_NUMA physical + $CORES_PER_NUMA SMT core(s) per socket..."
        local_host_cores=()
        IFS=$'\n' sorted_socket_ids=($(echo "${!SOCKET_IDS[@]}" | tr ' ' '\n' | sort -n)); unset IFS
        for _sock_id in "${sorted_socket_ids[@]}"; do
            _sock_phys=(); _sock_smt=()
            for _cpu_id in $(seq 0 $SMT_END); do
                [[ -v CPU_TO_SOCKET["$_cpu_id"] && "${CPU_TO_SOCKET[$_cpu_id]}" == "$_sock_id" ]] || continue
                if (( _cpu_id >= PHYS_START && _cpu_id <= PHYS_END )); then
                    _sock_phys+=("$_cpu_id")
                elif (( _cpu_id >= SMT_START && _cpu_id <= SMT_END )); then
                    _sock_smt+=("$_cpu_id")
                fi
            done
            IFS=$'\n' _sorted_phys=($(sort -n <<<"${_sock_phys[*]}")); unset IFS
            IFS=$'\n' _sorted_smt=($(sort -n <<<"${_sock_smt[*]}")); unset IFS
            _p=0; for _c in "${_sorted_phys[@]}"; do
                (( _p < CORES_PER_NUMA )) && { local_host_cores+=("$_c"); (( _p++ )) || true; }
            done
            _s=0; for _c in "${_sorted_smt[@]}"; do
                (( _s < CORES_PER_NUMA )) && { local_host_cores+=("$_c"); (( _s++ )) || true; }
            done
            log "  Socket $_sock_id: reserved cores added"
        done
        unset _sock_id _sock_phys _sock_smt _sorted_phys _sorted_smt _p _s _c sorted_socket_ids
        # Convert to JSON
        HOST_CORES_JSON="["
        _first=true
        for _c in "${local_host_cores[@]}"; do
            [[ "$_first" == "true" ]] && HOST_CORES_JSON+="$_c" || HOST_CORES_JSON+=",$_c"
            _first=false
        done
        HOST_CORES_JSON+="]"
        unset local_host_cores _first _c
        log "Socket-balanced host cores: $HOST_CORES_JSON"
    else
        # -a: original consolidation onto the least GPU-loaded NUMA node
        declare -A _node_gpu_slots
        for _nid in "${NUMA_NODE_IDS[@]}"; do _node_gpu_slots["$_nid"]=0; done
        _target_vram=$(jq -r '.gpu_settings.required_vram_mb // 2048' "$CONFIG_FILE")
        while IFS= read -r _pci; do
            [[ -z "$_pci" ]] && continue
            _pci_node=$(cat "/sys/bus/pci/devices/${_pci}/numa_node" 2>/dev/null || echo -1)
            [[ "$_pci_node" == "-1" ]] && _pci_node=0
            _prof=$(jq -r --arg p "$_pci" \
                '.gpu_settings.gpu_profile_map[$p] // .gpu_settings.mdev_override // "nvidia-47"' \
                "$CONFIG_FILE")
            _avail=$(cat "/sys/bus/pci/devices/${_pci}/mdev_supported_types/${_prof}/available_instances" 2>/dev/null || echo 0)
            _mem=$(nvidia-smi --id="$_pci" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo 0)
            if [[ "$_mem" =~ ^[0-9]+$ ]] && (( _mem > 0 )); then
                _max_by_vram=$(( _mem / _target_vram ))
                (( _max_by_vram < _avail )) && _avail=$_max_by_vram
            fi
            _node_gpu_slots["$_pci_node"]=$(( ${_node_gpu_slots[$_pci_node]:-0} + _avail ))
        done < <(jq -r '(.gpu_settings.gpu_pci_ids // (.gpu_settings.gpu_profile_map // {} | keys))[]' \
            "$CONFIG_FILE" 2>/dev/null)
        TARGET_NODE=${NUMA_NODE_IDS[0]}
        _min_slots=${_node_gpu_slots[${NUMA_NODE_IDS[0]}]:-0}
        for _nid in "${NUMA_NODE_IDS[@]}"; do
            if (( ${_node_gpu_slots[$_nid]:-0} < _min_slots )); then
                _min_slots=${_node_gpu_slots[$_nid]:-0}
                TARGET_NODE=$_nid
            fi
        done
        log "  Least GPU-loaded NUMA node: Node $TARGET_NODE (gpu_slots=${_min_slots})"
        unset _node_gpu_slots _target_vram _pci _pci_node _prof _avail _mem _max_by_vram _min_slots _nid

        # Calculate total physical cores to reserve (e.g., -a 2 on a 2-node system = 4 total physical)
        TOTAL_PHYS_TO_RESERVE=$(( CORES_PER_NUMA * ${#NUMA_NODE_IDS[@]} ))

        log "Consolidating host cores: Auto-selecting $TOTAL_PHYS_TO_RESERVE physical + $TOTAL_PHYS_TO_RESERVE SMT core(s) strictly on NUMA Node $TARGET_NODE..."

        HOST_CORES_JSON=$(auto_select_host_cores "$TOTAL_PHYS_TO_RESERVE" "$TARGET_NODE")
        log "Auto-selected host cores: $HOST_CORES_JSON"
    fi

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

declare -A GPU_MAP GPU_MDEV_PROFILE GPU_SLOTS_FREE GPU_SLOTS_REUSABLE GPU_SLOTS_CAP
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
            local vram_slot_cap=0
            if command -v nvidia-smi &> /dev/null; then
                local total_mem_mb=$(nvidia-smi --id="$pci_slot" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "0")
                if [[ "$total_mem_mb" -gt 0 ]]; then
                    local calculated_slots=$(( total_mem_mb / target_vram ))
                    vram_slot_cap=$calculated_slots
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
                if (( vram_slot_cap > 0 )); then
                    GPU_SLOTS_CAP["$pci_slot"]=$vram_slot_cap
                else
                    GPU_SLOTS_CAP["$pci_slot"]=$available_instances
                fi
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
declare -A VMS_TO_CONFIGURE VM_DISK_NODE_PREFERENCE VM_DISK_NODE_SOURCE
declare -A VM_MEMORY_MB VM_HUGEPAGE_1G_PAGES
declare -A NODE_1G_HUGEPAGES_TOTAL NODE_1G_HUGEPAGES_PLANNED
TOTAL_CORES_REQUESTED=0

HUGEPAGE_NODE_SAFETY_PAGES=$(jq -r '.global_settings.hugepage_node_safety_pages // 2' "$CONFIG_FILE")
if [[ ! "$HUGEPAGE_NODE_SAFETY_PAGES" =~ ^[0-9]+$ ]]; then
    HUGEPAGE_NODE_SAFETY_PAGES=2
fi
log "  Hugepage node safety margin: ${HUGEPAGE_NODE_SAFETY_PAGES} x 1G page(s)."

for node_id in "${NUMA_NODE_IDS[@]}"; do
    hp_file="/sys/devices/system/node/node${node_id}/hugepages/hugepages-1048576kB/nr_hugepages"
    NODE_1G_HUGEPAGES_PLANNED["$node_id"]=0
    if [[ -f "$hp_file" ]]; then
        hp_total=$(cat "$hp_file" 2>/dev/null || echo "-1")
        if [[ "$hp_total" =~ ^[0-9]+$ ]]; then
            NODE_1G_HUGEPAGES_TOTAL["$node_id"]=$hp_total
        else
            NODE_1G_HUGEPAGES_TOTAL["$node_id"]=-1
        fi
    else
        NODE_1G_HUGEPAGES_TOTAL["$node_id"]=-1
    fi
done

for vmid in $(jq -r '.vms | keys[]' "$CONFIG_FILE"); do
    cores=$(jq -r --arg vmid "$vmid" '.vms[$vmid]' "$CONFIG_FILE")
    VMS_TO_CONFIGURE["$vmid"]="$cores"
    TOTAL_CORES_REQUESTED=$((TOTAL_CORES_REQUESTED + cores))

    vm_mem_mb=$(qm config "$vmid" 2>/dev/null | awk '/^memory:/ {print $2; exit}')
    if [[ "$vm_mem_mb" =~ ^[0-9]+$ ]] && (( vm_mem_mb > 0 )); then
        vm_pages_1g=$(( (vm_mem_mb + 1023) / 1024 ))
    else
        vm_mem_mb=0
        vm_pages_1g=0
        warn "  VM $vmid: could not read memory size for hugepage planning; hugepage guard skipped for this VM."
    fi
    VM_MEMORY_MB["$vmid"]=$vm_mem_mb
    VM_HUGEPAGE_1G_PAGES["$vmid"]=$vm_pages_1g

    disk_pref_info=$(detect_vm_disk_preference "$vmid" || true)
    if [[ -n "$disk_pref_info" ]]; then
        IFS='|' read -r disk_node disk_source <<< "$disk_pref_info"
        VM_DISK_NODE_PREFERENCE["$vmid"]="$disk_node"
        VM_DISK_NODE_SOURCE["$vmid"]="$disk_source"
        log "  VM $vmid: $cores cores$([ $SKIP_GPU -eq 1 ] && echo '' || echo ' [GPU REQUIRED]') [Disk prefers Node $disk_node via $disk_source]"
    else
        log "  VM $vmid: $cores cores$([ $SKIP_GPU -eq 1 ] && echo '' || echo ' [GPU REQUIRED]') [Disk preference: none detected]"
    fi
done

adjust_gpu_slots_for_running_vms() {
    if [[ $SKIP_GPU -eq 1 ]]; then return; fi

    local vmid vm_status hostpci_line current_pci current_mdev expected_mdev reused_count
    local base_free effective_slots slot_cap effective_reused
    local adjusted_any=false
    declare -A running_vm_gpu_counts

    for current_pci in "${GPU_PCI_IDS[@]}"; do
        running_vm_gpu_counts["$current_pci"]=0
        GPU_SLOTS_REUSABLE["$current_pci"]=0
    done

    for vmid in "${!VMS_TO_CONFIGURE[@]}"; do
        vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || true)
        [[ "$vm_status" == "running" ]] || continue

        hostpci_line=$(qm config "$vmid" 2>/dev/null | sed -n 's/^hostpci0: //p' | head -n1)
        [[ -n "$hostpci_line" ]] || continue

        current_pci=$(echo "$hostpci_line" | cut -d',' -f1)
        [[ -v GPU_SLOTS_FREE["$current_pci"] ]] || continue

        current_mdev=$(echo "$hostpci_line" | sed -n 's/.*mdev=\([^,]*\).*/\1/p')
        expected_mdev=${GPU_MDEV_PROFILE["$current_pci"]:-}

        # Only reclaim slots from running VMs that already use the profile we plan to assign.
        if [[ -n "$expected_mdev" && -n "$current_mdev" && "$current_mdev" != "$expected_mdev" ]]; then
            continue
        fi

        running_vm_gpu_counts["$current_pci"]=$(( ${running_vm_gpu_counts[$current_pci]:-0} + 1 ))
    done

    for current_pci in "${GPU_PCI_IDS[@]}"; do
        reused_count=${running_vm_gpu_counts[$current_pci]:-0}
        base_free=${GPU_SLOTS_FREE[$current_pci]:-0}
        slot_cap=${GPU_SLOTS_CAP[$current_pci]:-0}
        effective_slots=$(( base_free + reused_count ))

        # Guardrail: never let planning exceed this GPU's capacity.
        if (( slot_cap > 0 && effective_slots > slot_cap )); then
            log "  Capping planning capacity on GPU $current_pci: requested ${effective_slots} slot(s) (free=${base_free} + reusable=${reused_count}), cap=${slot_cap}."
            effective_slots=$slot_cap
        fi

        effective_reused=$(( effective_slots - base_free ))
        if (( effective_reused < 0 )); then
            effective_reused=0
        fi

        GPU_SLOTS_REUSABLE["$current_pci"]=$effective_reused
        GPU_SLOTS_FREE["$current_pci"]=$effective_slots

        if (( reused_count > 0 )); then
            adjusted_any=true
            log "  Planning capacity: GPU $current_pci reuses $effective_reused running slot(s) from listed VMs."
        fi
    done

    if [[ "$adjusted_any" == true ]]; then
        log "  Effective GPU slot counts were adjusted to include reusable running assignments."
    fi
}

adjust_gpu_slots_for_running_vms

node_hugepage_fits() {
    local node_id=$1
    local vmid=$2
    local use_safety_margin=$3
    local total_pages=${NODE_1G_HUGEPAGES_TOTAL[$node_id]:--1}
    local planned_pages=${NODE_1G_HUGEPAGES_PLANNED[$node_id]:-0}
    local vm_pages=${VM_HUGEPAGE_1G_PAGES[$vmid]:-0}
    local limit_pages

    if (( total_pages < 0 || vm_pages <= 0 )); then
        return 0
    fi

    limit_pages=$total_pages
    if [[ "$use_safety_margin" == "true" ]]; then
        limit_pages=$(( total_pages - HUGEPAGE_NODE_SAFETY_PAGES ))
        if (( limit_pages < 0 )); then
            limit_pages=0
        fi
    fi

    (( planned_pages + vm_pages <= limit_pages ))
}

preflight_gpu_cpu_feasibility() {
    if [[ $SKIP_GPU -eq 1 ]]; then return; fi

    local total_gpu_vms=${#VMS_TO_CONFIGURE[@]}
    local -A unique_vm_core_counts=()
    local -A unique_vm_page_counts=()
    local vmid vm_cores
    for vmid in "${!VMS_TO_CONFIGURE[@]}"; do
        vm_cores=${VMS_TO_CONFIGURE[$vmid]}
        unique_vm_core_counts["$vm_cores"]=1
        unique_vm_page_counts["${VM_HUGEPAGE_1G_PAGES[$vmid]:-0}"]=1
    done

    # Exact early feasibility is only straightforward when all GPU VMs use one core count.
    if (( ${#unique_vm_core_counts[@]} != 1 )); then
        warn "Skipping strict pre-flight GPU/CPU feasibility check: mixed VM core counts detected."
        return
    fi

    local per_vm_cores
    for per_vm_cores in "${!unique_vm_core_counts[@]}"; do :; done

    local per_vm_pages=0
    local strict_hugepage_check=true
    if (( ${#unique_vm_page_counts[@]} == 1 )); then
        for per_vm_pages in "${!unique_vm_page_counts[@]}"; do :; done
    else
        strict_hugepage_check=false
        warn "Skipping strict pre-flight hugepage feasibility check: mixed VM memory sizes detected."
    fi

    local -A node_gpu_slots=()
    local pci node_id
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        node_gpu_slots["$node_id"]=0
    done

    for pci in "${GPU_PCI_IDS[@]}"; do
        node_id=${GPU_MAP[$pci]}
        node_gpu_slots["$node_id"]=$(( ${node_gpu_slots[$node_id]:-0} + ${GPU_SLOTS_FREE[$pci]:-0} ))
    done

    local total_pairable_vms=0
    local node_free_cores cores_limited_vms slot_limited_vms pairable_on_node
    local node_hugepages_total hugepage_limited_vms
    local avail_phys_list avail_smt_list
    local hugepage_context=""

    if [[ "$strict_hugepage_check" == "true" && "$per_vm_pages" =~ ^[0-9]+$ && $per_vm_pages -gt 0 ]]; then
        hugepage_context=" and ${per_vm_pages}x1G hugepages"
    fi

    log "--- PHASE 2.5: Pre-flight GPU/CPU Feasibility ---"
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        avail_phys_list=(${AVAILABLE_PHYS_CORES["$node_id"]:-})
        avail_smt_list=(${AVAILABLE_SMT_CORES["$node_id"]:-})
        node_free_cores=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))

        cores_limited_vms=$(( node_free_cores / per_vm_cores ))
        slot_limited_vms=${node_gpu_slots[$node_id]:-0}
        pairable_on_node=$cores_limited_vms
        if (( slot_limited_vms < pairable_on_node )); then
            pairable_on_node=$slot_limited_vms
        fi

        node_hugepages_total=${NODE_1G_HUGEPAGES_TOTAL[$node_id]:--1}
        hugepage_limited_vms=$pairable_on_node
        if [[ "$strict_hugepage_check" == "true" && "$per_vm_pages" =~ ^[0-9]+$ && $per_vm_pages -gt 0 && $node_hugepages_total -ge 0 ]]; then
            hugepage_limited_vms=$(( node_hugepages_total / per_vm_pages ))
            if (( hugepage_limited_vms < pairable_on_node )); then
                pairable_on_node=$hugepage_limited_vms
            fi
        fi

        total_pairable_vms=$(( total_pairable_vms + pairable_on_node ))
        if [[ "$strict_hugepage_check" == "true" && "$per_vm_pages" =~ ^[0-9]+$ && $per_vm_pages -gt 0 && $node_hugepages_total -ge 0 ]]; then
            log "  Node $node_id: free_cores=$node_free_cores, gpu_slots=${node_gpu_slots[$node_id]:-0}, hugepages_total=$node_hugepages_total, max_pairable_vms=$pairable_on_node"
        else
            log "  Node $node_id: free_cores=$node_free_cores, gpu_slots=${node_gpu_slots[$node_id]:-0}, max_pairable_vms=$pairable_on_node"
        fi
    done

    if (( total_pairable_vms < total_gpu_vms )); then
        error "Pre-flight failed: requested $total_gpu_vms GPU VM(s), but topology can pair at most $total_pairable_vms VM(s) at ${per_vm_cores} cores each${hugepage_context}. Reduce VM count/cores, reserve fewer host cores, increase GPU slots on constrained NUMA nodes, or add per-node hugepages."
    fi

    log "  Pre-flight passed: requested $total_gpu_vms GPU VM(s), max pairable is $total_pairable_vms."
}

preflight_gpu_cpu_feasibility


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

log_pairing_debug_state() {
    local vmid=$1
    local cpu_count=$2

    warn "Pairing debug for VM $vmid ($cpu_count cores required):"
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        local avail_phys_list=(${AVAILABLE_PHYS_CORES["$node_id"]:-})
        local avail_smt_list=(${AVAILABLE_SMT_CORES["$node_id"]:-})
        local total_avail=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))
        local node_gpu_slots=0
        local node_hugepages_total=${NODE_1G_HUGEPAGES_TOTAL[$node_id]:--1}
        local node_hugepages_planned=${NODE_1G_HUGEPAGES_PLANNED[$node_id]:-0}
        local node_hugepages_remaining="n/a"

        if (( node_hugepages_total >= 0 )); then
            node_hugepages_remaining=$(( node_hugepages_total - node_hugepages_planned ))
        fi

        for pci in "${GPU_PCI_IDS[@]}"; do
            if [[ "${GPU_MAP[$pci]}" == "$node_id" ]]; then
                node_gpu_slots=$(( node_gpu_slots + ${GPU_SLOTS_FREE[$pci]:-0} ))
            fi
        done

        warn "  Node $node_id: free_cores=$total_avail, free_gpu_slots=$node_gpu_slots, hugepages_planned=$node_hugepages_planned, hugepages_total=$node_hugepages_total, hugepages_remaining=$node_hugepages_remaining"
    done

    for pci in "${GPU_PCI_IDS[@]}"; do
        warn "  GPU $pci on Node ${GPU_MAP[$pci]}: slots_free=${GPU_SLOTS_FREE[$pci]:-0} (${GPU_MDEV_PROFILE[$pci]})"
    done
}

assign_resources() {
    local vmid=$1
    local forced_node=$2
    local gpu_pci=$3
    local gpu_mdev=$4
    local cpu_count=${VMS_TO_CONFIGURE[$vmid]}
    local vm_hugepage_pages=${VM_HUGEPAGE_1G_PAGES[$vmid]:-0}
    local disk_node_preference=${VM_DISK_NODE_PREFERENCE[$vmid]:-}
    local disk_source=${VM_DISK_NODE_SOURCE[$vmid]:-}
    local disk_match=false
    
    local target_node=$forced_node
    local avail_phys=(${AVAILABLE_PHYS_CORES["$target_node"]:-})
    local avail_smt=(${AVAILABLE_SMT_CORES["$target_node"]:-})

    if [[ -n "$disk_node_preference" && "$target_node" == "$disk_node_preference" ]]; then
        disk_match=true
    fi
    
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

    local node_hugepages_total=${NODE_1G_HUGEPAGES_TOTAL[$target_node]:--1}
    local node_hugepages_planned=${NODE_1G_HUGEPAGES_PLANNED[$target_node]:-0}
    if (( node_hugepages_total >= 0 && vm_hugepage_pages > 0 )); then
        if (( node_hugepages_planned + vm_hugepage_pages > node_hugepages_total )); then
            error "VM $vmid: Node $target_node has insufficient 1G hugepages! planned=${node_hugepages_planned}, needed=${vm_hugepage_pages}, total=${node_hugepages_total}"
        fi
    fi

    local assigned_cores=( "${avail_phys[@]:0:$phys_needed}" "${avail_smt[@]:0:$smt_needed}" )
    
    # [FIX] Changed delimiter from ':' to '|' to handle PCI IDs correctly
    local plan="cores=$(IFS=,; echo "${assigned_cores[*]}")|node=${target_node}"
    if [[ -n "$gpu_pci" ]]; then plan="$plan|gpu_pci=${gpu_pci}|mdev=${gpu_mdev}"; fi
    if [[ -n "$disk_node_preference" ]]; then
        plan="$plan|disk_node=${disk_node_preference}|disk_source=${disk_source}|disk_match=${disk_match}"
    fi
    
    VM_ASSIGNMENTS["$vmid"]="$plan"
    CORES_ASSIGNED_PER_NODE["$target_node"]=$(( ${CORES_ASSIGNED_PER_NODE[$target_node]} + cpu_count ))
    NODE_1G_HUGEPAGES_PLANNED["$target_node"]=$(( ${NODE_1G_HUGEPAGES_PLANNED[$target_node]:-0} + vm_hugepage_pages ))
    
    for core in "${assigned_cores[@]}"; do
        AVAILABLE_PHYS_CORES["$target_node"]=$(echo "${AVAILABLE_PHYS_CORES[$target_node]}" | sed "s/\b${core}\b\s*//g")
        AVAILABLE_SMT_CORES["$target_node"]=$(echo "${AVAILABLE_SMT_CORES[$target_node]}" | sed "s/\b${core}\b\s*//g")
    done
}

# --- MAIN ASSIGNMENT LOOP ---
for vmid in $sorted_vmids; do
    cpu_count=${VMS_TO_CONFIGURE[$vmid]}
    preferred_disk_node=${VM_DISK_NODE_PREFERENCE[$vmid]:-}
    preferred_disk_source=${VM_DISK_NODE_SOURCE[$vmid]:-}
    best_pci=""
    best_hugepage_fit_score=-1
    best_match_score=-1
    max_free_cores=-1
    slot_and_core_candidates=0
    slot_core_hugepage_blocked=0

    # 1. SCAN for Best Candidate
    for pci in "${GPU_PCI_IDS[@]}"; do
        if [[ ${GPU_SLOTS_FREE[$pci]} -gt 0 ]]; then
            node=${GPU_MAP[$pci]}
            match_score=0
            hugepage_fit_score=1

            # Count free cores on this node (Global Vars used, NO LOCAL)
            avail_phys_list=(${AVAILABLE_PHYS_CORES["$node"]:-})
            avail_smt_list=(${AVAILABLE_SMT_CORES["$node"]:-})
            total_avail=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))

            if (( cpu_count > total_avail )); then
                continue
            fi

            slot_and_core_candidates=$(( slot_and_core_candidates + 1 ))

            if ! node_hugepage_fits "$node" "$vmid" "false"; then
                slot_core_hugepage_blocked=$(( slot_core_hugepage_blocked + 1 ))
                continue
            fi

            if [[ -n "$preferred_disk_node" && "$node" == "$preferred_disk_node" ]]; then
                match_score=1
            fi
            if ! node_hugepage_fits "$node" "$vmid" "true"; then
                hugepage_fit_score=0
            fi

            if (( hugepage_fit_score > best_hugepage_fit_score \
                || (hugepage_fit_score == best_hugepage_fit_score && match_score > best_match_score) \
                || (hugepage_fit_score == best_hugepage_fit_score && match_score == best_match_score && total_avail > max_free_cores) )); then
                best_hugepage_fit_score=$hugepage_fit_score
                best_match_score=$match_score
                max_free_cores=$total_avail
                best_pci=$pci
            fi
        fi
    done

    # 2. ASSIGN if candidate found
    if [[ $SKIP_GPU -eq 1 ]]; then
        # No GPU — pick the least-loaded NUMA node
        best_node=""
        best_hugepage_fit_score=-1
        best_match_score=-1
        max_free_cores=-1
        for node_id in "${NUMA_NODE_IDS[@]}"; do
            avail_phys_list=(${AVAILABLE_PHYS_CORES["$node_id"]:-})
            avail_smt_list=(${AVAILABLE_SMT_CORES["$node_id"]:-})
            total_avail=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))
            match_score=0
            hugepage_fit_score=1
            if [[ -n "$preferred_disk_node" && "$node_id" == "$preferred_disk_node" ]]; then
                match_score=1
            fi
            if ! node_hugepage_fits "$node_id" "$vmid" "false"; then
                continue
            fi
            if ! node_hugepage_fits "$node_id" "$vmid" "true"; then
                hugepage_fit_score=0
            fi
            if (( cpu_count <= total_avail )) && (( hugepage_fit_score > best_hugepage_fit_score \
                || (hugepage_fit_score == best_hugepage_fit_score && match_score > best_match_score) \
                || (hugepage_fit_score == best_hugepage_fit_score && match_score == best_match_score && total_avail > max_free_cores) )); then
                best_hugepage_fit_score=$hugepage_fit_score
                best_match_score=$match_score
                max_free_cores=$total_avail
                best_node=$node_id
            fi
        done
        if [[ -z "$best_node" ]]; then
            error "VM $vmid: no NUMA node has enough free cores!"
        fi
        if [[ -n "$preferred_disk_node" ]]; then
            log "  Assigning VM $vmid to Node $best_node (disk prefers Node $preferred_disk_node via $preferred_disk_source, matched=$([ "$best_node" == "$preferred_disk_node" ] && echo yes || echo no), Node Free: $max_free_cores)"
        else
            log "  Assigning VM $vmid to Node $best_node (no GPU, disk preference=none, Node Free: $max_free_cores)"
        fi
        assign_resources "$vmid" "$best_node" "" ""
    elif [[ -n "$best_pci" ]]; then
        pci=$best_pci
        node=${GPU_MAP[$pci]}
        mdev=${GPU_MDEV_PROFILE[$pci]}

        if [[ -n "$preferred_disk_node" ]]; then
            log "  Assigning GPU $pci ($mdev) on Node $node to VM $vmid (disk prefers Node $preferred_disk_node via $preferred_disk_source, matched=$([ "$node" == "$preferred_disk_node" ] && echo yes || echo no), Node Free: $max_free_cores)"
        else
            log "  Assigning GPU $pci ($mdev) on Node $node to VM $vmid (disk preference=none, Node Free: $max_free_cores)"
        fi
        assign_resources "$vmid" "$node" "$pci" "$mdev"
        GPU_SLOTS_FREE[$pci]=$(( ${GPU_SLOTS_FREE[$pci]} - 1 ))
    else
        log_pairing_debug_state "$vmid" "$cpu_count"
        if (( slot_and_core_candidates > 0 && slot_core_hugepage_blocked == slot_and_core_candidates )); then
            error "VM $vmid has GPU slot/core candidate(s), but none have enough remaining 1G hugepages on their NUMA node. Add per-node hugepages or reduce VM memory/host reservations."
        fi
        error "VM $vmid needs a GPU/CPU pair, but no valid slot/core combination was found!"
    fi
done

for node_id in "${NUMA_NODE_IDS[@]}"; do
    node_hp_total=${NODE_1G_HUGEPAGES_TOTAL[$node_id]:--1}
    node_hp_planned=${NODE_1G_HUGEPAGES_PLANNED[$node_id]:-0}
    if (( node_hp_total >= 0 )); then
        log "  Node $node_id hugepages(1G): planned=${node_hp_planned}, total=${node_hp_total}, safety_margin=${HUGEPAGE_NODE_SAFETY_PAGES}"
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
    node=$(echo "$plan" | sed -n 's/.*|node=\([^|]*\).*/\1/p')
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
