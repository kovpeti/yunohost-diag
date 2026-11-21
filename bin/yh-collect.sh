#!/bin/bash
# yh-collect.sh — diagnosztikai csomag gyűjtése egy tarballba.
#
# Használat:
#   yh-collect.sh                 # teljes gyűjtés, /var/log/yh-diag/ alá
#   yh-collect.sh -o /tmp/x.tar.gz
#   yh-collect.sh -b 5            # 5 korábbi boot naplóját is begyűjti
#
# A kimenet egy .tar.gz, amit nyugodtan át lehet küldeni elemzésre.

set -uo pipefail

OUTDIR="/var/log/yh-diag"
OUTFILE=""
BOOTS=3          # hány korábbi boot naplóját gyűjtsük

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUTFILE="${2:-}"; shift 2 ;;
        -b|--boots)  BOOTS="${2:-3}"; shift 2 ;;
        -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Ismeretlen kapcsoló: $1" >&2; exit 2 ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
HOST=$(hostname -s 2>/dev/null || echo host)
WORK=$(mktemp -d /tmp/yh-diag.XXXXXX) || exit 1
D="$WORK/yh-diag-$STAMP"
mkdir -p "$D"
trap 'rm -rf "$WORK"' EXIT

# --- segédek ----------------------------------------------------------------
# run <fájlnév> <parancs...> — fejléc + kimenet + hibakód a fájlba
run() {
    local f="$1"; shift
    {
        echo "### CMD: $*"
        echo "### DATE: $(date -Is)"
        echo "### ---- output ----"
        timeout 60 "$@" 2>&1
        echo "### EXIT: $?"
        echo
    } >>"$D/$f" 2>/dev/null
}

# runsh <fájlnév> <shell-kifejezés> — összetett pipeline-okhoz
runsh() {
    local f="$1"; shift
    {
        echo "### SH: $*"
        echo "### DATE: $(date -Is)"
        echo "### ---- output ----"
        timeout 60 bash -c "$*" 2>&1
        echo "### EXIT: $?"
        echo
    } >>"$D/$f" 2>/dev/null
}

have() { command -v "$1" >/dev/null 2>&1; }

section() { echo "==> $*"; }

# --- 0. meta ----------------------------------------------------------------
section "Alapinformációk"
{
    echo "gyujtes_datuma=$(date -Is)"
    echo "host=$(hostname -f 2>/dev/null)"
    echo "kernel=$(uname -r)"
    echo "arch=$(uname -m)"
    echo "uptime_sec=$(cut -d. -f1 /proc/uptime)"
    echo "boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    echo "cmdline=$(cat /proc/cmdline)"
} >"$D/00-meta.txt"

run 00-uname.txt uname -a
run 00-os-release.txt cat /etc/os-release
run 00-lscpu.txt lscpu
run 00-dmidecode-system.txt dmidecode -t system
run 00-dmidecode-bios.txt dmidecode -t bios
run 00-dmidecode-memory.txt dmidecode -t memory
run 00-dmidecode-cache.txt dmidecode -t cache
run 00-lsblk.txt lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,ROTA,DISC-GRND
run 00-lspci.txt lspci -nnk
run 00-lsusb.txt lsusb

# --- 1. bootok / leállások --------------------------------------------------
section "Bootok és leállások"
run 10-boots.txt journalctl --list-boots
run 10-last.txt last -x -n 40
run 10-wtmp.txt last -F -x -n 40

# A watchdog daemon SOFT REBOOT-ja ír wtmp shutdown-bejegyzést, a hardveres
# reset viszont NEM. Ez a legfontosabb megkülönböztető jel.
runsh 10-wtmp-shutdowns.txt "last -x -F | grep -iE 'shutdown|reboot' | head -30"
runsh 10-wtmp-raw.txt "last -x -F -n 60"
run 10-uptime-history.txt uptime
run 10-systemd-analyze.txt systemd-analyze
run 10-systemd-blame.txt systemd-analyze blame

# Minden vizsgált boot naplója, plusz a "hogyan ért véget" kivonat
for i in $(seq 0 "$BOOTS"); do
    if [ "$i" -eq 0 ]; then B="0"; else B="-$i"; fi
    # létezik-e egyáltalán ez a boot?
    if journalctl -b "$B" -n 1 >/dev/null 2>&1; then
        run "11-journal-boot$B.txt" journalctl -b "$B" --no-pager -o short-precise
        run "12-kernel-boot$B.txt" journalctl -k -b "$B" --no-pager -o short-precise
        runsh "13-boot-end$B.txt" \
            "journalctl -b $B --no-pager -o short-precise -n 80"
        runsh "14-shutdown-markers$B.txt" \
            "journalctl -b $B --no-pager | grep -iE 'systemd-shutdown|systemd\[1\]: (Reached target (Shutdown|Power-Off|Reboot|Final Step)|Shutting down)|kernel: reboot: (Power down|Restarting system)|watchdog|Power key|SIGTERM' | tail -40"
    fi
