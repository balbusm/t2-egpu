#!/usr/bin/env bash
# 9-check-outputs.sh - what the card's outputs see, and whether GSP is really
# running. Read-only, safe to repeat, no reload needed.
#
# WHY SEPARATE
#
# run.sh leaves the driver stack loaded, so testing display needs nothing
# more than plugging a monitor in - hot-plug detect works live. This script
# just reports.
#
# HOW TO READ IT
#
# The EDID column is the answer. 0B on the connector you plugged the monitor
# into means the card is not reading the display. A non-empty EDID (typically
# 128 or 256 bytes) means it is.
#
# Note that HDMI reads EDID over DDC/I2C while DisplayPort uses AUX, so a
# working HDMI does not prove AUX works. "disconnected" comes from the HPD
# pin, which is independent of both.
#
# GSP: the requested mode in /proc/driver/nvidia/params is NOT proof. 18 =
# 0x12 = MODE_DEFAULT | POLICY_ALLOW_UNSIGNED only means "the driver decides".
# Proof is a non-empty GSP Firmware Version from nvidia-smi -q.
#
#   sudo ./9-check-outputs.sh
#   sudo ./9-check-outputs.sh --force   # force a re-detect on every connector

set -uo pipefail
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/lib/egpu-lib.sh"

FORCE=0
for a in "$@"; do case $a in
    --force) FORCE=1 ;;
    -h|--help) egpu_usage "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 2 ;;
esac; done
egpu_require_root "[--force]"

echo "=== 1. Is GSP actually running ==="
if [[ ! -d /sys/module/nvidia ]]; then
    echo "  the nvidia module is not loaded - run run.sh first" >&2; exit 1
fi
printf "  EnableGpuFirmware (requested mode): %s\n" \
    "$(grep -oP 'EnableGpuFirmware: \K\S+' /proc/driver/nvidia/params 2>/dev/null || echo '?')"
if gspv=$(egpu_gsp_version); then
    echo "  GSP Firmware Version: $gspv   <- FIRMWARE IS RUNNING"
else
    echo "  GSP Firmware Version: missing   <- GSP IS NOT RUNNING"
fi
printf "  modules: %s\n" "$(egpu_loaded_modules)"
echo "  (18 = 0x12 = MODE_DEFAULT|ALLOW_UNSIGNED, i.e. 'the driver decides' -"
echo "   That is NOT proof. The proof is the firmware version above.)"

echo
echo "=== 2. DRM card owned by nvidia ==="
if ! egpu_nv_card; then
    echo "  none - nvidia_drm not loaded, or KMS inactive." >&2
    echo "  Load it: sudo modprobe --ignore-install nvidia_drm modeset=1 fbdev=1" >&2
    exit 1
fi
nvcard=$EGPU_CARD
echo "  $nvcard"

if (( FORCE )); then
    echo
    echo "=== 2b. Forced re-detect ==="
    for conn in /sys/class/drm/$nvcard-*; do
        [[ -w $conn/status ]] || continue
        echo detect > "$conn/status" 2>/dev/null \
            && echo "  $(basename "$conn"): detect sent" \
            || echo "  $(basename "$conn"): detect rejected"
    done
    sleep 3
fi

echo
echo "=== 3. Card connectors ==="
found=0
egpu_print_connectors "$nvcard" && found=1

echo
echo "=== 4. AUX/EDID errors from nvidia-modeset ==="
# CAPTURED, NOT PIPED INTO "grep -q". It used to end in "| grep -q ." with an
# empty then-branch, so grep consumed the messages and the section printed
# NOTHING whenever there actually were errors - the exact opposite of what it is
# for. Same family of mistake as the pipefail/grep -q traps noted in 5-window.sh
# and 11-teardown.sh.
aux=$(dmesg | grep -i 'nvidia-modeset' | grep -iE 'edid|aux' | tail -8 | sed 's/^.*\] /  /')
if [[ -n $aux ]]; then
    printf '%s\n' "$aux"
else
    echo "  (no messages - either the card reads EDID, or the driver never probed)"
fi

echo
echo "=== 5. For comparison: connectors on every card ==="
for c in /sys/class/drm/card*-*; do
    [[ -e $c/status ]] || continue
    card=${c##*/}; card=${card%%-*}
    drv=$(basename "$(readlink -f /sys/class/drm/$card/device/driver 2>/dev/null)" 2>/dev/null)
    st=$(cat "$c/status")
    [[ $st == connected ]] || continue
    printf "  CONNECTED: %-20s EDID=%sB  driver=%s\n" "${c##*/}" \
        "$(wc -c < "$c/edid" 2>/dev/null || echo 0)" "$drv"
done

echo
if (( found )); then
    echo "=== RESULT: the card sees a connected monitor ==="
    echo "  Non-empty EDID means the card reads the display; try bringing up a session:"
    echo "    sudo systemctl restart display-manager   # or: run.sh --restart-ui"
else
    echo "=== RESULT: the card sees nothing connected ==="
    echo "  If a monitor IS plugged into the card's DP/HDMI, the card is not seeing it."
    echo "  If it is NOT, plug it in and run this again - no reload needed."
fi
