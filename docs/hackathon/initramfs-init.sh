#!/bin/sh
echo "============================================="
echo " Hello from SNP-protected mini VM!"
echo " Running OHCL kernel as direct guest"
echo "============================================="

# Mount essential filesystems
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null

echo "[init] Kernel: $(cat /proc/version 2>&1 | head -c 100)"
echo ""
echo "[init] Checking SEV status..."
if [ -d /sys/module/sev ]; then
    echo "[init] SEV module loaded"
fi
if [ -e /dev/sev-guest ]; then
    echo "[init] /dev/sev-guest EXISTS - SNP attestation available!"
else
    echo "[init] /dev/sev-guest does not exist"
fi
echo ""
echo "[init] Memory encryption status from dmesg:"
dmesg 2>/dev/null | grep -iE "sev|snp|memory encryption" | head -10
echo ""
echo "[init] CPU flags (look for sev/snp):"
grep -oE 'sev[a-z_]*|snp[a-z_]*' /proc/cpuinfo | sort -u | tr '\n' ' '
echo ""
echo ""
echo "============================================="
echo "  HELLO WORLD APP RUNNING IN SNP GUEST"
echo "============================================="
echo "[init] Sleeping 5s, then dropping to shell..."
sleep 5
exec /bin/sh
