#!/bin/bash
# yh-analyze.sh — a diagnosztikai csomag (vagy az élő rendszer) kiértékelése.
#
# Használat:
#   yh-analyze.sh                          # élő rendszer elemzése
#   yh-analyze.sh /var/log/yh-diag/x.tar.gz
#   yh-analyze.sh /tmp/yh-diag-20240101-1200/
#
# Kimenet: magyar nyelvű, súlyozott ítélet + a bizonyítékok sora.

set -uo pipefail

SRC="${1:-}"
TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# --- forrás megnyitása ------------------------------------------------------
if [ -n "$SRC" ]; then
    if [ -d "$SRC" ]; then
        D="$SRC"
        # ha a tarball tartalmának gyökere egyetlen alkönyvtár, lépjünk bele
        if [ ! -f "$D/00-meta.txt" ]; then
            inner=$(find "$D" -maxdepth 2 -name 00-meta.txt -printf '%h\n' 2>/dev/null | head -1)
            [ -n "$inner" ] && D="$inner"
        fi
    elif [ -f "$SRC" ]; then
        TMP=$(mktemp -d /tmp/yh-an.XXXXXX) || exit 1
        tar -xzf "$SRC" -C "$TMP" 2>/dev/null || { echo "Nem tudom kicsomagolni: $SRC" >&2; exit 1; }
        D=$(find "$TMP" -maxdepth 2 -name 00-meta.txt -printf '%h\n' | head -1)
        [ -z "$D" ] && D="$TMP"
    else
        echo "Nincs ilyen fájl/könyvtár: $SRC" >&2; exit 1
    fi
    MODE="csomag"
else
    D=""
    MODE="élő rendszer"
fi

# --- segédek ----------------------------------------------------------------
BOLD=""; DIM=""; RED=""; YEL=""; GRN=""; NC=""
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; NC=$'\033[0m'
fi

# getfile <minta> — a legjobban illeszkedő fájl tartalmát adja (élő módban üres)
getfile() {
    [ -z "$D" ] && return 0
    local f
    f=$(ls "$D"/$1 2>/dev/null | head -1)
    [ -n "$f" ] && cat "$f" 2>/dev/null
}

# get_or_live <fájlminta> <parancs...> — csomagból fájlt, élő módban parancsot
get_or_live() {
    local f="$1"; shift
    if [ -n "$D" ]; then getfile "$f"; else "$@" 2>/dev/null; fi
}

# Az élő módhoz: ugyanazok a lekérdezések, csak közvetlenül
live_journal_prev() { journalctl -k -b -1 --no-pager -o short-precise 2>/dev/null; }
live_journal_all()  { journalctl --no-pager 2>/dev/null; }

# src <fájlminta> <élő-parancs-függvény> — egységes forrás
src() {
    if [ -n "$D" ]; then getfile "$1"; else $2; fi
}

# prevsrc <fájl-prefix> <élő-parancs-függvény> — az ELŐZŐ boot fájlját célozza
# (a collect a -1 utótaggal menti az eggyel korábbi bootot). Nincs találgatás:
# ha nincs -1-es fájl, üres az eredmény.
prevsrc() {
    local pre="$1" livefn="$2" f
    if [ -z "$D" ]; then $livefn; return; fi
    f=$(ls "$D/$pre-1.txt" 2>/dev/null | head -1)
    [ -n "$f" ] && cat "$f" 2>/dev/null
}

# csak a tényleges kimenet, a "### CMD/SH/DATE/EXIT" fejlécek és a journal
# "nincs ilyen boot" jellegű zajsorai nélkül
body() {
    grep -vE '^###|^Data from the specified boot|^-- No entries --|^No journal files were found|^Hint: You are currently not seeing' 2>/dev/null
}

# hit <cím> <súly> <regex> <fájlminta> <élő-függvény> [max sor]
# Kiírja a találatokat és hozzáadja a súlyt a globális SCORE-hoz.
SCORE=0
declare -a FINDINGS=()
hit() {
    local title="$1" weight="$2" re="$3" pat="$4" livefn="$5" maxl="${6:-6}"
    local out n
    out=$(src "$pat" "$livefn" | body | grep -iE "$re" 2>/dev/null)
    n=$(printf '%s' "$out" | grep -c . 2>/dev/null)
    n=${n:-0}
    if [ "${n:-0}" -gt 0 ]; then
        SCORE=$((SCORE + weight))
        FINDINGS+=("$weight|$title|$n")
        printf '\n%s● %s%s  %s(%s találat, súly %s)%s\n' "$BOLD" "$title" "$NC" "$DIM" "$n" "$weight" "$NC"
        printf '%s\n' "$out" | head -n "$maxl" | sed 's/^/    /' | cut -c1-220
        [ "$n" -gt "$maxl" ] && printf '    %s… és további %s sor%s\n' "$DIM" "$((n - maxl))" "$NC"
    fi
}

