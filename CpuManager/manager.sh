#!/bin/bash
set -euo pipefail

# --- HELPER FUNCTIONS ---
log() { echo "[INFO] $@"; }
warn() { echo "[WARN] $@" >&2; }
error() { echo "[ERROR] $@" >&2; exit 1; }

usage() {
    echo "Usage: $0 -f <config.json> [-n] [-s <hook_script_path>] [-r] [-a [N]]"
    echo "  -f <config.json>:      Path to the JSON configuration file. Required."
    echo "  -n:                    Dry run mode. Plan changes but do not execute them. Optional."
    echo "  -s <hook_script_path>: Path to hook script for VM isolation. Optional."
    echo "                         If not specified, no hook script will be attached."
    echo "  -r:                    Show commands to reset host core pinning (allow all cores). Optional."
    echo "  -a [N]:                Auto-select first N physical + N SMT core(s) per NUMA node for host pinning. Optional."
    echo "                         If N is not specified, defaults to 1 physical + 1 SMT core per NUMA node."
    exit 1
}



# =============================================================================
# --- STATE MANAGEMENT FUNCTIONS ---
# =============================================================================

create_state_file() {
    local state_file="manager_state.json"
    local timestamp=$(date -Iseconds)
    
    log "Creating state file: $state_file"
    
    # Start building the state JSON
    cat > "$state_file" << STATEEOF
{
  "metadata": {
    "timestamp": "$timestamp",
    "version": "9.7",
    "config_file": "$CONFIG_FILE",
    "total_vms_configured": ${#VMS_TO_CONFIGURE[@]},
    "total_cores_requested": $TOTAL_CORES_REQUESTED,
    "total_phys_available": $TOTAL_PHYS_CORES_AVAILABLE,
    "total_smt_available": $TOTAL_SMT_CORES_AVAILABLE,
    "dry_run": $([ $DRY_RUN -eq 1 ] && echo "true" || echo "false")
  },
  "topology": {
    "numa_nodes": [$(IFS=','; echo "${NUMA_NODE_IDS[*]}")],
    "socket_ids": [$(for socket in "${!SOCKET_IDS[@]}"; do echo -n "$socket,"; done | sed 's/,$//')]
  },
  "core_assignments": {
STATEEOF

    # Add VM assignments
    local vm_count=0
    local total_vms=${#VMS_TO_CONFIGURE[@]}
    
    for vmid in $(for key in "${!VMS_TO_CONFIGURE[@]}"; do echo "$key"; done | sort -n); do
        vm_count=$((vm_count + 1))
        local cpu_count=${VMS_TO_CONFIGURE[$vmid]}
        local plan=${VM_ASSIGNMENTS[$vmid]}
        local assigned_cores_str=$(echo "$plan" | sed -n 's/.*cores=\([^:]*\):.*/\1/p')
        local assigned_node=$(echo "$plan" | sed -n 's/.*node=\(.*\)/\1/p')
        
        # Convert cores string to array
        IFS=',' read -ra assigned_cores_array <<< "$assigned_cores_str"
        
        # Get VM name from original config
        local vm_name=$(jq -r --arg vmid "$vmid" '.vms[] | select(.vmid == ($vmid | tonumber)) | .name' "$CONFIG_FILE")
        
        cat >> "$state_file" << VMSTATEEOF
    "$vmid": {
      "name": "$vm_name",
      "cores": $cpu_count,
      "assigned_physical_cores": [$(IFS=','; echo "${assigned_cores_array[*]}")],
      "numa_node": $assigned_node,
      "vcpu_mapping": {
VMSTATEEOF

        # Create vCPU to physical CPU mapping
        local vcpu=0
        for core in "${assigned_cores_array[@]}"; do
            echo "        \"$vcpu\": $core$([ $vcpu -lt $((cpu_count - 1)) ] && echo "," || echo "")" >> "$state_file"
            vcpu=$((vcpu + 1))
        done
        
        cat >> "$state_file" << VMSTATEEOF2
      },
      "windows_optimization": {
        "system_vcpus": [0],
        "game_vcpus": [$(seq -s, 1 $((cpu_count - 1)))]
      }
    }$([ $vm_count -lt $total_vms ] && echo "," || echo "")
VMSTATEEOF2
    done
    
    cat >> "$state_file" << STATEEOF2
  },
  "reserved_cores": [$(IFS=','; echo "${CORES_TO_RESERVE[*]:-}")],
  "available_cores": {
STATEEOF2

    # Add available cores per node
    local node_count=0
    local total_nodes=${#NUMA_NODE_IDS[@]}
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        node_count=$((node_count + 1))
        cat >> "$state_file" << NODESTATEEOF
    "$node_id": {
      "remaining_physical": [$(echo "${AVAILABLE_PHYS_CORES[$node_id]}" | tr ' ' ',' | sed 's/,$//' | sed 's/^,//')],
      "remaining_smt": [$(echo "${AVAILABLE_SMT_CORES[$node_id]}" | tr ' ' ',' | sed 's/,$//' | sed 's/^,//')]
    }$([ $node_count -lt $total_nodes ] && echo "," || echo "")
NODESTATEEOF
    done
    
    cat >> "$state_file" << STATEEOF3
  }
}
STATEEOF3

    log "State file created successfully: $state_file"
}

# --- ARGUMENT PARSING ---
CONFIG_FILE=""
DRY_RUN=0
HOOK_SCRIPT_PATH=""
RESET_HOST_PINNING=0
AUTO_HOST_CORES=0
CORES_PER_NUMA=1  # Default to 1 core per NUMA node

# Handle all arguments manually to support optional argument for -a
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -s|--hook-script)
            HOOK_SCRIPT_PATH="$2"
            shift 2
            ;;
        -r|--reset-host-pinning)
            RESET_HOST_PINNING=1
            shift
            ;;
        -a|--auto-host-cores)
            AUTO_HOST_CORES=1
            # Check if next argument is a number
            if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then
                CORES_PER_NUMA="$2"
                shift 2
            else
                shift
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done


