#!/bin/bash
#=============================================================
# VM Deployment Script for Proxmox VE 9.0.x or higher
# Author: Wouter Iliohan
#=============================================================
# Deploy a cloud-init–ready Ubuntu/Debian VM on Proxmox VE using either a
# downloaded cloud image (from --image-url) or a local image file (--image-file).
# The script minimizes noisy Proxmox CLI output by default; pass --verbose to
# show native `qm` output. It auto-detects the next free SCSI slot, sets boot
# order, configures cloud-init, optionally resizes the attached disk, and can
# tag and start the VM.
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
VERBOSE="false"				     # Whether to show verbose output from qm commands

#=============================================================
# --- Help and Usage Information ---
#=============================================================
usage() {
cat <<EOF
Usage: $0 [OPTIONS]


Options (in preferred order):
--vmid <id> VM ID (default: $VMID)
--name <name> VM name (default: $VMNAME)
--memory <MB> Memory in MB (default: $MEMORY)
--cores <num> CPU cores (default: $CORES)
--bridge <iface> Bridge interface (default: $BRIDGE)
--vlan <tag> VLAN tag (optional)
--mac <addr> MAC address (optional, XX:XX:XX:XX:XX:XX)
--storage <pool> Storage pool (default: $STORAGE)
--new-disksize <size> Resize after import (e.g., 20G; must include unit)
--image-url <url> Cloud image URL (exclusive with --image-file)
--image-file <file> Local image file (exclusive with --image-url)
--image-dir <dir> Directory for image storage (default: $IMPORT_DIR)
--ciuser <user> Cloud-init user (default: $CIUSER)
--nameserver <ip> DNS nameserver (default: $NAMESERVER)
--sshkey <path> SSH public key (default: $SSHKEY)
--startvm <true|false> Start VM after creation (default: $STARTVM)
--tag <tag> VM tag (optional)
--verbose Enable verbose mode (default: $VERBOSE)
-h, --help Show this help and exit


Notes:
- The VM will NOT auto-start unless you pass --startvm true.
- When using --image-url, the script downloads to --image-dir (or $IMPORT_DIR)
  unless a matching .img.raw or .img (same basename) already exists there.
- When using --image-file, the script looks in --image-dir (or $IMPORT_DIR) and
  falls back to the provided absolute/relative path if not found in that dir.
EOF
exit 0
}

#=============================================================
# --- Helpers for Quiet Execution ---
#=============================================================
run_qm() {
if [[ "$VERBOSE" == "true" ]]; then
qm "$@"
else
qm "$@" >/dev/null 2>&1
fi
}


wget_dl() {
# Quiet by default; show progress only if verbose
if [[ "$VERBOSE" == "true" ]]; then
wget --show-progress -O "$1" "$2"
else
wget -q -O "$1" "$2"
fi
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
        --verbose) VERBOSE="true"; shift ;;
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

#=============================================================
# Create VM (quiet by default)
#=============================================================
echo "[+] Creating VM ($VMNAME, ID: $VMID)..."
run_qm create "$VMID" --name "$VMNAME" --memory "$MEMORY" --cores "$CORES" --net0 "$NETCONFIG"

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

#=============================================================
# --- Determine next available SCSI slot ---
# --- Attach disk to first available SCSI slot ---
#=============================================================
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
run_qm set "$VMID" --scsihw virtio-scsi-pci --"$NEXT_SCSI" "$DISK_PATH"

#=============================================================
# --- CLOUD-INIT CONFIGURATION ---
#=============================================================
run_qm set "$VMID" --ide2 "$STORAGE:cloudinit"
run_qm set "$VMID" --boot c --bootdisk "$NEXT_SCSI"
run_qm set "$VMID" --serial0 socket --vga serial0
run_qm set "$VMID" --ipconfig0 ip=dhcp
run_qm set "$VMID" --sshkey "$SSHKEY"
run_qm set "$VMID" --ciuser "$CIUSER"
run_qm set "$VMID" --nameserver "$NAMESERVER"

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
    run_qm set "$VMID" --tags "$TAG"
fi

# --- Optional start VM ---
if [[ "$STARTVM" == "true" ]]; then
    echo "[+] Starting VM..."
    run_qm start "$VMID"
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
