#!/bin/bash

# --- Configuration ---
# Set the desired CPU model. x86-64-v2-AES is a good modern baseline.
CPU_TYPE_BASE="x86-64-v2-AES"
# Add/remove CPU flags. Semicolon-separated.
# +pdpe1gb: Exposes 1GB Hugepage capability to the guest.
# -spec-intel: Disables Spectre (IBRS/IBPB) mitigations for performance. SECURITY RISK.
# -md-clear: Disables VERW instruction on idle to clear microarchitectural buffers. SECURITY RISK.
CPU_TYPE_FLAGS="+pdpe1gb;-spec-intel;-md-clear"
# This combines the above into the final string used by qm set.
CPU_OPTION_STRING="${CPU_TYPE_BASE},flags=${CPU_TYPE_FLAGS}"
# Option to disable automatic host core reservation if needed
RESERVE_HOST_CORES=1 # Set to 0 to disable reservation

# --- Script Logic ---
set -euo pipefail

# --- Helper Functions ---
log() { echo "[INFO] $@"; }
warn() { echo "[WARN] $@" >&2; }
error() { echo "[ERROR] $@" >&2; exit 1; }

usage() {
    echo "Usage: $0 -r <vmid_range> -c <cpu_count> [-i <ignored_vmids>] [-n] [-x]"
    echo "  -r <vmid_range>:   Range of VM IDs (e.g., '100-105', '100,102,105', '100-103,105'). Required."
    echo "  -c <cpu_count>:    Number of CPU cores to assign to each VM. Required."
    echo "  -i <ignored_vmids>: Comma-separated list of VM IDs to ignore (e.g., '101,104'). Optional."
    echo "  -n:                Dry run mode. Show what would be done without making changes. Optional."
    echo "  -x:                Disable automatic host core reservation (reserves first physical core/socket). Optional."
    echo ""
    echo "  This script sets CPU core count, affinity, CPU type/flags ('${CPU_OPTION_STRING}'),"
    echo "  virtio NIC queues, 1GB hugepages, NUMA topology (including numa0 config),"
    echo "  and disables memory ballooning."
    echo "  WARNING: Review security warnings about disabled mitigations."
    exit 1
}

# ... (parse_range function remains the same) ...
parse_range() {
    local input_range=$1; local output_list=(); IFS=',' read -ra ranges <<< "$input_range"
    for range in "${ranges[@]}"; do if [[ "$range" == *-* ]]; then local start=$(echo "$range" | cut -d'-' -f1); local end=$(echo "$range" | cut -d'-' -f2); if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]]; then error "Invalid range: $range"; fi; for (( i=start; i<=end; i++ )); do output_list+=("$i"); done; elif [[ "$range" =~ ^[0-9]+$ ]]; then output_list+=("$range"); else error "Invalid element: $range"; fi; done
    printf "%s\n" "${output_list[@]}" | sort -un
}

# --- Argument Parsing ---
VMID_RANGE=""; CPU_COUNT=""; IGNORED_VMIDS_RAW=""; DRY_RUN=0
while getopts "r:c:i:nxh" opt; do
    case $opt in r) VMID_RANGE="$OPTARG" ;; c) CPU_COUNT="$OPTARG" ;; i) IGNORED_VMIDS_RAW="$OPTARG" ;; n) DRY_RUN=1 ;; x) RESERVE_HOST_CORES=0 ;; h) usage ;; \?) error "Invalid option: -$OPTARG" ;; esac
done
if [[ -z "$VMID_RANGE" || -z "$CPU_COUNT" ]]; then error "VM ID range (-r) and CPU count (-c) are required."; fi
if ! [[ "$CPU_COUNT" =~ ^[1-9][0-9]*$ ]]; then error "CPU count (-c) must be a positive integer."; fi
if [[ $RESERVE_HOST_CORES -eq 1 ]]; then log "Host core reservation ENABLED."; else log "Host core reservation DISABLED by -x flag."; fi

