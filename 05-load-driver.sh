#!/usr/bin/env bash
# 05-load-driver.sh - keep nvidia_drm and nvidia_modeset out of the way, then
# load nvidia and confirm it talks to the card.
#
# WHY THE BLOCKS
#
# nvidia_drm taking over display during bring-up hangs the machine, and any
# by-name loader (udev rules, nvidia-modprobe, a service) can bind the driver
# before the link-speed cap is in place - which resets the machine. So the
# modules are blocked in modprobe.d and loaded deliberately with
# modprobe --ignore-install.
#
# --ignore-install applies only to the module named on the command line, NOT to
# its dependencies. That is why the stack is loaded one module at a time,
# bottom-up: nvidia -> nvidia_uvm -> nvidia_modeset -> nvidia_drm.
#
# If BAR1 turns out unassigned at this point, 06-bar-fallback.sh is called to
# escalate. In a normal run that never happens, because 04-window already
# assigned it.
#
# TWO PHASES, AND WHY THE SPLIT EXISTS
#
#   --configure-only   sections 1-3b: write the modprobe.d and udev files, prove
#                      the block is effective, confirm BAR1, pin runtime PM.
#                      Loads NOTHING.
#   (no argument)      the above, then load nvidia and check nvidia-smi.
#
# run.sh asks for --configure-only. Without it the bring-up loaded nvidia here
# and run.sh unloaded it again three steps later to apply the link cap - a full
# load/unload cycle for nothing, and a load with no cap in place, which is the
# configuration this whole package exists to avoid. The GSP block was the only
# thing making it survivable.
#
# Run with no argument to load the driver here, which is what you want when
# invoking this script by hand. Note that it then comes up WITHOUT the link
# speed cap: see the warning at the end.

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run ./02-devices.sh to see what is present." >&2
    exit 1
fi


DEV=$EGPU_GPU
LOGDIR=$SELFDIR/logs
STAMP=$(egpu_stamp)
KLOG=${EGPU_KLOG:-$LOGDIR/kernel-$STAMP.log}
FALLBACK=$SELFDIR/06-bar-fallback.sh
UDEV_RULE=/etc/udev/rules.d/71-nvidia.rules

CONFIGURE_ONLY=0
for a in "$@"; do case $a in
    --configure-only) CONFIGURE_ONLY=1 ;;
    -h|--help) egpu_usage "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
esac; done

egpu_require_root
egpu_log_open "$LOGDIR" script "$STAMP"
trap egpu_cleanup EXIT

echo "=== logs ==="
echo "  kernel:  $KLOG"
echo "  script:  $EGPU_LOG"

# ---------------------------------------------------------------- 1
echo
echo "=== 1. Shadowing the udev rule 71-nvidia.rules ==="
# This OVERWRITES a file under /etc, and the content below is Ubuntu-specific
# (ub-device-create, nvidia-persistenced). Keep one backup of whatever was there
# before, once, so an existing hand-edited rule is recoverable. Not on every run:
# this script runs on every bring-up and would otherwise bury the original under
# copies of its own output.
if [[ -f $UDEV_RULE && ! -f $UDEV_RULE.orig ]]; then
    cp -a "$UDEV_RULE" "$UDEV_RULE.orig" \
        && echo "  kept the previous file as $UDEV_RULE.orig"
fi
cat > "$UDEV_RULE" <<'EOF'
# Shadows /lib/udev/rules.d/71-nvidia.rules for a Thunderbolt eGPU.
#
# REMOVED relative to the original:
#   RUN+="/sbin/modprobe nvidia-modeset"   - hangs during initialisation
#   RUN+="/sbin/modprobe nvidia-drm"       - "[nvidia-drm] Loading driver" = hang
#   RUN+="/sbin/modprobe nvidia-uvm"       - not needed for nvidia-smi
#
# CHANGED: power/control "auto" -> "on". Runtime PM puts the eGPU into D3cold,
# which over Thunderbolt is a known source of hangs.

# Tag for logind (LP: #1365336)
SUBSYSTEM=="pci", ATTRS{vendor}=="0x10de", DRIVERS=="nvidia", TAG+="seat", TAG+="master-of-seat"

# nvidia-persistenced
ACTION=="add", DEVPATH=="/bus/pci/drivers/nvidia", TAG+="systemd", ENV{SYSTEMD_WANTS}="nvidia-persistenced.service"

# /dev/nvidia* nodes
ACTION=="add", DEVPATH=="/bus/pci/drivers/nvidia", RUN+="/sbin/ub-device-create"
ACTION=="add", DEVPATH=="/module/nvidia_uvm", SUBSYSTEM=="module", RUN+="/sbin/ub-device-create"

