#!/bin/bash
set -euo pipefail

# =============================================================================
#
# Proxmox CPU Manager - A Declarative CPU & NUMA Management Script
#
# Author: Your Name/AI Assistant
# Date:   2023-10-27
# Version: 9.1 (Corrected State Management & Core Removal)
#
# =============================================================================


# --- HELPER FUNCTIONS ---
log() { echo "[INFO] $@"; }
warn() { echo "[WARN] $@" >&2; }
error() { echo "[ERROR] $@" >&2; exit 1; }

usage() {
    echo "Usage: $0 -f <config.json> [-n]"
    echo "  -f <config.json>: Path to the JSON configuration file. Required."
    echo "  -n:               Dry run mode. Plan changes but do not execute them. Optional."
    exit 1
}


# --- ARGUMENT PARSING ---
CONFIG_FILE=""
DRY_RUN=0
while getopts "f:nh" opt; do
    case $opt in
        f) CONFIG_FILE="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        \?) error "Invalid option: -$OPTARG" ;;
    esac
done


# --- PREREQUISITE CHECKS ---
if [[ -z "$CONFIG_FILE" ]]; then error "Configuration file (-f) is required."; fi
if [[ ! -f "$CONFIG_FILE" ]]; then error "Configuration file not found at: $CONFIG_FILE"; fi
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then error "This script must be run as root unless in dry run mode."; fi
for cmd in qm lscpu jq bc; do
    if ! command -v "$cmd" &> /dev/null; then error "Required command '$cmd' not found. Please install it (e.g., 'apt install bc')."; fi
done


# =============================================================================
# --- PHASE 1: PARSE SETTINGS & BUILD PRIORITIZED CORE POOLS ---
# =============================================================================
log "--- PHASE 1: Reading Global Settings & Discovering Host Topology ---"

CPU_CONFIG_STRING=$(jq -r '.global_settings.cpu_config_string' "$CONFIG_FILE")
RESERVE_HOST_CORES=$(jq -r '.global_settings.reserve_host_cores' "$CONFIG_FILE")
PHYS_START=$(jq -r '.global_settings.core_definitions.physical_start' "$CONFIG_FILE")
PHYS_END=$(jq -r '.global_settings.core_definitions.physical_end' "$CONFIG_FILE")
SMT_START=$(jq -r '.global_settings.core_definitions.logical_start' "$CONFIG_FILE")
SMT_END=$(jq -r '.global_settings.core_definitions.logical_end' "$CONFIG_FILE")
HOOK_SCRIPT_PATH="local:snippets/vm-isolation-hook.sh"

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

if [[ "$RESERVE_HOST_CORES" == "true" ]]; then
    log "Reserving first physical core of each socket for the host OS..."
    for socket_id in "${!SOCKET_IDS[@]}"; do
        min_core_id=${MIN_CORE_PER_SOCKET["$socket_id"]}
        log "  Socket $socket_id: Reserving physical core $min_core_id."
        for cpu_id in $(seq 0 $SMT_END); do
            if [[ -v CPU_TO_SOCKET["$cpu_id"] && "${CPU_TO_SOCKET[$cpu_id]}" == "$socket_id" && "${CPU_TO_CORE[$cpu_id]}" == "$min_core_id" ]]; then
                CORES_TO_RESERVE+=("$cpu_id"); CORES_TO_RESERVE_MAP["$cpu_id"]=1
            fi
        done
    done
    log "Logical CPUs reserved for host: ${CORES_TO_RESERVE[*]}"
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

USE_SMT_CORES=false
PHYSICAL_CORE_RATIO="1.0"
if (( TOTAL_CORES_REQUESTED > TOTAL_PHYS_CORES_AVAILABLE )); then
    USE_SMT_CORES=true
    PHYSICAL_CORE_RATIO=$(echo "scale=4; $TOTAL_PHYS_CORES_AVAILABLE / $TOTAL_CORES_REQUESTED" | bc)
    log "Physical core oversubscription detected. Using Fairness Mode with Physical Core Ratio: ${PHYSICAL_CORE_RATIO}"
else
    log "Sufficient physical cores are available. SMT cores will only be used if a single large VM requires them."
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
    else
        phys_cores_to_take=$cpu_count
    fi

    if (( phys_cores_to_take > ${#available_phys_on_node[@]} )); then
        phys_cores_to_take=${#available_phys_on_node[@]}
    fi
    smt_cores_to_take=$(( cpu_count - phys_cores_to_take ))

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

        log "Attaching host isolation hook script..."
        qm set "$vmid" --hookscript "$HOOK_SCRIPT_PATH"
        
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
        log "  DRY RUN: Would attach hook script: ${HOOK_SCRIPT_PATH}"
        log "  DRY RUN: Would enable iothread on the boot disk."
        log "--- DRY RUN for VM $vmid COMPLETE ---"
    fi
done

log "Script finished."