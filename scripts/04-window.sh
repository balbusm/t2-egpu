#!/usr/bin/env bash
# 04-window.sh - move the root-port prefetchable window above 4 GB, then
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
# The defaults come from lib/egpu-lib.sh (egpu_window_defaults) and are the
# SAME ones run.sh and 03-build-module.sh use. They used to be stated separately
# here, with different values - 0xf0000000/192/7 against the 0x4010000000/1024/8
# exported by the setup wrapper that used to sit above 03-build-module - so
# running this script the way its own header documented produced a 128 MB BAR1
# that run.sh then reported as a failure.
#
#   sudo ./scripts/04-window.sh
#   sudo WIN_BASE=0xf0000000 WIN_MB=192 REBAR_SIZE=7 ./scripts/04-window.sh   # override

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating

# Topology is DISCOVERED, never hardcoded: bus numbers behind a Thunderbolt
# tunnel shift between machines, between ports and between hot-plugs.
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/../lib/egpu-lib.sh"
egpu_resolve_or_die
RP=$EGPU_ROOT_PORT           # CPU root port whose prefetchable window we move
TB=$EGPU_TB_UPSTREAM         # first device below it - removed and rescanned
DEV=$EGPU_GPU                # the card itself
AUDIO=${DEV%.*}.1            # its HDMI-audio function, if present
RESCAN_BUS=$EGPU_SECONDARY_BUS
MODDIR=$EGPU_MODULE
# The module is built out of tree - module/Makefile explains why.
egpu_module_ko                 # sets EGPU_BUILDDIR and EGPU_KO
TARGET_BAR=1

LOGDIR=$EGPU_LOGS
STAMP=$(egpu_stamp)            # inherited from run.sh, so one run = one stamp

egpu_require_root
# AFTER the root check: REBAR_SIZE defaults to the size the card reports, which
# means reading its config space.
egpu_window_defaults           # WIN_BASE / WIN_MB / REBAR_SIZE
WIN_END=$((WIN_BASE + WIN_MB * 1024 * 1024 - 1))
egpu_log_open "$LOGDIR" script "$STAMP"
trap egpu_log_flush EXIT

echo "=== log: $EGPU_LOG ==="

# ---------------------------------------------------------------- 0
echo
echo "=== 0. Preflight checks ==="
[[ -f $EGPU_KO ]] || { echo "  ERROR: missing $EGPU_KO - make -C $MODDIR" >&2; exit 1; }
vm=$(modinfo "$EGPU_KO" | awk '/^vermagic:/ { print $2 }'); run=$(uname -r)
[[ $vm == "$run" ]] || { echo "  ERROR: module built for $vm, running kernel is $run - rebuild" >&2; exit 1; }
# The logic here is INVERTED: a match must ABORT.
# With "lsmod | grep -q" the pipeline returned 141 on SIGPIPE, so && never fired
# and execution continued with the module already loaded - worse than a false
# alarm. Testing the sysfs directory has no pipeline and cannot do that.
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

# ---------------------------------------------------------------- 1
echo
echo "=== 1. Detaching drivers ==="
for d in $DEV $AUDIO; do
    lnk=/sys/bus/pci/devices/$d/driver
    if [[ -L $lnk ]]; then
        drv=$(basename "$(readlink -f "$lnk")")
        echo "  unbind $d from $drv"; echo "$d" > /sys/bus/pci/drivers/$drv/unbind || true
    else
        echo "  $d no driver bound"
    fi
done
compgen -G "/sys/module/nvidia*" >/dev/null && modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null || true

# ---------------------------------------------------------------- 2
# ReBAR must be set NOW - after removing the subtree the card leaves sysfs
# and setpci has nothing to work on.
echo
printf "=== 2. ReBAR BAR1 -> %d MB ===\n" $((2 ** REBAR_SIZE))
# The capability OFFSET is discovered by walking the extended capability list.
# It used to be the literal 0xbb0 - correct on the machine this was developed
# on, and the last hardware-specific constant left in the package.
if ! cap=$(egpu_rebar_cap "$DEV"); then
    echo "  ERROR: the card exposes no Resizable BAR capability" >&2; exit 1
fi
printf "  Resizable BAR capability at 0x%x\n" "$cap"
if ! entry_off=$(egpu_rebar_entry "$DEV" "$TARGET_BAR"); then
    echo "  ERROR: no ReBAR capability entry for BAR$TARGET_BAR" >&2; exit 1
fi
old=$(egpu_pci_dword "$DEV" "$entry_off")
cur=$(egpu_rebar_get "$DEV" "$entry_off")
printf "  BAR1 now %d MB" $((2 ** cur))
if (( cur == REBAR_SIZE )); then
    echo " - already at target"
else
    echo
    egpu_rebar_set "$DEV" "$entry_off" "$REBAR_SIZE" \
        || { echo "  ERROR: the card did not accept the size" >&2; exit 1; }
    printf "  set to %d MB\n" $((2 ** $(egpu_rebar_get "$DEV" "$entry_off")))
fi
printf "  TO RESTORE: sudo setpci -s %s %x.L=%s\n" "$DEV" "$entry_off" "$old"

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
if insmod "$EGPU_KO" win_base=$WIN_BASE win_mb=$WIN_MB \
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
echo
echo "  prefetchable window of $RP, read back from hardware:"
lspci -vv -s "${RP#0000:}" | grep -i prefetchable | sed 's/^\s*/    /'
# The raw bridge registers (24.w/26.w/28.l/2c.l) used to be printed here as
# well. They say the same thing as the line above in hex, and were how the
# module was verified while it was being written. Same for a dmesg dump of the
# module's own messages on the SUCCESS path - it stays on the failure path
# below, where it is the only thing that explains what went wrong.

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
echo "=== 6. Result ==="
if [[ ! -d /sys/bus/pci/devices/$DEV ]]; then
    echo "  the card did not come back. Tree:"; lspci -tv 2>/dev/null | head -20 | sed 's/^/    /'
    echo "  (a reboot restores the firmware state)"; exit 1
fi
lspci -vv -s "${DEV#0000:}" | grep -E 'Region [0135]' | sed 's/^\s*/    /'
echo
# Walk the card's real ancestor chain - it differs per machine and per port.
while read -r b; do
    [[ -z $b ]] && continue
    printf "    --- %s ---\n" "$b"
    lspci -vv -s "${b#*:}" 2>/dev/null | grep -E 'Memory behind|Prefetchable' | sed 's/^\s*/      /'
done < <(egpu_ancestors "$DEV")
bar1=$(egpu_bar_base "$DEV" 1)
sz=$(egpu_bar_size "$DEV" 1)
echo
if [[ $bar1 == 0x0000000000000000 ]]; then
    echo "  BAR1 UNASSIGNED. Last 'can't assign':"
    dmesg | grep -E "can't assign|failed to assign" | tail -12 | sed 's/^.*\] /    /'
else
    echo "  ================================================"
    echo "  BAR1 = $bar1  size $sz"
    echo "  ================================================"
    echo "  Next: sudo $EGPU_SCRIPTS/05-load-driver.sh"
fi

