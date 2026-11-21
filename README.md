# YunoHost fagyás-diagnosztika

Egy kis csomag, ami megválaszolja a kérdést: **miért fagy meg / indul újra a szerver?**

A watchdog csak tüneti kezelés: ha a rendszer megfagy, újraindítja. De nem mondja meg, mi volt a baj. Ez a csomag előre felszereli a „fekete dobozt", hogy a **következő** fagyás pillanatában már legyen bizonyíték — és a boot után egy paranccsal emberi nyelven ki is értékeli.

## Miért kell ez egyáltalán

Alapértelmezésben a systemd journal a RAM-ban (`/run/log/journal`) tárol. Rebootkor ez eltűnik, tehát a fagyás előtti utolsó percek — pont a lényeg — nyom nélkül elvesznek. Ezért a legelső és legfontosabb lépés a perzisztens naplózás bekapcsolása. A telepítő ezt megteszi.

## Telepítés

```bash
# töltsd le / másold fel a szerverre a yunohost-diag könyvtárat, majd:
cd yunohost-diag
sudo ./install.sh

# ha a SMART / hőmérséklet / MCE eszközök is hiányoznak:
sudo ./install.sh --with-pkgs

# előbb csak nézd meg, mit tenne:
sudo ./install.sh --dry-run
```

A telepítő a következőket állítja be:

| Komponens | Mit tesz |
|---|---|
| `journald` drop-in | `Storage=persistent`, 1 GB keret, gyors szinkronizálás |
| `yh-blackbox.timer` | percenként egy soros állapotminta a `/var/log/yh-blackbox.log`-ba |
| `yh-bootcheck.service` | minden boot után megvizsgálja, hogy az előző leállás tiszta volt-e; ha nem, automatikusan gyűjt egy csomagot |
| `sysctl` drop-in | `kernel.panic=10`, `hung_task_timeout_secs=120`, `panic_on_oops=1` |
| `logrotate` | heti rotáció, 8 hét megtartás |

Telepítés után azonnal ellenőrizhető:

```bash
tail -f /var/log/yh-blackbox.log     # percenként nő
systemctl list-timers yh-blackbox.timer
```

## A fekete doboz sora

Egy sor, key=value párokkal, hogy `grep`/`awk`-val is vágható legyen:

```
ts=2024-05-11T03:14:02+02:00 uptime=84120 load=0.42/0.31/0.25 procs=1/212
memtotal=7980 memavail=612 swapused=1840 swaptotal=2048
psi_cpu=2.11 psi_io=47.83 psi_io_full=31.20 psi_mem=0.00 psi_mem_full=0.00
dstate=3 dnames=php:2,mount:1 topmem=mariadbd:1420MB,php-fpm7.4:610MB,nextcloud:220MB
topcpu=mariadbd:88%,php-fpm7.4:12%,systemd:1% root=91%/58G temp=71.0°C flags=IOERR,
```

Mit érdemes nézni benne:

- **`psi_io` / `psi_io_full`** — az I/O-nyomás. Ha ez 40-50 fölé szökik, a lemez a szűk keresztmetszet, és a fagyás szinte biztosan I/O-beragadás.
- **`psi_mem_full`** — ha nem nulla, a rendszer már a memória miatt akadozik (OOM előszoba).
- **`dstate` / `dnames`** — D (uninterruptible) állapotú processzek. Ha itt `mount`, `php` vagy `jbd2` jelenik meg, az I/O-ra váró, megakadt feladat.
- **`memavail`** — 200 MB alatt OOM közeli állapot.
- **`flags`** — a kernel utolsó 200 sorában talált minták: `OOM`, `IOERR`, `LOCKUP`, `MCE`, `FSERR`.
- **`temp`** — 85 °C felett a hő/throttling is okozhat instabilitást.

A naplóban a **lyukak** a legbeszédesebbek: ha a percenkénti minták között 5-10 perc kiesés van, ott történt a fagyás, és a lyuk előtti utolsó sor mutatja az állapotot közvetlenül előtte.

## Használat