# --- fejléc -----------------------------------------------------------------
echo "${BOLD}========================================================${NC}"
echo "${BOLD} YunoHost fagyás-diagnosztika — ${MODE}${NC}"
echo "${BOLD}========================================================${NC}"
if [ -n "$D" ]; then
    echo "${DIM}Forrás: $D${NC}"
    sed -n '1,12p' "$D/00-meta.txt" 2>/dev/null | sed 's/^/  /'
    echo
fi

# --- 1. Tiszta vagy tisztátlan leállás? -------------------------------------
echo
echo "${BOLD}1) Hogyan ért véget az előző boot?${NC}"
# Van-e egyáltalán előző boot az adatforrásban?
PREV_EXISTS=1
if [ -n "$D" ]; then
    ls "$D"/13-boot-end-1.txt >/dev/null 2>&1 || PREV_EXISTS=0
else
    journalctl -b -1 -n 1 >/dev/null 2>&1 || PREV_EXISTS=0
fi

ENDLOG=$(prevsrc "13-boot-end" live_journal_prev)
MARKERS=$(prevsrc "14-shutdown-markers" live_journal_prev)
LASTLINES=$(printf '%s' "$ENDLOG" | body | grep -v '^$' | tail -6)

CLEAN=0
# Szigorú minta: csak a PID 1 (rendszer) leállási sorai számítanak.
# Egy user-session systemd[X] is elérhet shutdown.target-et — az NEM rendszerleállás.
SHUT_RE='systemd-shutdown|systemd\[1\]: (Reached target (Shutdown|Power-Off|Reboot|Final Step)|Shutting down)|kernel: reboot: (Power down|Restarting system)'
if printf '%s' "$MARKERS" | body | grep -qiE "$SHUT_RE"; then
    CLEAN=1
fi
# --- watchdog soft reboot felismerése --------------------------------------
# A watchdog daemon hiba esetén MAGA állítja le a gépet: SIGTERM/SIGKILL,
# partíciók leválasztása, root read-only, majd reboot(). A systemd
# shutdown-szekvenciája ilyenkor NEM fut le, tehát a napló pont úgy néz ki,
# mint egy fagyásnál. Az ujjlenyomat: a daemon a wtmp-ba ír egy "shutdown"
# bejegyzést (a hardveres reset nem tesz ilyet).

# load-csúcsok a fekete dobozból
peaks_from() {
    awk '{n=split($0,a,"load="); if(n<2)next; split(a[2],b," "); split(b[1],c,"/");
          if(c[1]+0>m1)m1=c[1]+0; if(c[2]+0>m5)m5=c[2]+0; if(c[3]+0>m15)m15=c[3]+0}
         END{if(m1=="" && m5=="" && m15==""){print ""} else printf "%.2f %.2f %.2f\n", m1,m5,m15}' "$1" 2>/dev/null
}
PEAKS=""
if [ -n "$D" ]; then
    # a gyűjtő külön kiszámolt csúcsfájlt is ment — ez a pontosabb
    PEAKF=$(ls "$D"/95-blackbox-loadpeaks.txt 2>/dev/null | head -1)
    if [ -n "$PEAKF" ] && grep -q 'load1_max=' "$PEAKF" 2>/dev/null; then
        PEAKS=$(body <"$PEAKF" | grep -o 'load1_max=[0-9.]* load5_max=[0-9.]* load15_max=[0-9.]*' \
            | sed 's/load1_max=//; s/load5_max=//; s/load15_max=//' | head -1)
    fi
    if [ -z "$PEAKS" ]; then
        BBLOG=$(ls "$D"/95-blackbox-tail.txt 2>/dev/null | head -1)
        [ -n "$BBLOG" ] && [ -s "$BBLOG" ] && PEAKS=$(peaks_from "$BBLOG")
    fi