done

# --- 2. watchdog ------------------------------------------------------------
section "Watchdog"
run 20-wdctl.txt wdctl
runsh 20-watchdog-modules.txt "lsmod | grep -iE 'wdt|watchdog'"
runsh 20-watchdog-devices.txt "ls -l /dev/watchdog* 2>&1; cat /sys/class/watchdog/*/identity 2>/dev/null; for d in /sys/class/watchdog/*; do echo \"-- \$d\"; cat \$d/timeout \$d/state \$d/nowayout 2>/dev/null; done"
runsh 20-watchdog-config.txt "grep -rniE 'watchdog' /etc/systemd/system.conf /etc/systemd/system.conf.d/ /etc/default/grub /etc/kernel/cmdline 2>/dev/null"
runsh 20-watchdog-units.txt "systemctl list-units --all | grep -i watchdog; systemctl status watchdog.service --no-pager -l 2>&1 | head -30"
runsh 20-watchdog-journal.txt "journalctl -b -1 -k --no-pager | grep -iE 'watchdog|wdt|tco' | tail -50"
runsh 20-watchdog-proc.txt "cat /proc/sys/kernel/watchdog* 2>/dev/null; echo; cat /proc/sys/kernel/nmi_watchdog 2>/dev/null"
runsh 20-watchdog-hardlockup.txt "journalctl -k -b -1 --no-pager | grep -iE 'hard LOCKUP|soft lockup|BUG: soft|watchdog: BUG' | tail -40"

# --- watchdog daemon (a 'watchdog' csomag) — ez a soft reboot forrása ------
runsh 20-watchdog-conf.txt "cat /etc/watchdog.conf 2>/dev/null; echo '--- watchdog.d:'; ls -la /etc/watchdog.d/ 2>/dev/null; for f in /etc/watchdog.d/*; do [ -f \"\$f\" ] && { echo \"===== \$f\"; head -30 \"\$f\"; }; done"
runsh 20-watchdog-daemon.txt "systemctl status watchdog --no-pager -l 2>&1 | head -30; echo '--- unit:'; systemctl cat watchdog 2>/dev/null | head -40"
runsh 20-watchdog-daemon-journal.txt "journalctl -u watchdog --no-pager | tail -120"
runsh 20-watchdog-daemon-journal-prev.txt "journalctl -u watchdog -b -1 --no-pager | tail -80"
runsh 20-watchdog-syslog.txt "journalctl -t watchdog --no-pager | tail -100"
runsh 20-watchdog-loadcheck.txt "journalctl --no-pager | grep -iE 'watchdog.*(load|max-load|reboot|shutdown|halt|temperature|no action)' | tail -60"
runsh 20-watchdog-nowayout.txt "for d in /sys/class/watchdog/*; do echo \"\$d nowayout=\$(cat \$d/nowayout 2>/dev/null) timeout=\$(cat \$d/timeout 2>/dev/null) state=\$(cat \$d/state 2>/dev/null)\"; done"
runsh 20-watchdog-pid.txt "cat /var/run/watchdog.pid 2>/dev/null; ps -eo pid,ni,rtprio,comm | grep -i watchdog"
runsh 20-nproc.txt "nproc; grep -c ^processor /proc/cpuinfo"

# --- 3. memória / OOM -------------------------------------------------------
section "Memória és OOM"
run 30-free.txt free -m
run 30-meminfo.txt cat /proc/meminfo
run 30-swapon.txt swapon --show
run 30-vmstat.txt vmstat 1 5
runsh 30-pressure.txt "for f in /proc/pressure/*; do echo \"-- \$f\"; cat \$f; done"
runsh 30-oom-journal.txt "journalctl -k -b -1 --no-pager | grep -iE 'out of memory|oom-kill|killed process|oom_reaper' | tail -60"
runsh 30-oom-all.txt "journalctl --no-pager | grep -iE 'oom-kill|Out of memory: Killed' | tail -40"
runsh 30-oom-score.txt "for p in /proc/[0-9]*; do [ -r \$p/oom_score ] && echo \"\$(cat \$p/oom_score 2>/dev/null) \$(cat \$p/comm 2>/dev/null)\"; done | sort -rn | head -15"
run 30-top-mem.txt ps aux --sort=-%mem
runsh 30-zram.txt "zramctl 2>/dev/null; lsmod | grep -i zram; cat /etc/systemd/zram-generator.conf 2>/dev/null"
runsh 30-swap-files.txt "grep -i swap /etc/fstab; systemctl list-units --type=swap --all --no-pager"

