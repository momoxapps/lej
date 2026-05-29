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
# CHROME VERSION MANAGER (HYBRID SAFE FINAL FIXED)
############################################

echo
echo "[STEP X] Google Chrome version manager (HYBRID SAFE FINAL FIXED)..."

TARGET_USER="${SUDO_USER:-user}"
USER_HOME=$(eval echo "~$TARGET_USER")

CHROME_PROFILE="$USER_HOME/.config/google-chrome"

CURRENT_VERSION=$(
google-chrome --version 2>/dev/null \
| grep -oP '[0-9.]+' \
| head -n1
)

echo "[INFO] Current version: ${CURRENT_VERSION:-Not installed}"

############################################
# 1. FETCH UPGRADE VERSION (OFFICIAL)
############################################

echo "[INFO] Fetching available version from Google repo..."

mapfile -t UPGRADE_VERSIONS < <(
apt-cache madison google-chrome-stable 2>/dev/null \
| awk '{print $3}' \
| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' \
| sort -Vu
)

LATEST_UPGRADE="${UPGRADE_VERSIONS[-1]:-}"

############################################
# 2. VERIFIED DOWNGRADES (STATIC SAFE LIST)
############################################

DOWNGRADE_URLS=(
"http://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_147.0.7727.137-1_amd64.deb"
"http://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_146.0.7680.177-1_amd64.deb"
"http://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_145.0.7632.159-1_amd64.deb"
"http://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_143.0.7499.40-1_amd64.deb"
)

DOWNGRADE_NAMES=()
for url in "${DOWNGRADE_URLS[@]}"; do
    DOWNGRADE_NAMES+=("$(basename "$url")")
done

############################################
# 3. MENU
############################################

echo
echo "Available options:"
echo

echo "[UPGRADE]"
if [ -n "$LATEST_UPGRADE" ]; then
    echo "  [u] Upgrade to latest: $LATEST_UPGRADE"
else
    echo "  [u] No upgrade available"
fi

echo
echo "[DOWNGRADE]"
for i in "${!DOWNGRADE_NAMES[@]}"; do
    printf "  [d%d] %s\n" "$((i+1))" "${DOWNGRADE_NAMES[$i]}"
done

echo
echo "  [0] Skip (continue script)"
echo

read -rp "Choose option: " CHOICE

SELECTED_URL=""
SELECTED_VERSION=""
ACTION="none"

############################################
# 4. CHOICE HANDLER (SAFE)
############################################

case "$CHOICE" in

    u|U)
        SELECTED_VERSION="$LATEST_UPGRADE"
        ACTION="upgrade"
        ;;

    d1|d2|d3|d4)
        INDEX="${CHOICE#d}"
        INDEX=$((INDEX-1))
        SELECTED_URL="${DOWNGRADE_URLS[$INDEX]}"
        ACTION="downgrade"
        ;;

    0|"")
        echo "[INFO] Skip selected → continuing script"
        ACTION="skip"
        ;;

    *)
        echo "[WARN] Invalid choice → skipping safely"
        ACTION="skip"
        ;;
esac

############################################
# 5. INSTALL LOGIC (FIXED STABILITY)
############################################

if [ "$ACTION" = "downgrade" ]; then

    echo "[INFO] Downloading downgrade package..."
    wget -qO /tmp/chrome.deb "$SELECTED_URL" || {
        echo "[ERROR] Download failed"
        ACTION="skip"
    }

    if [ -f /tmp/chrome.deb ]; then

        echo "[INFO] Installing downgrade safely..."

        sudo dpkg -i /tmp/chrome.deb || true
        sudo apt-get install -f -y || true

        # IMPORTANT FIX → allow future installs without breaking apt
        sudo apt-mark hold google-chrome-stable >/dev/null 2>&1 || true

        echo "[INFO] Downgrade completed"
    fi

elif [ "$ACTION" = "upgrade" ]; then

    echo "[INFO] Removing hold from Chrome package..."
    sudo apt-mark unhold google-chrome-stable >/dev/null 2>&1 || true

    echo "[INFO] Installing upgrade version: $SELECTED_VERSION"

    sudo apt update

    sudo apt install -y \
        --allow-downgrades \
        --allow-change-held-packages \
        google-chrome-stable="$SELECTED_VERSION"

    echo "[INFO] Upgrade completed"

else
    echo "[INFO] No Chrome change applied"
fi

############################################
# 6. POST INSTALL CHECK
############################################

echo
echo "[INFO] Final Chrome version:"
google-chrome --version || true

############################################
# 7. STRONG SAFE PROFILE RESET (DOWNGRADE ONLY)
############################################

if [ "$ACTION" = "downgrade" ]; then

    echo "[INFO] Downgrade detected → performing strong safe Chrome reset..."

    pkill -f chrome 2>/dev/null || true

    for USER_DIR in /home/*; do

        [ -d "$USER_DIR" ] || continue

        CHROME_DIR="$USER_DIR/.config/google-chrome"
        DEFAULT_DIR="$CHROME_DIR/Default"

        [ -d "$DEFAULT_DIR" ] || continue

        USERNAME=$(basename "$USER_DIR")

        echo "[INFO] Cleaning Chrome profile for user: $USERNAME"


        mkdir -p /tmp/chrome-safe-backup

        cp -f "$DEFAULT_DIR/Bookmarks" \
            /tmp/chrome-safe-backup/Bookmarks 2>/dev/null || true

        cp -f "$DEFAULT_DIR/Login Data" \
            /tmp/chrome-safe-backup/LoginData 2>/dev/null || true

        cp -f "$DEFAULT_DIR/History" \
            /tmp/chrome-safe-backup/History 2>/dev/null || true

        sudo rm -rf "$CHROME_DIR"

        mkdir -p "$DEFAULT_DIR"

        cp -f /tmp/chrome-safe-backup/Bookmarks \
            "$DEFAULT_DIR/Bookmarks" 2>/dev/null || true

        cp -f /tmp/chrome-safe-backup/LoginData \
            "$DEFAULT_DIR/Login Data" 2>/dev/null || true

        cp -f /tmp/chrome-safe-backup/History \
            "$DEFAULT_DIR/History" 2>/dev/null || true

        chown -R "$USERNAME:$USERNAME" "$CHROME_DIR" 2>/dev/null || true

        rm -rf /tmp/chrome-safe-backup

        echo "[INFO] Chrome profile rebuilt safely for $USERNAME"
    done
fi

echo "[INFO] Chrome version manager completed safely"

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
