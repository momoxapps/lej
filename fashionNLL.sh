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
# 1. REMOVE EXISTING PRINTERS
############################################

echo
echo "[STEP 1] Removing existing printers..."

if command -v lpstat >/dev/null 2>&1; then
    lpstat -p 2>/dev/null | awk '{print $2}' | while read -r printer; do
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

CHROME_PROFILE="$HOME/.config/google-chrome/Default"

if [ -d "$CHROME_PROFILE" ]; then
    rm -rf "$CHROME_PROFILE"/Printer* || true
    rm -rf "$CHROME_PROFILE"/printing* || true
fi

pkill chrome || true

############################################
# 4. DISABLE NETWORK PRINT DISCOVERY
############################################

echo
echo "[STEP 4] Disabling network print discovery..."

# cups-browsed
sudo systemctl stop cups-browsed || true
sudo systemctl disable cups-browsed || true
sudo systemctl mask cups-browsed || true

# avahi daemon
sudo systemctl stop avahi-daemon || true
sudo systemctl disable avahi-daemon || true

# avahi socket
sudo systemctl stop avahi-daemon.socket || true
sudo systemctl disable avahi-daemon.socket || true

# mask both completely
sudo systemctl mask avahi-daemon.service || true
sudo systemctl mask avahi-daemon.socket || true

# reload systemd state
sudo systemctl daemon-reload || true

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
# 8. CONFIGURE PRINTER
############################################

echo
echo "[STEP 8] Configuring printer MX00001..."

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
# 9. FINAL RESTART
############################################

echo
echo "[STEP 9] Restarting CUPS..."

sudo systemctl restart cups

############################################
# 10. VERIFY
############################################

echo
echo "[STEP 10] Verifying configuration..."

lpoptions -p MX00001 || true
lpstat -p || true

echo
echo "================================================="
echo "DONE: $(date)"
echo "================================================="