else
    [ -s /var/log/yh-blackbox.log ] && PEAKS=$(peaks_from /var/log/yh-blackbox.log)
fi
read -r PEAK1 PEAK5 PEAK15 <<<"${PEAKS:-}"

# watchdog.conf
WD_CONF=$(get_or_live "20-watchdog-conf.txt" cat /etc/watchdog.conf | body)
conf_val() {
    printf '%s\n' "$WD_CONF" | grep -E "^[[:space:]]*$1[[:space:]]*=" | tail -1 \
        | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]'
}
ML1=$(conf_val max-load-1); ML5=$(conf_val max-load-5); ML15=$(conf_val max-load-15)
ML1=${ML1:-0}; ML5=${ML5:-0}; ML15=${ML15:-0}
# a man page szerint a hiányzó 5/15 perces limit a max-load-1-ből számolódik
DERIVED=""
if [ "$ML1" != "0" ] && [ -n "$ML1" ]; then
    [ "$ML5" = "0" ] && ML5=$(awk -v m="$ML1" 'BEGIN{printf "%.1f", m*3/4}')
    [ "$ML15" = "0" ] && ML15=$(awk -v m="$ML1" 'BEGIN{printf "%.1f", m/2}')
    DERIVED="igen"
fi

# wtmp: van-e shutdown-bejegyzés?
WTMP=$(get_or_live "10-wtmp-shutdowns.txt" bash -c "last -x -F 2>/dev/null | grep -iE 'shutdown|reboot'" | body)
WTMP_DOWN=$(printf '%s\n' "$WTMP" | grep -ciE 'system down')
WTMP_LAST=$(printf '%s\n' "$WTMP" | grep -iE 'system down' | head -2)

# watchdog daemon naplója
WD_LOG=$(get_or_live "20-watchdog-daemon-journal.txt" journalctl -u watchdog --no-pager 2>/dev/null | body)
WD_SYS=$(get_or_live "20-watchdog-syslog.txt" journalctl -t watchdog --no-pager 2>/dev/null | body)
WD_LOADMSG=$(printf '%s\n%s\n' "$WD_LOG" "$WD_SYS" | grep -iE 'load average|max-load|maximum load|too high|reboot|shutdown|halt' | head -8)

WD_SOFT=0
if [ "$CLEAN" -eq 0 ] && [ "${WTMP_DOWN:-0}" -gt 0 ]; then
    WD_SOFT=1
fi

if [ "$PREV_EXISTS" -eq 0 ] || [ -z "$(printf '%s' "$ENDLOG" | body | grep -v '^$')" ]; then
    if [ -n "$D" ]; then
        echo "  ${YEL}A csomagban nincs előző boot naplója.${NC}"
        echo "  Ez általában azt jelenti, hogy a gyűjtéskor még nem volt perzisztens"
        echo "  journald, vagy ez volt az első boot a napló bekapcsolása óta."
    else
        echo "  ${YEL}Nincs adat az előző bootról.${NC} Valószínűleg nincs perzisztens journald"
        echo "  (a napló rebootkor elveszik). Ezt először javítani kell — lásd install.sh."
    fi
    CLEAN=-1
elif [ "$CLEAN" -eq 1 ]; then
    echo "  ${GRN}Tiszta leállás nyomai láthatók${NC} (systemd-shutdown / Reached target Shutdown)."
    echo "  → Ez inkább ${BOLD}szándékos reboot${NC} volt (frissítés, cron, apt), nem fagyás."
    echo "  Utolsó sorok:"
    printf '%s\n' "$LASTLINES" | sed 's/^/    /' | cut -c1-200
elif [ "$WD_SOFT" -eq 1 ]; then
    echo "  ${YEL}Nincs systemd shutdown-szekvencia, DE van wtmp shutdown-bejegyzés.${NC}"
    echo "  → ${BOLD}Ez watchdog daemon soft reboot${NC}, nem hardveres fagyás."
    echo "  A watchdog hiba esetén maga állítja le a gépet, ezért nem fut le a"
    echo "  systemd leállási sora — a napló emiatt néz ki fagyásnak."
    echo "  wtmp bejegyzés(ek):"
    printf '%s\n' "$WTMP_LAST" | sed 's/^/    /' | cut -c1-180
    SCORE=$((SCORE + 3))
    FINDINGS+=("3|Watchdog daemon soft reboot (nem fagyás)|1")