```bash
# a következő tisztátlan leállás után automatikusan keletkezik:
ls -la /var/log/yh-diag/
# crash-hostname-20240511-031502.tar.gz  + last-crash-tail.txt

# elemzés:
sudo yh-analyze.sh /var/log/yh-diag/crash-*.tar.gz

# vagy élő rendszeren, csomag nélkül:
sudo yh-analyze.sh

# kézi gyűjtés + elemzés:
sudo yh-collect.sh
sudo yh-analyze.sh /var/log/yh-diag/yh-diag-*.tar.gz
```

Az elemző súlyozott pontszámot ad, és felsorolja a találatokat a bizonyítékokkal együtt. Nem varázslat: azt mondja meg, **melyik kategóriában van nyom**, és mit nézz tovább.

## Mit tartalmaz a csomag

| Fájl | Tartalom |
|---|---|
| `00-*` | gép, BIOS, RAM modulok, CPU, PCI, blokkeszközök |
| `10-*` | bootok listája, `last`, shutdown-idővonal |
| `11-14-*` | az utolsó 3 boot teljes journalja + kernel log + a boot **vége** |
| `20-*` | watchdog eszköz, timeout, systemd beállítás, lockup-ok, **`watchdog.conf`, a daemon naplója, nowayout** |
| `30-*` | memória, swap, zram, PSI, OOM kill-ek, top fogyasztók |
| `40-*` | I/O hibák, fájlrendszer hibák, SMART, NVMe, mdraid, LVM |
| `50-*` | MCE/EDAC, hőmérséklet, throttling, tápegység (DMI) |
| `60-*` | panic, Oops, pstore, /var/crash, kdump, coredump |
| `70-*` | cron, timerek, apt history, unattended-upgrades, Automatic-Reboot |
| `80-*` | YunoHost verzió, appok, szolgáltatások, backupok, YH logok |
| `90-*` | failed unitok, processzek, D-state, socketek, taint |
| `95-*` | fekete doboz napló, **load-csúcsok és top-load processzek**, journald konfiguráció, log2ram |
| `96-*` | UPS/NUT, rebootok története |

## Hogyan olvasd az eredményt — döntési fa

**1. Tiszta vagy tisztátlan volt a leállás?**
Ha az elemző „nincs tiszta leállásra utaló nyom"-ot ír, akkor a gép nem állt le szépen: fagyás, hard reset vagy áramkimaradás. Ha ott van a `systemd-shutdown` sor, akkor valami *szándékosan* indította újra — ilyenkor a 70-es csoportot nézd (apt, cron, timer).

**1b. Watchdog soft reboot — a legfontosabb csapda.**
A `watchdog` csomag daemonja hiba esetén **maga** állítja le a gépet: SIGTERM/SIGKILL, partíciók leválasztása, root read-only, majd `reboot()`. A systemd shutdown-szekvenciája ilyenkor **nem fut le**, tehát a napló pontosan úgy néz ki, mint egy fagyásnál — nincs `systemd-shutdown`, nincs `Reached target Shutdown`. Az elemző ezért külön megnézi a **wtmp**-t: a daemon a leállás 3. lépésében ír egy `shutdown` bejegyzést, amit a hardveres reset (valódi fagyás) **nem** tesz meg.

| Jel | Mit jelent |
|---|---|
| van `systemd-shutdown` | rendes systemd reboot (apt, cron) |
| nincs `systemd-shutdown`, **van** wtmp `shutdown` | watchdog daemon soft reboot |
| nincs egyik sem | valódi fagyás / hard reset / áramkimaradás |

A leggyakoribb kiváltó ok a `max-load-1`. A `watchdog.conf(5)` szerint ez egy **load-küszöb**: ha a terhelés átlépi, a gép újraindul. A `watchdog(8)` pedig kimondja, hogy a load-hiba **kivétel a retry-timeout alól** — nincs türelmi idő. Ráadásul a fájlban nem szereplő `max-load-5` és `max-load-15` **a `max-load-1`-ből számolódik**: `3/4` és `1/2` arányban. Tehát a `max-load-1 = 32` valójában `32 / 24 / 16` hármas küszöböt jelent, és a 15 perces átlag miatt a reboot akár 10-20 perccel a terheléscsúcs **után** következik be. Ez kelti a „random fagyás" látszatát.

