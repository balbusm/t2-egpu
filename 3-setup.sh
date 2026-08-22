#!/usr/bin/env bash
# 3-setup.sh - root-port window, BARs, and the driver. Called by run.sh.
#
# Runs 4-build-module.sh, which rebuilds the window module for the running
# kernel and then chains 5-window.sh (move the window, remove+rescan) and
# 6-load-driver.sh (block drm/modeset, load nvidia, check nvidia-smi).
# Finally loads nvidia_uvm, which CUDA needs.
#
# Does NOT load nvidia_drm - display output is handled by run.sh after the
# link cap is in place.
#
# IMPORTANT: running this on its own leaves the driver loaded WITHOUT the link
# speed cap. With GSP enabled that is the configuration that resets the
# machine. Use run.sh unless you know why you are not.
#
# The whole allocation lives in memory. It is lost on reboot and when the
# enclosure loses power; repeat from run.sh afterwards.
#
# Override the window target if ever needed:
#   sudo WIN_BASE=0xf0000000 WIN_MB=192 REBAR_SIZE=7 ./3-setup.sh

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run ./2-devices.sh to see what is present." >&2
    exit 1
fi


DEV=$EGPU_GPU
BUILD=$SELFDIR/4-build-module.sh
export WIN_BASE=${WIN_BASE:-0x4010000000}
export WIN_MB=${WIN_MB:-1024}
export REBAR_SIZE=${REBAR_SIZE:-8}

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[[ -x $BUILD ]] || { echo "ERROR: missing $BUILD" >&2; exit 1; }

echo "==================================================================="
echo " 3-setup: window $WIN_BASE (+${WIN_MB}M), BAR1 = $((2 ** REBAR_SIZE)) MB"
echo "==================================================================="

# --- preflight checks, so we do not enter 4-build-module blindly ---
if [[ ! -d /sys/bus/pci/devices/$DEV ]]; then
    echo "ERROR: card $DEV not present." >&2
    echo "  Plug the enclosure in or power-cycle it - after a hard" >&2
    echo "  reboot the card often drops out of the Thunderbolt tunnel." >&2
    echo "  Check: lspci -s "${DEV#*:}"" >&2
    exit 1
fi
if [[ -d /sys/module/egpu_rp_window ]]; then
    echo "ERROR: egpu_rp_window already loaded - the window was moved already." >&2
    echo "  Reboot before trying again." >&2
    exit 1
fi
if [[ -d /sys/module/nvidia ]]; then
    echo "NOTE: the nvidia module is already loaded."
    echo "  If nvidia-smi works there is nothing to do:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1 | sed 's/^/    /'
    exit 0
fi

echo
echo ">>> STEP 1/2: 4-build-module.sh"
if "$BUILD"; then
    echo ">>> STEP 1/2 finished"
else
    rc=$?
    echo ">>> STEP 1/2 FAILED (rc=$rc) - not loading nvidia_uvm" >&2
    exit $rc
fi

echo
echo ">>> STEP 2/2: nvidia_uvm (needed by CUDA)"
if [[ -d /sys/module/nvidia_uvm ]]; then
    echo "  already loaded"
elif modprobe --ignore-install nvidia_uvm; then
    echo "  loaded"
else
    echo "  failed - nvidia-smi still works, CUDA will not" >&2
fi

echo
echo "==================================================================="
echo " SUMMARY"
echo "==================================================================="
printf "  BAR1:    %s\n" "$(lspci -vv -s "${DEV#0000:}" 2>/dev/null | grep 'Region 1' | sed 's/^\s*//')"
printf "  modules:  "; for m in nvidia nvidia_uvm nvidia_modeset nvidia_drm; do
    [[ -d /sys/module/$m ]] && printf "%s " "$m"; done; echo
printf "  GPU:     %s\n" "$(nvidia-smi --query-gpu=name,memory.total,temperature.gpu,power.draw,pstate --format=csv,noheader 2>&1)"
echo
echo "  NOTE: 3-setup alone is NOT enough - nvidia is loaded WITHOUT the link"
echo "  speed cap. With GSP enabled that is the configuration that resets the machine."
echo "  The real entry point is:"
echo "    sudo ./run.sh"
