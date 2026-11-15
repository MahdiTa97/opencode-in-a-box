#!/bin/sh
# Install (or remove) the weekly maintenance timer. Needs root: the docker
# socket is root-only, so the unit has to run as root too.
#
#   sudo ./scripts/install-timer.sh            # install and enable
#   sudo ./scripts/install-timer.sh --remove   # stop and remove
#   sudo ./scripts/install-timer.sh --show     # print the generated units
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UNIT_DIR=/etc/systemd/system
SERVICE=$UNIT_DIR/oc-maintenance.service
TIMER=$UNIT_DIR/oc-maintenance.timer
MODE=${1:-install}

service_unit() {
  cat <<EOF
[Unit]
Description=OpenCode container maintenance (doctor, backup, audit, pins)
Documentation=file://$REPO/README.md
Wants=docker.service

[Service]
Type=oneshot
User=root
WorkingDirectory=$REPO
ExecStart=$REPO/scripts/maintenance.sh
TimeoutStartSec=30min
Nice=10
IOSchedulingClass=idle
EOF
}

timer_unit() {
  cat <<'EOF'
[Unit]
Description=Weekly OpenCode container maintenance

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
}

case "$MODE" in
  --show|show)
    service_unit
    printf '\n---\n\n'
    timer_unit
    ;;
  --remove|remove)
    systemctl disable --now oc-maintenance.timer 2>/dev/null || true
    rm -f "$SERVICE" "$TIMER"
    systemctl daemon-reload
    echo "removed oc-maintenance.timer"
    ;;
  install)
    [ "$(id -u)" = 0 ] || { echo "install-timer: run with sudo" >&2; exit 1; }
    service_unit > "$SERVICE"
    timer_unit > "$TIMER"
    chmod 644 "$SERVICE" "$TIMER"
    systemctl daemon-reload
    systemctl enable --now oc-maintenance.timer
    echo "installed. next runs:"
    systemctl list-timers oc-maintenance.timer --no-pager || true
    echo "logs: journalctl -u oc-maintenance.service"
    ;;
  *)
    echo "usage: $0 [--show|--remove]" >&2
    exit 2
    ;;
esac