else
    echo "  ${RED}Nincs tiszta leállásra utaló nyom, és nincs wtmp shutdown-bejegyzés sem.${NC}"
    echo "  → ${BOLD}Ez valódi fagyás / hard reset / áramkimaradás.${NC}"
    SCORE=$((SCORE + 2))
    FINDINGS+=("2|Tisztátlan leállás (nincs shutdown szekvencia)|1")
fi
if [ "$CLEAN" -ne 1 ] && [ -n "$(printf '%s' "$LASTLINES" | tr -d '[:space:]')" ]; then
    echo "  Utolsó sorok a leállás előtt:"
    printf '%s\n' "$LASTLINES" | sed 's/^/    /' | cut -c1-200
fi

# --- 1b. Load-elemzés a watchdog küszöbéhez --------------------------------
if [ -n "$PEAKS" ] || [ -n "$WD_CONF" ]; then
    echo
    echo "  ${DIM}Load-elemzés (watchdog max-load küszöbök):${NC}"
    if printf '%s' "$WD_CONF" | grep -qE 'watchdog-device|max-load|watchdog-timeout'; then
        if [ "$ML1" = "0" ] || [ -z "$ML1" ]; then
            echo "    max-load-1 = 0 → a load-alapú újraindítás ${GRN}kikapcsolva${NC}."
        else
            echo "    max-load-1 = ${ML1}   → ebből számolva max-load-5 = ${ML5}, max-load-15 = ${ML15}"
            [ -n "$DERIVED" ] && echo "    ${DIM}(a fájlban nem szereplő 5/15 perces limit a man page szerint automatikusan számolódik)${NC}"
        fi
    fi
    if [ -n "$PEAKS" ]; then
        echo "    mért csúcsok: load1=${PEAK1}  load5=${PEAK5}  load15=${PEAK15}"
        if [ "$ML1" != "0" ] && [ -n "$ML1" ]; then
            over=$(awk -v p1="${PEAK1:-0}" -v p5="${PEAK5:-0}" -v p15="${PEAK15:-0}" \
                       -v m1="$ML1" -v m5="$ML5" -v m15="$ML15" \
                       'BEGIN{ if(p1>=m1||p5>=m5||p15>=m15) print "igen"; else print "nem" }')
            if [ "$over" = "igen" ]; then
                echo "    ${RED}● A mért load ÁTLÉPTE a küszöböt — a watchdog ezért indíthatott újra.${NC}"
                SCORE=$((SCORE + 4))
                FINDINGS+=("4|Load átlépte a watchdog max-load küszöböt|1")
            else
                echo "    ${GRN}● A mért load nem érte el a küszöböt.${NC}"
            fi
        fi
    else
        echo "    ${DIM}(nincs fekete doboz minta — a load-csúcs nem ellenőrizhető)${NC}"
    fi
    if [ -n "$WD_LOADMSG" ]; then
        echo "    watchdog daemon naplója:"
        printf '%s\n' "$WD_LOADMSG" | sed 's/^/      /' | cut -c1-190
    fi
fi

# --- 2. OOM ----------------------------------------------------------------
echo
echo "${BOLD}2) Memória / OOM${NC}"
hit "OOM killer aktiválódott" 5 'out of memory|oom-kill|killed process|oom_reaper' '30-oom-journal.txt' live_journal_prev 8
hit "Korábbi OOM események (teljes napló)" 3 'oom-kill|Out of memory: Killed' '30-oom-all.txt' live_journal_all 5

# --- 3. I/O és lemezhibák --------------------------------------------------
echo
echo "${BOLD}3) Lemez / I/O hibák${NC}"
hit "I/O hibák, ATA/NVMe reset, medium error" 5 'i/o error|critical medium error|failed command|Buffer I/O error|blk_update_request|reset failed|link is slow|SMART' '40-io-errors.txt' live_journal_prev 8
hit "Fájlrendszer hibák / read-only remount" 5 'ext4-fs error|EXT4-fs.*(error|warning)|xfs.*(corrupt|error)|btrfs.*(error|corrupt)|remount.*read-only|metadata I/O error' '40-fs-errors.txt' live_journal_prev 6
hit "Beragadt (blokkolt) I/O műveletek" 4 'blocked for more than|task .* blocked|hung_task' '40-blocked.txt' live_journal_prev 6

