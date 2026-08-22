#!/usr/bin/env bash
# 5-window.sh - move the root-port prefetchable window above 4 GB, then
# remove and rescan the Thunderbolt subtree so the kernel lays out the bridge
# windows and BARs inside it.
#
# THE PROBLEM
#
# Firmware hands the root port a prefetchable window that is too small and
# entirely below 4 GB (224 MB on the machine this was developed on). The card
# needs BAR1 + BAR3 - 288 MB for a 16 GB Ada card. Linux claims the firmware
# value and never reallocates it, so pci_bus_alloc_resource() - which would
# prefer space above 4 GB for a 64-bit window - is never reached. Symptom:
#
#   pcieport: bridge window [mem size 0x12000000 64bit pref]: can't assign
#   pci: BAR 1 [mem size 0x10000000 64bit pref]: failed to assign
#
# THE FIX
#
# The egpu_rp_window module releases the root port's window, points it above
# 4 GB, claims it into the root bus resource tree and writes the bridge
# registers. Then we remove the Thunderbolt subtree and rescan, and the
# kernel's own allocator does the rest - nested bridge windows and BARs.
#
# THE RESCAN PATH IS THE TRAP
#
# dev_rescan_store() calls pci_rescan_bus(pdev->bus) - the bus the device
# SITS ON, not the one behind it. So
#
#   echo 1 > devices/<root port>/rescan
#
# rescans bus 00 (the host bridge, NVMe, internal GPU, PCH) and HANGS the
# machine. Two hangs were misattributed to memory above 4 GB before this was
# understood. The correct path goes through the bus directory:
#
#   echo 1 > devices/<root port>/pci_bus/<secondary bus>/rescan
#
# Both the root port and its secondary bus number are discovered, not written
# down - see lib/egpu-lib.sh.
#
# To undo everything: REBOOT.
#
#   sudo WIN_BASE=0x4010000000 WIN_MB=1024 REBAR_SIZE=8 ./5-window.sh

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating

# Topology is DISCOVERED, never hardcoded: bus numbers behind a Thunderbolt
# tunnel shift between machines, between ports and between hot-plugs.
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run ./2-devices.sh to see what is present." >&2
    exit 1
fi
RP=$EGPU_ROOT_PORT           # CPU root port whose prefetchable window we move
TB=$EGPU_TB_UPSTREAM         # first device below it - removed and rescanned
DEV=$EGPU_GPU                # the card itself
AUDIO=${DEV%.*}.1            # its HDMI-audio function, if present
RESCAN_BUS=$EGPU_SECONDARY_BUS
MODDIR=$SELFDIR/module
# The module is built out of tree - module/Makefile explains why. Ask make
# for the path so it is defined in exactly one place.
BUILDDIR=$(make --no-print-directory -C "$MODDIR" -s print-builddir 2>/dev/null)
BUILDDIR=${BUILDDIR:-$SELFDIR/build/module}
KO=$BUILDDIR/egpu_rp_window.ko

WIN_BASE=${WIN_BASE:-0xf0000000}
WIN_MB=${WIN_MB:-192}
WIN_END=$((WIN_BASE + WIN_MB * 1024 * 1024 - 1))

CAP=0xbb0
TARGET_BAR=1
TARGET_SIZE=${REBAR_SIZE:-7}   # 2^7 MB = 128 MB
EXP_CAP_ID=0x0015

LOGDIR=$SELFDIR/logs
STAMP=$(date +%Y%m%d-%H%M%S)
KLOG=$LOGDIR/kernel-$STAMP.log
SLOG=$LOGDIR/script-$STAMP.log

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
mkdir -p "$LOGDIR"; chown "${SUDO_USER:-root}:" "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$SLOG") 2>&1
TEE_PID=$!
# tee runs in a subprocess; without this a fast exit returns the shell to the
# prompt before tee flushes anything - the message vanishes from the screen,
# although it stays in the log. Close the descriptors and wait for tee.
_flush_tee() { exec 1>&- 2>&- ; wait "$TEE_PID" 2>/dev/null; }

BG=()
cleanup() { for p in "${BG[@]:-}"; do kill "$p" 2>/dev/null || true; done; sync; }
trap 'cleanup; _flush_tee' EXIT
mark() { printf '\n########## %s ##########\n' "$1" >> "$KLOG"; sync; echo ">>> $1"; }

echo "=== logi ==="
echo "  kernel:  $KLOG"
echo "  log: $SLOG"