# Runtime PM DISABLED for NVIDIA devices (the original set "auto")
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", TEST=="power/control", ATTR{power/control}="on"
EOF
echo "  wrote $UDEV_RULE"
udevadm control --reload && echo "  udev reloaded"

# ---------------------------------------------------------------- 2
echo
echo "=== 2. Blocking nvidia_drm / nvidia_modeset in modprobe ==="
# "zz-" sorts after every "nvidia-*", and for parameters the last one wins.
cat > /etc/modprobe.d/zz-egpu-nvidia.conf <<'EOF'
# Thunderbolt eGPU.
# nvidia-drm hangs the machine at "[nvidia-drm] Loading driver", so block it
# entirely. Deliberate override: modprobe --ignore-install nvidia_drm
install nvidia_drm /bin/false
install nvidia_modeset /bin/false

# NO "options nvidia_drm modeset=0 fbdev=0" HERE - it used to be, and it was a
# self-inflicted wound. Reasoning, in order:
#
#   1. The "install ... /bin/false" lines above are the load-bearing block.
#      Anything that gets past them used --ignore-install, which means it was
#      us, and we always pass the parameters we want explicitly. So the options
#      line protected nothing.
#   2. Both parameters default to 1 in this driver ("modinfo -p nvidia-drm"),
#      so the line fought the driver's own defaults.
#   3. Because modprobe.d files are concatenated and the kernel takes the LAST
#      repeated parameter, it silently turned KMS off for every plain
#      "modprobe nvidia_drm" - the display only worked because callers repeat
#      modeset=1 on the command line. fbdev=0 was never repeated, so THAT one
#      simply took effect, unnoticed.
#   4. It made 01-check.sh report a permanent NOTE, and it undid
#      "01-check.sh --fix" on every run of this script.

# No D3cold.
options nvidia NVreg_DynamicPowerManagement=0
EOF
echo "  wrote /etc/modprobe.d/zz-egpu-nvidia.conf"

echo
echo "  verification - what 'modprobe nvidia_drm' would do:"
modprobe --dry-run --show-depends nvidia_drm 2>&1 | sed 's/^/    /'
drmplan=$(modprobe --dry-run --show-depends nvidia_drm 2>&1 || true)
if grep -q "^install /bin/false" <<<"$drmplan"; then
    echo "  OK: nvidia_drm is blocked"
else
    echo "  NOTE: nvidia_drm is NOT blocked - aborting" >&2
    exit 1
fi

echo
echo "  is there an nvidia module for $(uname -r)?"
if modinfo -k "$(uname -r)" nvidia >/dev/null 2>&1; then
    echo "    $(modinfo -k "$(uname -r)" nvidia | awk '/^filename:/ { print $2 }')"
else
    echo "    MISSING - DKMS did not build nvidia for this kernel." >&2
    echo "    Fix: rebuild the driver for the running kernel, e.g." >&2
    echo "      sudo dkms autoinstall -k \"$(uname -r)\"" >&2
    echo "    Diagnose: sudo ./01-check.sh" >&2
    exit 1
fi
echo
echo "  nvidia module parameters:"
args=$(modprobe --dry-run --ignore-install --show-depends nvidia 2>&1 | tail -1)
echo "    $args"
if grep -o 'NVreg_DynamicPowerManagement=[^ "]*' <<<"$args" | sort -u | grep -qv '=0$'; then
    echo "  ERROR: DynamicPowerManagement != 0" >&2; exit 1
fi
echo "  OK: DynamicPowerManagement=0"

# ---------------------------------------------------------------- 3
echo
echo "=== 3. BAR1 ==="
if ! egpu_bar_assigned "$DEV" 1; then
    echo "  BAR1 unassigned - running 06-bar-fallback.sh"
    [[ -x $FALLBACK ]] || { echo "  ERROR: missing $FALLBACK" >&2; exit 1; }
    "$FALLBACK" || { echo "  06-bar-fallback could not do it - aborting" >&2; exit 1; }
fi
egpu_bar_assigned "$DEV" 1 || { echo "  ERROR: BAR1 still unassigned" >&2; exit 1; }
printf '  BAR1 = %s  size %s  OK\n' "$(egpu_bar_base "$DEV" 1)" "$(egpu_bar_size "$DEV" 1)"
lspci -vv -s "$DEV" 2>/dev/null | grep -E "Region [013]" | sed 's/^/  /'

