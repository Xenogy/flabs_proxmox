# Proxmox for FarmLabs

## Prerequisites

### Operating Systems
- GhostSpectre Windows 11 (available in FarmLabs documentation)
- Any OS capable of running Docker (Ubuntu 24.04 used in guide)

### VirtIO Drivers
- **Network Driver**: [VirtIO Guest Tools](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.266-1/virtio-win-guest-tools.exe)
- **Disk Driver**: [VirtIO ISO](https://www.dropbox.com/scl/fi/kd7d86vuu6dsm972lpd48/virtio-win-0.1.266.iso?rlkey=jwhu7ha5y52dsvi70a1qbjdbs&st=xzgmcv9q&dl=0)

### vGPU Setup Resources
- **Guide**: [vGPU Proxmox Guide](https://gitlab.com/polloloco/vgpu-proxmox)
- **License Server**: [FastAPI DLS](https://git.collinwebdesigns.de/oscar.krause/fastapi-dls)

### Proxmox Resources
- **Installation Guide**: [How to Install Proxmox](https://phoenixnap.com/kb/install-proxmox) (Note: If using one drive, limit boot partition size on step 6)
- **Proxmox ISO**: [Download Proxmox VE](https://www.proxmox.com/en/products/proxmox-virtual-environment/get-started)

## Installation Steps

### 1. Install Proxmox
Follow the installation guide linked in the prerequisites section.

#### 1.1 (Optional) Preserve hugepages for VMs
```bash
nano /etc/default/grub
```
Add `default_hugepagesz=2M hugepagesz=1G hugepages={n_hugepages}` to the `GRUB_CMDLINE_LINUX_DEFAULT` line. (replace {n_hugepages} with the number of 1GB hugepages you want to reserve for VMs, probably shouldn't exceed 80% system memory)
```bash
update-grub
```
Restart host.


### 2. Setup vGPU
#### 2.1 Configure vGPU Profile
Create or edit the configuration file at `/etc/vgpu_unlock/profile_override.toml`:

```yaml
[profile.nvidia-{profile id}]    # Replace {profile id} with your preferred base profile, can check available from `mdevctl types`
num_displays = 1
vgpu_type = "NVS"                # Improvises performance for Q profiles on some cards
frl_enabled = 0                  # Framerate lock

display_width = 1920
display_height = 1080
max_pixels = 2073600             # 1920x1080

framebuffer = 0x74000000         # 2GB vram
framebuffer_reservation = 0xC000000  # 2GB vram
```

#### 2.2 Setup License Server
Follow the license server setup guide linked in the prerequisites section.

### 3. Create a VM using GhostSpectre Windows 11
Follow the steps shown in the images below:

#### 3.1 General Tab Configuration
![VM Setup - General Tab](./flabs_proxmox/imgs/vm_setup-1-general.png)

#### 3.2 OS Configuration
![VM Setup - OS Tab](./flabs_proxmox/imgs/vm_setup-2-OS.png)

#### 3.3 System Configuration
![VM Setup - System Tab](./flabs_proxmox/imgs/vm_setup-3-System.png)

#### 3.4 Disk Configuration
![VM Setup - Disks Tab](./flabs_proxmox/imgs/vm_setup-4-Disks.png)

#### 3.5 CPU Configuration
![VM Setup - CPU Tab](./flabs_proxmox/imgs/vm_setup-5-CPU.png)

**Disclaimer:** cpu configuration varies a lot between systems. If using the cpu affinity bash script provided in the guide, you can skip this step.

#### 3.6 Memory Configuration
![VM Setup - Memory Tab](./flabs_proxmox/imgs/vm_setup-6-Memory.png)

#### 3.7 Network Configuration
![VM Setup - Network Tab](./flabs_proxmox/imgs/vm_setup-7-Network.png)

#### 3.8 Confirmation
![VM Setup - Confirm Tab](./flabs_proxmox/imgs/vm_setup-8-Confirm.png)

#### 3.9 Start VM
From here you can follow the Farmlabs documentation until the disk selection in the Windows setup.

### 4. Install VirtIO Disk Driver in Windows setup
Follow the steps shown in the images below:

#### 4.1 Driver Installation
![Windows Setup - VirtIO Driver Installation](./flabs_proxmox/imgs/windows_setup-1-Driver.png)

#### 4.2 Confirmation
![Windows Setup - Confirmation](./flabs_proxmox/imgs/windows_setup-2-OK.png)

#### 4.3 Driver Selection
![Windows Setup - Driver Selection](./flabs_proxmox/imgs/windows_setup-3-Select.png)

Now the disk should show up and be selectable, and you can continue following the Farmlabs documentation until completion.

### 5. Setup license server (docker compose)

The license server should technically work on any OS capable of running Docker, but the guide is written for Ubuntu 24.04.

#### 5.1 Install Docker
Follow the [official Docker installation guide](https://docs.docker.com/engine/install/ubuntu/) for Ubuntu 24.04.

#### 5.2 Setup working directory
```bash
mkdir ~/vgpu_licenser
cd ~/vgpu_licenser

get https://git.collinwebdesigns.de/oscar.krause/fastapi-dls/-/raw/main/docker-compose.yml
```

#### 5.3 Edit configuration file
Edit `docker-compose.yml` and change the TZ and DLS_URL variables.

```bash
nano docker-compose.yml
```

```yaml
version: '3.9'

x-dls-variables: &dls-variables
  TZ: Europe/Berlin     # REQUIRED, set your timezone correctly on fastapi-dls AND YOUR CLIENTS !!!
  DLS_URL: localhost    # REQUIRED, change to your ip or hostname
  DLS_PORT: 443
  LEASE_EXPIRE_DAYS: 90  # 90 days is maximum
  DATABASE: sqlite:////app/database/db.sqlite
  DEBUG: false

services:
  dls:
    image: collinwebdesigns/fastapi-dls:latest
    restart: always
    environment:
      <<: *dls-variables
    ports:
      - "443:443"
    volumes:
      - /opt/docker/fastapi-dls/cert:/app/cert
      - dls-db:/app/database
    logging: # optional, for those who do not need logs
      driver: "json-file"
      options:
        max-file: 5
        max-size: 10m

volumes:
  dls-db:
```

#### 5.4 Start the license server
```bash
docker-compose up -d
```

### 6. (Windows) VM setup

#### 6.1 (Windows) Install VirtIO Network Driver

#### 6.2 (Windows) Install GRID client driver
This should be bundled as an .exe file with the vGPU host driver you previously installed on your proxmox node.
After completion, open powershell and run
```powershell
curl.exe --insecure -L -X GET https://<dls-hostname-or-ip>/-/client-token -o "C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken\client_configuration_token_$($(Get-Date).tostring('dd-MM-yy-hh-mm-ss')).tok"
```

#### 6.3 (Windows) Setup remote access
Log into parsec or install your preferred remote management software, after the following step the proxmox console redirection will no longer work.

#### 6.4 (Proxmox) Update VM network adapter
Go to the VM's hardware tab and select the network adapter.
![VirtIO Network Adapter](./flabs_proxmox/imgs/vm_update-1-hardware.png)

Change the adapter model to VirtIO.
![VirtIO Network Adapter](./flabs_proxmox/imgs/vm_update-2-Adapter.png)

Check that the VM can connect to the internet afterwards.

#### 6.5 (Proxmox) Pass vGPU to VM

![VM Hardware Tab](./flabs_proxmox/imgs/pass_gpu-1-hardware.png)
Open the VM's hardware tab and select the GPU you want to pass through.
![VM Hardware Tab](./flabs_proxmox/imgs/pass_gpu-2-device.png)
Select the GPU you want to pass through.
![VM Hardware Tab](./flabs_proxmox/imgs/pass_gpu-3-finish.png)
Enable:
    - PCI Express
    - Primary GPU

Add and turn off VM.

### 7. (Proxmox Host) -- OPTIONAL -- Run CPU Affinity bash script
This attempts to balance cpu pinning and numa node assignment for your VMs. It will also reserve the first physical core of each socket for the host, aswell as set 1GB hugepages, disable memory ballooning, and set the number of virtio queues to the number of vCPUs.
(it is possible to run without setting hugepages, but it is recommended for performance)

To view the help menu for the script, run:
```bash
bash affinity.sh -h
```