#!/usr/bin/env bash
# 01-check.sh - verify prerequisites. Read-only unless --fix is given.
#
# WHY: the package must work after being moved to another machine or after
# reinstalling the system. Files under /etc are then missing, and they are a
# hard requirement whose absence shows up not as an error but as a machine RESET.
# This script verifies them before anything touches the hardware.
#
# --fix writes ONLY files this package owns (modprobe.d). The kernel cmdline
# needs a GRUB edit and a reboot, so it is only reported, never changed.
#
# USAGE:
#   sudo ./scripts/01-check.sh          # report
#   sudo ./scripts/01-check.sh --fix    # + write the missing modprobe.d file
#   ./scripts/01-check.sh --quiet       # exit code only (0 = ready)
#
# EXIT CODE: 0 = everything critical is in place, 1 = something critical is missing.

set -uo pipefail
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/../lib/egpu-lib.sh"
egpu_resolve "${GPU:-}" >/dev/null 2>&1 || true


FIX=0; QUIET=0
for a in "$@"; do case $a in
    --fix)   FIX=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) egpu_usage "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 2 ;;
esac; done

CRIT=0; WARN=0
say()  { (( QUIET )) || printf '%s\n' "$*"; }
hdr()  { (( QUIET )) || printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
pass() { (( QUIET )) || printf '  \033[32mOK  \033[0m %s\n' "$*"; }
fail() { CRIT=$((CRIT+1)); (( QUIET )) || printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { WARN=$((WARN+1)); (( QUIET )) || printf '  \033[33mNOTE\033[0m %s\n' "$*"; }
info() { (( QUIET )) || printf '       %s\n' "$*"; }

MODPROBE_D=/etc/modprobe.d

# WHY THERE IS A "MAYBE FAIL"
#
# Most of this file checks the NVIDIA proprietary driver, and rightly so - the
# reset this package exists to avoid is an NVIDIA/GSP failure mode. But
# lib/egpu-lib.sh recognises AMD and Intel cards as well, and run.sh uses
# "01-check --quiet" as a hard gate. Written as plain fail() these checks made
# 01-check report "no NVIDIA card on the PCI bus" for a perfectly good AMD eGPU,
# and run.sh then refused to run at all.
#
# So: a hard failure when the card is NVIDIA or when no card is present (this
# package's default assumption), and a note when we positively know it is not.
IS_NVIDIA=1
[[ -n ${EGPU_VENDOR:-} && ${EGPU_VENDOR,,} != 0x10de ]] && IS_NVIDIA=0
nvfail() {
    if (( IS_NVIDIA )); then fail "$@"
    else warn "$* - not applicable, the card is ${EGPU_VENDOR_NAME:-not NVIDIA}"; fi
}

say "==================================================================="
say " 01-check: prerequisites$( ((FIX)) && echo '   [--fix]')"
say " package: $EGPU_ROOT"
say "==================================================================="

# ---------------------------------------------------------------- 1
hdr "1. Tools"
for t in lspci setpci modprobe modinfo make gcc awk; do
    if command -v "$t" >/dev/null; then pass "$t"
    else fail "$t - install it (pciutils / build-essential / kmod)"; fi
done
if command -v nvidia-smi >/dev/null; then pass "nvidia-smi"
else nvfail "nvidia-smi - the NVIDIA driver is not installed"; fi
command -v boltctl >/dev/null && pass "boltctl" || warn "boltctl - useful for diagnosing the tunnel (package: bolt)"

# ---------------------------------------------------------------- 2
hdr "2. Kernel and headers"
KVER=$(uname -r)
info "kernel: $KVER"
if [[ -d /lib/modules/$KVER/build ]]; then pass "kernel headers for $KVER"
else fail "missing /lib/modules/$KVER/build - the window module cannot be built"; fi
case $KVER in
    7.2.*|7.3.*|8.*)
        warn "kernel $KVER: NVIDIA 610.43.02 does NOT build here"
        info "atomic modesetting API was reworked; stay on the 7.1.x line" ;;
    7.1.*) pass "kernel line 7.1.x - matches the driver" ;;
    *)     warn "untested kernel line ($KVER)" ;;
esac

# ---------------------------------------------------------------- 3
hdr "3. NVIDIA driver"
if lic=$(modinfo -F license nvidia 2>/dev/null) && [[ -n $lic ]]; then
    ver=$(modinfo -F version nvidia 2>/dev/null)
    info "version: $ver   license: $lic"
    if [[ $lic == "NVIDIA" ]]; then
        pass "PROPRIETARY driver - lets you disable GSP as an escape hatch"
    else
        warn "OPEN driver ($lic) - the open module REQUIRES GSP"
        info "there is then no way back to a no-GSP configuration"
    fi