Az elemző kiírja a mért load-csúcsokat a fekete dobozból, kiszámolja a származtatott limiteket, és ha a csúcs átlépte őket, külön kategóriaként kimondja: *„Load átlépte a watchdog max-load küszöböt"*. Ilyenkor a load a **tünet**, nem az ok — a `95-blackbox-topload.txt` megmutatja, milyen processzek hajtották fel.

**2. Van OOM?**
`Out of memory: Killed process ...` → a RAM elfogyott. Nézd meg a `30-top-mem.txt`-t, és tedd rá a `MemoryMax=`-et a bűnös szolgáltatásra. YunoHost alatt tipikus: MariaDB + Nextcloud cron + PHP-FPM egyszerre.

**3. Van I/O hiba?**
`I/O error`, `ataX: failed command`, `nvme ... reset`, `Buffer I/O error`, `remount read-only` → lemez/kábel. A SMART-ban `Reallocated_Sector_Ct` vagy `UDMA_CRC_Error_Count` növekedése különösen árulkodó (utóbbi gyakran csak rossz SATA kábel).

**4. Van lockup / hung task?**
`soft lockup`, `hung task`, `blocked for more than 120 seconds` → a kernel egy driverben vagy I/O-ban akadt be. A `Call Trace` első pár sora mondja meg, melyik alrendszer.

**5. Van MCE / EDAC?**
`Machine check`, `Hardware Error`, `EDAC ... UE` → hardver: RAM vagy CPU. Ilyenkor memtest86+ (legalább 4 óra, egy éjszaka jobb), és a BIOS eseménynaplója.

**6. Semmi nyom, a napló csak megszakad?**
Ez a tiszta hardveres fagyás képe: táp, RAM, alaplap, vagy a watchdog túl agresszív beállítása. Sorrend: tápcsere/próba → memtest → watchdog timeout emelése → alaplap/CPU.

## A watchdog beállítása

A watchdog akkor hasznos, ha a timeout **elég nagy** ahhoz, hogy egy lassú, de működő rendszert ne lőjön le. Egy éjszakai backup vagy egy `apt upgrade` alatt a load és az I/O-nyomás percekig magas lehet — ha a watchdog 10-15 másodperc, akkor lecsap egy olyan rendszerre, ami valójában csak dolgozik.

```bash
# jelenlegi állapot
sudo wdctl
systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec

# emelés (pl. 60 s hardveres, 120 s reboot esetén)
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/99-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=60s
RebootWatchdogSec=120s
EOF
sudo systemctl daemon-reexec
```

Ez nem javítja meg az okot, de megakadályozza, hogy egy ártalmatlan lassulás újraindításhoz vezessen — és így a valódi fagyásoktól megkülönböztethető lesz.

## GYIK

**Mennyi helyet foglal?** A fekete doboz napi ~1-2 MB, rotálva 8 hét. A csomagok 5-50 MB közöttiek, bootonként egy.

**Lassítja a gépet?** A minta egyetlen `oneshot` processz, `Nice=10`, `IOSchedulingClass=idle`, 64 MB memóriakorlát, 20% CPU. Elhanyagolható.

**Mi van, ha SD-kártyán fut?** A percenkénti írás apró, de a kártyát kímélni lehet: állítsd a `yh-blackbox.timer`-ben az `OnUnitActiveSec=5min`-re. A journald `SystemMaxUse=1G` szintén csökkenthető.

**Kell hozzá kdump?** Nem kötelező, de ha a kernel panic okát akarod látni, érdemes: `apt install kdump-tools` és `crashkernel=` a GRUB-ban. A csomag a `/var/crash` és a pstore tartalmát is begyűjti, ha van.

**Eltávolítás:** `sudo ./uninstall.sh` (a naplók megmaradnak), vagy `--purge` a naplókkal együtt.

## Fájlok

```
yunohost-diag/
├── install.sh                  telepítő
├── uninstall.sh                eltávolító
├── README.md                   ez a fájl
├── bin/
│   ├── yh-blackbox.sh          percenkénti minta
│   ├── yh-bootcheck.sh         boot utáni tisztátlan-leállás észlelés
│   ├── yh-collect.sh           diagnosztikai csomag gyűjtése
│   └── yh-analyze.sh           kiértékelés magyar nyelven
└── systemd/
    ├── yh-blackbox.service
    ├── yh-blackbox.timer
    └── yh-bootcheck.service
```