# --- PREREQUISITE CHECKS ---
if [[ -z "$CONFIG_FILE" ]]; then error "Configuration file (-f) is required."; fi
if [[ ! -f "$CONFIG_FILE" ]]; then error "Configuration file not found at: $CONFIG_FILE"; fi
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then error "This script must be run as root unless in dry run mode."; fi
for cmd in qm lscpu jq bc; do
    if ! command -v "$cmd" &> /dev/null; then error "Required command '$cmd' not found. Please install it (e.g., 'apt install bc')."; fi
done

# Hook script validation (only if specified)
if [[ -n "$HOOK_SCRIPT_PATH" ]]; then
    log "Hook script specified: $HOOK_SCRIPT_PATH"
else
    log "No hook script specified - VMs will be configured without isolation hooks"
fi

# Handle host core pinning reset
if [[ $RESET_HOST_PINNING -eq 1 ]]; then
    log "Host core pinning reset commands (run these manually as root):"
    echo ""
    echo "  # Reset system.slice to allow all cores"
    echo "  systemctl set-property system.slice AllowedCPUs=\"\""
    echo ""
    echo "  # Reset user.slice to allow all cores"
    echo "  systemctl set-property user.slice AllowedCPUs=\"\""
    echo ""
    echo "  # Reset init.scope to allow all cores"
    echo "  systemctl set-property init.scope AllowedCPUs=\"\""
    echo ""
    log "Host core pinning reset complete."
    exit 0
fi


# =============================================================================
# --- PHASE 1: PARSE SETTINGS & BUILD PRIORITIZED CORE POOLS ---
# =============================================================================
log "--- PHASE 1: Reading Global Settings & Discovering Host Topology ---"

CPU_CONFIG_STRING=$(jq -r '.global_settings.cpu_config_string' "$CONFIG_FILE")
RESERVE_HOST_CORES=$(jq -r '.global_settings.reserve_host_cores' "$CONFIG_FILE")

# Read host cores configuration
HOST_CORES_JSON=$(jq -r '.global_settings.host_cores // []' "$CONFIG_FILE")
if [[ "$HOST_CORES_JSON" == "[]" || "$HOST_CORES_JSON" == "null" ]]; then
    HOST_CORES_JSON=""
fi

