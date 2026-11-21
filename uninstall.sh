#!/bin/bash
# uninstall.sh — a diagnosztikai csomag eltávolítása.
#
#   sudo ./uninstall.sh           # eltávolítás, a gyűjtött naplók megmaradnak
#   sudo ./uninstall.sh --purge   # naplók törlése is
#   sudo ./uninstall.sh --dry-run

set -uo pipefail

UNIT_DIR="/etc/systemd/system"
BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/yunohost-diag"
LOG_DIR="/var/log/yh-diag"
PURGE=0
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --purge)   PURGE=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Ismeretlen kapcsoló: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Root jog kell: sudo ./uninstall.sh" >&2; exit 1; }

doit() {
    if [ "$DRY" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else eval "$@"; fi
}

echo "==> Szolgáltatások leállítása"
doit "systemctl disable --now yh-blackbox.timer 2>/dev/null || true"
doit "systemctl disable yh-bootcheck.service 2>/dev/null || true"

echo "==> Fájlok eltávolítása"
doit "rm -f '$UNIT_DIR/yh-blackbox.service' '$UNIT_DIR/yh-blackbox.timer' '$UNIT_DIR/yh-bootcheck.service'"
doit "rm -f '$BIN_DIR/yh-blackbox.sh' '$BIN_DIR/yh-collect.sh' '$BIN_DIR/yh-analyze.sh' '$BIN_DIR/yh-bootcheck.sh'"
doit "rm -rf '$SHARE_DIR'"
doit "rm -f /etc/logrotate.d/yh-blackbox"
doit "systemctl daemon-reload"

echo "==> Beállítások visszaállítása"
doit "rm -f /etc/sysctl.d/99-yh-diag.conf"
doit "sysctl --system >/dev/null 2>&1 || true"
# A journald beállítást NEM bántjuk: a perzisztens napló általában hasznos marad.
echo "  (a perzisztens journald beállítás megmarad — ez általában kívánatos)"

if [ "$PURGE" -eq 1 ]; then
    echo "==> Naplók törlése (--purge)"
    doit "rm -rf '$LOG_DIR' /var/log/yh-blackbox.log*"
else
    echo "==> Naplók megmaradtak: $LOG_DIR és /var/log/yh-blackbox.log"
fi

echo
echo "Eltávolítás kész."
exit 0
