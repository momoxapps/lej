#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/provisioning_cups_chrome.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== START PROVISIONING: $(date) ==="

############################
# 1. REMOVE EXISTING PRINTERS
############################
echo "[INFO] Removing existing printers..."

lpstat -p | awk '{print $2}' | while read -r printer; do
    [ -n "$printer" ] && sudo lpadmin -x "$printer" || true
done


############################
# 2. RESET CUPS CONFIG
############################
echo "[INFO] Resetting CUPS configuration..."

if [ -f /etc/cups/printers.conf ]; then
    sudo cp /etc/cups/printers.conf /etc/cups/printers.conf.bak
    sudo rm -f /etc/cups/printers.conf
fi

if [ -f /etc/cups/classes.conf ]; then
    sudo cp /etc/cups/classes.conf /etc/cups/classes.conf.bak
    sudo rm -f /etc/cups/classes.conf
fi

sudo systemctl restart cups


############################
# 3. CLEAN CHROME PRINT DATA
############################
echo "[INFO] Cleaning Chrome print data..."

CHROME_PROFILE="$HOME/.config/google-chrome/Default"

rm -rf "$CHROME_PROFILE/Printer"* || true
rm -rf "$CHROME_PROFILE/printing"* || true

pkill chrome || true


############################
# 4. DISABLE NETWORK PRINT DISCOVERY
############################
echo "[INFO] Disabling cups-browsed and avahi..."

sudo systemctl stop cups-browsed || true
sudo systemctl disable cups-browsed || true
sudo systemctl mask cups-browsed || true

sudo systemctl stop avahi-daemon || true
sudo systemctl disable avahi-daemon || true
sudo systemctl mask avahi-daemon || true


############################
# 5. PATCH cupsd.conf SAFELY
############################
echo "[INFO] Updating cupsd.conf..."

CUPS_FILE="/etc/cups/cupsd.conf"
sudo cp "$CUPS_FILE" "$CUPS_FILE.bak"

sudo awk '
!/^[[:space:]]*Browsing[[:space:]]+/ &&
!/^[[:space:]]*BrowseLocalProtocols[[:space:]]+/ &&
!/^[[:space:]]*BrowseRemoteProtocols[[:space:]]+/
' "$CUPS_FILE" | sudo tee "$CUPS_FILE.tmp" > /dev/null

if ! grep -q "Browsing Off" "$CUPS_FILE.tmp"; then
    sudo sed -i '/^Listen \/run\/cups\/cups.sock/a Browsing Off\nBrowseLocalProtocols none\nBrowseRemoteProtocols none' "$CUPS_FILE.tmp"
fi

sudo mv "$CUPS_FILE.tmp" "$CUPS_FILE"

sudo systemctl restart cups


############################
# 6. CHROME POLICY UPDATE
############################
echo "[INFO] Updating Chrome policy..."

POLICY_FILE="/etc/opt/chrome/policies/managed/default_policy.json"
TMP_FILE="/tmp/default_policy.json"

sudo cp "$POLICY_FILE" "$POLICY_FILE.bak"

STATION=$(grep -oP "shipping_outbound/pack_nll/\K[0-9]+" "$POLICY_FILE" | head -n1 || true)

if [ -n "${STATION:-}" ]; then
    PACK_URL="https://app.lg.int.momox.biz/shipping_outbound/pack_nll/$STATION"
else
    PACK_URL="https://app.lg.int.momox.biz/shipping_outbound/pack_nll/"
fi

python3 - <<EOF
import json, urllib.request

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


############################
# 7. CHROME DESKTOP MODE
############################
echo "[INFO] Updating Chrome desktop entry..."

DESKTOP_FILE="$HOME/.local/share/applications/google-chrome.desktop"

if [ -f "$DESKTOP_FILE" ]; then
    cp "$DESKTOP_FILE" "$DESKTOP_FILE.bak"
    sed -i 's|^Exec=/usr/bin/google-chrome.*|Exec=/usr/bin/google-chrome --kiosk-printing --ignore-certificate-errors %U|' "$DESKTOP_FILE"
fi


############################
# 8. CONFIGURE PRINTER
############################
echo "[INFO] Configuring printer MX00001..."

sudo lpadmin -p MX00001 -E \
    -v socket://10.24.1.113:9100 \
    -m drv:///sample.drv/zebraep2.ppd \
    -o PageSize=w288h432 \
    -o media=w288h432 \
    -o fit-to-page=false \
    -o sides=one-sided \
    -o job-sheets=none,none \
    -o printer-is-shared=false

sudo lpoptions -d MX00001

echo "[INFO] Printer set as default."


############################
# 9. FINAL RESTART
############################
echo "[INFO] Restarting CUPS..."

sudo systemctl restart cups


############################
# 10. VERIFY
############################
echo "[INFO] Verifying configuration..."

lpoptions -p MX00001 || true
lpstat -p || true

echo "=== DONE: $(date) ==="