# Auto-select first core per NUMA node function
auto_select_host_cores() {
    # Use the already-parsed topology data
    local auto_host_cores=()
    
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        # Collect physical and SMT cores separately for this NUMA node
        local node_phys_cores=()
        local node_smt_cores=()
        
        # Look through all CPUs to find cores for this node
        for cpu_id in $(seq 0 $SMT_END); do
            if [[ -v CPU_TO_NODE["$cpu_id"] && "${CPU_TO_NODE[$cpu_id]}" == "$node_id" ]]; then
                # Check if it's a physical core (within PHYS_START to PHYS_END)
                if (( cpu_id >= PHYS_START && cpu_id <= PHYS_END )); then
                    node_phys_cores+=("$cpu_id")
                # Check if it's an SMT core (within SMT_START to SMT_END)
                elif (( cpu_id >= SMT_START && cpu_id <= SMT_END )); then
                    node_smt_cores+=("$cpu_id")
                fi
            fi
        done
        
        # Sort cores numerically
        IFS=$'\n' sorted_phys_cores=($(sort -n <<<"${node_phys_cores[*]}")); unset IFS
        IFS=$'\n' sorted_smt_cores=($(sort -n <<<"${node_smt_cores[*]}")); unset IFS
        
        
        # Add the first CORES_PER_NUMA physical cores from this node
        local phys_cores_added=0
        for core in "${sorted_phys_cores[@]}"; do
            if (( phys_cores_added < CORES_PER_NUMA )); then
                auto_host_cores+=("$core")
                phys_cores_added=$((phys_cores_added + 1))
            fi
        done
        
        # Add the first CORES_PER_NUMA SMT cores from this node
        local smt_cores_added=0
        for core in "${sorted_smt_cores[@]}"; do
            if (( smt_cores_added < CORES_PER_NUMA )); then
                auto_host_cores+=("$core")
                smt_cores_added=$((smt_cores_added + 1))
            fi
        done
    done
    
    # Convert array to JSON format
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

# Auto-detect core definitions from system topology
auto_detect_core_definitions() {
    log "Auto-detecting core definitions from system topology..."
    
    # Get unique core IDs and sort them
    local unique_cores=($(lscpu -p=CPU,CORE,SOCKET,NODE | grep -v '^#' | awk -F',' '{print $2}' | sort -n | uniq))
    local total_cores=${#unique_cores[@]}
    local max_core_id=${unique_cores[$((total_cores - 1))]}
    
    # Get total logical CPUs
    local total_cpus=$(lscpu -p=CPU,CORE,SOCKET,NODE | grep -v '^#' | wc -l)
    
    # Physical cores are typically the first half (or first N cores)
    # SMT cores are the second half (or cores N+1 to total)
    PHYS_START=0
    PHYS_END=$max_core_id
    SMT_START=$((max_core_id + 1))
    SMT_END=$((total_cpus - 1))
    
    log "Auto-detected core definitions:"
    log "  Physical cores: $PHYS_START to $PHYS_END (total: $((PHYS_END - PHYS_START + 1)))"
    log "  SMT cores: $SMT_START to $SMT_END (total: $((SMT_END - SMT_START + 1)))"
    log "  Total logical CPUs: $total_cpus"
}

# Always auto-detect core definitions from actual system topology
log "Auto-detecting core definitions from system topology..."
auto_detect_core_definitions

# Update the config file with auto-detected core definitions
log "Updating config file with auto-detected core definitions..."
if [[ $DRY_RUN -eq 0 ]]; then
    # Create a backup of the original config file (if not already created by host cores update)
    backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    if [[ ! -f "$backup_file" ]]; then
        cp "$CONFIG_FILE" "$backup_file"
        log "  Created backup: $backup_file"
    fi
    
    # Update the core_definitions in the config file
    core_defs_json="{\"physical_start\":$PHYS_START,\"physical_end\":$PHYS_END,\"logical_start\":$SMT_START,\"logical_end\":$SMT_END}"
    if jq --argjson core_defs "$core_defs_json" '.global_settings.core_definitions = $core_defs' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        log "  Updated core_definitions in config file: $CONFIG_FILE"
    else
        error "Failed to update config file with auto-detected core definitions"
    fi
else
    log "  DRY RUN: Would update core_definitions in config file: $CONFIG_FILE"
fi

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

# Check if auto-selection is requested (after topology discovery)
if [[ $AUTO_HOST_CORES -eq 1 ]]; then
    log "Auto-selection requested, overriding config host_cores..."
    log "Auto-selecting first $CORES_PER_NUMA physical + $CORES_PER_NUMA SMT core(s) per NUMA node for host pinning..."
    HOST_CORES_JSON=$(auto_select_host_cores)
    log "Auto-selected host cores: $HOST_CORES_JSON"
    
    # Update the config file with the auto-selected cores
    log "Updating config file with auto-selected host cores..."
    if [[ $DRY_RUN -eq 0 ]]; then
        # Create a backup of the original config file
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        log "  Created backup: ${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Update the host_cores in the config file
        if jq --argjson host_cores "$HOST_CORES_JSON" '.global_settings.host_cores = $host_cores' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
            mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            log "  Updated host_cores in config file: $CONFIG_FILE"
        else
            error "Failed to update config file with auto-selected host cores"
        fi
    else
        log "  DRY RUN: Would update host_cores in config file: $CONFIG_FILE"
        log "  DRY RUN: Would create backup: ${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Log the selected cores for clarity
    while IFS= read -r core_id; do
        if [[ "$core_id" =~ ^[0-9]+$ ]]; then
            # Find which NUMA node this core belongs to
            node_id=""
            for cpu in $(seq 0 $SMT_END); do
                if [[ -v CPU_TO_NODE["$cpu"] && "$cpu" == "$core_id" ]]; then
                    node_id=${CPU_TO_NODE["$cpu"]}
                    break
                fi
            done
            log "  NUMA node $node_id: Selected core $core_id"
        fi
    done < <(echo "$HOST_CORES_JSON" | jq -r '.[]')
fi

if [[ "$RESERVE_HOST_CORES" == "true" ]]; then
    
    if [[ -n "$HOST_CORES_JSON" ]]; then
        log "Reserving configured host cores from config file..."
        # Parse the JSON array and add each core to the reservation list
        while IFS= read -r core_id; do
            if [[ "$core_id" =~ ^[0-9]+$ ]]; then
                # Validate core ID is within system range
                if (( core_id >= 0 && core_id <= SMT_END )); then
                    CORES_TO_RESERVE+=("$core_id")
                    CORES_TO_RESERVE_MAP["$core_id"]=1
                    log "  Reserving CPU $core_id for host OS"
                else
                    error "Host core ID $core_id is out of range (0-$SMT_END). Please check your configuration."
                fi
            else
                error "Invalid host core ID in config: $core_id (must be numeric)"
            fi
        done < <(echo "$HOST_CORES_JSON" | jq -r '.[]')
        log "Configured CPUs reserved for host: ${CORES_TO_RESERVE[*]}"
    else
        log "No host_cores configured, auto-detecting first physical core of each socket..."
        for socket_id in "${!SOCKET_IDS[@]}"; do
            min_core_id=${MIN_CORE_PER_SOCKET["$socket_id"]}
            log "  Socket $socket_id: Reserving physical core $min_core_id."
            for cpu_id in $(seq 0 $SMT_END); do
                if [[ -v CPU_TO_SOCKET["$cpu_id"] && "${CPU_TO_SOCKET[$cpu_id]}" == "$socket_id" && "${CPU_TO_CORE[$cpu_id]}" == "$min_core_id" ]]; then
                    CORES_TO_RESERVE+=("$cpu_id"); CORES_TO_RESERVE_MAP["$cpu_id"]=1
                fi
            done
        done
        log "Auto-detected CPUs reserved for host: ${CORES_TO_RESERVE[*]}"
    fi
    
    # Provide host core pinning commands for manual execution
    if [[ ${#CORES_TO_RESERVE[@]} -gt 0 ]]; then
        host_cores_string=$(IFS=' '; echo "${CORES_TO_RESERVE[*]}")
        
        log "Host core pinning commands (run these manually as root):"
        echo ""
        echo "  # Pin system.slice to reserved cores"
        echo "  systemctl set-property system.slice AllowedCPUs=\"$host_cores_string\""
        echo ""
        echo "  # Pin user.slice to reserved cores"
        echo "  systemctl set-property user.slice AllowedCPUs=\"$host_cores_string\""
        echo ""
        echo "  # Pin init.scope to reserved cores"
        echo "  systemctl set-property init.scope AllowedCPUs=\"$host_cores_string\""
        echo ""
        echo "  # To reset host pinning (allow all cores):"
        echo "  systemctl set-property system.slice AllowedCPUs=\"\""
        echo "  systemctl set-property user.slice AllowedCPUs=\"\""
        echo "  systemctl set-property init.scope AllowedCPUs=\"\""
        echo ""
    fi
fi

declare -A AVAILABLE_PHYS_CORES AVAILABLE_SMT_CORES
TOTAL_PHYS_CORES_AVAILABLE=0
TOTAL_SMT_CORES_AVAILABLE=0
for node_id in "${NUMA_NODE_IDS[@]}"; do
    AVAILABLE_PHYS_CORES["$node_id"]=""; AVAILABLE_SMT_CORES["$node_id"]=""
done
for cpu_id in $(seq "$PHYS_START" "$PHYS_END"); do
    if [[ -v CPU_TO_NODE["$cpu_id"] && ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then
        node=${CPU_TO_NODE["$cpu_id"]}; AVAILABLE_PHYS_CORES["$node"]+="$cpu_id "
        TOTAL_PHYS_CORES_AVAILABLE=$((TOTAL_PHYS_CORES_AVAILABLE + 1))
    fi
done
for cpu_id in $(seq "$SMT_START" "$SMT_END"); do
    if [[ -v CPU_TO_NODE["$cpu_id"] && ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then
        node=${CPU_TO_NODE["$cpu_id"]}; AVAILABLE_SMT_CORES["$node"]+="$cpu_id "
        TOTAL_SMT_CORES_AVAILABLE=$((TOTAL_SMT_CORES_AVAILABLE + 1))
    fi
done

log "Initialization complete. Total physical cores available for VMs: $TOTAL_PHYS_CORES_AVAILABLE"
log "Initialization complete. Total SMT cores available for VMs: $TOTAL_SMT_CORES_AVAILABLE"


# =============================================================================
# --- PHASE 2: READ AND VALIDATE VM CONFIGURATION ---
# =============================================================================
log "--- PHASE 2: Reading and Validating VM Configurations ---"
declare -A VMS_TO_CONFIGURE
TOTAL_CORES_REQUESTED=0

while IFS= read -r json_object; do
    [[ -z "$json_object" ]] && continue
    vmid=$(jq -r '.vmid' <<< "$json_object"); cores=$(jq -r '.cores' <<< "$json_object"); name=$(jq -r '.name' <<< "$json_object")
    if ! [[ "$vmid" =~ ^[0-9]+$ && "$cores" =~ ^[1-9][0-9]*$ ]]; then
        error "Invalid VM entry in JSON for '${name}'. VMID and Cores must be positive integers."
    fi
    log "  Found enabled VM: ${name} (VMID: ${vmid}), requesting ${cores} cores."
    VMS_TO_CONFIGURE["$vmid"]="$cores"; TOTAL_CORES_REQUESTED=$((TOTAL_CORES_REQUESTED + cores))
done < <(jq -c '.vms[] | select(.enabled == true)' "$CONFIG_FILE")

if [[ ${#VMS_TO_CONFIGURE[@]} -eq 0 ]]; then error "No VMs with 'enabled: true' found in config."; fi
if (( TOTAL_CORES_REQUESTED > (TOTAL_PHYS_CORES_AVAILABLE + TOTAL_SMT_CORES_AVAILABLE) )); then
    error "Resource overdraft: Requested cores ($TOTAL_CORES_REQUESTED) exceed total available ($((TOTAL_PHYS_CORES_AVAILABLE + TOTAL_SMT_CORES_AVAILABLE)))."
fi


# =============================================================================
# --- PHASE 3: PLAN CORE ASSIGNMENTS WITH FAIRNESS ALGORITHM ---
# =============================================================================
log "--- PHASE 3: Planning All Core Assignments with Fairness Algorithm ---"
declare -A VM_ASSIGNMENTS
declare -A CORES_ASSIGNED_PER_NODE
for node_id in "${NUMA_NODE_IDS[@]}"; do CORES_ASSIGNED_PER_NODE["$node_id"]=0; done

USE_SMT_CORES=true
# Always use balanced SMT core distribution
# Use a balanced ratio that ensures both physical and SMT cores are used
if (( TOTAL_CORES_REQUESTED > TOTAL_PHYS_CORES_AVAILABLE )); then
    PHYSICAL_CORE_RATIO=$(echo "scale=4; $TOTAL_PHYS_CORES_AVAILABLE / $TOTAL_CORES_REQUESTED" | bc)
    log "Physical core oversubscription detected. Using Fairness Mode with Physical Core Ratio: ${PHYSICAL_CORE_RATIO}"
else
    # When there are enough physical cores, use a balanced approach (e.g., 70% physical, 30% SMT)
    PHYSICAL_CORE_RATIO="0.7"
    log "Using balanced SMT core distribution. Physical Core Ratio: ${PHYSICAL_CORE_RATIO}"
fi

sorted_vmids=$(for vmid in "${!VMS_TO_CONFIGURE[@]}"; do echo "${VMS_TO_CONFIGURE[$vmid]} $vmid"; done | sort -rn | awk '{print $2}')

for vmid in $sorted_vmids; do
    cpu_count=${VMS_TO_CONFIGURE[$vmid]}
    
    min_load=${CORES_ASSIGNED_PER_NODE[${NUMA_NODE_IDS[0]}]}
    target_node=${NUMA_NODE_IDS[0]}
    for node_id in "${NUMA_NODE_IDS[@]:1}"; do
        if (( ${CORES_ASSIGNED_PER_NODE[$node_id]} < min_load )); then
            min_load=${CORES_ASSIGNED_PER_NODE[$node_id]}; target_node=$node_id
        fi
    done
    
    available_phys_on_node=(${AVAILABLE_PHYS_CORES["$target_node"]:-})
    available_smt_on_node=(${AVAILABLE_SMT_CORES["$target_node"]:-})
    
    phys_cores_to_take=0; smt_cores_to_take=0
    if [[ "$USE_SMT_CORES" == true ]]; then
        phys_cores_to_take=$(echo "$cpu_count * $PHYSICAL_CORE_RATIO / 1" | bc)
        # Ensure we don't take more physical cores than available
        if (( phys_cores_to_take > ${#available_phys_on_node[@]} )); then
            phys_cores_to_take=${#available_phys_on_node[@]}
        fi
        smt_cores_to_take=$(( cpu_count - phys_cores_to_take ))
        # Ensure SMT cores is not negative
        if (( smt_cores_to_take < 0 )); then
            smt_cores_to_take=0
        fi
    else
        phys_cores_to_take=$cpu_count
        smt_cores_to_take=0
    fi

    if (( smt_cores_to_take > ${#available_smt_on_node[@]} )); then
        error "Fatal planning error for VM ${vmid} on node ${target_node}. Not enough SMT cores to make up the difference."
    fi
    
    log "  VM ${vmid} on Node ${target_node} will be assigned: ${phys_cores_to_take} Physical, ${smt_cores_to_take} SMT"

    cores_to_assign_list=( "${available_phys_on_node[@]:0:$phys_cores_to_take}" )
    cores_to_assign_list+=( "${available_smt_on_node[@]:0:$smt_cores_to_take}" )
    
    VM_ASSIGNMENTS["$vmid"]="cores=$(IFS=,; echo "${cores_to_assign_list[*]}"):node=${target_node}"

    CORES_ASSIGNED_PER_NODE["$target_node"]=$(( ${CORES_ASSIGNED_PER_NODE[$target_node]} + cpu_count ))

    # --- DEFINITIVE STATE MANAGEMENT FIX ---
    # Loop through each assigned core and explicitly remove it from the correct pool string.
    for core in "${cores_to_assign_list[@]}"; do
        # The '\b' ensures we match whole words (e.g., '1' not '11').
        # The '\s*' handles any trailing spaces gracefully.
        AVAILABLE_PHYS_CORES["$target_node"]=$(echo "${AVAILABLE_PHYS_CORES[$target_node]}" | sed "s/\b${core}\b\s*//g")
        AVAILABLE_SMT_CORES["$target_node"]=$(echo "${AVAILABLE_SMT_CORES[$target_node]}" | sed "s/\b${core}\b\s*//g")
    done
    # --- END OF FIX ---
done

log "Assignment planning complete."

# =============================================================================
# --- PHASE 3.5: CREATE STATE FILE ---
# =============================================================================
log "--- PHASE 3.5: Creating State File ---"
create_state_file
sorted_vmid_keys=$(for key in "${!VM_ASSIGNMENTS[@]}"; do echo "$key"; done | sort -n)
for vmid in $sorted_vmid_keys; do log "  VM ${vmid} Plan -> ${VM_ASSIGNMENTS[$vmid]}"; done


# =============================================================================
# --- PHASE 4: EXECUTE PLANNED CONFIGURATION ---
# =============================================================================
log "--- PHASE 4: Executing Planned Configuration ---"
if [[ $DRY_RUN -eq 1 ]]; then warn "*** DRY RUN MODE ACTIVE - NO CHANGES WILL BE MADE ***"; fi

for vmid in "${!VMS_TO_CONFIGURE[@]}"; do
    log "--- Processing VMID: $vmid ---"
    cpu_count=${VMS_TO_CONFIGURE[$vmid]}
    plan=${VM_ASSIGNMENTS[$vmid]}
    affinity_option=$(echo "$plan" | sed -n 's/.*cores=\([^:]*\):.*/\1/p')
    assigned_node=$(echo "$plan" | sed -n 's/.*node=\(.*\)/\1/p')
    
    if [[ $DRY_RUN -eq 0 ]]; then
        log "Setting cores, CPU flags, and affinity..."
        qm set "$vmid" -cores "$cpu_count" -cpu "$CPU_CONFIG_STRING" -affinity "$affinity_option"
        
        log "Setting NUMA, Hugepages, and Ballooning..."
        vm_memory=$(qm config "$vmid" | grep '^memory:' | awk '{print $2}')
        numa_cpus_range="0-$((cpu_count - 1))"
        numa0_opts="cpus=${numa_cpus_range},hostnodes=${assigned_node},memory=${vm_memory},policy=bind"
        qm set "$vmid" -numa 1 -numa0 "$numa0_opts" -hugepages 1024 -balloon 0
        
        log "Setting virtio NIC queues..."
        while IFS= read -r line; do
            iface=$(echo "$line" | awk -F': ' '{print $1}'); current_opts=$(echo "$line" | awk -F': ' '{print $2}')
            if [[ "$current_opts" == *"virtio"* ]]; then
                opts_without_queues=$(echo "$current_opts" | sed -E 's/,?queues=[0-9]+//g')
                final_opts="${opts_without_queues},queues=${cpu_count}"
                qm set "$vmid" -"$iface" "$final_opts"
            fi
        done < <(qm config "$vmid" | grep '^net[0-9]\+:' || true)

        # Hook script attachment (only if specified)
        if [[ -n "$HOOK_SCRIPT_PATH" ]]; then
            log "Attaching host isolation hook script: $HOOK_SCRIPT_PATH"
            qm set "$vmid" --hookscript "$HOOK_SCRIPT_PATH"
        else
            log "Skipping hook script attachment (not specified)"
        fi
        
        log "Enabling I/O thread on boot disk..."
        boot_disk_device=$(qm config "$vmid" | grep '^boot:' | sed -e 's/.*order=//' -e 's/;.*//' -e 's/(.*)//' || true)
        if [[ -n "$boot_disk_device" ]]; then
            disk_config_line=$(qm config "$vmid" | grep "^${boot_disk_device}:" || true)
            if [[ -n "$disk_config_line" && "$disk_config_line" != *"iothread=1"* ]]; then
                disk_storage_path=$(echo "$disk_config_line" | awk -F': ' '{print $2}' | cut -d',' -f1)
                all_disk_options=$(echo "$disk_config_line" | awk -F': ' '{print $2}' | cut -d',' -f2-)
                final_disk_options="${all_disk_options},iothread=1"
                qm set "$vmid" -"$boot_disk_device" "${disk_storage_path},${final_disk_options}"
            fi
        fi
        log "--- Configuration for VM $vmid COMPLETE ---"
    else
        log "  DRY RUN: Would set cores=${cpu_count}, affinity=${affinity_option}, numa_node=${assigned_node}"
        log "  DRY RUN: Would enable hugepages, disable ballooning, and set virtio NIC queues."
        if [[ -n "$HOOK_SCRIPT_PATH" ]]; then
            log "  DRY RUN: Would attach hook script: ${HOOK_SCRIPT_PATH}"
        else
            log "  DRY RUN: Would skip hook script attachment (not specified)"
        fi
        log "  DRY RUN: Would enable iothread on the boot disk."
        log "--- DRY RUN for VM $vmid COMPLETE ---"
    fi
done

log "Script finished."
