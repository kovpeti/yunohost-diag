#!/bin/bash
# yh-blackbox.sh — percenkénti állapotpillanatkép egy sima szöveges fájlba.
# Célja: a fagyás/újraindulás ELŐTTI utolsó állapot túlélje a rebootot.
# Formátum: egy sor = egy minta, key=value párok, awk/grep-barát.
#
# Használat:  yh-blackbox.sh [kimeneti fájl]
# Alapértelmezett: /var/log/yh-blackbox.log

set -uo pipefail

LOG="${1:-${YH_BLACKBOX_LOG:-/var/log/yh-blackbox.log}}"

# Ha nem írható a célkönyvtár, essünk vissza /tmp-re (ne haljon meg némán)
if ! { mkdir -p "$(dirname "$LOG")" 2>/dev/null && : >>"$LOG" 2>/dev/null; }; then
    LOG="/tmp/yh-blackbox.log"
    : >>"$LOG" 2>/dev/null || exit 0
fi

# --- egyszerű segédek -------------------------------------------------------
kv() { printf '%s=%s ' "$1" "$2"; }

# Egy értéket ad vissza egy /proc/pressure fájl megadott sorából.
# Ha a kernel nem támogatja a PSI-t (nincs /proc/pressure), "-" lesz.
psi_val() {  # $1=cpu|io|memory  $2=some|full  $3=avg10
    local v
    v=$(awk -v s="$2" -v k="$3" '$1==s{for(i=2;i<=NF;i++){split($i,a,"="); if(a[1]==k){print a[2]; exit}}}' \
        "/proc/pressure/$1" 2>/dev/null)
    printf '%s' "${v:--}"
}

# --- minta összeállítása ----------------------------------------------------
line=""
line+="ts=$(date -Is) "
line+="uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null) "

# load és processz-számok (a 4. mező "futó/összes" formátumú)
read -r l1 l5 l15 runtot lastpid < /proc/loadavg 2>/dev/null || true
runprocs="${runtot%%/*}"; totprocs="${runtot##*/}"
line+="load=${l1:-?}/${l5:-?}/${l15:-?} "
line+="procs=${runprocs:-?}/${totprocs:-?} "

# memória / swap (MB)
memline=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2} \
    END{printf "memtotal=%d memavail=%d swapused=%d swaptotal=%d", t/1024, a/1024, (st-sf)/1024, st/1024}' \
    /proc/meminfo 2>/dev/null)
line+="$memline "

# PSI — ez a legjobb előjel a "mindjárt megfagy" állapotra
line+="psi_cpu=$(psi_val cpu some avg10) "
line+="psi_io=$(psi_val io some avg10) "
line+="psi_io_full=$(psi_val io full avg10) "
line+="psi_mem=$(psi_val memory some avg10) "
line+="psi_mem_full=$(psi_val memory full avg10) "

# D állapotú (megakadt) processzek — I/O vagy driver beragadás jele.
# Egy ps hívásból számolunk, hogy a két érték konzisztens legyen.
psout=$(ps -eo stat=,comm= 2>/dev/null)
dstate=$(printf '%s\n' "$psout" | awk '$1 ~ /^D/{n++} END{print n+0}')
line+="dstate=${dstate:-0} "
dnames=$(printf '%s\n' "$psout" | awk '$1 ~ /^D/{print $2}' | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s:%s,", $2, $1}')
line+="dnames=${dnames:--} "

# Legnagyobb memóriafogyasztók (top 3)
topmem=$(ps -eo rss=,comm= 2>/dev/null | sort -rn | head -3 | awk '{printf "%s:%dMB,", $2, $1/1024}')
line+="topmem=${topmem:--} "

# CPU-t eszik-e valami éppen (top 3)
topcpu=$(ps -eo pcpu=,comm= 2>/dev/null | sort -rn | head -3 | awk '{printf "%s:%s%%,", $2, $1}')
line+="topcpu=${topcpu:--} "

# Gyökér fájlrendszer tele van? (tele lemez = fagyás tünet)
read -r rootuse rootavail < <(df -P / 2>/dev/null | awk 'NR==2{print $5, $4}')
line+="root=${rootuse:-?} rootfree=${rootavail:-?}KB "

# Hőmérséklet, ha van szenzor
temp="-"
if command -v sensors >/dev/null 2>&1; then
    temp=$(sensors 2>/dev/null | grep -oE '[+-][0-9]+\.[0-9]+°C' | tr -d '+' | sort -rn | head -1)
    [ -n "$temp" ] || temp="-"
elif [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    temp="$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))C"
fi
line+="temp=${temp} "

# Kernel utolsó figyelmeztetései (OOM, I/O hiba, lockup) — rövid jelzés
flags=""
if dmesg 2>/dev/null | tail -n 200 | grep -qiE 'out of memory|oom-kill'; then flags+="OOM,"; fi
if dmesg 2>/dev/null | tail -n 200 | grep -qiE 'i/o error|failed command|medium error|reset failed'; then flags+="IOERR,"; fi
if dmesg 2>/dev/null | tail -n 200 | grep -qiE 'soft lockup|hard lockup|hung task'; then flags+="LOCKUP,"; fi
if dmesg 2>/dev/null | tail -n 200 | grep -qiE 'machine check|hardware error|mce:'; then flags+="MCE,"; fi
if dmesg 2>/dev/null | tail -n 200 | grep -qiE 'remount.*read-only|ext4-fs error|xfs.*corrupt'; then flags+="FSERR,"; fi
line+="flags=${flags:--}"

# Egyetlen atomi írás — így nem lesz fél sor a fagyás pillanatában
printf '%s\n' "$line" >>"$LOG"

# Egyszerű méretkorlát: 20 000 sor (~2 hét percenkénti minta) felett felezzük
if [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 20000 ]; then
    tail -n 10000 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

exit 0