else
    nvfail "the nvidia module is not built for this kernel"
fi

# ---------------------------------------------------------------- 4
hdr "4. Effective module configuration (the EFFECT matters, not file names)"
#
# WHY BY EFFECT AND NOT BY FILE NAME: modprobe concatenates options from ALL
# files in modprobe.d, alphabetically. The same effect can come from many
# different file layouts, so testing for a file NAME produces
# false alarms. We ask modprobe what it will ACTUALLY assemble.
#
# WHY THIS IS CRITICAL: if the driver binds to the card before
# the link speed cap, the machine RESETS. Blocking autoload is the only
# thing that prevents it.
MOD_CRIT=0      # blocks the run (reset risk)
MOD_FIXABLE=0   # worth fixing, does not block

# Asked ONCE. Three of the checks below used to run this identical command for
# themselves. "install ... /bin/false" is tested separately, without
# --ignore-install, because that one is asking a different question: whether the
# block is effective at all.
NV_PLAN=$(modprobe --dry-run --ignore-install --show-depends nvidia 2>/dev/null)

# 4a. is autoload blocked?
if modprobe --dry-run --show-depends nvidia 2>/dev/null | grep -q '^install /bin/false'; then
    pass "nvidia autoload is blocked (install ... /bin/false is effective)"
else
    nvfail "nvidia autoload is NOT blocked"
    info "the driver can bind before the cap = machine reset"
    (( IS_NVIDIA )) && MOD_CRIT=1
fi

# 4b. Is KMS on? The kernel takes the LAST repeated parameter.
if eff=$(modprobe --dry-run --ignore-install --show-depends nvidia_drm 2>/dev/null | grep 'nvidia-drm.ko'); then
    info "$(sed 's|.*/nvidia-drm.ko|nvidia-drm.ko|' <<<"$eff")"
    last=$(grep -oE 'modeset=[01]' <<<"$eff" | tail -1)
    if [[ $last == modeset=1 ]]; then
        pass "effective $last - KMS enabled (required for display)"
    else
        # NOT a blocker: run.sh and 07-link-cap-gsp.sh pass "modeset=1" on the
        # modprobe command line, which is appended last and therefore wins. The
        # conflict only bites something ELSE loading nvidia_drm - a service, a
        # udev rule, or you by hand. Worth fixing, not worth refusing to run.
        warn "effective ${last:-modeset not set} - KMS would be off for a plain modprobe"
        info "a conflicting 'options nvidia_drm modeset=0' exists in $MODPROBE_D"
        info "files are concatenated alphabetically and the kernel takes the last one"
        info "run.sh works around this by passing modeset=1 explicitly, so it does"
        info "not block the run - but fix it, or a plain modprobe yields no display"
        MOD_FIXABLE=1
    fi
    # fbdev, checked separately and for a specific reason: callers repeat
    # modeset=1 on the command line, so a stray modeset=0 is survivable. NOBODY
    # used to repeat fbdev, so a stray fbdev=0 simply took effect and nothing
    # reported it. Both parameters default to 1 in this driver.
    lastfb=$(grep -oE 'fbdev=[01]' <<<"$eff" | tail -1)
    if [[ -z $lastfb || $lastfb == fbdev=1 ]]; then
        pass "effective ${lastfb:-fbdev not set (driver default 1)}"
    else
        warn "effective $lastfb - the driver creates no framebuffer device"
        info "a conflicting 'options nvidia_drm fbdev=0' exists in $MODPROBE_D"
        info "both modeset and fbdev default to 1 - see 'modinfo -p nvidia-drm'"
        MOD_FIXABLE=1
    fi
else
    warn "cannot determine the effective options for nvidia_drm"
fi

# 4b-bis. Does /dev/nvidia-modeset exist?
#
# Checked explicitly because its absence is invisible everywhere else. Ubuntu
# creates the /dev/nvidia* nodes with /sbin/ub-device-create, fired by a udev
# rule when nvidia BINDS to the PCI device - before we load nvidia_modeset by
# hand. Our /etc/udev/rules.d/71-nvidia.rules deliberately comments out the
# "RUN+=/sbin/modprobe nvidia-modeset" line, because auto-loading it hung the
# machine during bring-up. Net effect: the node never got created.
#
# Nothing obvious breaks. Compute, CUDA, rendering and KMS use other nodes and
# all work. Only Vulkan opens this one, and when it is missing the driver
# answers VK_ERROR_UNKNOWN from vkCreateSwapchainKHR while vulkaninfo
# segfaults - which is exactly as misleading as it sounds. Do not remove this
# check.
if [[ -e /dev/nvidia-modeset ]]; then
    pass "/dev/nvidia-modeset present - Vulkan presentation can initialise"
