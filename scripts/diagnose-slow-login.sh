#!/usr/bin/env bash
set -euo pipefail

# diagnose-slow-login.sh — Diagnose extremely slow login on Kali Linux
# Run this script after logging in to identify the cause of slow boot/login.

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== Kali Linux - Diagnose Slow Login ===${NC}"
echo ""

# 1. Check systemd blame (which services took longest to start)
echo -e "${BOLD}[1/7] Traagste systemd services:${NC}"
systemd-analyze blame 2>/dev/null | head -15 || echo "  (systemd-analyze niet beschikbaar)"
echo ""

# 2. Check for services that timed out or failed
echo -e "${BOLD}[2/7] Gefaalde of vastgelopen services:${NC}"
systemctl --failed 2>/dev/null || echo "  (kon niet ophalen)"
echo ""

# 3. Total boot time
echo -e "${BOLD}[3/7] Totale opstarttijd:${NC}"
systemd-analyze time 2>/dev/null || echo "  (niet beschikbaar)"
echo ""

# 4. Check critical chain (bottleneck path)
echo -e "${BOLD}[4/7] Kritiek pad (bottleneck):${NC}"
systemd-analyze critical-chain 2>/dev/null | head -20 || echo "  (niet beschikbaar)"
echo ""

# 5. Disk usage
echo -e "${BOLD}[5/7] Schijfgebruik:${NC}"
df -h / /home /tmp 2>/dev/null | awk '
NR==1 { print "  " $0 }
NR>1 {
    gsub(/%/,"",$5)
    if ($5+0 >= 90) printf "  \033[0;31m%s (BIJNA VOL!)\033[0m\n", $0
    else if ($5+0 >= 75) printf "  \033[1;33m%s\033[0m\n", $0
    else printf "  \033[0;32m%s\033[0m\n", $0
}'
echo ""

# 6. Memory and swap
echo -e "${BOLD}[6/7] Geheugen en swap:${NC}"
free -h 2>/dev/null | while IFS= read -r line; do echo "  $line"; done
echo ""

# 7. Network - check if DNS resolution is slow (common cause)
echo -e "${BOLD}[7/7] DNS-resolutie snelheid:${NC}"
DNS_START=$(date +%s%N)
if host -W 5 google.com > /dev/null 2>&1; then
    DNS_END=$(date +%s%N)
    DNS_MS=$(( (DNS_END - DNS_START) / 1000000 ))
    if [ "$DNS_MS" -gt 3000 ]; then
        echo -e "  ${RED}DNS duurt ${DNS_MS}ms - TRAAG! Dit kan de oorzaak zijn.${NC}"
        echo -e "  ${YELLOW}Tip: Probeer een snellere DNS in /etc/resolv.conf:${NC}"
        echo "    nameserver 8.8.8.8"
        echo "    nameserver 1.1.1.1"
    else
        echo -e "  ${GREEN}DNS OK (${DNS_MS}ms)${NC}"
    fi
else
    echo -e "  ${RED}DNS werkt niet! Controleer je netwerkverbinding.${NC}"
fi
echo ""

# Summary and common fixes
echo -e "${BOLD}=== Veelvoorkomende oplossingen ===${NC}"
echo ""
echo "Als een specifieke service traag is (zie [1/7] hierboven):"
echo "  sudo systemctl disable <service-naam>    # uitschakelen"
echo "  sudo systemctl mask <service-naam>        # volledig blokkeren"
echo ""
echo "Veelvoorkomende boosdoeners na een Kali update:"
echo "  - NetworkManager-wait-online.service  (netwerk timeout)"
echo "    Fix: sudo systemctl disable NetworkManager-wait-online.service"
echo ""
echo "  - plymouth-quit-wait.service  (boot splash timeout)"
echo "    Fix: sudo systemctl disable plymouth-quit-wait.service"
echo ""
echo "  - apt-daily.service / apt-daily-upgrade.service"
echo "    Fix: sudo systemctl disable apt-daily.timer apt-daily-upgrade.timer"
echo ""
echo "  - GPU driver probleem (scherm bevriest)"
echo "    Fix: sudo apt install -y kali-defaults kali-desktop-xfce"
echo "    Of herinstalleer drivers: sudo apt install -y nvidia-driver (als NVIDIA)"
echo ""
echo "Als de schijf bijna vol is:"
echo "  sudo apt autoremove && sudo apt clean"
echo ""
echo "Volledige desktop environment herstellen:"
echo "  sudo apt update && sudo apt install -y --reinstall kali-desktop-xfce"
echo "  (vervang xfce door gnome als je GNOME gebruikt)"