# SMART összegzés
SMART=$(getfile "40-smart-all.txt")
if [ -n "$SMART" ]; then
    if printf '%s' "$SMART" | grep -qiE 'FAILED!|SMART overall-health self-assessment test result: FAILED'; then
        echo "  ${RED}● SMART: a lemez FAILED állapotban van!${NC}"
        SCORE=$((SCORE + 8)); FINDINGS+=("8|SMART FAILED|1")
    fi
    if printf '%s' "$SMART" | grep -qiE 'Reallocated_Sector_Ct.*[1-9]|Current_Pending_Sector.*[1-9]|Offline_Uncorrectable.*[1-9]|Media and Data Integrity Errors.*[1-9]'; then
        echo "  ${RED}● SMART: újrapozicionált / függő szektorok vannak (lemez kopás).${NC}"
        printf '%s' "$SMART" | grep -iE 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Media and Data Integrity Errors' | head -6 | sed 's/^/    /'
        SCORE=$((SCORE + 5)); FINDINGS+=("5|SMART: rossz szektorok|1")
    fi
    if printf '%s' "$SMART" | grep -qiE 'UDMA_CRC_Error_Count.*[1-9]|CRC_Error_Count.*[1-9]'; then
        echo "  ${YEL}● SMART: UDMA CRC hibák — gyakori a rossz SATA kábel!${NC}"
        SCORE=$((SCORE + 3)); FINDINGS+=("3|SATA CRC hibák (kábel?)|1")
    fi
fi

# --- 4. Lockup / hung task -------------------------------------------------
echo
echo "${BOLD}4) Kernel lockup / beragadt feladat${NC}"
hit "Soft/hard lockup, hung task" 5 'soft lockup|hard LOCKUP|BUG: soft|hung task|watchdog: BUG' '20-watchdog-hardlockup.txt' live_journal_prev 6
hit "Kernel panic / Oops / Call Trace" 6 'Kernel panic|Oops|BUG:|general protection fault|unable to handle|RIP:' '60-panic-journal.txt' live_journal_all 8

# --- 5. Hardver: MCE, hő ---------------------------------------------------
echo
echo "${BOLD}5) Hardverhibák (MCE, hő, throttling)${NC}"
hit "Machine Check / EDAC / Hardware Error" 7 'machine check|mce:|Hardware Error|EDAC.*error|Corrected error' '50-mce.txt' live_journal_all 8
hit "Hőmérsékleti / throttling események" 3 'cpu clock throttled|thermal.*(critical|trip)|Core temperature.*above' '50-throttling.txt' live_journal_all 5

# EDAC számlálók
EDAC=$(getfile "50-edac.txt")
if [ -n "$EDAC" ]; then
    ce=$(printf '%s' "$EDAC" | grep -oE 'ce_count=[0-9]+' | cut -d= -f2 | sort -rn | head -1)
    ue=$(printf '%s' "$EDAC" | grep -oE 'ue_count=[0-9]+' | cut -d= -f2 | sort -rn | head -1)
    if [ "${ue:-0}" -gt 0 ]; then
        echo "  ${RED}● EDAC: ${ue} javíthatatlan memóriahiba (UE) — RAM hiba!${NC}"
        SCORE=$((SCORE + 8)); FINDINGS+=("8|EDAC uncorrected memóriahiba|1")
    elif [ "${ce:-0}" -gt 0 ]; then
        echo "  ${YEL}● EDAC: ${ce} javított memóriahiba (CE) — RAM öregszik, figyelni kell.${NC}"
        SCORE=$((SCORE + 3)); FINDINGS+=("3|EDAC corrected memóriahiba|1")
    fi
fi

# --- 6. Watchdog -----------------------------------------------------------
echo
echo "${BOLD}6) Watchdog${NC}"
WD=$(getfile "20-watchdog-config.txt")
if [ -n "$WD" ]; then
    # csak az aktív (nem kikommentelt) beállítások; a grep -r kimenetben
    # a fájlnév után kettőspont áll, ezért a ':#' mintát is szűrjük
    WD_ACTIVE=$(printf '%s\n' "$WD" | body | grep -E 'RuntimeWatchdogSec|RebootWatchdogSec|WatchdogDevice' | grep -vE ':[[:space:]]*#')
    if [ -n "$WD_ACTIVE" ]; then
        printf '%s\n' "$WD_ACTIVE" | head -8 | sed 's/^/  /'
    else
        echo "  ${DIM}(nincs explicit watchdog beállítás — a systemd alapértékei érvényesek)${NC}"
    fi
