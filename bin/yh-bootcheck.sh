#!/bin/bash
# yh-bootcheck.sh — boot után eldönti, hogy az előző leállás tiszta volt-e,
# és ha nem, automatikusan lement egy diagnosztikai csomagot.
#
# Ezt a yh-bootcheck.service futtatja minden boot után.
# Kimenet: /var/log/yh-diag/crash-<host>-<időbélyeg>.tar.gz
#          + /var/log/yh-diag/crash-history.log (egy sor / esemény)

set -uo pipefail

OUTDIR="/var/log/yh-diag"
HIST="$OUTDIR/crash-history.log"
mkdir -p "$OUTDIR" 2>/dev/null || OUTDIR="/tmp/yh-diag"
HIST="$OUTDIR/crash-history.log"

log() { echo "$(date -Is) $*" >>"$HIST" 2>/dev/null; logger -t yh-bootcheck "$*" 2>/dev/null; }

# --- előző boot létezik-e egyáltalán? --------------------------------------
PREV_ID=$(journalctl --list-boots --no-pager -o json 2>/dev/null | \
    python3 -c 'import sys,json
ids=[]
for ln in sys.stdin:
    ln=ln.strip()
    if not ln: continue
    try: ids.append(json.loads(ln)["boot_id"])
    except Exception: pass
print(ids[-2] if len(ids)>=2 else "")' 2>/dev/null)

if [ -z "$PREV_ID" ]; then
    log "nincs előző boot a naplóban (perzisztens journald még nem volt bekapcsolva?) — kihagyva"
    exit 0
fi

# --- tiszta leállás nyomai? ------------------------------------------------
MARKERS=$(journalctl -b "$PREV_ID" --no-pager -o cat 2>/dev/null | \
    grep -iE 'systemd-shutdown|Reached target (Shutdown|Power-Off|Reboot|Final Step)|Shutting down' | tail -3)

# előző boot hossza és vége
PREV_END=$(journalctl -b "$PREV_ID" --no-pager -o short-precise -n 1 2>/dev/null | cut -c1-40)
PREV_START=$(journalctl -b "$PREV_ID" --no-pager -o short-precise 2>/dev/null | head -1 | cut -c1-40)

if [ -n "$MARKERS" ]; then
    log "előző leállás TISZTA ($PREV_ID, $PREV_START → $PREV_END) — nincs teendő"
    exit 0
fi

# --- tisztátlan: gyűjtés ---------------------------------------------------
log "előző leállás TISZTÁTLAN ($PREV_ID, kezdet: $PREV_START, utolsó sor: $PREV_END) — csomag gyűjtése"

STAMP=$(date +%Y%m%d-%H%M%S)
HOST=$(hostname -s 2>/dev/null || echo host)
OUT="$OUTDIR/crash-$HOST-$STAMP.tar.gz"

# Az előző boot utolsó sorait külön is mentsük el azonnal (a legfontosabb nyom)
{
    echo "=== előző boot: $PREV_ID ==="
    echo "=== kezdet: $PREV_START  utolsó sor: $PREV_END ==="
    echo "=== utolsó 120 sor ==="
    journalctl -b "$PREV_ID" --no-pager -o short-precise -n 120 2>/dev/null
    echo
    echo "=== kernel utolsó 120 sor ==="
    journalctl -k -b "$PREV_ID" --no-pager -o short-precise -n 120 2>/dev/null
} >"$OUTDIR/last-crash-tail.txt" 2>/dev/null

# Teljes csomag (a gyűjtő lehet, hogy még nincs telepítve — akkor csak a tail marad)
COLLECT="$(dirname "$0")/yh-collect.sh"
if [ -x "$COLLECT" ]; then
    "$COLLECT" -o "$OUT" -b 3 >>"$OUTDIR/collect.log" 2>&1 || true
    log "csomag: $OUT ($(du -h "$OUT" 2>/dev/null | cut -f1))"
else
    log "yh-collect.sh nem található — csak a last-crash-tail.txt készült el"
fi

exit 0
