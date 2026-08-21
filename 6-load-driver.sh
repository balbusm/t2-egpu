#!/usr/bin/env bash
# 6-load-driver.sh - keep nvidia_drm and nvidia_modeset out of the way, then
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
# If BAR1 turns out unassigned at this point, 7-bar-fallback.sh is called to
# escalate. In a normal run that never happens, because 5-window already
# assigned it.

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run ./2-devices.sh to see what is present." >&2
    exit 1
fi


DEV=$EGPU_GPU
LOGDIR=$SELFDIR/logs
STAMP=$(date +%Y%m%d-%H%M%S)
KLOG=$LOGDIR/kernel-$STAMP.log
SLOG=$LOGDIR/script-$STAMP.log
FALLBACK=$SELFDIR/7-bar-fallback.sh

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
mkdir -p "$LOGDIR"; chown "${SUDO_USER:-root}:" "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$SLOG") 2>&1

BG=()
cleanup() { for p in "${BG[@]:-}"; do kill "$p" 2>/dev/null || true; done; sync; }
trap cleanup EXIT
mark() { printf '\n########## %s ##########\n' "$1" >> "$KLOG"; sync; echo ">>> $1"; }

echo "=== logi ==="
echo "  kernel:  $KLOG"
echo "  skrypt: $SLOG"

# ---------------------------------------------------------------- 1
echo
echo "=== 1. Shadowing the udev rule 71-nvidia.rules ==="
cat > /etc/udev/rules.d/71-nvidia.rules <<'EOF'
# Shadows /lib/udev/rules.d/71-nvidia.rules for a Thunderbolt eGPU.
#
# USUNIETE wzgledem oryginalu:
#   RUN+="/sbin/modprobe nvidia-modeset"   - hangs during initialisation
#   RUN+="/sbin/modprobe nvidia-drm"       - "[nvidia-drm] Loading driver" = hang
#   RUN+="/sbin/modprobe nvidia-uvm"       - not needed for nvidia-smi
#
# ZMIENIONE: power/control "auto" -> "on". Runtime PM usypia eGPU w D3cold,
# which over Thunderbolt is a known source of hangs.

# Tag dla logind (LP: #1365336)
SUBSYSTEM=="pci", ATTRS{vendor}=="0x10de", DRIVERS=="nvidia", TAG+="seat", TAG+="master-of-seat"

# nvidia-persistenced
ACTION=="add", DEVPATH=="/bus/pci/drivers/nvidia", TAG+="systemd", ENV{SYSTEMD_WANTS}="nvidia-persistenced.service"

# Wezly /dev/nvidia*
ACTION=="add", DEVPATH=="/bus/pci/drivers/nvidia", RUN+="/sbin/ub-device-create"
ACTION=="add", DEVPATH=="/module/nvidia_uvm", SUBSYSTEM=="module", RUN+="/sbin/ub-device-create"

# Runtime PM DISABLED for NVIDIA devices (the original set "auto")
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", TEST=="power/control", ATTR{power/control}="on"
EOF
echo "  zapisano /etc/udev/rules.d/71-nvidia.rules"
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

# If it loads anyway, do not let it take over the display.
options nvidia_drm modeset=0 fbdev=0

# Bez D3cold.
options nvidia NVreg_DynamicPowerManagement=0
EOF
echo "  zapisano /etc/modprobe.d/zz-egpu-nvidia.conf"

echo
echo "  verification - what 'modprobe nvidia_drm' would do:"
modprobe --dry-run --show-depends nvidia_drm 2>&1 | sed 's/^/    /'
drmplan=$(modprobe --dry-run --show-depends nvidia_drm 2>&1 || true)
if grep -q "^install /bin/false" <<<"$drmplan"; then
    echo "  OK: nvidia_drm zablokowany"
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
    echo "    Diagnoza: sudo ./1-check.sh" >&2
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
bar1=$(awk 'NR==2 { print $1 }' /sys/bus/pci/devices/$DEV/resource 2>/dev/null || echo x)
if [[ $bar1 == 0x0000000000000000 || $bar1 == x ]]; then
    echo "  BAR1 unassigned - running 7-bar-fallback.sh"
    [[ -x $FALLBACK ]] || { echo "  ERROR: missing $FALLBACK" >&2; exit 1; }
    "$FALLBACK" || { echo "  7-bar-fallback could not do it - aborting" >&2; exit 1; }
    bar1=$(awk 'NR==2 { print $1 }' /sys/bus/pci/devices/$DEV/resource 2>/dev/null || echo x)
fi
[[ $bar1 != 0x0000000000000000 && $bar1 != x ]] || {
    echo "  ERROR: BAR1 still unassigned" >&2; exit 1; }
echo "  BAR1 = $bar1  OK"
lspci -vv -s "$DEV" 2>/dev/null | grep -E "Region [013]" | sed 's/^/  /'

# ---------------------------------------------------------------- 4
echo
echo "=== 4. Capturing the kernel log ==="
stdbuf -oL dmesg -w >> "$KLOG" &  BG+=($!)
( while :; do sync; sleep 0.2; done ) & BG+=($!)
sleep 1; echo "  aktywne"

# ---------------------------------------------------------------- 5
echo
echo "=== 5. modprobe nvidia (tylko ten module) ==="
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
echo "  runtime PM of the card:"
printf "    power/control = %s\n" "$(cat /sys/bus/pci/devices/$DEV/power/control 2>/dev/null)"
echo on > /sys/bus/pci/devices/$DEV/power/control 2>/dev/null && echo "    forced to 'on'"

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
  sudo modprobe --ignore-install nvidia_drm modeset=1

Loading nvidia_drm by hand WITHOUT "modeset=1" gives no display, because a
conflicting "options nvidia_drm modeset=0" may exist in modprobe.d and the
kernel takes the last repeated parameter. Run ./1-check.sh to see the effective
value.
EOF
else
    rc=$?; mark "PO nvidia-smi ERROR rc=$rc"
    echo "  nvidia-smi rc=$rc" >&2
    echo
    echo "  Komunikaty NVRM:"
    dmesg | grep -iE "nvrm|nvidia" | tail -30 | sed 's/^/    /'
fi

echo
echo "Log kernel: $KLOG"
echo
echo "To revert what this script changed:"
echo "  sudo rm /etc/udev/rules.d/71-nvidia.rules /etc/modprobe.d/zz-egpu-nvidia.conf"
echo "  sudo udevadm control --reload"
sync