# ---------------------------------------------------------------- 0
echo
echo "=== 0. Kontrola wstepna ==="
[[ -f $KO ]] || { echo "  ERROR: missing $KO - make -C $MODDIR" >&2; exit 1; }
vm=$(modinfo "$KO" | awk '/^vermagic:/ { print $2 }'); run=$(uname -r)
[[ $vm == "$run" ]] || { echo "  ERROR: module built for $vm, running kernel is $run - rebuild" >&2; exit 1; }
# The logic here is INVERTED: a match must ABORT.
# With "lsmod | grep -q", SIGPIPE returned 141, so && never fired and the
# let execution continue with the module loaded - worse than a false alarm.
[[ -d /sys/module/egpu_rp_window ]] && { echo "  ERROR: module already loaded - reboot" >&2; exit 1; }
[[ -d /sys/bus/pci/devices/$DEV ]] || { echo "  ERROR: $DEV not present - plug the enclosure in" >&2; exit 1; }
printf "  module OK (%s)\n" "$vm"

# ---------------------------------------------------------------- 0b
# Confirm the target hole really is free. Read /proc/iomem
# (as root the real addresses are visible) and look for anything overlapping
# our range. The "PCI Bus" container is skipped - that is where we sit.
echo
printf "=== 0b. Is %s-%#x free? ===\n" "$WIN_BASE" "$WIN_END"
conflict=""
while IFS= read -r line; do
    l="${line#"${line%%[![:space:]]*}"}"          # strip leading spaces
    [[ $l == *" : "* ]] || continue
    range="${l%% : *}"; name="${l#* : }"
    [[ $range == *-* ]] || continue
    s=$((16#${range%%-*})); e=$((16#${range##*-}))
    # the container we sit in - skip
    [[ $name == "PCI Bus 0000:00" ]] && continue
    # another PCI container fully covering our range - skip as well
    if [[ $name == "PCI Bus"* ]] && (( s <= WIN_BASE && e >= WIN_END )); then continue; fi
    if (( s <= WIN_END && e >= WIN_BASE )); then
        conflict+="    $range : $name"$'\n'
    fi
done < /proc/iomem
if [[ -n $conflict ]]; then
    echo "  COLLISION - something already occupies the target range:"
    echo "$conflict"
    echo "  ABORTED. Not overwriting someone else's address space." >&2
    exit 1
fi
echo "  target range is free - no collision"

stdbuf -oL dmesg -w >> "$KLOG" &  BG+=($!)
( while :; do sync; sleep 0.2; done ) & BG+=($!)
sleep 1

# ---------------------------------------------------------------- 1
echo
echo "=== 1. Detaching drivers ==="
for d in $DEV $AUDIO; do
    lnk=/sys/bus/pci/devices/$d/driver
    if [[ -L $lnk ]]; then
        drv=$(basename "$(readlink -f "$lnk")")
        echo "  unbind $d z $drv"; echo "$d" > /sys/bus/pci/drivers/$drv/unbind || true
    else
        echo "  $d no driver bound"
    fi
done
compgen -G "/sys/module/nvidia*" >/dev/null && modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null || true

# ---------------------------------------------------------------- 2
# ReBAR must be set NOW - after removing the subtree the card leaves sysfs
# and setpci has nothing to work on.
echo
echo "=== 2. ReBAR BAR1 -> 128 MB ==="
rd() { setpci -s "$DEV" "$(printf '%x' $1).L" 2>/dev/null; }
hdr=$((16#$(rd $CAP))); cap_id=$((hdr & 0xffff))
printf "  Extended Cap ID = %#06x\n" "$cap_id"
(( cap_id == EXP_CAP_ID )) || { echo "  ERROR: not a ReBAR capability" >&2; exit 1; }
ctrl0=$((16#$(rd $((CAP + 0x08))))); nbars=$(( (ctrl0 >> 5) & 0x7 ))
entry_off=-1
for ((i = 0; i < nbars; i++)); do
    off=$((CAP + 0x08 + 8 * i)); v=$((16#$(rd $off)))
    (( (v & 0x7) == TARGET_BAR )) && entry_off=$off
done
(( entry_off >= 0 )) || { echo "  ERROR: no ReBAR capability entry for BAR1" >&2; exit 1; }
old=$((16#$(rd $entry_off))); cur=$(( (old >> 8) & 0x3f ))
printf "  BAR1 now %d MB" $((2 ** cur))
if (( cur == TARGET_SIZE )); then
    echo " - already at target"
else
    new=$(( (old & ~0x00003f00) | (TARGET_SIZE << 8) ))
    setpci -s "$DEV" "$(printf '%x' $entry_off).L=$(printf '%08x' $new)"
    back=$((16#$(rd $entry_off))); got=$(( (back >> 8) & 0x3f ))
    printf " -> ustawiono %d MB\n" $((2 ** got))
    (( got == TARGET_SIZE )) || { echo "  ERROR: the card did not accept the size" >&2; exit 1; }
fi
printf "  TO RESTORE: sudo setpci -s %s %x.L=%08x\n" "$DEV" "$entry_off" "$old"

# ---------------------------------------------------------------- 3
echo
echo "=== 3. Removing the Thunderbolt subtree ($TB) ==="
mark "BEFORE remove $TB"
[[ -d /sys/bus/pci/devices/$TB ]] && { echo 1 > /sys/bus/pci/devices/$TB/remove; sleep 3; echo "  removed"; }
mark "AFTER remove $TB"

# ---------------------------------------------------------------- 4
echo
printf "=== 4. insmod egpu_rp_window win_base=%s win_mb=%d rp=%s ===\n" "$WIN_BASE" "$WIN_MB" "$RP"
mark "BEFORE insmod"
if insmod "$KO" win_base=$WIN_BASE win_mb=$WIN_MB \
        rp_bus=$EGPU_RP_BUS rp_dev=$EGPU_RP_DEV rp_fn=$EGPU_RP_FN; then
    echo "  loaded"
else
    rc=$?; mark "AFTER insmod ERROR rc=$rc"
    dmesg | grep -i egpu_rp_window | tail -12 | sed 's/^.*\] /    /'
    echo "  To restore the subtree use the BUS path, not devices/.../rescan,"
    echo "  because that one rescans bus 00 and hangs the machine:"
    echo "    echo 1 | sudo tee /sys/bus/pci/devices/$RP/pci_bus/$RESCAN_BUS/rescan"
    exit $rc
fi
mark "AFTER insmod"
dmesg | grep -i egpu_rp_window | tail -8 | sed 's/^.*\] /    /'
echo
echo "  prefetchable window of $RP, read from hardware:"
lspci -vv -s "${RP#0000:}" | grep -i prefetchable | sed 's/^\s*/    /'
printf "    rejestry: 24.w=%s 26.w=%s 28.l=%s 2c.l=%s\n" \
    "$(setpci -s $RP 24.w)" "$(setpci -s $RP 26.w)" \
    "$(setpci -s $RP 28.l)" "$(setpci -s $RP 2c.l)"

# ---------------------------------------------------------------- 5
echo
echo "=== 5. rescan of the SECONDARY bus (never bus 00) ==="
RESCAN=/sys/bus/pci/devices/$RP/pci_bus/$RESCAN_BUS/rescan
if [[ ! -w $RESCAN ]]; then
    echo "  ERROR: missing $RESCAN" >&2
    echo "  NOT using /sys/bus/pci/devices/$RP/rescan - that rescans bus 00" >&2
    echo "  Restoring the subtree requires a reboot." >&2
    exit 1
fi
echo "  path: $RESCAN"
mark "BEFORE rescan of the secondary bus"
echo 1 > "$RESCAN"
sleep 6
mark "AFTER rescan of the secondary bus"

# ---------------------------------------------------------------- 6
echo
echo "=== 6. Wynik ==="
if [[ ! -d /sys/bus/pci/devices/$DEV ]]; then
    echo "  the card did not come back. Tree:"; lspci -tv 2>/dev/null | head -20 | sed 's/^/    /'
    echo "  Log: $KLOG   (a reboot restores the firmware state)"; exit 1
fi
lspci -vv -s "${DEV#0000:}" | grep -E 'Region [0135]' | sed 's/^\s*/    /'
echo
# Walk the card's real ancestor chain - it differs per machine and per port.
while read -r b; do
    [[ -z $b ]] && continue
    printf "    --- %s ---\n" "$b"
    lspci -vv -s "${b#*:}" 2>/dev/null | grep -E 'Memory behind|Prefetchable' | sed 's/^\s*/      /'
done < <(egpu_ancestors "$DEV")
bar1=$(awk 'NR==2 { print $1 }' /sys/bus/pci/devices/$DEV/resource)
sz=$(lspci -vv -s "${DEV#0000:}" | sed -n 's/.*Region 1:.*\[size=\([^]]*\)\].*/\1/p')
echo
if [[ $bar1 == 0x0000000000000000 ]]; then
    echo "  BAR1 UNASSIGNED. Last 'can't assign':"
    grep -E "can't assign|failed to assign" "$KLOG" | tail -12 | sed 's/^.*\] /    /'
else
    echo "  ================================================"
    echo "  BAR1 = $bar1  rozmiar $sz"
    echo "  ================================================"
    echo "  Next: sudo ./6-load-driver.sh"
fi
echo
echo "Log kernel: $KLOG"
sync
