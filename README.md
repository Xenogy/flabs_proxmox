# Proxmox for FarmLabs

This guide provides instructions for setting up Proxmox with vGPU support for FarmLabs.

## Prerequisites

### Operating Systems
- **Host**: Proxmox VE (installation guide below)
- **Guest VM**: GhostSpectre Windows 11 (available in FarmLabs documentation)
- **License Server**: Any OS capable of running Docker (Ubuntu 24.04 used in this guide)

### VirtIO Drivers
- **Network Driver**: [VirtIO Guest Tools](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.266-1/virtio-win-guest-tools.exe)
- **Disk Driver**: [VirtIO ISO](https://www.dropbox.com/scl/fi/kd7d86vuu6dsm972lpd48/virtio-win-0.1.266.iso?rlkey=jwhu7ha5y52dsvi70a1qbjdbs&st=xzgmcv9q&dl=0)

### vGPU Setup Resources
- **Guide**: [vGPU Proxmox Guide](https://gitlab.com/polloloco/vgpu-proxmox)
- **License Server**: [FastAPI DLS](https://git.collinwebdesigns.de/oscar.krause/fastapi-dls)

### Proxmox Resources
- **Installation Guide**: [How to Install Proxmox](https://phoenixnap.com/kb/install-proxmox)
  > **Note**: If using a single drive, limit boot partition size on step 6 to make space for VM storage.
- **Proxmox ISO**: [Download Proxmox VE](https://www.proxmox.com/en/products/proxmox-virtual-environment/get-started)

## Installation Steps

### 1. Install Proxmox
Follow the installation guide linked in the prerequisites section.

#### 1.1 (Optional) Configure Hugepages for VMs
This step improves VM performance by reserving memory pages.

1. Edit the GRUB configuration:
   ```bash
   nano /etc/default/grub
   ```

2. Add the following to the `GRUB_CMDLINE_LINUX_DEFAULT` line:
   ```
   default_hugepagesz=2M hugepagesz=1G hugepages=N
   ```
   > **Note**: Replace `N` with the number of 1GB hugepages you want to reserve for VMs. This should probably not exceed ~80% of your system memory.

3. Update GRUB and restart:
   ```bash
   update-grub
   reboot
   ```

### 2. Setup vGPU
Follow the vGPU setup guide linked in the prerequisites section.

#### 2.1 Configure vGPU Profile
Create or edit the configuration file:

```bash
nano /etc/vgpu_unlock/profile_override.toml
```

Add the following configuration (adjust as needed):

```toml
[profile.nvidia-{profile id}]    # Replace {profile id} with your preferred base profile
num_displays = 1
vgpu_type = "NVS"                # Improves performance for Q profiles on some cards
frl_enabled = 0                  # Framerate lock (0 = disabled)

display_width = 1920
display_height = 1080
max_pixels = 2073600             # 1920x1080

framebuffer = 0x74000000         # 2GB vram
framebuffer_reservation = 0xC000000  # 2GB vram
```

> **Tip**: Check available profiles with `mdevctl types`

#### 2.2 Setup License Server
Follow the license server setup guide linked in the prerequisites section. Detailed instructions are also provided in Section 5 of this guide.

### 3. Create a VM using GhostSpectre Windows 11
Follow the steps shown in the images below to configure your VM in Proxmox:

#### 3.1 VM Configuration Steps

| Step | Configuration | Screenshot |
|------|--------------|------------|
| **General** | Set VM name and ID | ![VM Setup - General Tab](./imgs/vm_setup-1-general.png) |
| **OS** | Select OS type | ![VM Setup - OS Tab](./imgs/vm_setup-2-OS.png) |
| **System** | Configure BIOS and system settings | ![VM Setup - System Tab](./imgs/vm_setup-3-System.png) |
| **Disks** | Configure storage | ![VM Setup - Disks Tab](./imgs/vm_setup-4-Disks.png) |
| **CPU** | Set CPU cores and type | ![VM Setup - CPU Tab](./imgs/vm_setup-5-CPU.png) |
| **Memory** | Allocate RAM | ![VM Setup - Memory Tab](./imgs/vm_setup-6-Memory.png) |
| **Network** | Configure network adapter | ![VM Setup - Network Tab](./imgs/vm_setup-7-Network.png) |
| **Confirm** | Review and create VM | ![VM Setup - Confirm Tab](./imgs/vm_setup-8-Confirm.png) |

> **Note**: CPU configuration varies significantly between systems. If you plan to use the CPU affinity script provided in Section 7, you can use default settings here.

#### 3.2 Start VM and Begin Windows Installation
After creating the VM, start it and begin the Windows installation process. Follow the FarmLabs documentation until you reach the disk selection screen in the Windows setup.

### 4. Install VirtIO Disk Driver in Windows Setup
During Windows installation, you'll need to load the VirtIO disk driver to make your virtual disk visible:

#### 4.1 VirtIO Driver Installation Process

| Step | Action | Screenshot |
|------|--------|------------|
| **Load Driver** | Click "Load driver" when prompted for disk selection | ![Windows Setup - VirtIO Driver Installation](./imgs/windows_setup-1-Driver.png) |
| **Confirm** | Click "OK" to browse for drivers | ![Windows Setup - Confirmation](./imgs/windows_setup-2-OK.png) |
| **Select Driver** | Navigate to the VirtIO ISO and select the appropriate driver | ![Windows Setup - Driver Selection](./imgs/windows_setup-3-Select.png) |

After installing the driver, your virtual disk should appear in the Windows installation disk selection screen. Continue following the FarmLabs documentation to complete the Windows installation.

### 5. Setup License Server with Docker Compose

This section covers setting up the NVIDIA vGPU license server using Docker. While the license server can run on any OS that supports Docker, this guide uses Ubuntu 24.04.

#### 5.1 Install Docker
1. Follow the [official Docker installation guide](https://docs.docker.com/engine/install/ubuntu/) for Ubuntu 24.04
2. Make sure to install Docker Compose as well

#### 5.2 Create License Server Directory
```bash
# Create and navigate to working directory
mkdir ~/vgpu_licenser
cd ~/vgpu_licenser

# Download the docker-compose configuration
wget https://git.collinwebdesigns.de/oscar.krause/fastapi-dls/-/raw/main/docker-compose.yml
```

#### 5.3 Configure the License Server
Edit the `docker-compose.yml` file to update the timezone and server URL:

```bash
nano docker-compose.yml
```

Modify the following settings in the file:

```yaml
version: '3.9'

x-dls-variables: &dls-variables
  TZ: Europe/Berlin     # REQUIRED: Set to your correct timezone
  DLS_URL: localhost    # REQUIRED: Change to your server's IP address or hostname
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
    logging:
      driver: "json-file"
      options:
        max-file: 5
        max-size: 10m

volumes:
  dls-db:
```

> **Important**: Make sure to set the correct timezone and update the DLS_URL to your server's actual IP address or hostname.

#### 5.4 Start the License Server
```bash
docker-compose up -d
```

You can verify the server is running with:
```bash
docker-compose ps
```

### 6. Configure Windows VM and vGPU Passthrough

After installing Windows, you need to configure the VM for optimal performance with vGPU.

#### 6.1 Install VirtIO Network Driver
1. Download and install the VirtIO Guest Tools from the link in the Prerequisites section
2. Restart the VM if prompted

#### 6.2 Install NVIDIA GRID Client Driver
1. Locate the NVIDIA GRID client driver (bundled as an .exe file with the vGPU host driver you installed on your Proxmox node)
2. Install the driver and restart when prompted
3. After installation, open PowerShell and run the following command to obtain a license token:

```powershell
# Replace SERVER_IP with your license server's IP address
curl.exe --insecure -L -X GET https://SERVER_IP/-/client-token -o "C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken\client_configuration_token_$($(Get-Date).tostring('dd-MM-yy-hh-mm-ss')).tok"
```

#### 6.3 Setup Remote Access
Before changing the VM's display adapter, set up remote access:
1. Install Parsec or your preferred remote desktop software
2. Configure and test the connection

> **Important**: After switching to the vGPU, the Proxmox console redirection will no longer work.

#### 6.4 Update VM Network Adapter in Proxmox

| Step | Action | Screenshot |
|------|--------|------------|
| **Access Hardware** | Go to the VM's hardware tab | ![VM Hardware Tab](./imgs/vm_update-1-hardware.png) |
| **Change Adapter** | Select the network adapter and change model to VirtIO | ![VirtIO Network Adapter](./imgs/vm_update-2-Adapter.png) |

After changing the network adapter, verify that the VM can still connect to the internet.

#### 6.5 Pass vGPU to VM

| Step | Action | Screenshot |
|------|--------|------------|
| **Access Hardware** | Open the VM's hardware tab | ![VM Hardware Tab](./imgs/pass_gpu-1-hardware.png) |
| **Select GPU** | Click "Add" and select the GPU | ![Select GPU](./imgs/pass_gpu-2-device.png) |
| **Configure GPU** | Enable "PCI Express" and "Primary GPU" options | ![Configure GPU](./imgs/pass_gpu-3-finish.png) |

After adding the GPU, shut down the VM completely before starting it again.

### 7. (Optional) Optimize CPU Affinity for VMs
This is sort of experimental, but has improved performance at higher utilization.

The included CPU affinity script helps optimize VM performance by:
- Balancing CPU pinning and NUMA node assignment
- Reserving the first physical core of each socket for the host
- Configuring 1GB hugepages
- Disabling memory ballooning
- Setting the number of VirtIO queues to match vCPU count

> **Note**: While it's possible to run without hugepages, they are recommended for optimal performance.

#### 7.1 Using the CPU Affinity Script

To view available options and usage instructions:
```bash
bash affinity.sh -h
```

The script is applied once, if you change your amount of running vms you must reapply with the new config.

## Troubleshooting

If you encounter issues:

1. **License Server Problems**: Check that the DLS_URL in docker-compose.yml matches your server's actual IP address
2. **vGPU Not Working**: Verify that the vGPU profile is correctly configured in `/etc/vgpu_unlock/profile_override.toml`
3. **Performance Issues**: Try enabling hugepages as described in Section 1.1

## Additional Resources

- [NVIDIA vGPU Documentation](https://docs.nvidia.com/grid/index.html)
- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
- [VirtIO Drivers Documentation](https://docs.fedoraproject.org/en-US/quick-docs/creating-windows-virtual-machines-using-virtio-drivers/)
