#!/bin/bash
# install.sh — YunoHost fagyás-diagnosztikai csomag telepítése.
#
#   sudo ./install.sh              # telepítés
#   sudo ./install.sh --with-pkgs  # + smartmontools, lm-sensors, nvme-cli, rasdaemon
#   sudo ./install.sh --dry-run    # csak kiírja, mit tenne
#
# Amit beállít:
#   1. perzisztens journald (reboot után is megmarad a napló)
#   2. percenkénti állapotminta (fekete doboz) systemd timerrel
#   3. boot utáni automatikus tisztátlan-leállás észlelés + csomaggyűjtés
#   4. kernel panic / hung task rögzítés (sysctl)
#   5. logrotate a fekete doboz naplójára

set -uo pipefail

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
BIN_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
SHARE_DIR="/usr/local/share/yunohost-diag"
LOG_DIR="/var/log/yh-diag"
DRY=0
WITH_PKGS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY=1; shift ;;
        --with-pkgs) WITH_PKGS=1; shift ;;
        -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "Ismeretlen kapcsoló: $1" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
doit() {
    if [ "$DRY" -eq 1 ]; then
        printf '  [dry-run] %s\n' "$*"
    else
        eval "$@"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Root jog kell: sudo ./install.sh" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "Ez a csomag systemd-t feltételez (YunoHost alatt ez adott)." >&2
    exit 1
fi

# --- 0. előfeltételek -------------------------------------------------------
step "Előfeltételek ellenőrzése"
for f in bin/yh-blackbox.sh bin/yh-collect.sh bin/yh-analyze.sh bin/yh-bootcheck.sh; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        echo "Hiányzó fájl: $f" >&2; exit 1
    fi
done
ok "scriptek megvannak"

if [ "$WITH_PKGS" -eq 1 ]; then
    step "Csomagok telepítése (opcionális)"
    PKGS=""
    command -v smartctl >/dev/null 2>&1 || PKGS="$PKGS smartmontools"
    command -v sensors  >/dev/null 2>&1 || PKGS="$PKGS lm-sensors"
    command -v nvme     >/dev/null 2>&1 || PKGS="$PKGS nvme-cli"
    command -v ras-mc-ctl >/dev/null 2>&1 || PKGS="$PKGS rasdaemon"
    command -v dmidecode >/dev/null 2>&1 || PKGS="$PKGS dmidecode"
    if [ -n "$PKGS" ]; then
        say "  Telepítendő:$PKGS"
        doit "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKGS"
        ok "csomagok telepítve"
    else
        ok "minden szükséges csomag már fent van"
    fi
fi

# --- 1. perzisztens journald ------------------------------------------------
step "Perzisztens journald bekapcsolása"
doit "mkdir -p /var/log/journal"
doit "mkdir -p /etc/systemd/journald.conf.d"
doit "cat > /etc/systemd/journald.conf.d/99-yh-diag.conf <<'EOF'
# YunoHost fagyás-diagnosztika: a napló reboot után is maradjon meg
[Journal]
Storage=persistent
SystemMaxUse=1G
SystemMaxFileSize=128M
# A fagyás előtti utolsó másodpercek is érdekesek
SyncIntervalSec=5s
RateLimitIntervalSec=0
RateLimitBurst=0
EOF"
doit "systemctl restart systemd-journald"
ok "journald perzisztens (Storage=persistent)"

# --- 2. scriptek ------------------------------------------------------------
step "Scriptek telepítése"
doit "install -d -m 755 '$SHARE_DIR'"
doit "install -m 755 '$SRC_DIR/bin/yh-blackbox.sh'  '$BIN_DIR/yh-blackbox.sh'"
doit "install -m 755 '$SRC_DIR/bin/yh-collect.sh'   '$BIN_DIR/yh-collect.sh'"
doit "install -m 755 '$SRC_DIR/bin/yh-analyze.sh'   '$BIN_DIR/yh-analyze.sh'"
doit "install -m 755 '$SRC_DIR/bin/yh-bootcheck.sh' '$BIN_DIR/yh-bootcheck.sh'"
doit "install -m 644 '$SRC_DIR/README.md' '$SHARE_DIR/README.md' 2>/dev/null || true"
doit "mkdir -p '$LOG_DIR'"
ok "scriptek: $BIN_DIR/yh-*.sh"

# --- 3. systemd egységek ----------------------------------------------------
step "Systemd egységek telepítése"
doit "install -m 644 '$SRC_DIR/systemd/yh-blackbox.service' '$UNIT_DIR/yh-blackbox.service'"
doit "install -m 644 '$SRC_DIR/systemd/yh-blackbox.timer'   '$UNIT_DIR/yh-blackbox.timer'"
doit "install -m 644 '$SRC_DIR/systemd/yh-bootcheck.service' '$UNIT_DIR/yh-bootcheck.service'"
doit "systemctl daemon-reload"
doit "systemctl enable --now yh-blackbox.timer"
doit "systemctl enable yh-bootcheck.service"
ok "yh-blackbox.timer aktív (percenkénti minta)"
ok "yh-bootcheck.service engedélyezve (boot utáni ellenőrzés)"

# --- 4. sysctl: panic és hung task rögzítés --------------------------------
step "Kernel viselkedés beállítása (panic / hung task rögzítés)"
doit "cat > /etc/sysctl.d/99-yh-diag.conf <<'EOF'
# YunoHost fagyás-diagnosztika
# 10 mp múlva indítson újra kernel panic esetén (a watchdog mellett)
kernel.panic = 10
# Oops esetén is legyen panic, hogy legyen nyom (pstore/kdump)
kernel.panic_on_oops = 1
# 120 mp után írja ki a naplóba, melyik process akadt be D állapotban
kernel.hung_task_timeout_secs = 120
kernel.hung_task_panic = 0
# Ne írjon panic-ot soft lockupra, azt a watchdog kezeli
kernel.softlockup_panic = 0
# OOM esetén ne fagyjon meg a rendszer, hanem öljön
vm.panic_on_oom = 0
EOF"
doit "sysctl --system >/dev/null 2>&1 || true"
ok "kernel.panic=10, hung_task_timeout_secs=120"

# --- 5. logrotate -----------------------------------------------------------
step "Logrotate a fekete doboz naplójára"
doit "cat > /etc/logrotate.d/yh-blackbox <<'EOF'
/var/log/yh-blackbox.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF"
ok "heti rotáció, 8 hét megtartás"

# --- 6. első minta és ellenőrzés -------------------------------------------
step "Első minta és ellenőrzés"
doit "systemctl start yh-blackbox.service || true"
if [ "$DRY" -eq 0 ]; then
    sleep 1
    if [ -s /var/log/yh-blackbox.log ]; then
        ok "fekete doboz működik, első sor:"
        tail -1 /var/log/yh-blackbox.log | cut -c1-200 | sed 's/^/    /'
    else
        warn "a fekete doboz napló még üres — nézd meg: journalctl -u yh-blackbox"
    fi
    if journalctl --list-boots --no-pager 2>/dev/null | wc -l | grep -q '^[1-9]'; then
        ok "journald látja a bootokat"
    fi
fi

# --- összefoglaló -----------------------------------------------------------
cat <<EOF

$(printf '\033[1m')Telepítés kész.$(printf '\033[0m')

Mit tegyél most:
  1. Ellenőrizd, hogy gyűlnek-e a minták (1-2 perc múlva):
       tail -f /var/log/yh-blackbox.log
  2. Nézd meg a watchdog beállításait:
       sudo wdctl
       systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec
  3. Ha a fagyás megismétlődik, a következő boot után automatikusan lesz csomag:
       ls -la /var/log/yh-diag/
       sudo yh-analyze.sh /var/log/yh-diag/crash-*.tar.gz
  4. Kézi gyűjtés bármikor:
       sudo yh-collect.sh
       sudo yh-analyze.sh

Fontos: az újraindulás előtti napló csak MOSTANTÓL marad meg.
Ami korábban történt, az már elveszett — de a következő esemény már dokumentálva lesz.

EOF

exit 0