# ---------------------------------------------------------------- 3b
echo
echo "=== 3b. Runtime PM of the card ==="
# Pinned to "on" BEFORE the driver can bind, not after. D3cold over Thunderbolt
# is a known way to get "fallen off the bus", and this used to sit in the load
# section - so the --configure-only path, which is the one run.sh takes, would
# have skipped it. The udev rule and NVreg_DynamicPowerManagement=0 say the same
# thing; this is the belt to their braces.
printf "  power/control = %s\n" "$(cat /sys/bus/pci/devices/$DEV/power/control 2>/dev/null)"
echo on > /sys/bus/pci/devices/$DEV/power/control 2>/dev/null \
    && echo "  forced to 'on'"

if (( CONFIGURE_ONLY )); then
    echo
    echo "=== --configure-only: stopping before the driver load ==="
    echo "  /etc is configured, the block is proven effective, BAR1 is assigned,"
    echo "  runtime PM is pinned. Nothing is loaded."
    echo "  The caller loads the driver itself, AFTER the link speed cap - which"
    echo "  is the whole point of not loading it here."
    echo
    echo "  To revert what this script changed:"
    echo "    sudo rm $UDEV_RULE /etc/modprobe.d/zz-egpu-nvidia.conf"
    echo "    sudo udevadm control --reload"
    exit 0
fi

# ---------------------------------------------------------------- 4
echo
echo "=== 4. Capturing the kernel log ==="
egpu_klog_start "$KLOG"
echo "  active"

# ---------------------------------------------------------------- 5
echo
echo "=== 5. modprobe nvidia (this module only) ==="
sync
mark "BEFORE modprobe nvidia"
if modprobe --ignore-install nvidia; then
    mark "AFTER modprobe nvidia - insmod OK"
else
    rc=$?; mark "AFTER modprobe nvidia - ERROR rc=$rc"
    echo "  ERROR modprobe rc=$rc" >&2
    dmesg | tail -25 | sed 's/^/    /'
    exit $rc
fi
sleep 3
mark "3s AFTER insmod"

echo
echo "  loaded modules:"
lsmod | grep -E "^nvidia" | sed 's/^/    /' || echo "    (missing!)"
if [[ -d /sys/module/nvidia_drm || -d /sys/module/nvidia_modeset ]]; then
    echo "  NOTE: nvidia_drm/modeset loaded despite the block!" >&2
else
    echo "  OK: nvidia_drm and nvidia_modeset are NOT loaded"
fi

echo
echo "  driver bound to the device:"
lspci -vv -s "$DEV" 2>/dev/null | grep -E "Kernel driver|Region [013]" | sed 's/^/    /'

# ---------------------------------------------------------------- 6
echo
echo "=== 6. nvidia-smi ==="
mark "BEFORE nvidia-smi"
if nvidia-smi; then
    mark "AFTER nvidia-smi OK"
    echo
    echo "=============================================================="
    echo "  THE CARD RESPONDS"
    echo "=============================================================="
    cat <<'EOF'

This confirms the GPU works. Read the BAR1 size from section 3 above.

For compute (CUDA) you also need:

  sudo modprobe --ignore-install nvidia_uvm

For display output from the card's own connectors, load KMS as well - but note
that run.sh does this for you, in the right order and after the link-speed cap:

  sudo modprobe --ignore-install nvidia_modeset
  sudo modprobe --ignore-install nvidia_drm modeset=1 fbdev=1
  sudo /sbin/ub-device-create          # creates /dev/nvidia-modeset

Do not skip that last one. The udev rule that normally runs ub-device-create
fires when nvidia binds to the PCI device, which is BEFORE nvidia_modeset is
loaded here, so /dev/nvidia-modeset never appears. Nothing visible breaks -
compute, CUDA, rendering and KMS use other nodes - but Vulkan presentation
fails with VK_ERROR_UNKNOWN and vulkaninfo segfaults.

Loading nvidia_drm by hand WITHOUT "modeset=1" gives no display, because a
conflicting "options nvidia_drm modeset=0" may exist in modprobe.d and the
kernel takes the last repeated parameter. Run ./01-check.sh to see the effective
value.
EOF
else
    rc=$?; mark "AFTER nvidia-smi ERROR rc=$rc"
    echo "  nvidia-smi rc=$rc" >&2
    echo
    echo "  NVRM messages:"
    dmesg | grep -iE "nvrm|nvidia" | tail -30 | sed 's/^/    /'
fi

echo
echo "Log kernel: $KLOG"
echo
echo "To revert what this script changed:"
echo "  sudo rm /etc/udev/rules.d/71-nvidia.rules /etc/modprobe.d/zz-egpu-nvidia.conf"
echo "  sudo udevadm control --reload"
sync
