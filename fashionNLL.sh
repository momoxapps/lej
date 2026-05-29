#!/usr/bin/env bash

set -uo pipefail

LOG_FILE="/var/log/provisioning_cups_chrome.log"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================="
echo "START PROVISIONING: $(date)"
echo "================================================="

############################################
# HELPERS
############################################

handle_error() {
    local exit_code=$?
    local line_no=$1
    local command="$2"

    echo
    echo "[ERROR] Command failed at line $line_no"
    echo "[ERROR] Command: $command"
    echo "[ERROR] Exit code: $exit_code"
    echo

    while true; do
        echo "Choose action:"
        echo "  [r] Retry"
        echo "  [c] Continue"
        echo "  [a] Abort"
        read -rp "> " choice

        case "$choice" in
            r|R)
                echo "[INFO] Retrying..."
                eval "$command"
                return 0
                ;;
            c|C)
                echo "[WARN] Continuing despite error..."
                return 0
                ;;
            a|A)
                echo "[INFO] Aborted by user."
                exit 1
                ;;
            *)
                echo "[WARN] Invalid choice."
                ;;
        esac
    done
}

trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

backup_file() {
    local file="$1"

    if [ -f "$file" ]; then
        sudo cp -f "$file" "${file}.bak"
    fi
}

service_exists() {
    systemctl list-unit-files | grep -q "^$1"
}

############################################
# CHROME VERSION MANAGER (ROBUST)
############################################

echo
echo "[STEP X] Google Chrome version manager..."

CURRENT_VERSION=$(
google-chrome --version 2>/dev/null \
| grep -oP '[0-9.]+' \
| head -n1
)

echo "[INFO] Current version: ${CURRENT_VERSION:-Not installed}"

echo "[INFO] Updating package lists..."
sudo apt update -qq

echo
echo "[INFO] Fetching available versions from Google repo..."

mapfile -t ALL_VERSIONS < <(
apt-cache madison google-chrome-stable \
| awk '{print $3}' \
| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' \
| sort -Vu
)

if [ ${#ALL_VERSIONS[@]} -eq 0 ]; then
    echo "[WARN] No versions found in repo."
    exit 0
fi

# آخر 5 نسخ (stable history)
mapfile -t VERSIONS < <(
printf "%s\n" "${ALL_VERSIONS[@]}" | tail -n 5
)

echo
echo "Available Chrome versions:"
echo

for i in "${!VERSIONS[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${VERSIONS[$i]}"
done

echo
echo "  [u] Upgrade to latest"
echo "  [d] Downgrade (choose older)"
echo "  [0] Skip"
echo

read -rp "Choose option: " CHOICE

SELECTED=""

case "$CHOICE" in

    u|U)
        SELECTED="${VERSIONS[-1]}"
        ;;

    d|D)
        read -rp "Select version (1-${#VERSIONS[@]}): " IDX
        if [[ "$IDX" =~ ^[0-9]+$ ]]; then
            SELECTED="${VERSIONS[$((IDX-1))]}"
        fi
        ;;

    0)
        echo "[INFO] Skipping Chrome update."
        exit 0
        ;;

    *)
        if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
            SELECTED="${VERSIONS[$((CHOICE-1))]}"
        fi
        ;;
esac

if [ -z "$SELECTED" ]; then
    echo "[WARN] No version selected."
    exit 0
fi

echo
echo "[INFO] Selected version: $SELECTED"

echo "[INFO] Installing..."

sudo apt install -y \
    --allow-downgrades \
    google-chrome-stable="$SELECTED" || {
        echo "[ERROR] Installation failed"
        echo "[INFO] Keeping current version: $CURRENT_VERSION"
        exit 0
    }

echo
echo "[INFO] Final Chrome version:"
google-chrome --version || true

############################################
# 1. REMOVE EXISTING PRINTERS
############################################

echo
echo "[STEP 1] Removing existing printers..."