fi
WDJ=$(getfile "20-watchdog-journal.txt" | body | grep -v '^$')
if [ -n "$WDJ" ]; then
    echo "  Watchdog események az előző bootban:"
    printf '%s\n' "$WDJ" | tail -6 | sed 's/^/    /' | cut -c1-200
fi
WDS=$(getfile "20-watchdog-devices.txt" | body | grep -iE 'timeout|identity|state')
[ -n "$WDS" ] && printf '%s\n' "$WDS" | head -6 | sed 's/^/  /'

# A 'watchdog' csomag daemonja (ez a soft reboot forrása)
if printf '%s' "$WD_CONF" | grep -qE 'watchdog-device|max-load|watchdog-timeout'; then
    echo "  ${DIM}/etc/watchdog.conf (aktív sorok):${NC}"
    printf '%s\n' "$WD_CONF" | grep -vE '^[[:space:]]*(#|$)' | head -12 | sed 's/^/    /'
fi
NOWAYOUT=$(get_or_live "20-watchdog-nowayout.txt" bash -c 'for d in /sys/class/watchdog/*; do echo "$d nowayout=$(cat $d/nowayout 2>/dev/null)"; done' | body)
if printf '%s' "$NOWAYOUT" | grep -q 'nowayout=1'; then
    echo "  ${RED}● nowayout=1: a /dev/watchdog bezárása azonnali resetet okoz.${NC}"
    echo "    ${DIM}→ a 'systemctl restart watchdog' MAGA lesz a következő újraindulás.${NC}"
    SCORE=$((SCORE + 2))
    FINDINGS+=("2|watchdog nowayout=1 (restart = reset)|1")
fi
if [ -n "$WD_LOADMSG" ]; then
    echo "  ${DIM}watchdog daemon üzenetek (load/reboot):${NC}"
    printf '%s\n' "$WD_LOADMSG" | head -6 | sed 's/^/    /' | cut -c1-190
fi

# --- 7. Időzítés: ütemezett-e a fagyás? -----------------------------------
echo
echo "${BOLD}7) Időzítés — ütemezett feladat okozza-e?${NC}"
BBFILE=""
if [ -n "$D" ]; then
    BBFILE="$D/95-blackbox-tail.txt"
else
    BBFILE=$(mktemp /tmp/yh-bb.XXXXXX)
    tail -400 /var/log/yh-blackbox.log >"$BBFILE" 2>/dev/null
    [ -s "$BBFILE" ] || : >"$BBFILE"
fi
if [ -s "$BBFILE" ]; then
    python3 - "$BBFILE" <<'PY' 2>/dev/null
import sys, os, re, datetime
f = sys.argv[1]
lines = []
for ln in open(f, errors='replace'):
    m = re.match(r'ts=(\S+)', ln.strip())
    if m:
        try: lines.append((datetime.datetime.fromisoformat(m.group(1).replace('Z','+00:00')), ln.strip()))
        except Exception: pass
if len(lines) < 3:
    print("  Kevés minta a fekete dobozban (még gyűlik).")
    raise SystemExit
gaps = []
for (t1, _), (t2, _) in zip(lines, lines[1:]):
    dt = (t2 - t1).total_seconds()
    if dt > 180:
        gaps.append((t1, t2, dt))
print(f"  Minták: {len(lines)}  ({lines[0][0]:%Y-%m-%d %H:%M} → {lines[-1][0]:%Y-%m-%d %H:%M})")
if not gaps:
    print("  Nincs 3 percnél nagyobb lyuk a mintákban (a fagyás a napló vége után következett be).")
else:
    print(f"  {len(gaps)} lyuk (>3 perc) — ezek a fagyás/újraindulás pillanatai:")
    for a, b, dt in gaps[-5:]:
        print(f"    {a:%Y-%m-%d %H:%M:%S} → {b:%Y-%m-%d %H:%M:%S}  ({dt/60:.1f} perc kiesés)")
        # az utolsó minta a lyuk előtt: mi volt a helyzet?
        prev = [l for t, l in lines if t == a]
        if prev:
            p = prev[0]
            def g(k):
                m = re.search(k + r'=([^\s]+)', p)
                return m.group(1) if m else '?'
            print(f"      utolsó előtti állapot: load={g('load')} mem={g('memavail')}MB szabad "
                  f"psi_io={g('psi_io')} psi_mem={g('psi_mem')} dstate={g('dstate')} "
                  f"temp={g('temp')} flags={g('flags')}")
            print(f"      legnagyobb processzek: {g('topmem')}")
