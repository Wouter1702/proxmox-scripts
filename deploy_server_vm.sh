#!/bin/bash
#=============================================================
# VM Deployment Script for Proxmox VE 9.0.x or higher
# Author: Wouter Iliohan
#=============================================================
# Description:
# This script automates the deployment of an VM in Proxmox VE 9.0 and higher.
# It supports both local image files and remote cloud images, validates input,
# handles image import and resizing, and configures cloud-init for SSH access.
#=============================================================

set -e

#=============================================================
# --- Default Configuration Variables ---
#=============================================================
VMID=9000						 # Unique VM identifier in Proxmox
VMNAME="server"					 # Name of the new VM
MEMORY=4096						 # RAM size in MB
CORES=2							 # Number of CPU cores
BRIDGE="vmbr0"					 # Default network bridge
VLAN=""							 # Optional VLAN tag for network isolation
MACADDR=""						 # Optional custom MAC address (format: XX:XX:XX:XX:XX:XX)
STORAGE="local-lvm"				 # Default Proxmox storage backend
NEW_DISKSIZE=""					 # Optional new disk size after import (e.g. 20G)
IMAGE_URL=""					 # Optional image URL for download
IMAGE_FILE=""					 # Optional local image filename
IMAGE_DIR=""					 # Optional custom image directory
IMPORT_DIR="/var/lib/vz/import"	 # Default image import directory in Proxmox
CIUSER="serveradmin"			 # Default cloud-init user
NAMESERVER="1.1.1.1"			 # Default DNS nameserver
SSHKEY="$HOME/.ssh/id_rsa.pub"	 # Default SSH key for cloud-init access
STARTVM="false"					 # Whether to start the VM after creation
TAG=""							 # Optional VM tag for identification

#=============================================================
# --- Help and Usage Information ---
#=============================================================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --vmid <id>             VM ID (default: $VMID)"
    echo "  --name <name>           VM name (default: $VMNAME)"
    echo "  --memory <MB>           Memory in MB (default: $MEMORY)"
    echo "  --cores <num>           CPU cores (default: $CORES)"
    echo "  --bridge <iface>        Bridge interface (default: $BRIDGE)"
    echo "  --vlan <tag>            VLAN tag (optional)"
    echo "  --mac <address>         MAC address (optional, format: XX:XX:XX:XX:XX:XX)"
    echo "  --storage <pool>        Storage pool (default: $STORAGE)"
    echo "  --new-disksize <size>   Resize disk after import (e.g., 20G, must be >= image size and include unit K|M|G|T)"
    echo "  --image-url <url>       Cloud image URL (exclusive with --image-file)"
    echo "  --image-file <file>     Local image file (exclusive with --image-url)"
    echo "  --image-dir <dir>       Directory for image storage (optional, default: $IMPORT_DIR)"
    echo "  --ciuser <user>         Cloud-init user (default: $CIUSER)"
    echo "  --nameserver <ip>       DNS nameserver (default: $NAMESERVER)"
    echo "  --sshkey <path>         SSH public key (default: $SSHKEY)"
    echo "  --startvm <true|false>  Start VM after creation (default: $STARTVM)"
    echo "  --tag <tag>             VM tag (optional)"
    echo "  -h, --help              Show this help and exit"
    echo ""
    echo "Note: The VM will not start automatically unless you specify --startvm true."
    exit 0
}

#=============================================================
# --- Argument Parsing ---
#=============================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid) VMID="$2"; shift 2 ;;
        --name) VMNAME="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --bridge) BRIDGE="$2"; shift 2 ;;
        --vlan) VLAN="$2"; shift 2 ;;
        --mac) MACADDR="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --new-disksize) NEW_DISKSIZE="$2"; shift 2 ;;
        --image-url) IMAGE_URL="$2"; shift 2 ;;
        --image-file) IMAGE_FILE="$2"; shift 2 ;;
        --image-dir) IMAGE_DIR="$2"; shift 2 ;;
        --ciuser) CIUSER="$2"; shift 2 ;;
        --nameserver) NAMESERVER="$2"; shift 2 ;;
        --sshkey|-sshkey) SSHKEY="$2"; shift 2 ;;
        --startvm) STARTVM="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "❌ Unknown option: $1"; usage ;;
    esac
done

#=============================================================
# --- Input Validation ---
#=============================================================
[[ "$VMID" =~ ^[0-9]+$ ]] || { echo "❌ VMID must be numeric."; exit 1; }
[[ "$MEMORY" =~ ^[0-9]+$ ]] || { echo "❌ Memory must be numeric."; exit 1; }
[[ "$CORES" =~ ^[0-9]+$ ]] || { echo "❌ CPU cores must be numeric."; exit 1; }
[[ -f "$SSHKEY" ]] || { echo "❌ SSH key file not found: $SSHKEY"; exit 1; }