PRINTERS=$(lpstat -p 2>/dev/null | awk '{print $2}' || true)

if [ -z "$PRINTERS" ]; then
    echo "[INFO] No existing printers found. Skipping removal."
else
    echo "$PRINTERS" | while read -r printer; do
        if [ -n "$printer" ]; then
            echo "[INFO] Removing printer: $printer"
            sudo lpadmin -x "$printer" || true
        fi
    done
fi

############################################
# 2. RESET CUPS CONFIG
############################################

echo
echo "[STEP 2] Resetting CUPS configuration..."

for file in /etc/cups/printers.conf /etc/cups/classes.conf; do
    if [ -f "$file" ]; then
        backup_file "$file"
        sudo rm -f "$file"
    fi
done

sudo systemctl restart cups

############################################
# 3. CLEAN CHROME PRINT DATA
############################################

echo
echo "[STEP 3] Cleaning Chrome print data..."

TARGET_USER="${SUDO_USER:-user}"
USER_HOME=$(eval echo "~$TARGET_USER")

CHROME_PROFILE="$USER_HOME/.config/google-chrome/Default"

if [ -d "$CHROME_PROFILE" ]; then
    echo "[INFO] Cleaning Chrome profile for user: $TARGET_USER"

    sudo rm -rf "$CHROME_PROFILE/Printer"* 2>/dev/null || true
    sudo rm -rf "$CHROME_PROFILE/printing"* 2>/dev/null || true
else
    echo "[INFO] Chrome profile not found for user: $TARGET_USER"
fi

pkill -u "$TARGET_USER" chrome 2>/dev/null || true


############################################
# 4. DISABLE NETWORK PRINT DISCOVERY
############################################

echo
echo "[STEP 4] Disabling network print discovery..."

# cups-browsed
sudo systemctl stop cups-browsed 2>/dev/null || true
sudo systemctl mask cups-browsed 2>/dev/null || true

# avahi socket first
sudo systemctl stop avahi-daemon.socket 2>/dev/null || true
sudo systemctl mask avahi-daemon.socket 2>/dev/null || true

# avahi service
sudo systemctl stop avahi-daemon 2>/dev/null || true
sudo systemctl mask avahi-daemon.service 2>/dev/null || true

sudo systemctl daemon-reload 2>/dev/null || true

############################################
# 5. PATCH CUPSD.CONF
############################################

echo
echo "[STEP 5] Updating cupsd.conf..."

CUPS_FILE="/etc/cups/cupsd.conf"

backup_file "$CUPS_FILE"

sudo awk '
!/^[[:space:]]*Browsing[[:space:]]+/ &&
!/^[[:space:]]*BrowseLocalProtocols[[:space:]]+/ &&
!/^[[:space:]]*BrowseRemoteProtocols[[:space:]]+/
' "$CUPS_FILE" | sudo tee "${CUPS_FILE}.tmp" >/dev/null

if ! grep -q "Browsing Off" "${CUPS_FILE}.tmp"; then
    sudo sed -i '/^Listen \/run\/cups\/cups.sock/a Browsing Off\nBrowseLocalProtocols none\nBrowseRemoteProtocols none' "${CUPS_FILE}.tmp"
fi

sudo mv "${CUPS_FILE}.tmp" "$CUPS_FILE"

sudo systemctl restart cups

############################################
# 6. CHROME POLICY UPDATE
############################################

echo
echo "[STEP 6] Updating Chrome policy..."

POLICY_DIR="/etc/opt/chrome/policies/managed"
BACKUP_DIR="/etc/opt/chrome/policies/backup"

POLICY_FILE="${POLICY_DIR}/default_policy.json"

TMP_FILE=$(mktemp)

sudo mkdir -p "$POLICY_DIR"
sudo mkdir -p "$BACKUP_DIR"

# backup managed Chrome 

if [ -f "$POLICY_FILE" ]; then
    sudo cp "$POLICY_FILE" \
    "${BACKUP_DIR}/default_policy.json.bak"
