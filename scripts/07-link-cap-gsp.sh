#!/usr/bin/env bash
# 07-link-cap-gsp.sh - run the bring-up with the graphical session out of the
# way, so a hang costs a reboot instead of your session.
#
# THIS SCRIPT NO LONGER IMPLEMENTS THE BRING-UP. It used to: cap, GSP, load,
# nvidia-smi, connectors, telemetry - a second copy of run.sh steps 4 to 9,
# including a second copy of the three ordering constraints that the whole
# package is built around. Two copies of those is how they drift. So this now
# sets up the conditions and calls run.sh, and there is exactly one
# implementation of the bring-up.
#
# WHAT IS LEFT HERE, i.e. what run.sh deliberately does NOT do:
#
#   - drops to multi-user.target first, so the compositor is not holding
#     /dev/dri/* and a hang cannot take a session with unsaved work
#   - detaches into a transient systemd unit, so killing the session it was
#     started from does not kill the run
#
# It used to also arm panic-on-stall (--arm-panic: hung_task_panic,
# softlockup_panic, hardlockup_panic, kernel.panic=15). That was an instrument
# for making a silent reset leave a log, and it worked - the reset is understood
# and fixed. What is left of it is a way to lose unsaved work to a transient
# stall in something unrelated, so it is gone. "sysctl -w kernel.softlockup_panic=1"
# is one line if a future experiment ever wants it back.
#
# THE MECHANISM run.sh IMPLEMENTS, for reference
#
# Behind a Thunderbolt tunnel the PCIe link oscillates Gen3<->Gen4. The driver
# retrains it upwards, and a retrain inside the GSP RPC handshake window drops
# the card off the bus - an instant reset with no kernel output, no oops, no
# AER. Two fields in Link Control 2 (CAP_EXP+0x30) decide it:
#
#   bit 5      Hardware Autonomous Speed Disable - stops the oscillation
#   bits [3:0] Target Link Speed - the ceiling (3 = Gen3)
#
# The cap must be applied BEFORE nvidia.ko binds. Confirmed on this hardware
# 2026-08-21: with the cap, nvidia-smi survives, GSP reports its firmware
# version, and the card's own HDMI output works.
#
# WHEN TO REACH FOR THIS RATHER THAN run.sh
#
# Almost never, now that cap plus GSP is verified working. It is for a new risky
# experiment: a different CAP_SPEED, a forced retrain, a kernel or driver you
# have not tried. On a good day run.sh in a terminal is strictly nicer, because
# you can watch it.
#
# USAGE
#
#   sudo ./scripts/07-link-cap-gsp.sh              # Gen3 + bit 5, GSP on
#   sudo CAP_SPEED=2 ./scripts/07-link-cap-gsp.sh  # Gen2 ceiling
#   sudo ./scripts/07-link-cap-gsp.sh --retrain    # force a retrain as well
#   sudo ./scripts/07-link-cap-gsp.sh --off        # revert - hands off to
#                                                  # run.sh --off, which is the
#                                                  # same thing and works with
#                                                  # the card already gone

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/../lib/egpu-lib.sh"

SELF=$SELFDIR/$(basename "${BASH_SOURCE[0]}")

WANT_OFF=0; WANT_RETRAIN=0
for a in "$@"; do case $a in
    --off)     WANT_OFF=1 ;;
    --retrain) WANT_RETRAIN=1 ;;
    -h|--help) egpu_usage "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
esac; done

# --- REVERT: the same code path as run.sh --off ---------------------------
#
# These were step-for-step identical: unload the stack, restore the GSP block,
# drop the .disabled-* leftovers, clear the cap, say "reboot then run again".
# run.sh --off also works with no card on the bus, which is the state you are
# usually in when reverting, so it is the better of the two to keep.
if (( WANT_OFF )); then
    exec "$EGPU_ROOT/run.sh" --off
fi

egpu_require_root "[--retrain] [--off]"

# --- detach, because a hang is possible ----------------------------------
#
# Restarting into multi-user.target kills the session this script runs in, so
# the run has to outlive it. A transient unit does; IgnoreOnIsolate keeps the
# isolate below from stopping the unit that issued it.
MYTTY=$(tty 2>/dev/null || echo '?')
if [[ $MYTTY != /dev/tty[0-9]* && ${EGPU_DETACHED:-0} != 1 ]]; then
    command -v systemd-run >/dev/null \
        || { bad "on $MYTTY and systemd-run is missing - switch to a text console"; exit 1; }
    hdr "Detaching"
    warn "you are on $MYTTY - the graphical session will go"
    info "when it finishes: Ctrl+Alt+F1, then"
    info "    sudo cat \$(ls -t $EGPU_LOGS/run-*.log | head -1)"
    warn "starting in 5 s (Ctrl+C aborts)"
    sleep 5
    exec systemd-run --unit=egpu-07-link-cap-gsp --collect \
        -p IgnoreOnIsolate=yes -p Type=oneshot -p TimeoutStartSec=900 \
        -E EGPU_DETACHED=1 -E CAP_SPEED="${CAP_SPEED:-}" \
        -E GPU="${GPU:-}" -E BRIDGE="${BRIDGE:-}" "$SELF" "$@"
fi

hdr "Dropping the graphical session"
if systemctl is-active graphical.target >/dev/null 2>&1; then
    systemctl isolate multi-user.target; sleep 4; ok "dropped"
else
    info "already inactive"
fi

# --- and now the one implementation of the bring-up ----------------------
#
# --plain suppresses run.sh's two no-argument defaults. --restart-ui would be
# actively wrong here: the session is deliberately gone, and --primary-gpu
# needs a session to take effect in.
hdr "Handing over to run.sh"
ARGS=(--plain)
(( WANT_RETRAIN )) && ARGS+=(--retrain)
info "run.sh ${ARGS[*]}"
"$EGPU_ROOT/run.sh" "${ARGS[@]}"
rc=$?

hdr "DONE (rc=$rc)"
cat <<EOF
  Back to a desktop:      sudo systemctl isolate graphical.target
  Revert configuration:   sudo $SELF --off  &&  sudo reboot
  If GSP still dies:      sudo CAP_SPEED=2 $SELF --retrain
                          then CAP_SPEED=1 - Gen1 costs a lot of bandwidth,
                          but it tests whether the mechanism is the problem
EOF
exit $rc