PY
else
    echo "  Nincs fekete doboz napló (még nem gyűlt adat, vagy nem ez a gép készítette)."
fi

# Rebootok óránkénti eloszlása — ütemezett vagy véletlen?
LASTFILE=""
if [ -n "$D" ]; then
    LASTFILE="$D/10-last.txt"
else
    LASTFILE=$(mktemp /tmp/yh-last.XXXXXX)
    last -x -n 40 >"$LASTFILE" 2>/dev/null
fi
if [ -s "$LASTFILE" ]; then
    python3 - "$LASTFILE" <<'PY' 2>/dev/null
import sys, os, re, collections
f = sys.argv[1]
hours = collections.Counter()
days = set()
for ln in open(f, errors='replace'):
    if re.search(r'\b(reboot|shutdown)\b', ln, re.I):
        m = re.search(r'(\w{3}) (\w{3})\s+(\d+) (\d\d):(\d\d)', ln)
        if m:
            hours[int(m.group(4))] += 1
            days.add((m.group(1), m.group(3), m.group(4)))
if hours:
    total = sum(hours.values())
    top = hours.most_common(3)
    print("  Újraindulások óránkénti eloszlása:", ", ".join(f"{h}:00×{c}" for h, c in sorted(hours.items())))
    if total < 3:
        print(f"  → Csak {total} esemény: még kevés az adat a mintázat megállapításához.")
    elif top[0][1] / total >= 0.5:
        print(f"  → A rebootok többsége {top[0][0]}:00 körül van: erősen ütemezett feladatra utal.")
    else:
        print("  → A rebootok szétszórtan jelentkeznek: inkább hardver/terhelés, mint fix cron.")
    print(f"  Érintett napok: {len(days)}")
PY
fi

# --- 8. Ütemezett feladatok listája ---------------------------------------
echo
echo "${BOLD}8) Miben lehet a bűnös? (ütemezett feladatok)${NC}"
TIMERS=$(get_or_live "70-timers.txt" systemctl list-timers --all --no-pager)
if [ -n "$TIMERS" ]; then
    printf '%s\n' "$TIMERS" | grep -vE '^###|^$' | head -14 | sed 's/^/  /' | cut -c1-190
fi
CRON=$(get_or_live "70-cron.txt" bash -c 'crontab -l 2>&1; echo "--- /etc/cron.d"; ls /etc/cron.d /etc/cron.daily /etc/cron.weekly 2>/dev/null')
if [ -n "$CRON" ]; then
    printf '%s\n' "$CRON" | grep -vE '^###|^$|^---' | head -12 | sed 's/^/  /' | cut -c1-190
fi
APTRB=$(get_or_live "70-apt-reboot.txt" grep -rniE "Automatic-Reboot" /etc/apt/apt.conf.d/)
if printf '%s' "$APTRB" | grep -qiE 'Automatic-Reboot\s+"?true'; then
    echo "  ${YEL}● Az apt Automatic-Reboot be van kapcsolva — az apt magától újraindíthat!${NC}"
    SCORE=$((SCORE + 2)); FINDINGS+=("2|apt Automatic-Reboot aktív|1")
fi

# --- 9. Összefoglaló ítélet -----------------------------------------------
echo
echo "${BOLD}========================================================${NC}"
echo "${BOLD} ÖSSZEFOGLALÓ${NC}"
echo "${BOLD}========================================================${NC}"

