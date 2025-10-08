# 🚀 Proxmox VE Automated Server VM Deployment

This Bash script automates the deployment of **cloud-init–enabled virtual machines** on **Proxmox VE 8/9**.  
It supports both **local image files** and **cloud image URLs**, automatically handles disk import, resizing, tagging, and optional auto-start.

---

## 📋 Features

- ✅ Supports **cloud image downloads** (Ubuntu, Debian, etc.) or **existing local images**  
- ✅ Automatically imports and attaches the disk to a new VM  
- ✅ Detects and sets the first available SCSI slot  
- ✅ Optionally resizes the imported disk (`--new-disksize`)  
- ✅ Configures **Cloud-Init** (SSH keys, DNS, user, DHCP)  
- ✅ Optional VLAN tagging and MAC address assignment  
- ✅ Optionally starts the VM after creation (`--startvm true`)  
- ✅ Supports tagging VMs for organization in the Proxmox UI  
- ✅ Comprehensive validation and detailed runtime feedback  

---

## ⚙️ Requirements

- Proxmox VE 8.x or 9.x  
- `qm`, `wget`, `file`, and `numfmt` commands available (default on Proxmox)  
- SSH key file accessible to Proxmox (`.pub` file)  
- Sufficient storage space on the target storage pool  

---

## 📦 Installation

```bash
wget https://example.com/deploy-server.sh -O /root/deploy-server.sh
chmod +x /root/deploy-server.sh
```

(Optional) Move it to your scripts directory:
```bash
mv /root/deploy-server.sh /usr/local/bin/
```

---

## 🧠 Usage

```bash
./deploy-server.sh [OPTIONS]
```

### Example 1 — Deploy using a Cloud Image URL
```bash
./deploy-server.sh \
  --vmid 1000 \
  --name ansible \
  --memory 2048 \
  --cores 2 \
  --ciuser serveradmin \
  --sshkey /etc/pve/priv/ssh-keys \
  --vlan 128 \
  --tag homelab \
  --image-url https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  --new-disksize 10G \
  --startvm true
```

### Example 2 — Deploy from a Local Image File
```bash
./deploy-server.sh \
  --vmid 1001 \
  --name testvm \
  --memory 4096 \
  --cores 4 \
  --ciuser devops \
  --sshkey ~/.ssh/id_rsa.pub \
  --image-file noble-server-cloudimg-amd64.img \
  --image-dir /var/lib/vz/import \
  --new-disksize 20G
```

---

## 🗾 Parameters

| Parameter | Description | Default |
|------------|-------------|----------|
| `--vmid` | Proxmox VM ID | `9000` |
| `--name` | VM name | `server` |
| `--memory` | Memory in MB | `4096` |
| `--cores` | CPU cores | `2` |
| `--bridge` | Network bridge | `vmbr0` |
| `--vlan` | VLAN tag (optional) | none |
| `--mac` | Custom MAC address | auto |
| `--storage` | Proxmox storage pool | `local-lvm` |
| `--new-disksize` | Resize disk after import (e.g., `20G`) | none |
| `--image-url` | Cloud image URL | none |
| `--image-file` | Local image filename | none |
| `--image-dir` | Directory for image storage | `/var/lib/vz/import` |
| `--ciuser` | Cloud-init user | `ansible` |
| `--nameserver` | DNS nameserver | `1.1.1.1` |
| `--sshkey` | SSH public key path | `~/.ssh/id_rsa.pub` |
| `--startvm` | Auto-start VM after creation (`true`/`false`) | `false` |
| `--tag` | VM tag (optional) | none |

---

## 🧩 Logic Overview

1. **Validate Input** — Ensures numeric values, valid MAC format, file existence, and exclusive image source.  
2. **Prepare Image Directory** — Creates the image directory if it doesn’t exist.  
3. **Select or Download Image** — Uses existing `.img` or `.img.raw` file if available, otherwise downloads.  
4. **Create and Configure VM** — Runs `qm create` with all user parameters.  
5. **Import Disk** — Uses `qm disk import` and determines the actual disk path automatically.  
6. **Attach and Configure Disk** — Detects next free SCSI slot, attaches the disk, and configures Cloud-Init.  
7. **Optional Resize** — Resizes disk if `--new-disksize` is larger than the current size.  
8. **Tagging & Startup** — Optionally tags and starts the VM.  

---

## 🧮 Output Example

```
✅ SUCCESS: VM Deployment Complete
---------------------------------------
 VM ID:          1000
 Name:           server
 Status:         Started
 Memory:         2048MB
 Cores:          2
 Storage:        local-lvm
 Disk Path:      local-lvm:vm-1000-disk-0
 Disk Format:    raw
 Disk Size:      10G
 Bridge:         vmbr0
 VLAN Tag:       128
 MAC Address:    Auto
 Cloud User:     serveradmin
 Nameserver:     1.1.1.1
 SSH Key:        /etc/pve/priv/ssh-keys
 VM Tag:         homelab
 Image Source:   https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
---------------------------------------
Access the VM after boot with:
  ssh serveradmin@<vm_ip>
```

---

## 🛠️ Troubleshooting

- **Invalid image file:** Ensure the file is a valid QCOW2 or RAW disk image.  
- **Import fails:** Check available storage space in the target pool.  
- **Resize skipped:** The new size must be larger than the original size and include a unit (e.g., `10G`).  
- **VM won’t start:** Use the Proxmox UI or run `qm start <vmid>` manually.  

---

## 📄 License

MIT License – free to use, modify, and distribute.

