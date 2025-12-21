#!/bin/bash

# Print Headers
printf "%-15s %-10s %s\n" "PCI Address" "NUMA Node" "GPU Name"
printf "%-15s %-10s %s\n" "-----------" "---------" "--------"

# 1. List all devices using lspci
# 2. Grep for Class [0300] (VGA) or [0302] (3D Controller)
lspci -D -nn | grep -E "\[03(00|02)\]" | while read -r line; do

    # Extract the PCI slot (first word of the line)
    pci_slot=$(echo "$line" | cut -d ' ' -f 1)

    # Extract the device name (everything after the class code brackets and colon)
    # This sed command looks for ']: ' and keeps everything after it
    gpu_name=$(echo "$line" | sed 's/.*]: //')

    # Path to NUMA node file in sysfs
    numa_path="/sys/bus/pci/devices/${pci_slot}/numa_node"

    # Read NUMA node
    if [ -f "$numa_path" ]; then
        numa_node=$(cat "$numa_path")

        # If numa_node is -1, it means the system is single-socket
        # or the device is not bound to a specific node.
        if [ "$numa_node" -eq -1 ]; then
            numa_node="0"
        fi
    else
        numa_node="N/A"
    fi

    # Print the details
    printf "%-15s %-10s %s\n" "$pci_slot" "$numa_node" "$gpu_name"
done
