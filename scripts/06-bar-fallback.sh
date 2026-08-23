#!/usr/bin/env bash
# 06-bar-fallback.sh - fallback when BAR1 came out unassigned. Called by
# 05-load-driver.sh, not run directly in a normal bring-up.
#
# WHAT IT DOES
#
# Shrinks BAR1 through ReBAR so the request fits, then escalates the level the
# kernel reallocates from. A rescan only reassigns resources below the bridge
# it starts from, so each level detaches a larger subtree:
#
#   level 1  detach the enclosure, rescan from the host-side Thunderbolt port
#   level 2  detach the Thunderbolt controller subtree, rescan from the root port
#   level 3  the same, but a global rescan - last resort
#
# The ladder is DERIVED from the discovered chain (lib/egpu-lib.sh), so it
# adapts to a different machine, enclosure or Thunderbolt port.

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/../lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run $EGPU_SCRIPTS/02-devices.sh to see what is present." >&2
    exit 1
fi


DEV=$EGPU_GPU
TARGET_BAR=1
# Shrink to 64 MB, half of what 04-window asks for: the point of this script is
# to make the request small enough to fit whatever the kernel can still lay out.
TARGET_SIZE=6                 # 2^6 MB = 64 MB

LOGDIR=$EGPU_LOGS
STAMP=$(egpu_stamp)
# 05-load-driver calls this script while its own capture is running and exports
# EGPU_KLOG; adopting it avoids a second "dmesg -w" on the same file.
KLOG=${EGPU_KLOG:-$LOGDIR/kernel-$STAMP.log}

egpu_require_root
[[ -d /sys/bus/pci/devices/$DEV ]] || {
    echo "ERROR: $DEV does not exist - plug the enclosure in." >&2; exit 1; }

egpu_log_open "$LOGDIR" script "$STAMP"
trap egpu_cleanup EXIT

echo "=== logs ==="
echo "  kernel:  $KLOG"
echo "  script:  $EGPU_LOG"

egpu_klog_start "$KLOG"

# Set BAR1 to the target size if it is not already there. A bridge reset can
# restore the previous size, which is why this runs before EVERY attempt rather
# than once. The capability offset is discovered, not the old hardcoded 0xbb0.
apply_rebar() {
    local off cur
    off=$(egpu_rebar_entry "$DEV" "$TARGET_BAR") \
        || { echo "  ERROR: no ReBAR capability entry for BAR$TARGET_BAR"; return 1; }
    cur=$(egpu_rebar_get "$DEV" "$off") || return 1
    if (( cur == TARGET_SIZE )); then
        printf '  ReBAR BAR1 already = %d MB\n' $((2 ** TARGET_SIZE))
        return 0
    fi
    printf '  ReBAR BAR1 = %d MB -> setting %d MB\n' $((2 ** cur)) $((2 ** TARGET_SIZE))
    egpu_rebar_set "$DEV" "$off" "$TARGET_SIZE" \
        || { echo "  ERROR: the card did not accept the size"; return 1; }
    printf '  confirmed: %d MB\n' $((2 ** TARGET_SIZE))
}

bar1_assigned() { egpu_bar_assigned "$DEV" 1; }

show_state() {
    echo "  --- BARs ---"
    awk 'NR<=4 { printf "    BAR%d start=%s flags=%s\n", NR-1, $1, $3 }' \
        /sys/bus/pci/devices/$DEV/resource 2>/dev/null || echo "    device not present"
    echo "  --- prefetchable windows ---"
    # Walk the card's real ancestor chain instead of a written-down list -
    # the chain differs per machine and per Thunderbolt port.
    while read -r b; do
        [[ -z $b ]] && continue
        printf "    %s: %s\n" "$b" \
            "$(lspci -vv -s "${b#*:}" 2>/dev/null | grep -i 'Prefetchable' | sed 's/^\s*//' || echo '?')"
    done < <(egpu_ancestors "$DEV")
}

# --- escalation ladder, DERIVED from the discovered chain ---
#
# "description|device to remove|what to rescan". Each level detaches a larger
# subtree, because a rescan only reassigns resources below the bridge it starts
# from. GLOBAL is the last resort.
#
# The chain from the card upwards is, for example:
#   GPU -> enclosure downstream -> enclosure upstream -> host TB port -> ...
#          -> host TB upstream -> root port
# so level 1 detaches the enclosure and rescans from the host-side TB port,
# level 2 detaches everything below the root port.
mapfile -t CHAIN < <(egpu_ancestors "$DEV")
ENCLOSURE=${CHAIN[1]:-${CHAIN[0]:-}}      # enclosure upstream port
HOST_PORT=${CHAIN[2]:-$EGPU_ROOT_PORT}    # host-side TB downstream port
LEVELS=()
[[ -n $ENCLOSURE && -n $HOST_PORT ]] && \
    LEVELS+=("level 1: detach enclosure, rescan $HOST_PORT|$ENCLOSURE|$HOST_PORT")
[[ -n $EGPU_TB_UPSTREAM ]] && \
    LEVELS+=("level 2: detach TB controller subtree, rescan $EGPU_ROOT_PORT|$EGPU_TB_UPSTREAM|$EGPU_ROOT_PORT")
[[ -n $EGPU_TB_UPSTREAM ]] && \
    LEVELS+=("level 3: detach TB controller subtree, global rescan|$EGPU_TB_UPSTREAM|GLOBAL")
if (( ${#LEVELS[@]} == 0 )); then
    echo "Cannot build an escalation ladder - topology too shallow." >&2
    exit 1
fi
echo "Escalation ladder for $DEV:"
printf '  %s\n' "${LEVELS[@]%%|*}"

for spec in "${LEVELS[@]}"; do
    IFS='|' read -r desc rmdev scan <<< "$spec"
    echo
    echo "=============================================================="
    echo "$desc"
    echo "=============================================================="

    if [[ ! -d /sys/bus/pci/devices/$DEV ]]; then
        echo "  card disappeared - aborting"
        break
    fi

    apply_rebar || { echo "  cannot set ReBAR, aborting"; break; }

    mark "BEFORE remove ($rmdev)"
    if [[ -d /sys/bus/pci/devices/$rmdev ]]; then
        echo 1 > /sys/bus/pci/devices/$rmdev/remove
    else
        echo "  $rmdev does not exist - skipping remove"
    fi
    sleep 2
    mark "AFTER remove ($rmdev)"

    mark "BEFORE rescan ($scan)"
    if [[ $scan == GLOBAL ]]; then
        echo 1 > /sys/bus/pci/rescan
    else
        echo 1 > /sys/bus/pci/devices/$scan/rescan
    fi
    sleep 4
    mark "AFTER rescan ($scan)"

    echo
    show_state

    if bar1_assigned; then
        echo
        echo "=============================================================="
        echo "  SUCCESS at this level"
        echo "=============================================================="
        lspci -vv -s "$DEV" 2>/dev/null | grep -E "Region" | sed 's/^/  /'
        cat <<'EOF'

  Do NOT load the driver from inside GNOME - switch to a text console:
    sudo systemctl isolate multi-user.target
    sudo modprobe nvidia
    nvidia-smi

  If it hangs: the blacklist in /etc/modprobe.d keeps the driver out on the next boot
  guarantees a clean next boot, and the log is in:
EOF
        echo "    $KLOG"
        sync
        exit 0
    fi

    echo "  BAR1 still unassigned - escalating"
done

echo
echo "=============================================================="
echo "  No escalation level managed to assign BAR1."
echo "=============================================================="
echo "  Log kernel: $KLOG"
echo "  Look for 'can't assign' after the last rescan marker."
sync