# --- 4. lemez / I/O / fájlrendszer -----------------------------------------
section "Lemez, I/O, fájlrendszer"
run 40-df.txt df -h
run 40-df-inode.txt df -i
run 40-mount.txt mount
run 40-fstab.txt cat /etc/fstab
runsh 40-io-errors.txt "journalctl -k -b -1 --no-pager | grep -iE 'i/o error|critical medium error|failed command|ata[0-9]+.*(error|failed)|nvme.*(error|reset)|Buffer I/O error|blk_update_request|reset failed|link is slow|SMART' | tail -80"
runsh 40-fs-errors.txt "journalctl -k -b -1 --no-pager | grep -iE 'ext4-fs error|EXT4-fs.*(error|warning)|xfs.*(corrupt|error)|btrfs.*(error|corrupt)|remount.*read-only|metadata I/O error' | tail -60"
runsh 40-blocked.txt "journalctl -k -b -1 --no-pager | grep -iE 'blocked for more than|task .* blocked|hung_task' | tail -40"
runsh 40-diskstats.txt "cat /proc/diskstats"
runsh 40-smart-all.txt "for d in \$(lsblk -dno NAME,TYPE | awk '\$2==\"disk\"{print \$1}'); do echo \"===== /dev/\$d\"; smartctl -H -A -l error /dev/\$d 2>&1 | head -60; done"
runsh 40-nvme.txt "for d in \$(lsblk -dno NAME | grep -i nvme); do echo \"===== /dev/\$d\"; nvme smart-log /dev/\$d 2>&1 | head -40; nvme error-log /dev/\$d 2>&1 | head -30; done"
runsh 40-md-raid.txt "cat /proc/mdstat 2>/dev/null; mdadm --detail --scan 2>/dev/null"
runsh 40-lvm.txt "pvs 2>/dev/null; vgs 2>/dev/null; lvs 2>/dev/null"
runsh 40-fsck-last.txt "journalctl --no-pager | grep -iE 'fsck|filesystem check' | tail -20"
runsh 40-io-sched.txt "for d in /sys/block/*/queue/scheduler; do echo \"\$d: \$(cat \$d 2>/dev/null)\"; done"

# --- 5. hardverhibák: MCE, hő, táp -----------------------------------------
section "Hardverhibák (MCE, hő, feszültség)"
runsh 50-mce.txt "journalctl -k --no-pager | grep -iE 'machine check|mce:|Hardware Error|EDAC|CPU[0-9]+: Core temperature|thermal' | tail -60"
runsh 50-edac.txt "ls /sys/devices/system/edac/mc/ 2>/dev/null; for f in /sys/devices/system/edac/mc/mc*/ce_count /sys/devices/system/edac/mc/mc*/ue_count; do [ -r \$f ] && echo \"\$f=\$(cat \$f)\"; done; edac-util -v 2>/dev/null | head -20"
runsh 50-ras.txt "ras-mc-ctl --errors 2>/dev/null | head -40; ras-mc-ctl --summary 2>/dev/null | head -20"
runsh 50-sensors.txt "sensors -A 2>/dev/null; for z in /sys/class/thermal/thermal_zone*; do echo \"\$z: \$(cat \$z/type 2>/dev/null) \$(cat \$z/temp 2>/dev/null)\"; done"
runsh 50-throttling.txt "grep -i . /sys/devices/system/cpu/cpu*/thermal_throttle/* 2>/dev/null | head -20; dmesg 2>/dev/null | grep -iE 'cpu clock throttled|thermal' | tail -20"
runsh 50-cpufreq.txt "cpupower frequency-info 2>/dev/null | head -25; grep -i . /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null"
runsh 50-psu.txt "dmidecode -t 39 2>/dev/null | head -40"