# --- Prerequisite Checks ---
if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]]; then error "Must run as root unless in dry run mode."; fi
for cmd in qm lscpu grep awk sed sort head cut declare; do if ! command -v $cmd &> /dev/null; then if [[ "$cmd" == "declare" && "$(type -t declare)" == "builtin" ]]; then continue; fi; error "Required command '$cmd' not found."; fi; done

# --- Security and Host Config Warnings ---
log "********************************************************************************"
log "*** SECURITY WARNING: CPU mitigations are being DISABLED via CPU flags.      ***"
log "*** This increases performance but exposes VMs to security vulnerabilities   ***"
log "*** like Spectre and others. Only proceed in a fully trusted environment.    ***"
log "********************************************************************************"
log "*** HOST CONFIGURATION WARNINGS ***"
log "1. 1GB Hugepages: Ensure host configured ('hugepagesz=1G hugepages=N' + reboot)."
log "2. CPU Governor: Ensure host set to 'performance'."
log "3. KSM: Consider disabling KSM on host."
log "***********************************"

# --- Parse Ignored VMs ---
declare -A IGNORED_VMID_MAP
if [[ -n "$IGNORED_VMIDS_RAW" ]]; then IFS=',' read -ra ignored_list <<< "$IGNORED_VMIDS_RAW"; for vmid in "${ignored_list[@]}"; do if [[ "$vmid" =~ ^[0-9]+$ ]]; then IGNORED_VMID_MAP["$vmid"]=1; log "Will ignore VMID: $vmid"; else warn "Ignoring invalid VMID '$vmid' in ignored list."; fi; done; fi

