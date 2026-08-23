#!/usr/bin/env bash
# 4-build-module.sh - rebuild the window module, then run 5-window and
# 6-load-driver. Called by 3-setup.sh.
#
# WHY REBUILD EVERY TIME
#
# egpu_rp_window is an out-of-tree module and must match the running kernel's
# vermagic. Rebuilding on every run means a kernel update inside the supported
# line needs no manual step.
#
# STEPS
#
#   1. sanity-check the card is on the bus
#   2. make clean all in module/, verify vermagic against the running kernel
#   3. 5-window.sh      - move the root-port window, remove+rescan, assign BARs
#   4. only if BAR1 came out assigned: 6-load-driver.sh
#
# Variables passed through to 5-window.sh (all optional):
#   WIN_BASE   base address of the new prefetchable window
#   WIN_MB     its size in MB
#   REBAR_SIZE ReBAR size code for BAR1 (8 = 256 MB)

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run ./2-devices.sh to see what is present." >&2
    exit 1
fi


RUN=$(uname -r)
MODDIR=$SELFDIR/module
# Build artifacts live outside the source tree - see module/Makefile for why.
BUILDDIR=$(make --no-print-directory -C "$MODDIR" -s print-builddir 2>/dev/null)
BUILDDIR=${BUILDDIR:-$SELFDIR/build/module}
KO=$BUILDDIR/egpu_rp_window.ko
WINDOW=$SELFDIR/5-window.sh
DRIVER=$SELFDIR/6-load-driver.sh
DEV=$EGPU_GPU
NO_LOAD=0
[[ ${1:-} == --no-load ]] && NO_LOAD=1

# --- Gate BEFORE redirecting to tee, so the message is not swallowed ---
if ! modinfo -k "$RUN" nvidia >/dev/null 2>&1; then
    echo "ERROR: no loadable nvidia module for the running kernel $RUN." >&2
    echo "Kernels that do have it:" >&2
    found=0
    for k in $(ls /lib/modules 2>/dev/null | sort -V); do
        if modinfo -k "$k" nvidia >/dev/null 2>&1; then echo "    $k" >&2; found=1; fi
    done
    (( found )) || echo "    (zadne - sudo dkms autoinstall)" >&2
    echo "Boot into one of them, or build: sudo dkms autoinstall -k $RUN" >&2
    exit 1
fi
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[[ -x $WINDOW ]] || { echo "ERROR: missing $WINDOW" >&2; exit 1; }
[[ -x $DRIVER  ]] || { echo "ERROR: missing $DRIVER"  >&2; exit 1; }

LOGDIR=$SELFDIR/logs
STAMP=$(date +%Y%m%d-%H%M%S)
SLOG=$LOGDIR/script-$STAMP.log
mkdir -p "$LOGDIR"; chown "${SUDO_USER:-root}:" "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$SLOG") 2>&1
TEE_PID=$!
_flush_tee() { exec 1>&- 2>&- ; wait "$TEE_PID" 2>/dev/null; }
trap _flush_tee EXIT

echo "=== log: $SLOG ==="

echo
echo "=== 1. Preflight checks ==="
printf "  kernel: %s\n" "$RUN"
modinfo -k "$RUN" nvidia | grep -E '^(filename|version)' | sed 's/^/    /'
[[ -d /sys/bus/pci/devices/$DEV ]] || { echo "  ERROR: $DEV not present - plug the enclosure in" >&2; exit 1; }
echo "  card present"
if [[ -d /sys/module/egpu_rp_window ]]; then
    echo "  ERROR: egpu_rp_window already loaded - the window was moved already." >&2
    echo "  Reboot before trying again." >&2
    exit 1
fi

echo
echo "=== 2. Rebuilding the window module for $RUN ==="
make -C "$MODDIR" clean all 2>&1 | tail -6 | sed 's/^/  /' || true
printf "  artifacts: %s\n" "$BUILDDIR"
# This script runs under sudo, so hand the artifacts back to the invoking
# user - same reason as LOGDIR above. Otherwise the next non-root build
# cannot overwrite them.
chown -R "${SUDO_USER:-root}:" "$BUILDDIR" 2>/dev/null || true
vm=$(modinfo "$KO" 2>/dev/null | awk '/^vermagic:/ {print $2}')
printf "  vermagic: %s\n" "${vm:-none}"
[[ ${vm:-} == "$RUN" ]] || { echo "  ERROR: the module did not build for $RUN" >&2; exit 1; }

echo
echo "=== 3. 5-window - root-port window + BAR-y ==="
ENVARGS=()
for v in WIN_BASE WIN_MB REBAR_SIZE; do
    [[ -n ${!v:-} ]] && ENVARGS+=("$v=${!v}")
done
if (( ${#ENVARGS[@]} )); then
    echo "  parameters passed to 5-window: ${ENVARGS[*]}"
else
    echo "  default parameters 5-window (0xf0000000, 192 MB, BAR1 128 MB)"
fi
if env "${ENVARGS[@]}" "$WINDOW"; then
    echo "  5-window finished"
else
    rc=$?; echo "  5-window returned $rc - not loading the driver" >&2; exit $rc
fi

echo
echo "=== 4. Gate to 6-load-driver ==="
bar1=$(awk 'NR==2 {print $1}' /sys/bus/pci/devices/$DEV/resource 2>/dev/null || echo x)
sz=$(lspci -vv -s "${DEV#0000:}" 2>/dev/null | sed -n 's/.*Region 1:.*\[size=\([^]]*\)\].*/\1/p')
if [[ $bar1 == 0x0000000000000000 || $bar1 == x ]]; then
    echo "  BAR1 unassigned - not loading the driver. See the log of 5-window above." >&2
    exit 1
fi
echo "  BAR1 = $bar1  rozmiar $sz"
case $bar1 in
    0x000000004*) echo "  (above 4 GB - space beyond 4 GB works on this machine)" ;;
esac
if (( NO_LOAD )); then
    echo "  --no-load: stopping here."
    echo "  By hand: sudo $DRIVER"
    exit 0
fi

echo
echo "=== 5. 6-load-driver - block nvidia-drm, modprobe nvidia, check nvidia-smi ==="
exec "$DRIVER"