# --- 6. kernel panic / crash dump ------------------------------------------
section "Kernel panic, crash dump"
runsh 60-pstore.txt "ls -la /sys/fs/pstore/ 2>/dev/null; for f in /sys/fs/pstore/*; do [ -f \"\$f\" ] && { echo \"===== \$f\"; head -c 20000 \"\$f\"; }; done"
runsh 60-crash-dir.txt "ls -la /var/crash/ 2>/dev/null; for f in /var/crash/*; do [ -f \"\$f\" ] && { echo \"===== \$f\"; head -60 \"\$f\"; }; done"
run 60-coredumpctl.txt coredumpctl list --no-pager
runsh 60-kdump.txt "systemctl status kdump-tools --no-pager 2>&1 | head -20; cat /etc/default/kdump-tools 2>/dev/null; cat /proc/sys/kernel/panic /proc/sys/kernel/panic_on_oops /proc/sys/kernel/hung_task_timeout_secs"
runsh 60-panic-journal.txt "journalctl -k --no-pager | grep -iE 'Kernel panic|Oops|BUG:|general protection fault|Call Trace|RIP:|WARNING:|stack segment|unable to handle' | tail -60"
runsh 60-sysctl.txt "sysctl kernel.panic kernel.panic_on_oops kernel.hung_task_timeout_secs kernel.hung_task_panic kernel.softlockup_panic kernel.nmi_watchdog vm.panic_on_oom vm.oom_kill_allocating_task 2>/dev/null"

# --- 7. ütemezett feladatok / frissítések ----------------------------------
section "Ütemezett feladatok és frissítések"
runsh 70-cron.txt "crontab -l 2>&1; echo '--- /etc/crontab'; cat /etc/crontab 2>/dev/null; echo '--- cron.d'; ls -la /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ /etc/cron.weekly/ /etc/cron.monthly/ 2>/dev/null"
runsh 70-cron-content.txt "for f in /etc/cron.d/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; do [ -f \"\$f\" ] && { echo \"===== \$f\"; head -40 \"\$f\"; }; done"
run 70-timers.txt systemctl list-timers --all --no-pager
runsh 70-timer-units.txt "for u in \$(systemctl list-timers --all --no-legend --no-pager | awk '{print \$NF}'); do echo \"===== \$u\"; systemctl cat \$u 2>/dev/null | head -30; done"
runsh 70-apt-reboot.txt "grep -rniE 'Automatic-Reboot|Unattended-Upgrade' /etc/apt/apt.conf.d/ 2>/dev/null"
runsh 70-apt-history.txt "tail -80 /var/log/apt/history.log 2>/dev/null; echo '--- term.log tail'; tail -40 /var/log/apt/term.log 2>/dev/null"
runsh 70-dpkg-tail.txt "tail -60 /var/log/dpkg.log 2>/dev/null"
runsh 70-unattended.txt "systemctl status unattended-upgrades --no-pager 2>&1 | head -20; cat /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | tail -40"
runsh 70-reboot-required.txt "ls -la /var/run/reboot-required* 2>/dev/null; cat /var/run/reboot-required.pkgs 2>/dev/null"

# --- 8. YunoHost ------------------------------------------------------------
section "YunoHost"
run 80-yh-version.txt yunohost --version
run 80-yh-apps.txt yunohost app list -f json
run 80-yh-services.txt yunohost service status
run 80-yh-backups.txt yunohost backup list
runsh 80-yh-settings.txt "yunohost settings list 2>/dev/null | head -60"
runsh 80-yh-journal.txt "journalctl -b -1 --no-pager -u yunohost-api -u yunohost-portal -u nginx -u php*-fpm -u mariadb -u postgresql | tail -120"
runsh 80-yh-logs.txt "ls -la /var/log/yunohost/ 2>/dev/null; tail -60 /var/log/yunohost/yunohost-cli.log 2>/dev/null; tail -40 /var/log/yunohost/yunohost-api.log 2>/dev/null"
runsh 80-yh-diag.txt "yunohost diagnosis run 2>&1 | head -80"

