#!/bin/bash

# --- BASH VERSION CHECK ---
# This script requires features from Bash v4.0+. Exit if not compatible.
if [[ -z "$BASH_VERSION" || "${BASH_VERSION%%.*}" -lt 4 ]]; then
    echo "ERROR: This script requires Bash version 4.0 or newer." >&2
    echo "Your Bash version is: ${BASH_VERSION:-'Not Bash or unknown'}" >&2
    echo "Please run with a modern Bash shell (e.g., 'bash ./your_script_name.sh')." >&2
    exit 1
fi

# --- Configuration ---
CPU_CONFIG_STRING="host,flags=+md-clear;-pcid;-spec-ctrl;-ssbd;+pdpe1gb;+hv-tlbflush;+aes"
RESERVE_HOST_CORES=1 # Set to 0 to disable reservation

# --- Script Logic ---
set -euo pipefail

# --- Helper Functions ---
log() { echo "[INFO] $@"; }
warn() { echo "[WARN] $@" >&2; }
error() { echo "[ERROR] $@" >&2; exit 1; }

usage() {
    echo "Usage: $0 -r <vmid_range> -c <cpu_count> [-i <ignored_vmids>] [-n] [-x] [-s]"
    echo "  -r <vmid_range>:   Range of VM IDs. Required."
    echo "  -c <cpu_count>:    Number of CPU cores to assign to each VM. Required."
    echo "  -i <ignored_vmids>: Comma-separated list of VM IDs to ignore. Optional."
    echo "  -n:                Dry run mode. Optional."
    echo "  -x:                Disable automatic host core reservation. Optional."
    echo "  -s:                Enable sibling-aware core assignment. Optional."
    echo ""
    echo "  This script sets core count, affinity, CPU type/flags (target: '${CPU_CONFIG_STRING}'),"
    echo "  queues, hugepages, NUMA, and disables ballooning."
    echo "  WARNING: Review security warnings about disabled mitigations."
    exit 1
}

parse_range() {
    local input_range=$1; local output_list=()
    IFS=',' read -ra ranges <<< "$input_range"
    for range in "${ranges[@]}"; do
        if [[ "$range" == *-* ]]; then
            local start; start=$(echo "$range" | cut -d'-' -f1)
            local end; end=$(echo "$range" | cut -d'-' -f2)
            if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]]; then error "Invalid range: $range"; fi
            for (( i=start; i<=end; i++ )); do output_list+=("$i"); done
        elif [[ "$range" =~ ^[0-9]+$ ]]; then output_list+=("$range");
        else error "Invalid element: $range"; fi
    done
    printf "%s\n" "${output_list[@]}" | sort -un
}

# --- Argument Parsing ---
VMID_RANGE=""; CPU_COUNT=""; IGNORED_VMIDS_RAW=""; DRY_RUN=0; SIBLING_AWARE=0
while getopts "r:c:i:nxhs" opt; do
    case $opt in
        r) VMID_RANGE="$OPTARG" ;; c) CPU_COUNT="$OPTARG" ;; i) IGNORED_VMIDS_RAW="$OPTARG" ;;
        n) DRY_RUN=1 ;; x) RESERVE_HOST_CORES=0 ;; s) SIBLING_AWARE=1 ;;
        h) usage ;; \?) error "Invalid option: -$OPTARG" ;;
    esac
done

if [[ -z "$VMID_RANGE" || -z "$CPU_COUNT" ]]; then error "VM ID range (-r) and CPU count (-c) are required."; fi
if ! [[ "$CPU_COUNT" =~ ^[1-9][0-9]*$ ]]; then error "CPU count (-c) must be a positive integer."; fi
if [[ $RESERVE_HOST_CORES -eq 1 ]]; then log "Host core reservation ENABLED."; else log "Host core reservation DISABLED by -x flag."; fi
if [[ $SIBLING_AWARE -eq 1 ]]; then log "Sibling-aware core assignment ENABLED."; else log "Linear core assignment ENABLED."; fi

