#!/usr/bin/env bash
# 03-build-module.sh - rebuild the window module, then run 04-window and
# 05-load-driver. Called by run.sh; usable on its own.
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
#   3. 04-window.sh      - move the root-port window, remove+rescan, assign BARs
#   4. only if BAR1 came out assigned: 05-load-driver.sh
#
# HOW FAR IT GOES
#
#   (no argument)       through 05-load-driver, which LOADS the driver. Note
#                       that the driver then comes up with no link speed cap.
#   --configure-only    through 05-load-driver --configure-only: /etc is written
#                       and BAR1 confirmed, but nothing is loaded. THIS IS WHAT
#                       run.sh USES, so that the cap can be applied before the
#                       driver ever binds.
#   --no-load           stop after 04-window. Nothing under /etc is touched.
#
# Variables passed through to 04-window.sh (all optional):
#   WIN_BASE   base address of the new prefetchable window
#   WIN_MB     its size in MB
#   REBAR_SIZE ReBAR size code for BAR1 (8 = 256 MB)

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/../lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run $EGPU_SCRIPTS/02-devices.sh to see what is present." >&2
    exit 1
fi


RUN=$(uname -r)
MODDIR=$EGPU_MODULE
# Build artifacts live outside the source tree - see module/Makefile for why.
BUILDDIR=$(make --no-print-directory -C "$MODDIR" -s print-builddir 2>/dev/null)
BUILDDIR=${BUILDDIR:-$EGPU_BUILD}
KO=$BUILDDIR/egpu_rp_window.ko
WINDOW=$EGPU_SCRIPTS/04-window.sh
DRIVER=$EGPU_SCRIPTS/05-load-driver.sh
DEV=$EGPU_GPU
MODE=full
for a in "$@"; do case $a in
    --no-load)        MODE=no-load ;;
    --configure-only) MODE=configure-only ;;
    -h|--help) egpu_usage "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
esac; done

# --- Gate BEFORE redirecting to tee, so the message is not swallowed ---
if ! modinfo -k "$RUN" nvidia >/dev/null 2>&1; then
    echo "ERROR: no loadable nvidia module for the running kernel $RUN." >&2
    echo "Kernels that do have it:" >&2
    found=0
    for k in $(ls /lib/modules 2>/dev/null | sort -V); do
        if modinfo -k "$k" nvidia >/dev/null 2>&1; then echo "    $k" >&2; found=1; fi
    done
    (( found )) || echo "    (none - sudo dkms autoinstall)" >&2
    echo "Boot into one of them, or build: sudo dkms autoinstall -k $RUN" >&2
    exit 1
fi
egpu_require_root
[[ -x $WINDOW ]] || { echo "ERROR: missing $WINDOW" >&2; exit 1; }
[[ -x $DRIVER  ]] || { echo "ERROR: missing $DRIVER"  >&2; exit 1; }

LOGDIR=$EGPU_LOGS
STAMP=$(egpu_stamp)
egpu_log_open "$LOGDIR" script "$STAMP"
trap egpu_cleanup EXIT

echo "=== log: $EGPU_LOG ==="

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
echo "=== 3. 04-window - root-port window and BARs ==="
# egpu_window_defaults EXPORTS these, so 04-window inherits them - no need to
# rebuild the environment by hand. It also means there is one statement of the
# defaults instead of three: this script used to print "0xf0000000, 192 MB, BAR1
# 128 MB" while the setup wrapper that used to sit above this script exported
# 0x4010000000/1024/8, and the message was unreachable in the normal path
# anyway.
egpu_window_defaults
printf "  window %s +%s MB, BAR1 %s\n" "$WIN_BASE" "$WIN_MB" "$(egpu_bar1_expected)"
if "$WINDOW"; then
    echo "  04-window finished"
else
    rc=$?; echo "  04-window returned $rc - not loading the driver" >&2; exit $rc
fi

echo
echo "=== 4. Gate to 05-load-driver ==="
if ! egpu_bar_assigned "$DEV" 1; then
    echo "  BAR1 unassigned - not loading the driver. See the log of 04-window above." >&2
    exit 1
fi
bar1=$(egpu_bar_base "$DEV" 1)
echo "  BAR1 = $bar1  size $(egpu_bar_size "$DEV" 1)"
case $bar1 in
    0x000000004*) echo "  (above 4 GB - space beyond 4 GB works on this machine)" ;;
esac
if [[ $MODE == no-load ]]; then
    echo "  --no-load: stopping here. Nothing under /etc has been touched."
    echo "  By hand: sudo $DRIVER"
    exit 0
fi

echo
if [[ $MODE == configure-only ]]; then
    echo "=== 5. 05-load-driver --configure-only - write /etc, load nothing ==="
    exec "$DRIVER" --configure-only
fi
echo "=== 5. 05-load-driver - block nvidia-drm, modprobe nvidia, check nvidia-smi ==="
exec "$DRIVER"