# --- Parse Target VMs ---
TARGET_VMIDS=(); while IFS= read -r line; do TARGET_VMIDS+=("$line"); done < <(parse_range "$VMID_RANGE")
if [[ ${#TARGET_VMIDS[@]} -eq 0 ]]; then error "No valid VM IDs found in range: $VMID_RANGE"; fi
log "Target VM IDs: ${TARGET_VMIDS[*]}"

# --- NUMA Discovery and Host Core Reservation ---
log "Detecting NUMA layout and reserving host cores..."
declare -A ALL_CORES_NODE; declare -A CPU_TO_CORE; declare -A CPU_TO_SOCKET; declare -A CPU_TO_NODE; declare -a ALL_LOGICAL_CPUS=();
declare -A SOCKET_IDS; declare -A MIN_CORE_PER_SOCKET; declare -a CORES_TO_RESERVE=(); declare -A CORES_TO_RESERVE_MAP

# Step 1: Parse full topology from lscpu
while IFS= read -r line; do
    [[ "$line" =~ ^# ]] && continue; [[ -z "$line" ]] && continue
    cpu_id=$(echo "$line" | awk -F',' '{print $1}'); core_id=$(echo "$line" | awk -F',' '{print $2}'); socket_id=$(echo "$line" | awk -F',' '{print $3}'); node_id=$(echo "$line" | awk -F',' '{print $4}')
    if [[ -z "$cpu_id" || ! "$cpu_id" =~ ^[0-9]+$ ]]; then warn "Parse error (CPU): $line"; continue; fi
    if [[ -z "$core_id" || ! "$core_id" =~ ^[0-9]+$ ]]; then core_id="?"; fi
    if [[ -z "$socket_id" || ! "$socket_id" =~ ^[0-9]+$ ]]; then socket_id=0; fi
    if [[ -z "$node_id" || ! "$node_id" =~ ^[0-9]+$ ]]; then node_id=0; fi
    ALL_LOGICAL_CPUS+=("$cpu_id"); CPU_TO_CORE["$cpu_id"]=$core_id; CPU_TO_SOCKET["$cpu_id"]=$socket_id; CPU_TO_NODE["$cpu_id"]=$node_id; SOCKET_IDS["$socket_id"]=1
    if [[ -v ALL_CORES_NODE["$node_id"] ]]; then ALL_CORES_NODE["$node_id"]+="$cpu_id "; else ALL_CORES_NODE["$node_id"]="$cpu_id "; fi
    if [[ "$core_id" != "?" ]]; then if [[ ! -v MIN_CORE_PER_SOCKET["$socket_id"] || "$core_id" -lt "${MIN_CORE_PER_SOCKET["$socket_id"]}" ]]; then MIN_CORE_PER_SOCKET["$socket_id"]=$core_id; fi; fi
done < <(lscpu -p=CPU,CORE,SOCKET,NODE 2>/dev/null)
if [[ ${#ALL_LOGICAL_CPUS[@]} -eq 0 ]]; then error "Could not detect any CPU information via lscpu."; fi

# Step 2: Identify cores to reserve
if [[ $RESERVE_HOST_CORES -eq 1 ]]; then
    log "Identifying host cores to reserve (first physical core per socket)..."
    for socket_id in "${!SOCKET_IDS[@]}"; do
        if [[ ! -v MIN_CORE_PER_SOCKET["$socket_id"] ]]; then warn "Cannot determine min physical core for socket $socket_id. Cannot reserve."; continue; fi
        min_core_id=${MIN_CORE_PER_SOCKET["$socket_id"]}; log "  Socket $socket_id: Reserving physical core $min_core_id."
        reserved_count_this_socket=0
        for cpu_id in "${ALL_LOGICAL_CPUS[@]}"; do
            if [[ "${CPU_TO_SOCKET[$cpu_id]}" == "$socket_id" && "${CPU_TO_CORE[$cpu_id]}" == "$min_core_id" ]]; then
                CORES_TO_RESERVE+=("$cpu_id"); CORES_TO_RESERVE_MAP["$cpu_id"]=1; log "    -> Reserving logical CPU: $cpu_id"
                reserved_count_this_socket=$((reserved_count_this_socket + 1))
            fi
        done
        if [[ $reserved_count_this_socket -eq 0 ]]; then warn "    -> No logical CPUs found for physical core $min_core_id on socket $socket_id."; fi
    done
    log "Total logical CPUs reserved for host: ${CORES_TO_RESERVE[*]}"
else log "Host core reservation skipped by user."; fi

# Step 3: Filter reserved cores and initialize available cores
declare -A NUMA_CORES; declare -A AVAILABLE_CORES_NODE; NUMA_NODE_IDS=(); TOTAL_LOGICAL_CORES_AVAILABLE=0
for node_id in "${!ALL_CORES_NODE[@]}"; do
    available_node_cores_str=""; cores_on_node=(${ALL_CORES_NODE["$node_id"]})
    for cpu_id in "${cores_on_node[@]}"; do if [[ ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then available_node_cores_str+="$cpu_id "; fi; done
    available_node_cores_str=${available_node_cores_str% }; if [[ -n "$available_node_cores_str" ]]; then
        NUMA_CORES["$node_id"]="$available_node_cores_str"; AVAILABLE_CORES_NODE["$node_id"]="$available_node_cores_str"; NUMA_NODE_IDS+=("$node_id")
        cores_array=($available_node_cores_str); TOTAL_LOGICAL_CORES_AVAILABLE=$((TOTAL_LOGICAL_CORES_AVAILABLE + ${#cores_array[@]}))
    else log "  Node $node_id has no available cores after host reservation."; fi
done
if [[ ${#NUMA_NODE_IDS[@]} -gt 0 ]]; then IFS=$'\n' NUMA_NODE_IDS=($(sort -n <<<"${NUMA_NODE_IDS[*]}")); unset IFS;
else error "No NUMA nodes with available cores found after potential host reservation."; fi
NUM_NUMA_NODES=${#NUMA_NODE_IDS[@]}
log "Initialization complete. $NUM_NUMA_NODES NUMA node(s) with available cores for VMs: ${NUMA_NODE_IDS[*]}"
for node_id in "${NUMA_NODE_IDS[@]}"; do cores_array=(${AVAILABLE_CORES_NODE["$node_id"]}); log "  Node $node_id available cores (${#cores_array[@]}): ${cores_array[*]}"; done
log "Total logical cores available for VMs: $TOTAL_LOGICAL_CORES_AVAILABLE"
if [[ $TOTAL_LOGICAL_CORES_AVAILABLE -lt $CPU_COUNT ]]; then error "Total available cores ($TOTAL_LOGICAL_CORES_AVAILABLE) < required per VM ($CPU_COUNT)."; fi

# --- Core Assignment Loop ---
declare -A ASSIGNED_CORES_TOTAL; CURRENT_NODE_INDEX=0
log "Starting VM configuration process..."
for vmid in "${TARGET_VMIDS[@]}"; do
    log "--- Processing VMID: $vmid ---"
    if [[ -v IGNORED_VMID_MAP["$vmid"] ]]; then log "Ignoring VMID $vmid."; continue; fi
    if ! qm config "$vmid" > /dev/null 2>&1; then warn "VMID $vmid does not exist. Skipping."; continue; fi

    # Find a suitable NUMA node and cores
    assigned_node=-1; cores_to_assign_list=""; nodes_checked=0; start_node_check_index=$CURRENT_NODE_INDEX
    while [[ $nodes_checked -lt $NUM_NUMA_NODES ]]; do
        node_id=${NUMA_NODE_IDS[$CURRENT_NODE_INDEX]}; if [[ ! -v AVAILABLE_CORES_NODE["$node_id"] || -z "${AVAILABLE_CORES_NODE["$node_id"]}" ]]; then log "Node $node_id has no available cores. Checking next."; nodes_checked=$((nodes_checked + 1)); CURRENT_NODE_INDEX=$(((CURRENT_NODE_INDEX + 1) % NUM_NUMA_NODES)); continue; fi
        available_cores_on_node=(${AVAILABLE_CORES_NODE["$node_id"]}); num_available=${#available_cores_on_node[@]}; log "Checking Node $node_id: $num_available available core(s)."
        if [[ $num_available -ge $CPU_COUNT ]]; then cores_to_assign_list=$(printf "%s," "${available_cores_on_node[@]:0:$CPU_COUNT}"); cores_to_assign_list=${cores_to_assign_list%,}; assigned_node=$node_id; remaining_cores=("${available_cores_on_node[@]:$CPU_COUNT}"); AVAILABLE_CORES_NODE["$node_id"]="${remaining_cores[*]}"; log "Selected Node $node_id. Assigning cores: $cores_to_assign_list"; break; fi
        CURRENT_NODE_INDEX=$(((CURRENT_NODE_INDEX + 1) % NUM_NUMA_NODES)); nodes_checked=$((nodes_checked + 1)); if [[ $CURRENT_NODE_INDEX -eq $start_node_check_index ]]; then break; fi
    done
    if [[ $assigned_node -eq -1 ]]; then warn "Could not find NUMA node with $CPU_COUNT available cores for VM $vmid. Skipping."; CURRENT_NODE_INDEX=$(((start_node_check_index + 1) % NUM_NUMA_NODES)); continue; fi

    # Apply VM Configuration
    log "Applying settings for VM $vmid..."
    cores_step_failed=0; cpu_step_failed=0; affinity_step_failed=0; numa_enable_step_failed=0; numa0_config_step_failed=0; hugepages_step_failed=0; balloon_step_failed=0

    # Stage 0: Set Core Count
    log "--- Stage 0: Setting Core Count ---"; log "  Setting Core Count: -cores ${CPU_COUNT}"
    if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -cores "$CPU_COUNT"; then warn "Failed to set core count."; cores_step_failed=1; else log "  Successfully set core count."; fi; else log "  DRY RUN: qm set $vmid -cores ..."; cores_step_failed=0; fi

    # Stage 1: Set CPU Type and Flags
    if [[ $cores_step_failed -eq 0 ]]; then
        log "--- Stage 1: Setting CPU Type and Flags ---"
        if [[ $DRY_RUN -eq 0 ]]; then qm set "$vmid" --delete cpu &> /dev/null || true; fi
        log "  Setting CPU Type & Flags: -cpu \"${CPU_OPTION_STRING}\""
        if [[ $DRY_RUN -eq 0 ]]; then set_cpu_output=$(qm set "$vmid" -cpu "$CPU_OPTION_STRING" 2>&1) || cpu_step_failed=$?; if [[ $cpu_step_failed -ne 0 ]]; then warn "Failed CPU type/flags (Exit: $cpu_step_failed)"; warn "  Output: ${set_cpu_output//$'\n'/\\n}"; else log "  Successfully set CPU type/flags."; cpu_step_failed=0; fi
        else log "  DRY RUN: qm set $vmid -cpu ..."; cpu_step_failed=0; fi
    else log "  Skipping CPU Type/Flags setting due to Core Count failure."; cpu_step_failed=1; fi

    # Stage 2: Set affinity
    if [[ $cores_step_failed -eq 0 && $cpu_step_failed -eq 0 ]]; then
        log "--- Stage 2: Setting CPU Affinity ---"; affinity_option="${cores_to_assign_list}"
        if [[ $DRY_RUN -eq 0 ]]; then qm set "$vmid" --delete affinity &> /dev/null || true; fi
        log "  Setting CPU Affinity: -affinity ${affinity_option}"
        if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -affinity "$affinity_option"; then warn "Failed to set CPU affinity."; affinity_step_failed=1; else log "  Successfully set CPU affinity."; fi; else log "  DRY RUN: qm set $vmid -affinity ..."; fi
    else log "  Skipping Affinity setting due to previous failure."; affinity_step_failed=1; fi

    critical_cpu_failed=$((cores_step_failed + cpu_step_failed + affinity_step_failed))

    # Stage 3a: Enable NUMA
    if [[ $critical_cpu_failed -eq 0 ]]; then
        log "--- Stage 3a: Enabling NUMA ---"; if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -numa 1; then warn "Failed to enable NUMA."; numa_enable_step_failed=1; else log "Successfully enabled NUMA."; fi; else log "    DRY RUN: qm set $vmid -numa 1"; fi
    else log "  Skipping NUMA enabling."; numa_enable_step_failed=1; fi

    # Stage 3b: Configure Guest NUMA Node 0
    if [[ $critical_cpu_failed -eq 0 && $numa_enable_step_failed -eq 0 ]]; then
        log "--- Stage 3b: Configuring Guest NUMA Node 0 ---"
        vm_memory=$(qm config "$vmid" | grep '^memory:' | awk '{print $2}') || vm_memory=""; if [[ -z "$vm_memory" ]]; then warn "  Could not fetch memory size for VM $vmid."; numa0_config_step_failed=1; else
            log "  Detected VM memory: $vm_memory MB"; numa_cpus_range="0-$((CPU_COUNT - 1))"; numa0_opts="cpus=${numa_cpus_range},hostnodes=${assigned_node},memory=${vm_memory},policy=bind"
            log "  Setting Guest NUMA Node 0: -numa0 \"${numa0_opts}\""
            if [[ $DRY_RUN -eq 0 ]]; then qm set "$vmid" --delete numa0 &> /dev/null || true; if ! qm set "$vmid" -numa0 "$numa0_opts"; then warn "  Failed to set numa0 config."; numa0_config_step_failed=1; else log "  Successfully configured numa0."; fi; else log "    DRY RUN: qm set $vmid -numa0 ..."; fi
        fi
    else log "  Skipping NUMA0 configuration."; numa0_config_step_failed=1; fi

    # Stage 4: Set Hugepages
    if [[ $critical_cpu_failed -eq 0 ]]; then
        log "--- Stage 4: Setting 1GB Hugepages ---"; if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -hugepages 1024; then warn "Failed to set hugepages. (Host configured?)"; hugepages_step_failed=1; else log "Successfully set hugepages."; fi; else log "    DRY RUN: qm set $vmid -hugepages 1024"; fi
    else log "  Skipping Hugepages setting."; hugepages_step_failed=1; fi

    # Stage 5: Disable Ballooning
    if [[ $critical_cpu_failed -eq 0 ]]; then
        log "--- Stage 5: Disabling Memory Ballooning ---"; if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -balloon 0; then warn "Failed to disable ballooning."; balloon_step_failed=1; else log "Successfully disabled ballooning."; fi; else log "    DRY RUN: qm set $vmid -balloon 0"; fi
    else log "  Skipping Ballooning setting."; balloon_step_failed=1; fi

    # Stage 6: Set virtio NIC queues directly
    if [[ $critical_cpu_failed -eq 0 ]]; then
        log "--- Stage 6: Setting virtio NIC queues ---"; declare -a net_lines; net_lines=()
        while IFS= read -r line; do [[ -z "$line" ]] && continue; net_lines+=("$line"); done < <(qm config "$vmid" | grep '^net[0-9]\+:') || { log "  No network interfaces (netX) found."; net_lines=(); }
        if [[ ${#net_lines[@]} -gt 0 ]]; then
            for net_line in "${net_lines[@]}"; do iface=$(echo "$net_line" | awk -F': ' '{print $1}'); current_opts=$(echo "$net_line" | awk -F': ' '{print $2}'); if [[ "$current_opts" == *"virtio"* ]]; then current_queues=$(echo "$current_opts" | grep -o 'queues=[0-9]\+' | cut -d= -f2) || current_queues=""; if [[ "$current_queues" == "$CPU_COUNT" ]]; then log "    Queues already set for ${iface}."; continue; fi; new_opts=$(echo "$current_opts" | sed -E 's/,?queues=[0-9]+//g; s/^,//; s/,*$//' ); if [[ -n "$new_opts" ]]; then new_opts+=",queues=${CPU_COUNT}"; else base_opts=$(echo "$current_opts" | awk -F, '{print $1}'); new_opts="${base_opts},queues=${CPU_COUNT}"; new_opts=${new_opts#,} ; fi; log "    Setting options for ${iface}: '${new_opts}'"; if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -"$iface" "$new_opts"; then warn "    Failed to set queues for ${iface}."; fi; else log "    DRY RUN: qm set $vmid -${iface} ..."; fi; else log "    ${iface} not virtio, skipping."; fi; done
        fi
    else log "  Skipping NIC queue setting."; fi

    # Finalization
    assigned_cores_array=(); IFS=',' read -ra assigned_cores_array <<< "$cores_to_assign_list"; for core in "${assigned_cores_array[@]}"; do ASSIGNED_CORES_TOTAL["$core"]=1; done
    assigned_node_index=-1; for i in "${!NUMA_NODE_IDS[@]}"; do if [[ "${NUMA_NODE_IDS[$i]}" = "$assigned_node" ]]; then assigned_node_index="$i"; break; fi; done
    if [[ $assigned_node_index -ne -1 ]]; then CURRENT_NODE_INDEX=$(((assigned_node_index + 1) % NUM_NUMA_NODES)); else CURRENT_NODE_INDEX=$(((start_node_check_index + 1) % NUM_NUMA_NODES)); warn "Could not find index for assigned node $assigned_node."; fi
    log "--- Finished processing VMID: $vmid ---"
done

log "Script finished."
if [[ $DRY_RUN -eq 1 ]]; then log "*** DRY RUN MODE ACTIVE - NO CHANGES WERE MADE ***"; fi
exit 0