if [[ -n "$MACADDR" ]]; then
    if ! [[ "$MACADDR" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        echo "❌ Invalid MAC address format: $MACADDR"
        echo "Expected format: XX:XX:XX:XX:XX:XX"
        exit 1
    fi
fi

if [[ -n "$NEW_DISKSIZE" ]]; then
    if ! [[ "$NEW_DISKSIZE" =~ ^[0-9]+[KkMmGgTt]$ ]]; then
        echo "❌ Invalid --new-disksize format. Use syntax like 20G, 512M, etc."
        exit 1
    fi
fi

# --- Validate image source exclusivity ---
if [[ -n "$IMAGE_URL" && -n "$IMAGE_FILE" ]]; then
    echo "❌ You cannot specify both --image-url and --image-file."; exit 1;
fi
if [[ -z "$IMAGE_URL" && -z "$IMAGE_FILE" ]]; then
    echo "❌ You must specify either --image-url or --image-file."; exit 1;
fi

#=============================================================
# --- Image Preparation ---
#=============================================================
if [[ -z "$IMAGE_DIR" ]]; then
    IMAGE_DIR="$IMPORT_DIR"
fi
if [ ! -d "$IMAGE_DIR" ]; then
    echo "[+] Creating image directory: $IMAGE_DIR"
    mkdir -p "$IMAGE_DIR"
fi

echo "[✓] Input validated successfully."

#=============================================================
# --- Build network configuration ---
#=============================================================
NETCONFIG="virtio,bridge=${BRIDGE}"
[[ -n "$VLAN" ]] && NETCONFIG+=" ,tag=${VLAN}"
[[ -n "$MACADDR" ]] && NETCONFIG+=" ,macaddr=${MACADDR}"

#=============================================================
# --- Image Selection or Download ---
#=============================================================
if [[ -n "$IMAGE_URL" ]]; then
    BASENAME=$(basename "$IMAGE_URL")
    BASENAME_NO_EXT="${BASENAME%.img}"
    BASENAME_NO_EXT="${BASENAME_NO_EXT%.qcow2}"

    RAW_FILE="$IMAGE_DIR/${BASENAME_NO_EXT}.img.raw"
    IMG_FILE="$IMAGE_DIR/${BASENAME}"

    if [ -f "$RAW_FILE" ]; then
        echo "[✓] Found existing RAW image: $RAW_FILE"
        IMAGE_FILE="$RAW_FILE"
    elif [ -f "$IMG_FILE" ]; then
        echo "[✓] Found existing IMG file: $IMG_FILE"
        IMAGE_FILE="$IMG_FILE"
    else
        echo "[+] Downloading image from $IMAGE_URL to $IMAGE_DIR..."
        wget -q --show-progress -O "$IMG_FILE" "$IMAGE_URL"
        IMAGE_FILE="$IMG_FILE"
    fi
else
    if [ -f "$IMAGE_DIR/$IMAGE_FILE" ]; then
        IMAGE_FILE="$IMAGE_DIR/$IMAGE_FILE"
        echo "[✓] Using image file: $IMAGE_FILE"
    elif [ -f "$IMAGE_FILE" ]; then
        echo "[✓] Using provided absolute image path: $IMAGE_FILE"
    else
        echo "❌ Image file not found: $IMAGE_FILE in $IMAGE_DIR or given path"
        exit 1
    fi
fi

#=============================================================
# --- Image Validation and VM Creation ---
#=============================================================
FILETYPE=$(file "$IMAGE_FILE")
if ! echo "$FILETYPE" | grep -Eiq "QEMU|QCOW|boot sector|DOS/MBR|raw|data"; then
    echo "❌ Invalid image file detected: $FILETYPE"; exit 1
fi
echo "[✓] Valid image detected: $FILETYPE"

# --- Detect disk format ---
if echo "$FILETYPE" | grep -qi "qcow"; then
    DISK_FORMAT="qcow2"
else
    DISK_FORMAT="raw"
fi
[[ "$STORAGE" == "local-lvm" ]] && DISK_FORMAT="raw"
echo "[✓] Using disk format: $DISK_FORMAT"

# --- Create VM ---
echo "[+] Creating VM ($VMNAME, ID: $VMID)..."
qm create "$VMID" --name "$VMNAME" --memory "$MEMORY" --cores "$CORES" --net0 "$NETCONFIG"

#=============================================================
# --- Disk Import and Attachment ---
#=============================================================
echo "[+] Importing disk into $STORAGE..."
IMPORT_OUTPUT=$(qm disk import "$VMID" "$IMAGE_FILE" "$STORAGE" --format "$DISK_FORMAT" 2>&1)
DISK_PATH=$(echo "$IMPORT_OUTPUT" | grep -Eo "[a-zA-Z0-9_-]+:[a-zA-Z0-9._-]+-disk-[0-9]+" | tail -n1)

if [ -z "$DISK_PATH" ]; then
    echo "❌ Could not parse imported disk path!"
    echo "$IMPORT_OUTPUT"
    exit 1
fi

echo "[✓] Disk imported as: $DISK_PATH"

# --- Determine next available SCSI slot ---
NEXT_SCSI=$(for i in {0..15}; do
    if ! qm config "$VMID" | grep -q "^scsi${i}:"; then
        echo "scsi${i}"
        break
    fi
done)

if [ -z "$NEXT_SCSI" ]; then
    echo "❌ No available SCSI slots found for VM $VMID."
    exit 1
fi

echo "[+] Attaching imported disk as $NEXT_SCSI..."
qm set "$VMID" --scsihw virtio-scsi-pci --"$NEXT_SCSI" "$DISK_PATH"

#=============================================================
# --- CLOUD-INIT CONFIGURATION ---
#=============================================================
qm set "$VMID" --ide2 "$STORAGE:cloudinit"
qm set "$VMID" --boot c --bootdisk "$NEXT_SCSI"
qm set "$VMID" --serial0 socket --vga serial0
qm set "$VMID" --ipconfig0 ip=dhcp
qm set "$VMID" --sshkey "$SSHKEY"
qm set "$VMID" --ciuser "$CIUSER"
qm set "$VMID" --nameserver "$NAMESERVER"

#=============================================================
# --- OPTIONAL DISK RESIZE ---
#=============================================================
if [[ -n "$NEW_DISKSIZE" ]]; then
    echo "[+] Checking current attached disk size for VM $VMID ($NEXT_SCSI)..."
    CURRENT_SIZE=$(qm config "$VMID" | grep -E "^${NEXT_SCSI}:" | grep -oP 'size=\\K[0-9]+[KMGTP]?')
    if [ -z "$CURRENT_SIZE" ]; then
        echo "❌ Could not determine current disk size from VM config."
        exit 1
    fi

    echo "[✓] Current disk size: $CURRENT_SIZE"

    CURRENT_VALUE=$(echo "$CURRENT_SIZE" | grep -oE '^[0-9]+')
    CURRENT_UNIT=$(echo "$CURRENT_SIZE" | grep -oE '[KMGTP]$' | tr '[:upper:]' '[:lower:]')
    TARGET_VALUE=$(echo "$NEW_DISKSIZE" | grep -oE '^[0-9]+')
    TARGET_UNIT=$(echo "$NEW_DISKSIZE" | grep -oE '[KMGTP]$' | tr '[:upper:]' '[:lower:]')

    CURRENT_UNIT=${CURRENT_UNIT:-g}
    TARGET_UNIT=${TARGET_UNIT:-g}

    CURRENT_BYTES=$(numfmt --from=iec "${CURRENT_VALUE}${CURRENT_UNIT^^}")
    TARGET_BYTES=$(numfmt --from=iec "${TARGET_VALUE}${TARGET_UNIT^^}")

    if (( TARGET_BYTES > CURRENT_BYTES )); then
        echo "[+] Resizing $NEXT_SCSI from $CURRENT_SIZE to $NEW_DISKSIZE..."
        qm resize "$VMID" "$NEXT_SCSI" "$NEW_DISKSIZE"
        echo "[✓] Disk resized successfully to $NEW_DISKSIZE."
    else
        echo "⚠️  Requested disk size ($NEW_DISKSIZE) is not larger than current size ($CURRENT_SIZE). Skipping resize."
    fi
fi

#=============================================================
# --- TAGGING AND STARTUP ---
#=============================================================
if [[ -n "$TAG" ]]; then
    echo "[+] Tagging VM with: $TAG"
    qm set "$VMID" --tags "$TAG"
fi

# --- Optional start VM ---
if [[ "$STARTVM" == "true" ]]; then
    echo "[+] Starting VM..."
    qm start "$VMID"
    echo "[✓] VM with ID $VMID started successfully."
    VM_STATUS="Started"
else
    echo "[ℹ] VM creation complete. Not starting (use --startvm true to auto-start)."
    echo "To start manually: qm start $VMID, or click the start button in the Proxmox UI."
    VM_STATUS="Not started"
fi

#=============================================================
# --- FINAL SUMMARY ---
#=============================================================
echo ""
echo "✅ SUCCESS: Server VM prepared."
echo "---------------------------------------"
echo " VM ID:          $VMID"
echo " Name:           $VMNAME"
echo " Status:         $VM_STATUS"
echo " Memory:         ${MEMORY}MB"
echo " Cores:          $CORES"
echo " Storage:        $STORAGE"
echo " Disk Path:      $DISK_PATH"
echo " Disk Format:    $DISK_FORMAT"
echo " Disk Size:      ${NEW_DISKSIZE:-Current size unchanged}"
echo " Bridge:         $BRIDGE"
echo " VLAN Tag:       ${VLAN:-None}"
echo " MAC Address:    ${MACADDR:-Auto}"
echo " Cloud User:     $CIUSER"
echo " Nameserver:     $NAMESERVER"
echo " SSH Key:        $SSHKEY"
echo " VM Tag:         ${TAG:-None}"
echo " Image Source:   ${IMAGE_URL:-$IMAGE_FILE}"
echo "---------------------------------------"

echo "Access the VM after boot with:"
echo "  ssh ${CIUSER}@<vm_ip>"
echo ""