# --- Prerequisite Checks ---
if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]]; then error "This script must be run as root unless in dry run mode."; fi
for cmd in qm lscpu grep awk sed sort head cut; do
    if ! command -v "$cmd" &> /dev/null; then error "Required command '$cmd' not found."; fi
done

# --- Security and Host Config Warnings ---
log "********************************************************************************"
log "*** SECURITY WARNING: CPU mitigations are being DISABLED via CPU flags.      ***"
log "*** This increases performance but exposes VMs to security vulnerabilities.  ***"
log "*** Only proceed in a fully trusted environment.                             ***"
log "********************************************************************************"
log "*** HOST CONFIGURATION WARNINGS ***"
log "1. 1GB Hugepages: Ensure host configured ('hugepagesz=1G hugepages=N' + reboot)."
log "2. CPU Governor: Ensure host set to 'performance'."
log "3. KSM: Consider disabling KSM on host."
log "***********************************"

# --- Parse Ignored VMs ---
declare -A IGNORED_VMID_MAP
if [[ -n "$IGNORED_VMIDS_RAW" ]]; then
    IFS=',' read -ra ignored_list <<< "$IGNORED_VMIDS_RAW"
    for vmid in "${ignored_list[@]}"; do
        if [[ "$vmid" =~ ^[0-9]+$ ]]; then IGNORED_VMID_MAP["$vmid"]=1; log "Will ignore VMID: $vmid";
        else warn "Ignoring invalid VMID '$vmid' in ignored list."; fi
    done
fi