# --- 9. rendszerállapot, szolgáltatások ------------------------------------
section "Rendszerállapot"
run 90-failed-units.txt systemctl --failed --no-pager
run 90-all-units.txt systemctl list-units --all --no-pager
runsh 90-restarts.txt "systemctl list-units --all --no-pager | awk '\$4 ~ /failed|auto-restart/'; journalctl -b -1 --no-pager | grep -iE 'Scheduled restart|start request repeated|Failed with result|Main process exited' | tail -60"
runsh 90-ps.txt "ps auxf"
runsh 90-ps-dstate.txt "ps -eo pid,ppid,stat,wchan:32,comm | awk '\$3 ~ /^D/'"
runsh 90-ps-wchan.txt "ps -eo pid,stat,wchan:40,comm --sort=-%mem | head -40"
runsh 90-ss.txt "ss -tulpn"
runsh 90-lsof-deleted.txt "lsof +L1 2>/dev/null | head -20"
runsh 90-file-descriptors.txt "cat /proc/sys/fs/file-nr; ulimit -a"
runsh 90-network.txt "ip -br a; ip r; cat /etc/resolv.conf"
runsh 90-entropy.txt "cat /proc/sys/kernel/random/entropy_avail"
runsh 90-kernel-taint.txt "cat /proc/sys/kernel/tainted; journalctl -k -b -1 --no-pager | grep -iE 'taint|module verification|out-of-tree' | tail -20"

# --- 10. fekete doboz -------------------------------------------------------
section "Fekete doboz napló"
runsh 95-blackbox-tail.txt "tail -400 /var/log/yh-blackbox.log 2>/dev/null"
runsh 95-blackbox-stats.txt "awk '{print}' /var/log/yh-blackbox.log 2>/dev/null | wc -l; ls -la /var/log/yh-blackbox.log 2>/dev/null"

# Load-csúcsok a fekete dobozból — a watchdog max-load küszöbéhez viszonyítva
runsh 95-blackbox-loadpeaks.txt "if [ -f /var/log/yh-blackbox.log ]; then awk '{n=split(\$0,a,\"load=\"); if(n<2)next; split(a[2],b,\" \"); split(b[1],c,\"/\"); if(c[1]+0>m1)m1=c[1]+0; if(c[2]+0>m5)m5=c[2]+0; if(c[3]+0>m15)m15=c[3]+0} END{printf \"load1_max=%.2f load5_max=%.2f load15_max=%.2f\\n\", m1,m5,m15}' /var/log/yh-blackbox.log; else echo 'nincs /var/log/yh-blackbox.log'; fi"
runsh 95-blackbox-topload.txt "awk '{n=split(\$0,a,\"load=\"); if(n<2)next; split(a[2],b,\" \"); split(b[1],c,\"/\"); printf \"%s %s\n\", c[1], \$0}' /var/log/yh-blackbox.log 2>/dev/null | sort -rn | head -8 | cut -c1-260"
runsh 95-journald-config.txt "cat /etc/systemd/journald.conf 2>/dev/null; ls -la /var/log/journal 2>/dev/null | head; du -sh /var/log/journal 2>/dev/null; journalctl --disk-usage"
runsh 95-log2ram.txt "systemctl status log2ram --no-pager 2>&1 | head -15; cat /etc/log2ram.conf 2>/dev/null"

# --- 11. környezet: hőmérséklet, áram, UPS --------------------------------
section "Környezet"
runsh 96-ups.txt "upsc -l 2>/dev/null; for u in \$(upsc -l 2>/dev/null); do upsc \$u 2>/dev/null | head -30; done"
runsh 96-nut.txt "systemctl status nut-monitor --no-pager 2>&1 | head -15"
runsh 96-last-reboots.txt "journalctl --no-pager | grep -iE 'Linux version|Command line' | tail -20"

# --- csomagolás -------------------------------------------------------------
section "Csomagolás"
if [ -z "$OUTFILE" ]; then
    mkdir -p "$OUTDIR"
    OUTFILE="$OUTDIR/yh-diag-$HOST-$STAMP.tar.gz"
fi
mkdir -p "$(dirname "$OUTFILE")" 2>/dev/null

# Rövid összefoglaló a csomagba
{
    echo "YunoHost diagnosztikai csomag"
    echo "host: $HOST"
    echo "dátum: $(date -Is)"
    echo "kernel: $(uname -r)"
    echo "uptime: $(uptime -p 2>/dev/null)"
    echo
    echo "Fájlok:"
    ls -la "$D" | awk 'NR>1{print "  " $9 " (" $5 " byte)"}'
} >"$D/README.txt"

tar -czf "$OUTFILE" -C "$WORK" "yh-diag-$STAMP" 2>/dev/null
rc=$?
if [ $rc -eq 0 ] && [ -s "$OUTFILE" ]; then
    echo
    echo "Kész: $OUTFILE ($(du -h "$OUTFILE" | cut -f1))"
    echo "Elemzés:  yh-analyze.sh $OUTFILE"
    exit 0
else
    echo "HIBA: a csomagolás nem sikerült (rc=$rc). A nyers könyvtár: $D" >&2
    trap - EXIT
    exit 1
fi