fi

STATION=""

if [ -f "$POLICY_FILE" ]; then
    STATION=$(grep -oP "shipping_outbound/pack_nll/\K[0-9]+" "$POLICY_FILE" | head -n1 || true)
fi

if [ -n "${STATION:-}" ]; then
    PACK_URL="https://app.lg.int.momox.biz/shipping_outbound/pack_nll/$STATION"
else
    PACK_URL="https://app.lg.int.momox.biz/shipping_outbound/pack_nll/"
fi

python3 <<EOF
import json
import urllib.request

url = "https://raw.githubusercontent.com/momoxapps/lej/refs/heads/main/default_policy.json"

with urllib.request.urlopen(url) as r:
    data = json.loads(r.read().decode("utf-8"))

pack_url = "$PACK_URL"

for item in data.get("ManagedBookmarks", []):
    if item.get("name") == "B&M Pack":
        item["url"] = pack_url

data["RestoreOnStartupURLs"] = [pack_url]

with open("$TMP_FILE", "w") as f:
    json.dump(data, f, indent=2)
EOF

sudo mv "$TMP_FILE" "$POLICY_FILE"
sudo chmod 644 "$POLICY_FILE"

echo "[INFO] Chrome policy updated successfully."

############################################
# 7. CHROME DESKTOP MODE
############################################

echo
echo "[STEP 7] Updating Chrome desktop entry..."

DESKTOP_FILE="/home/user/.local/share/applications/google-chrome.desktop"

if [ -f "$DESKTOP_FILE" ]; then

    cp -f "$DESKTOP_FILE" "${DESKTOP_FILE}.bak"

    sed -i \
    's|^Exec=/usr/bin/google-chrome.*|Exec=/usr/bin/google-chrome --kiosk-printing --ignore-certificate-errors %U|' \
    "$DESKTOP_FILE"

    if grep -q -- "--kiosk-printing" "$DESKTOP_FILE"; then
        echo "[INFO] Chrome desktop entry updated successfully."
    else
        echo "[WARN] Chrome desktop modification failed."
    fi

else
    echo "[WARN] Desktop file not found:"
    echo "       $DESKTOP_FILE"
fi


############################################
# 8. ADD MADMIN TO PRINTER MANAGEMENT GROUP
############################################
echo
echo "[STEP 8] Ensuring madmin is in lpadmin group..."

if id "madmin" &>/dev/null; then
    sudo /sbin/usermod -aG lpadmin madmin
else
    echo "[WARN] User madmin does not exist"
fi

############################################
# 9. CONFIGURE PRINTER
############################################

echo
echo "[STEP 9] Configuring printer MX00001..."

while true; do

    read -rp "Enter printer IP address (e.g. 10.24.1.113): " PRINTER_IP

    if [[ -z "${PRINTER_IP}" ]]; then
        echo "[ERROR] Printer IP cannot be empty"
        continue
    fi

    if ! [[ "$PRINTER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "[ERROR] Invalid IP format"
        continue
    fi

    break
done

echo "[INFO] Using printer IP: $PRINTER_IP"

sudo lpadmin -p MX00001 -E \
    -v "socket://${PRINTER_IP}:9100" \
    -m drv:///sample.drv/zebraep2.ppd \
    -o PageSize=w288h432 \
    -o media=w288h432 \
    -o fit-to-page=false \
    -o sides=one-sided \
    -o job-sheets=none,none \
    -o printer-is-shared=false

sudo lpoptions -d MX00001

echo "[INFO] Printer set as default."

############################################
# 10. FINAL RESTART
############################################

echo
echo "[STEP 10] Restarting CUPS..."

sudo systemctl restart cups

############################################
# 11. VERIFY
############################################

echo
echo "[STEP 11] Verifying configuration..."

lpoptions -p MX00001 || true
lpstat -p || true

echo
echo "================================================="
echo "DONE: $(date)"
echo "================================================="