if [ ${#FINDINGS[@]} -eq 0 ]; then
    echo "  Nem találtam egyértelmű okot a gyűjtött adatokban."
    echo "  Ez gyakori, ha a fagyás után a napló nem maradt meg, vagy ha a hiba"
    echo "  tiszta hardveres (táp, RAM, alaplap) és semmilyen nyomot nem hagy."
else
    echo "  Találatok súly szerint:"
    printf '%s\n' "${FINDINGS[@]}" | sort -t'|' -k1,1 -rn | awk -F'|' '{printf "    [%s] %s (%s db)\n", $1, $2, $3}'
fi

echo
if [ "$SCORE" -ge 12 ]; then
    VERDICT="${RED}ERŐS OK AZONOSÍTVA${NC}"
elif [ "$SCORE" -ge 6 ]; then
    VERDICT="${YEL}VALÓSZÍNŰ OK VAN${NC}"
elif [ "$SCORE" -ge 1 ]; then
    VERDICT="${YEL}GYENGE JELZÉSEK${NC}"
else
    VERDICT="${DIM}NINCS EGYÉRTELMŰ OK${NC}"
fi
echo "  Összpontszám: ${BOLD}${SCORE}${NC}  →  ${VERDICT}"
echo

# Konkrét következtetés a domináns kategória alapján
if printf '%s\n' "${FINDINGS[@]:-}" | grep -q 'OOM'; then
    echo "  ${BOLD}Teendő:${NC} nézd meg, melyik process ette meg a RAM-ot (30-top-mem.txt),"
    echo "  és tedd rá a memórialimit-et (systemd MemoryMax=) vagy ütemezd át a feladatot."
fi
if printf '%s\n' "${FINDINGS[@]:-}" | grep -qE 'I/O|fájlrendszer|SMART|CRC'; then
    echo "  ${BOLD}Teendő:${NC} cseréld a SATA kábelt / ellenőrizd a lemezt (smartctl -t long),"
    echo "  és nézd meg a 40-io-errors.txt + 40-smart-all.txt fájlokat."
fi
if printf '%s\n' "${FINDINGS[@]:-}" | grep -qE 'MCE|EDAC'; then
    echo "  ${BOLD}Teendő:${NC} memóriateszt (memtest86+, legalább 4 óra), és ha van,"
    echo "  nézd meg a BIOS eseménynaplóját. A RAM/alaplap a gyanús."
fi
if printf '%s\n' "${FINDINGS[@]:-}" | grep -qE 'lockup|panic'; then
    echo "  ${BOLD}Teendő:${NC} a Call Trace-t érdemes bemásolni kereséshez; gyakran driver"
    echo "  vagy fájlrendszer-alrendszer a hunyó. Kapcsold be a pstore/kdump rögzítést."
fi
if printf '%s\n' "${FINDINGS[@]:-}" | grep -qi 'watchdog daemon soft reboot'; then
    echo "  ${BOLD}Teendő:${NC} nem fagyás volt, hanem a watchdog indított újra."
    echo "  A max-load küszöbök a gyanúsak: a hiányzó max-load-5/15 a max-load-1-ből"
    echo "  számolódik (3/4 és 1/2), tehát a tényleges limitek alacsonyabbak, mint amit"
    echo "  a fájlban látsz. Írd ki mindhármat expliciten, vagy nullázd őket:"
    echo "    max-load-1 = 0   max-load-5 = 0   max-load-15 = 0"
    echo "  Előtte: cat /sys/class/watchdog/watchdog0/nowayout  (1 esetén a restart resetet okoz!)"
fi
if printf '%s\n' "${FINDINGS[@]:-}" | grep -qi 'max-load küszöböt'; then
    echo "  ${BOLD}Teendő:${NC} a mért load átlépte a watchdog küszöböt — ezért indult újra a gép."
    echo "  Ha a load a munka miatt magas (backup, scan), emeld a limiteket a valós csúcs fölé,"
    echo "  vagy kapcsold ki a load-tesztet. A load itt tünet, nem ok: keresd meg, mi hajtja fel"
    echo "  (95-blackbox-topload.txt mutatja a legnagyobb load mellett a top processzeket)."
fi
if printf '%s\n' "${FINDINGS[@]:-}" | grep -q 'Tisztátlan'; then
    echo "  ${BOLD}Teendő:${NC} a napló megszakad, tehát a gép nem állt le szépen."
    echo "  Ha a fenti kategóriák üresek, akkor a sorrend: táp → RAM → alaplap,"
    echo "  és közben emeld meg a watchdog timeoutot, hogy ne kapkodjon."
fi

echo
echo "${DIM}Megjegyzés: a watchdog csak egy tüneti eszköz — a fagyás okát nem szünteti meg,${NC}"
echo "${DIM}csak hamarabb újraindít. A fenti elemzés a valódi okot keresi.${NC}"
echo
exit 0