elif [[ -d /sys/module/nvidia_modeset ]]; then
    nvfail "/dev/nvidia-modeset MISSING while nvidia_modeset is loaded"
    info "Vulkan presentation fails with VK_ERROR_UNKNOWN and vulkaninfo segfaults"
    info "fix: sudo /sbin/ub-device-create"
    info "or:  sudo mknod /dev/nvidia-modeset c 195 254 && sudo chmod 666 /dev/nvidia-modeset"
else
    info "/dev/nvidia-modeset absent, but nvidia_modeset is not loaded yet - expected"
fi

# 4c. Is D3cold disabled?
dpm=$(grep -oE 'NVreg_DynamicPowerManagement=[^ "]*' <<<"$NV_PLAN" | sort -u | tail -1)
if [[ $dpm == "NVreg_DynamicPowerManagement=0" ]]; then
    pass "effective $dpm (no D3cold through the tunnel)"
else
    warn "DynamicPowerManagement: ${dpm:-not set}, we want =0"
    info "D3cold over Thunderbolt is a known way to get 'fallen off the bus'"
fi

# 4d. Is ReBAR disabled?
if grep -q 'NVreg_EnableResizableBar=0' <<<"$NV_PLAN"; then
    pass "effective NVreg_EnableResizableBar=0"
else
    warn "NVreg_EnableResizableBar not set to 0"
fi

