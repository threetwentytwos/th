#!/bin/bash
# Fix laptop freezing caused by system-wide jemalloc configuration
# Run with: sudo bash fix-jemalloc-freeze.sh
# After running, REBOOT immediately: sudo reboot

set -e

echo "=== jemalloc freeze fix ==="
echo ""

FOUND=0

# 1. Check /etc/ld.so.preload (most common cause of system-wide freeze)
if [ -f /etc/ld.so.preload ]; then
    if grep -qi jemalloc /etc/ld.so.preload; then
        echo "[FIX] Removing jemalloc from /etc/ld.so.preload"
        sed -i '/jemalloc/d' /etc/ld.so.preload
        FOUND=1
    fi
    # Remove file if empty after cleanup
    if [ -f /etc/ld.so.preload ] && [ ! -s /etc/ld.so.preload ]; then
        rm -f /etc/ld.so.preload
        echo "  -> Removed empty /etc/ld.so.preload"
    fi
fi

# 2. Check /etc/environment
if [ -f /etc/environment ]; then
    if grep -qi jemalloc /etc/environment; then
        echo "[FIX] Removing jemalloc LD_PRELOAD from /etc/environment"
        sed -i '/jemalloc/d' /etc/environment
        FOUND=1
    fi
fi

# 3. Check /etc/profile.d/ scripts
for f in /etc/profile.d/*.sh; do
    if [ -f "$f" ] && grep -qi jemalloc "$f"; then
        echo "[FIX] Removing $f (contains jemalloc config)"
        rm -f "$f"
        FOUND=1
    fi
done

# 4. Check user profile files
for f in ~/.bashrc ~/.profile ~/.bash_profile ~/.zshrc; do
    if [ -f "$f" ] && grep -qi jemalloc "$f"; then
        echo "[FIX] Removing jemalloc lines from $f"
        sed -i '/jemalloc/d' "$f"
        FOUND=1
    fi
done

# 5. Check systemd system-wide environment
if [ -d /etc/systemd/system.conf.d/ ]; then
    for f in /etc/systemd/system.conf.d/*.conf; do
        if [ -f "$f" ] && grep -qi jemalloc "$f"; then
            echo "[FIX] Removing $f (systemd jemalloc override)"
            rm -f "$f"
            FOUND=1
        fi
    done
fi
if [ -f /etc/systemd/system.conf ] && grep -qi jemalloc /etc/systemd/system.conf; then
    echo "[FIX] Removing jemalloc from /etc/systemd/system.conf"
    sed -i '/jemalloc/d' /etc/systemd/system.conf
    FOUND=1
fi

# 6. Check /etc/default/ for any service-level jemalloc configs
for f in /etc/default/*; do
    if [ -f "$f" ] && grep -qi jemalloc "$f"; then
        echo "[FIX] Removing jemalloc from $f"
        sed -i '/jemalloc/d' "$f"
        FOUND=1
    fi
done

# 7. Unset LD_PRELOAD for current session (immediate relief)
if echo "$LD_PRELOAD" | grep -qi jemalloc 2>/dev/null; then
    echo "[FIX] Unsetting LD_PRELOAD for current session"
    unset LD_PRELOAD
    FOUND=1
fi

echo ""
if [ "$FOUND" -eq 1 ]; then
    echo "=== FIXES APPLIED ==="
    echo "REBOOT NOW to complete the fix:"
    echo "  sudo reboot"
else
    echo "=== No jemalloc configuration found in standard locations ==="
    echo ""
    echo "Searching entire system for jemalloc references..."
    echo "LD_PRELOAD locations:"
    grep -r "jemalloc" /etc/ 2>/dev/null || echo "  (none found in /etc/)"
    grep -r "jemalloc" ~/.* 2>/dev/null || echo "  (none found in user dotfiles)"
    echo ""
    echo "Installed jemalloc packages:"
    dpkg -l 2>/dev/null | grep jemalloc || rpm -qa 2>/dev/null | grep jemalloc || pacman -Q 2>/dev/null | grep jemalloc || echo "  (could not determine package manager)"
fi
