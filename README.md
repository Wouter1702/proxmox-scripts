# 🚀 Proxmox VE Automated Server VM Deployment (Verbose Edition)

This Bash script automates the deployment of **cloud-init–enabled virtual machines** on **Proxmox VE 8/9**.  
It supports both **local image files** and **cloud image URLs**, automatically handles disk import, resizing, tagging, and optional auto-start — now with a **`--verbose`** mode to control command output.

---

## ✨ What's New (Verbose Mode)

- 🆕 Added `--verbose` option to toggle full Proxmox CLI output.
- 💤 By default, the script hides noisy `qm` and `wget` output for clean logs.
- 🗣️ When `--verbose` is specified, you see **all** `qm` messages, downloads, and progress.
- 🔇 Without `--verbose`, only intentional `echo` lines are shown (no system clutter).

Example difference:
```bash
# Normal mode (quiet)
[+] Creating VM (server, ID: 1000)...
[✓] Disk imported as: local-lvm:vm-1000-disk-0

# Verbose mode
[+] Creating VM (server, ID: 1000)...
update VM 1000: -boot c -bootdisk scsi0
update VM 1000: -ide2 local-lvm:cloudinit
[✓] Disk imported as: local-lvm:vm-1000-disk-0
```

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
- ✅ **New:** Toggleable verbosity (`--verbose`) for debugging or clean runs  

---

## ⚙️ Requirements

- Proxmox VE 8.x or 9.x  
- `qm`, `wget`, `file`, and `numfmt` commands available (default on Proxmox)  
- SSH key file accessible to Proxmox (`.pub` file)  
- Sufficient storage space on the target storage pool  

---

## 🧠 Usage

```bash
./deploy-server.sh [OPTIONS]
```

### Example 1 — Quiet Mode (default)
```bash
./deploy-server.sh \
  --vmid 1000 \
  --name ansible \
  --memory 2048 \
  --cores 2 \
  --ciuser serveradmin \
  --sshkey /etc/pve/priv/ssh-keys \
  --image-url https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  --new-disksize 10G \
  --startvm true
```

### Example 2 — Verbose Mode (show all `qm` messages)
```bash
./deploy-server.sh \
  --vmid 1001 \
  --name debugvm \
  --memory 4096 \
  --cores 4 \
  --ciuser devops \
  --sshkey ~/.ssh/id_rsa.pub \
  --image-file noble-server-cloudimg-amd64.img \
  --image-dir /var/lib/vz/import \
  --new-disksize 20G \
  --verbose
```

---

## 🧾 Parameters

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
| `--verbose` | Show full Proxmox CLI and download output | `false` |

---

## 🧩 Verbose Mode Implementation

Internally, `qm` and `wget` commands are wrapped in helper functions:

```bash
run_qm() {
  if [[ "$VERBOSE" == "true" ]]; then
    qm "$@"
  else
    qm "$@" >/dev/null 2>&1
  fi
}

wget_dl() {
  if [[ "$VERBOSE" == "true" ]]; then
    wget --show-progress -O "$1" "$2"
  else
    wget -q -O "$1" "$2"
  fi
}
```

This ensures that normal runs stay clean, while `--verbose` provides all output for debugging or auditing.

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

## 🧰 Troubleshooting

- **Invalid image file:** Ensure the file is a valid QCOW2 or RAW disk image.  
- **Import fails:** Check available storage space in the target pool.  
- **Resize skipped:** The new size must be larger than the original size and include a unit (e.g., `10G`).  
- **Noisy output:** Add `--verbose` to see all commands for debugging.  

---

## 📜 License

MIT License — free to use, modify, and distribute.