info ""
info "files providing these settings:"
grep -lsE 'nvidia' "$MODPROBE_D"/*.conf 2>/dev/null | while read -r f; do
    info "  $(basename "$f")"
done

# 4e. --fix ONLY when the effect is wrong; otherwise we would add duplicates.
#
# TWO THINGS HAVE TO HAPPEN, and the file name matters as much as the content:
#
#   1. Any OTHER file that sets "options nvidia_drm modeset=0" must be
#      neutralised. Leaving a contradictory line in place is a trap: the module
#      only works because callers repeat modeset=1 on the command line.
#   2. Our file must sort LAST in /etc/modprobe.d, because modprobe
#      concatenates alphabetically and the kernel takes the last repeated
#      parameter. A name like "egpu-00-*.conf" sorts early and would lose to
#      any "zz-*.conf" already present - which is exactly what happened here.
if (( MOD_CRIT || MOD_FIXABLE )); then
    CANON=$MODPROBE_D/zzzz-egpu-package.conf
    if (( FIX )); then
        # 1. comment out conflicting modeset=0 lines in other files
        # Matches modeset=0 OR fbdev=0. The old pattern only caught modeset,
        # which meant a line like "options nvidia_drm fbdev=0" survived --fix
        # untouched and kept the framebuffer device off with nothing reporting it.
        while read -r f; do
            [[ -z $f || $f == "$CANON" ]] && continue
            cp -a "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
            # Delimiter is @ and the expression is ERE, both on purpose. Written
            # as BRE with a | delimiter, the alternation "\|" collides with the
            # delimiter itself: sed reads it as an escaped @-style separator and
            # the substitution silently matches nothing. It looks like it worked.
            sed -E -i 's@^(options nvidia_drm .*(modeset|fbdev)=0.*)$@# disabled by 01-check.sh --fix: conflicted with the canonical file\n#\1@' "$f"
            pass "neutralised conflicting modeset=0/fbdev=0 in $(basename "$f")"
        done < <(grep -lsE 'options nvidia_drm .*(modeset|fbdev)=0' "$MODPROBE_D"/*.conf 2>/dev/null)

        # 2. write our file under a name that sorts last
        cat > "$CANON" <<'EOF'
# Written by 01-check.sh --fix. Do not rename to something that sorts earlier:
# modprobe concatenates /etc/modprobe.d alphabetically and the kernel takes the
# LAST repeated parameter, so this file has to come after everything else.
#
# The card is hot-plugged. The driver MUST NOT bind before the BARs are
# assigned and before the PCIe link-speed cap is applied - that combination
# resets the machine.
#
#   blacklist          closes the modalias path (udev matching on PCI ID)
#   install /bin/false also closes loading by name and as a dependency
#
# Deliberate load: modprobe --ignore-install <module>
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
install nvidia /bin/false
install nvidia_drm /bin/false
install nvidia_modeset /bin/false

# KMS on - required for output from the card's own connectors. fbdev is stated
# too, even though 1 is the driver default: modprobe.d is concatenated and the
# kernel takes the last repeated value, so being explicit here is what makes the
# effective configuration deterministic on a system with older leftovers.
options nvidia_drm modeset=1 fbdev=1

# No D3cold over the tunnel: it is a known way to get "fallen off the bus".
# This does not block P-states; the card still idles at P8 once GSP runs.
options nvidia NVreg_DynamicPowerManagement=0

# ReBAR off - resizing fails when bridge windows are tight.
options nvidia NVreg_EnableResizableBar=0
EOF
        pass "wrote $CANON"
        info "re-run this check to confirm: sudo $0"
    else
        info ""
        info "Fix: sudo $0 --fix"
        info "  - comments out conflicting 'options nvidia_drm modeset=0/fbdev=0' lines"
        info "  - writes $CANON, named so it sorts last"
    fi
fi

# ---------------------------------------------------------------- 5
hdr "5. udev rules"
UDEV=/etc/udev/rules.d/71-nvidia.rules
if [[ -f $UDEV ]]; then
    if grep -qE '^\s*[^#]*RUN\+=.*modprobe' "$UDEV"; then
        fail "$UDEV contains an active RUN+=modprobe - this loads the driver BY NAME"
        info "blacklist will not stop it. Comment those lines out."
    else
        pass "$UDEV with no active RUN+=modprobe"
    fi
elif [[ -f /lib/udev/rules.d/71-nvidia.rules ]] \
     && grep -qE '^\s*[^#]*RUN\+=.*modprobe' /lib/udev/rules.d/71-nvidia.rules; then
    fail "no $UDEV, and the /lib version loads the driver via RUN+=modprobe"
    info "shadow it: copy the file from /lib to /etc and comment out RUN+="
else
    pass "no udev rules that load the driver"
fi

# ---------------------------------------------------------------- 6
hdr "6. Kernel parameters (cmdline)"
CMD=$(cat /proc/cmdline)
CMD_CRIT=0
need_crit="pcie_ports=native pcie_aspm=off pcie_port_pm=off"
need_warn="thunderbolt.host_reset=0 thunderbolt.clx=0"
for p in $need_crit; do
    grep -qw -- "$p" <<<"$CMD" && pass "$p" || { fail "$p - missing from cmdline"; CMD_CRIT=1; }
done
for p in $need_warn; do
    grep -qw -- "$p" <<<"$CMD" && pass "$p" || warn "$p - missing (tunnel stability)"
done
if grep -qE 'pci=[^ ]*hpbussize' <<<"$CMD"; then
    pass "pci=...hpbussize... present"
    info "$(grep -oE 'pci=[^ ]+' <<<"$CMD")"
else
    warn "missing pci=assign-busses,hpbussize=... - bus numbering behind the tunnel"
fi
if (( CMD_CRIT )); then
    info ""
    info "Target line in /etc/default/grub (GRUB_CMDLINE_LINUX_DEFAULT):"
    info "  pcie_ports=native pcie_aspm=off pcie_port_pm=off"
    info "  pci=assign-busses,hpbussize=0x33,realloc,hpmmiosize=32M,hpmmioprefsize=1M,hpiosize=0"
    info "  thunderbolt.host_reset=0 thunderbolt.clx=0"
    info "Then: sudo update-grub && sudo reboot"
fi

# ---------------------------------------------------------------- 7
hdr "7. Hardware"
#
# Discovery comes from lib/egpu-lib.sh, which is already sourced at the top of
# this file. It used to be a fifth private copy here - and one that matched on
# vendor 0x10de only, so it contradicted the library it sat next to.
if [[ -z ${EGPU_GPU:-} ]]; then
    fail "no display controller found behind a Thunderbolt/USB4 tunnel"
    info "power-cycle the enclosure, plug the cable in, check: boltctl list"
    info "see what the kernel does show:  $EGPU_SCRIPTS/02-devices.sh --all"
else
    pass "card: $EGPU_GPU  $EGPU_VENDOR_NAME"
    info "$EGPU_DESC"
    if lspci -s "${EGPU_BRIDGE#*:}" 2>/dev/null | grep -qiE 'thunderbolt|usb4'; then
        pass "bridge above the card: $EGPU_BRIDGE (Thunderbolt/USB4)"
    else
        warn "bridge above the card: $EGPU_BRIDGE - does not look like Thunderbolt"
        info "the link speed cap only makes sense behind a tunnel"
    fi
    b1=$(egpu_bar_size "$EGPU_GPU" 1)
    [[ -n $b1 ]] && info "BAR1 now: $b1" \
                 || info "BAR1 unassigned (normal before the first run.sh)"
fi

# ---------------------------------------------------------------- 8
hdr "8. Window module state (matters after a replug)"
#
# WHY THIS CHECK EXISTS
#
# egpu_rp_window moves ONE root port's prefetchable window, chosen by the
# rp_bus/rp_dev/rp_fn parameters it was loaded with. Those parameters are
# read-only after load (0444), and rmmod does NOT restore the old window, so:
#
#   * replug on a port behind the SAME root port  -> the moved window is still
#     in place, the kernel can assign BARs again, nothing to redo
#   * replug on a port behind a DIFFERENT root port -> that root port still has
#     its small firmware window, and the loaded module cannot be retargeted.
#     A REBOOT is required before the card can work there.
#
# Without this check the failure looks like an unexplained "BAR1 still != 256M".
MODPARAM=/sys/module/egpu_rp_window/parameters
if [[ -d /sys/module/egpu_rp_window ]]; then
    if [[ -r $MODPARAM/rp_bus ]]; then
        LOADED_RP=$(printf '0000:%02x:%02x.%s' \
            "$(cat "$MODPARAM/rp_bus")" "$(cat "$MODPARAM/rp_dev")" "$(cat "$MODPARAM/rp_fn")")
        info "module loaded, window moved for root port $LOADED_RP"
        if [[ -n ${EGPU_ROOT_PORT:-} ]]; then
            if [[ $LOADED_RP == "$EGPU_ROOT_PORT" ]]; then
                pass "matches the card's current root port"
            else
                fail "card is now behind $EGPU_ROOT_PORT, module was loaded for $LOADED_RP"
                info "that root port still has its small firmware window, and the"
                info "module cannot be retargeted while loaded (parameters are read-only)"
                info "REBOOT, then run ./run.sh on this port"
            fi
        fi
    else
        info "module loaded (parameters not readable)"
    fi
else
    pass "module not loaded - a clean run will load it"
fi

hdr "9. Package integrity"
#
# The list used to be written out by hand and had fallen behind: 09-primary-gpu,
# 10-teardown and lib/egpu-lib.sh were all missing from it, and run.sh execs the
# first two and sources the third. The required set is still explicit - a glob
# cannot notice a file that is absent - but anything matching the numbered
# pattern is additionally checked for the execute bit, so a new script cannot be
# silently non-executable.
# run.sh is the entry point and lives in the package root; the numbered steps
# live in scripts/. Paths come from the library (EGPU_ROOT / EGPU_SCRIPTS)
# rather than from this script's own directory, which is scripts/ and no longer
# the same thing.
[[ -x $EGPU_ROOT/run.sh ]] && pass "run.sh" || fail "run.sh - missing or not executable"
for f in 01-check.sh 02-devices.sh 03-build-module.sh 04-window.sh \
         05-load-driver.sh 06-bar-fallback.sh 07-link-cap-gsp.sh 08-check-outputs.sh \
         09-primary-gpu.sh 10-teardown.sh; do
    [[ -x $EGPU_SCRIPTS/$f ]] && pass "scripts/$f" || fail "scripts/$f - missing or not executable"
done
for f in lib/egpu-lib.sh module/egpu_rp_window.c module/Makefile; do
    [[ -f $EGPU_ROOT/$f ]] && pass "$f" || fail "$f - missing"
done
shopt -s nullglob
for f in "$EGPU_SCRIPTS"/[0-9]*-*.sh; do
    [[ -x $f ]] || fail "scripts/$(basename "$f") - present but not executable"
done
shopt -u nullglob

# ---------------------------------------------------------------- summary
say ""
say "==================================================================="
if (( CRIT )); then
    say " RESULT: $CRIT critical failure(s), $WARN warning(s)"
    say " Do NOT run ./run.sh while critical items are unresolved."
    (( FIX )) || say " Some of this can be fixed: sudo $0 --fix"
    say "==================================================================="
    exit 1
fi
say " RESULT: ready to run ($WARN warning(s))"
say " Next: sudo ./run.sh"
say "==================================================================="
exit 0
