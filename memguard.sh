#!/bin/sh
# memguard — активный сторож против обвала памяти/fd у xray (PassWall2).
#
# Установлен 2026-09-15 по факту пойманного коллапса 2026-09-14:
# от здоровых ~140 МБ available до 0 МБ / load 11-17 прошло ~6-9 минут,
# xray fd застрял на ~4680 и не снижался даже когда conntrack уже спадал —
# похоже на утечку fd/памяти у xray под всплеском нагрузки, не на плавный дрейф.
# Порог CRIT подобран по этим цифрам (см. hang-2026-09-09-ram-investigation.md
# и лог обсуждения 2026-09-14): здоровый фон avail~130-145МБ ct~100-300,
# самоизлечившийся всплеск 15:09-15:39 не опускал avail ниже 109 и ct выше 4825 —
# пороги ниже НАМЕРЕННО между "самоизлечивающимся" и "реальным" всплеском.
#
# Проверка каждую минуту (лёгкая, только /proc). Действие — только при CRIT,
# не чаще, чем раз в COOLDOWN секунд.
#
# Ручная проверка без изменений: memguard.sh --check

L=/root/memguard.log
COOLDOWN=900                 # 15 минут между вмешательствами
AVAIL_CRIT=100                # МБ
CT_CRIT=6000
FD_CRIT=2000
AVAIL_WARN=120
CT_WARN=2000
FD_WARN=500

CHECK_ONLY=0
[ "$1" = "--check" ] && CHECK_ONLY=1

[ -f "$L" ] && [ "$(wc -c < "$L")" -gt 409600 ] && { tail -n 600 "$L" > "$L.t"; mv "$L.t" "$L"; }

log() {
	echo "$(date '+%F %T') $*" >> "$L"
	[ "$CHECK_ONLY" = "1" ] && echo "$*"
}

XP=$(pgrep -f 'passwall2/bin/xray' | head -1)
XR=$(awk '/VmRSS/{print $2}' /proc/$XP/status 2>/dev/null)
XF=$(ls /proc/$XP/fd 2>/dev/null | wc -l)
MA=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
CT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
LO=$(cut -d' ' -f1 /proc/loadavg)
DP=$(pgrep -f dnsmasq_default | wc -l)

SNAPSHOT="avail=${MA}MB xrayRSS=${XR:-0}k xrayFd=${XF:-0} ct=${CT:-0} load=$LO dnsmasq=$DP"

CRIT=0
[ "${MA:-999}" -lt "$AVAIL_CRIT" ] && CRIT=1
[ "${CT:-0}" -gt "$CT_CRIT" ] 2>/dev/null && CRIT=1
[ "${XF:-0}" -gt "$FD_CRIT" ] 2>/dev/null && CRIT=1

WARN=0
[ "${MA:-999}" -lt "$AVAIL_WARN" ] && WARN=1
[ "${CT:-0}" -gt "$CT_WARN" ] 2>/dev/null && WARN=1
[ "${XF:-0}" -gt "$FD_WARN" ] 2>/dev/null && WARN=1

if [ "$CHECK_ONLY" = "1" ]; then
	echo "$SNAPSHOT"
	[ "$CRIT" = "1" ] && echo "-> CRIT" || { [ "$WARN" = "1" ] && echo "-> WARN" || echo "-> OK"; }
	exit 0
fi

if [ "$CRIT" != "1" ]; then
	[ "$WARN" = "1" ] && log "WARN $SNAPSHOT"
	exit 0
fi

# --- CRIT: не действуем чаще, чем раз в COOLDOWN ---
STAMP=/tmp/memguard.last
NOW=$(date +%s)
LAST=0
[ -f "$STAMP" ] && LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
if [ $((NOW - LAST)) -lt "$COOLDOWN" ]; then
	log "CRIT $SNAPSHOT — вмешательство отложено (последнее $((NOW - LAST)) сек назад из $COOLDOWN)"
	exit 0
fi
echo "$NOW" > "$STAMP"

log "CRIT $SNAPSHOT — начинаю вмешательство"
logread | grep -iE 'oom|killed process|lowmem|cannot allocate' | tail -5 | while read x; do log "    !! $x"; done

# 1. дешёвая попытка: сброс кэша (почти наверняка не поможет при утечке, но бесплатно)
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
sleep 5
MA2=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
if [ "$MA2" -ge "$AVAIL_CRIT" ]; then
	log "ПОСЛЕ drop_caches: avail=${MA2}MB — в норме, рестарт passwall2 не потребовался"
	exit 0
fi

# 2. настоящее лечение: перезапуск passwall2 (сбрасывает RSS/fd у xray)
log "avail всё ещё ${MA2}MB после drop_caches — перезапускаю passwall2"
/etc/init.d/passwall2 restart >/dev/null 2>&1

i=0
while [ "$i" -lt 12 ]; do
	sleep 5
	i=$((i + 1))
	if curl -s -m 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q '^ip='; then
		MA3=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
		log "ГОТОВО через $((i * 5)) сек: туннель поднялся, avail=${MA3}MB"
		exit 0
	fi
done
MA3=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
log "ВНИМАНИЕ: через 60 сек после рестарта туннель не поднялся, avail=${MA3}MB — нужна ручная разборка"