# --- Parse Target VMs ---
TARGET_VMIDS_TEMP=()
while IFS= read -r line; do TARGET_VMIDS_TEMP+=("$line"); done < <(parse_range "$VMID_RANGE")
TARGET_VMIDS=()
for vmid in "${TARGET_VMIDS_TEMP[@]}"; do if [[ ! -v IGNORED_VMID_MAP["$vmid"] ]]; then TARGET_VMIDS+=("$vmid"); fi; done
if [[ ${#TARGET_VMIDS[@]} -eq 0 ]]; then error "No valid, non-ignored VM IDs found to process."; fi
log "Final list of VMs to process: ${TARGET_VMIDS[*]}"

# --- NUMA Discovery and Host Core Reservation ---
log "Detecting NUMA layout and reserving host cores..."
declare -A ALL_CORES_NODE; declare -A CPU_TO_CORE; declare -A CPU_TO_SOCKET; declare -a ALL_LOGICAL_CPUS
declare -A SOCKET_IDS; declare -A MIN_CORE_PER_SOCKET; declare -a CORES_TO_RESERVE; declare -A CORES_TO_RESERVE_MAP
SMT_LEVEL=1

# Safely capture lscpu output and check for errors
lscpu_output=$(lscpu -p=CPU,CORE,SOCKET,NODE 2>&1) || error "lscpu command failed. Please check if it is installed and works. The error was:\n$lscpu_output"
if [[ -z "$lscpu_output" ]]; then error "lscpu command succeeded but produced no output. Cannot detect CPU topology."; fi

while IFS= read -r line; do
    [[ "$line" =~ ^# ]] && continue; [[ -z "$line" ]] && continue
    IFS=',' read -r cpu_id core_id socket_id node_id <<< "$line"
    if [[ -z "$cpu_id" ]]; then continue; fi
    socket_id=${socket_id:-0}; node_id=${node_id:-0}
    ALL_LOGICAL_CPUS+=("$cpu_id"); CPU_TO_CORE["$cpu_id"]=$core_id; CPU_TO_SOCKET["$cpu_id"]=$socket_id; SOCKET_IDS["$socket_id"]=1
    ALL_CORES_NODE["$node_id"]+="$cpu_id "
    if [[ -n "$core_id" ]]; then if [[ ! -v MIN_CORE_PER_SOCKET["$socket_id"] || "$core_id" -lt "${MIN_CORE_PER_SOCKET["$socket_id"]}" ]]; then MIN_CORE_PER_SOCKET["$socket_id"]=$core_id; fi; fi
done <<< "$lscpu_output"

if [[ ${#ALL_LOGICAL_CPUS[@]} -eq 0 ]]; then error "Could not parse any CPU information from lscpu output."; fi

if [[ -n "${CPU_TO_CORE[${ALL_LOGICAL_CPUS[0]}]}" ]]; then
    first_core_id=${CPU_TO_CORE[${ALL_LOGICAL_CPUS[0]}]}; smt_count=0
    for cpu in "${ALL_LOGICAL_CPUS[@]}"; do if [[ "${CPU_TO_CORE[$cpu]}" == "$first_core_id" ]]; then ((smt_count++)); fi; done
    SMT_LEVEL=$smt_count
fi
log "Detected SMT level (threads per physical core): $SMT_LEVEL"

if [[ $RESERVE_HOST_CORES -eq 1 ]]; then
    log "Identifying host cores to reserve..."
    for socket_id in "${!SOCKET_IDS[@]}"; do
        min_core_id=${MIN_CORE_PER_SOCKET["$socket_id"]:-}
        if [[ -z "$min_core_id" ]]; then warn "Cannot determine min physical core for socket $socket_id. Cannot reserve."; continue; fi
        log "  Socket $socket_id: Reserving physical core $min_core_id."
        for cpu_id in "${ALL_LOGICAL_CPUS[@]}"; do
            if [[ "${CPU_TO_SOCKET[$cpu_id]}" == "$socket_id" && "${CPU_TO_CORE[$cpu_id]}" == "$min_core_id" ]]; then
                CORES_TO_RESERVE+=("$cpu_id"); CORES_TO_RESERVE_MAP["$cpu_id"]=1
            fi
        done
    done
    log "Logical CPUs reserved for host: ${CORES_TO_RESERVE[*]}"
else log "Host core reservation skipped by user."; fi

declare -A NUMA_CORES; declare -A AVAILABLE_CORES_NODE; NUMA_NODE_IDS=(); TOTAL_LOGICAL_CORES_AVAILABLE=0
for node_id in "${!ALL_CORES_NODE[@]}"; do
    available_node_cores_str=""
    for cpu_id in ${ALL_CORES_NODE["$node_id"]}; do if [[ ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then available_node_cores_str+="$cpu_id "; fi; done
    if [[ -n "$available_node_cores_str" ]]; then
        available_node_cores_str=${available_node_cores_str% }; NUMA_CORES["$node_id"]="$available_node_cores_str"; AVAILABLE_CORES_NODE["$node_id"]="$available_node_cores_str"; NUMA_NODE_IDS+=("$node_id")
        cores_array=($available_node_cores_str); TOTAL_LOGICAL_CORES_AVAILABLE=$((TOTAL_LOGICAL_CORES_AVAILABLE + ${#cores_array[@]}))
    else log "  Node $node_id has no available cores after host reservation."; fi
done
if [[ ${#NUMA_NODE_IDS[@]} -eq 0 ]]; then error "No NUMA nodes with available cores found."; fi
IFS=$'\n' NUMA_NODE_IDS=($(sort -n <<<"${NUMA_NODE_IDS[*]}")); unset IFS
NUM_NUMA_NODES=${#NUMA_NODE_IDS[@]}
log "Initialization complete. Total logical cores available for VMs: $TOTAL_LOGICAL_CORES_AVAILABLE"
if [[ $TOTAL_LOGICAL_CORES_AVAILABLE -lt $CPU_COUNT ]]; then error "Total available cores ($TOTAL_LOGICAL_CORES_AVAILABLE) < required per VM ($CPU_COUNT)."; fi

# --- Core Assignment Loop ---
declare -A ASSIGNED_CORES_TOTAL; CURRENT_NODE_INDEX=0
log "Starting VM configuration process..."
for vmid in "${TARGET_VMIDS[@]}"; do
    log "--- Processing VMID: $vmid ---"
    if ! qm config "$vmid" > /dev/null 2>&1; then warn "VMID $vmid does not exist. Skipping."; continue; fi

    # Find a suitable NUMA node and cores
    assigned_node=-1; cores_to_assign_list=(); nodes_checked=0; start_node_check_index=$CURRENT_NODE_INDEX
    while [[ $nodes_checked -lt $NUM_NUMA_NODES ]]; do
        node_id=${NUMA_NODE_IDS[$CURRENT_NODE_INDEX]}
        if [[ ! -v AVAILABLE_CORES_NODE["$node_id"] || -z "${AVAILABLE_CORES_NODE["$node_id"]}" ]]; then
            log "Node $node_id has no available cores. Checking next."
            nodes_checked=$((nodes_checked + 1)); CURRENT_NODE_INDEX=$(((CURRENT_NODE_INDEX + 1) % NUM_NUMA_NODES)); continue;
        fi
        available_cores_on_node=(${AVAILABLE_CORES_NODE["$node_id"]}); num_available=${#available_cores_on_node[@]};
        log "Checking Node $node_id: $num_available available core(s)."
        if [[ $num_available -ge $CPU_COUNT ]]; then
            temp_assigned_cores=();
            if [[ $SIBLING_AWARE -eq 1 && $SMT_LEVEL -gt 1 ]]; then
                log "  Using sibling-aware assignment strategy..."; cores_to_find=$CPU_COUNT; declare -A available_by_phys_core
                for cpu in "${available_cores_on_node[@]}"; do phys_core=${CPU_TO_CORE["$cpu"]}; available_by_phys_core["$phys_core"]+="$cpu "; done
                for phys_core in "${!available_by_phys_core[@]}"; do
                    if [[ $cores_to_find -lt $SMT_LEVEL ]]; then break; fi
                    siblings_on_core=(${available_by_phys_core["$phys_core"]})
                    if [[ ${#siblings_on_core[@]} -eq $SMT_LEVEL ]]; then
                        log "    Found full physical core $phys_core"; temp_assigned_cores+=( "${siblings_on_core[@]}" ); cores_to_find=$(( cores_to_find - SMT_LEVEL )); unset available_by_phys_core["$phys_core"];
                    fi
                done
                if [[ $cores_to_find -gt 0 ]]; then
                    log "    Need to find $cores_to_find more single cores...";
                    for phys_core in "${!available_by_phys_core[@]}"; do
                        single_cores=(${available_by_phys_core["$phys_core"]})
                        for cpu in "${single_cores[@]}"; do
                            if [[ $cores_to_find -gt 0 ]]; then log "      Taking single core $cpu"; temp_assigned_cores+=( "$cpu" ); cores_to_find=$(( cores_to_find - 1 ));
                            else break 2; fi
                        done
                    done
                fi
            else
                log "  Using linear assignment strategy..."; cores_to_find=0;
                temp_assigned_cores=( "${available_cores_on_node[@]:0:$CPU_COUNT}" )
            fi

            if [[ $cores_to_find -eq 0 && ${#temp_assigned_cores[@]} -eq $CPU_COUNT ]]; then
                cores_to_assign_list=( "${temp_assigned_cores[@]}" ); assigned_node=$node_id;
                log "Selected Node $node_id. Assigning cores: ${cores_to_assign_list[*]}"
                new_available_str=""; for core in "${available_cores_on_node[@]}"; do is_assigned=0; for assigned_core in "${cores_to_assign_list[@]}"; do if [[ "$core" == "$assigned_core" ]]; then is_assigned=1; break; fi; done; if [[ $is_assigned -eq 0 ]]; then new_available_str+="$core "; fi; done
                AVAILABLE_CORES_NODE["$node_id"]="${new_available_str% }"; break
            else log "  Could not find a suitable core combination on this node. Checking next."; fi
        fi
        CURRENT_NODE_INDEX=$(((CURRENT_NODE_INDEX + 1) % NUM_NUMA_NODES)); nodes_checked=$((nodes_checked + 1));
        if [[ $CURRENT_NODE_INDEX -eq $start_node_check_index ]]; then break; fi
    done
    if [[ $assigned_node -eq -1 ]]; then warn "Could not find any NUMA node with a valid core combination for VM $vmid. Skipping."; CURRENT_NODE_INDEX=$(((start_node_check_index + 1) % NUM_NUMA_NODES)); continue; fi

    # Apply VM Configuration
    log "Applying settings for VM $vmid..."
    cores_step_failed=0; cpu_step_failed=0; affinity_step_failed=0; numa_enable_step_failed=0; numa0_config_step_failed=0; hugepages_step_failed=0; balloon_step_failed=0

    # Stage 0: Set Core Count
    log "--- Stage 0: Setting Core Count ---"
    if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -cores "$CPU_COUNT"; then warn "Failed to set core count."; cores_step_failed=1; else log "  Successfully set core count."; fi;
    else log "  DRY RUN: qm set $vmid -cores ${CPU_COUNT}"; cores_step_failed=0; fi

    # Stage 1: Set CPU Type and Flags
    if [[ $cores_step_failed -eq 0 ]]; then
        log "--- Stage 1: Setting CPU Type and Flags ---"
        log "  Setting CPU: -cpu \"${CPU_CONFIG_STRING}\""
        if [[ $DRY_RUN -eq 0 ]]; then
            qm set "$vmid" --delete cpu &> /dev/null || true
            if ! qm set "$vmid" -cpu "$CPU_CONFIG_STRING"; then warn "  Failed to set CPU string."; cpu_step_failed=1; else log "  Successfully set CPU configuration string."; fi
        else log "    DRY RUN: qm set $vmid -cpu \"$CPU_CONFIG_STRING\""; fi
    else log "  Skipping CPU settings due to Core Count failure."; cpu_step_failed=1; fi

    # Stage 2: Set affinity
    if [[ $cores_step_failed -eq 0 && $cpu_step_failed -eq 0 ]]; then
        log "--- Stage 2: Setting CPU Affinity ---"; affinity_option=$(IFS=,; echo "${cores_to_assign_list[*]}")
        if [[ $DRY_RUN -eq 0 ]]; then qm set "$vmid" --delete affinity &> /dev/null || true; fi
        log "  Setting CPU Affinity: -affinity ${affinity_option}"
        if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -affinity "$affinity_option"; then warn "Failed to set CPU affinity."; affinity_step_failed=1; else log "  Successfully set CPU affinity."; fi; else log "  DRY RUN: qm set $vmid -affinity ..."; fi
    else log "  Skipping Affinity setting due to previous failure."; affinity_step_failed=1; fi

    critical_cpu_failed=$((cores_step_failed + cpu_step_failed + affinity_step_failed))

    # Stage 3a: Enable NUMA
    if [[ $critical_cpu_failed -eq 0 ]]; then
        log "--- Stage 3a: Enabling NUMA ---"
        if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -numa 1; then warn "Failed to enable NUMA."; numa_enable_step_failed=1; else log "Successfully enabled NUMA."; fi; else log "    DRY RUN: qm set $vmid -numa 1"; fi
    else log "  Skipping NUMA enabling."; numa_enable_step_failed=1; fi

    # Stage 3b: Configure Guest NUMA Node 0
    if [[ $critical_cpu_failed -eq 0 && $numa_enable_step_failed -eq 0 ]]; then
        log "--- Stage 3b: Configuring Guest NUMA Node 0 ---"
        vm_memory=$(qm config "$vmid" | grep '^memory:' | awk '{print $2}') || vm_memory=""
        if [[ -z "$vm_memory" ]]; then warn "  Could not fetch memory size for VM $vmid."; numa0_config_step_failed=1; else
            numa_cpus_range="0-$((CPU_COUNT - 1))"; numa0_opts="cpus=${numa_cpus_range},hostnodes=${assigned_node},memory=${vm_memory},policy=bind"
            log "  Setting Guest NUMA Node 0: -numa0 \"${numa0_opts}\""
            if [[ $DRY_RUN -eq 0 ]]; then
                qm set "$vmid" --delete numa0 &> /dev/null || true
                if ! qm set "$vmid" -numa0 "$numa0_opts"; then warn "  Failed to set numa0 config."; numa0_config_step_failed=1; else log "  Successfully configured numa0."; fi
            else log "    DRY RUN: qm set $vmid -numa0 ..."; fi
        fi
    else log "  Skipping NUMA0 configuration."; numa0_config_step_failed=1; fi

    # Stage 4: Set Hugepages
    if [[ $critical_cpu_failed -eq 0 ]]; then
        log "--- Stage 4: Setting 1GB Hugepages ---"
        if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -hugepages 1024; then warn "Failed to set hugepages. (Host configured?)"; else log "Successfully set hugepages."; fi; else log "    DRY RUN: qm set $vmid -hugepages 1024"; fi
    else log "  Skipping Hugepages setting."; fi

    # Stage 5: Disable Ballooning
    if [[ $critical_cpu_failed -eq 0 ]]; then
        log "--- Stage 5: Disabling Memory Ballooning ---"
        if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -balloon 0; then warn "Failed to disable ballooning."; else log "Successfully disabled ballooning."; fi; else log "    DRY RUN: qm set $vmid -balloon 0"; fi
    else log "  Skipping Ballooning setting."; fi

    # Stage 6: Set virtio NIC queues directly
    if [[ $critical_cpu_failed -eq 0 ]]; then
        log "--- Stage 6: Setting virtio NIC queues ---"; declare -a net_lines; net_lines=()
        while IFS= read -r line; do [[ -z "$line" ]] && continue; net_lines+=("$line"); done < <(qm config "$vmid" | grep '^net[0-9]\+:') || { log "  No network interfaces (netX) found."; net_lines=(); }
        if [[ ${#net_lines[@]} -gt 0 ]]; then
            for net_line in "${net_lines[@]}"; do
                iface=$(echo "$net_line" | awk -F': ' '{print $1}'); current_opts=$(echo "$net_line" | awk -F': ' '{print $2}')
                if [[ "$current_opts" == *"virtio"* ]]; then
                    current_queues=$(echo "$current_opts" | grep -o 'queues=[0-9]\+' | cut -d= -f2) || current_queues=""
                    if [[ "$current_queues" == "$CPU_COUNT" ]]; then log "    Queues already set for ${iface}."; continue; fi
                    new_opts=$(echo "$current_opts" | sed -E 's/,?queues=[0-9]+//g; s/^,//; s/,*$//' )
                    if [[ -n "$new_opts" ]]; then new_opts+=",queues=${CPU_COUNT}"; else base_opts=$(echo "$current_opts" | awk -F, '{print $1}'); new_opts="${base_opts},queues=${CPU_COUNT}"; new_opts=${new_opts#,} ; fi
                    log "    Setting options for ${iface}: '${new_opts}'"
                    if [[ $DRY_RUN -eq 0 ]]; then if ! qm set "$vmid" -"$iface" "$new_opts"; then warn "    Failed to set queues for ${iface}."; fi; else log "    DRY RUN: qm set $vmid -${iface} ..."; fi
                else log "    ${iface} not virtio, skipping."; fi
            done
        fi
    else log "  Skipping NIC queue setting."; fi

    # Finalization
    assigned_cores_array=(); IFS=',' read -ra assigned_cores_array <<< "${cores_to_assign_list[@]}"; for core in "${assigned_cores_array[@]}"; do ASSIGNED_CORES_TOTAL["$core"]=1; done
    assigned_node_index=-1; for i in "${!NUMA_NODE_IDS[@]}"; do if [[ "${NUMA_NODE_IDS[$i]}" = "$assigned_node" ]]; then assigned_node_index="$i"; break; fi; done
    if [[ $assigned_node_index -ne -1 ]]; then CURRENT_NODE_INDEX=$(((assigned_node_index + 1) % NUM_NUMA_NODES)); else CURRENT_NODE_INDEX=$(((start_node_check_index + 1) % NUM_NUMA_NODES)); warn "Could not find index for assigned node $assigned_node."; fi
    log "--- Finished processing VMID: $vmid ---"
done

log "Script finished."
if [[ $DRY_RUN -eq 1 ]]; then log "*** DRY RUN MODE ACTIVE - NO CHANGES WERE MADE ***"; fi
exit 0
