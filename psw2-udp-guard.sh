#!/bin/sh
# psw2-udp-guard v2 — сторож PassWall2 на OpenWrt.
#
# Проверяет три известные болячки и чинит их:
#   1. Патч allowedNetwork -> network в util_xray.lua (слетает при обновлении
#      пакета passwall2). Без него UDP-инбаунд поднимается как TCP и весь UDP,
#      включая DNS, проваливается в никуда.
#   2. Наличие UDP-сокета xray на tproxy-порту (2001).
#   3. Дубли процессов dnsmasq_default — после серии рестартов PassWall2 старый
#      экземпляр не умирает, два процесса дерутся за порт 2003, и DNS у клиентов
#      перестаёт отвечать.
# Плюс функциональная проверка: реально ли резолвится имя через локальный DNS.
#
# Установка:
#   поместить в /usr/bin/psw2-udp-guard.sh, chmod +x
#   crontab: */10 * * * * /usr/bin/psw2-udp-guard.sh
# Ручная проверка (ничего не меняет): psw2-udp-guard.sh --check

PORT=2001                                        # tproxy-порт PassWall2
DNS_PORT=2003                                    # порт PassWall2-dnsmasq
DNS_PROBE=cloudflare.com                         # имя для функциональной проверки
LUA=/usr/lib/lua/luci/passwall2/util_xray.lua
LOG=/var/log/psw2-udp-guard.log
STAMP=/tmp/psw2-udp-guard.last
COOLDOWN=600                                     # сек между авто-рестартами

CHECK_ONLY=0
[ "$1" = "--check" ] && CHECK_ONLY=1

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
	[ "$CHECK_ONLY" = "1" ] && echo "$*"
}

say() { [ "$CHECK_ONLY" = "1" ] && echo "$*"; }

# --- ротация лога, чтобы не съел overlay ---
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ]; then
	tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

HEX=$(printf '%04X' "$PORT")

udp_socket_present() {
	awk -v hex="$HEX" 'NR > 1 { split($2, a, ":"); if (a[2] == hex) { found = 1 } }
	                   END { exit !found }' /proc/net/udp /proc/net/udp6 2>/dev/null
}

dnsmasq_count() {
	pgrep -f dnsmasq_default 2>/dev/null | wc -l
}

dns_works() {
	nslookup "$DNS_PROBE" 127.0.0.1 2>/dev/null | grep -qE '^Address: *[0-9]+\.[0-9]+'
}

# --- PassWall2 вообще должен работать? ---
if [ "$(uci -q get passwall2.@global[0].enabled)" != "1" ]; then
	say "PassWall2 выключен (enabled=0) — сторожить нечего"
	exit 0
fi

# --- xray запущен? если нет, значит PassWall2 ещё стартует — не мешаем ---
if ! pgrep -f 'passwall2/bin/xray' > /dev/null 2>&1; then
	say "xray ещё не запущен — пропускаю проверку"
	exit 0
fi

PROBLEM=""
KILLED_DUPES=0

# --- 1. патч в util_xray.lua ---
if grep -q 'allowedNetwork' "$LUA" 2>/dev/null; then
	PROBLEM="патч слетел"
	if [ "$CHECK_ONLY" = "1" ]; then
		echo "ПРОБЛЕМА: в $LUA снова allowedNetwork (обновился пакет passwall2?)"
	else
		log "ПАТЧ СЛЕТЕЛ: в $LUA снова allowedNetwork — применяю заново"
		cp "$LUA" "$LUA.bak.$(date +%s)"
		sed -i 's/allowedNetwork/network/g' "$LUA"
	fi
else
	say "OK: патч network в util_xray.lua на месте"
fi

# --- 2. дубли dnsmasq_default ---
DUPES=$(dnsmasq_count)
if [ "$DUPES" -gt 1 ]; then
	PROBLEM="${PROBLEM:+$PROBLEM, }дубли dnsmasq_default ($DUPES шт.)"
	if [ "$CHECK_ONLY" = "1" ]; then
		echo "ПРОБЛЕМА: процессов dnsmasq_default $DUPES вместо 1 — они дерутся за порт $DNS_PORT, DNS у клиентов молчит"
	else
		log "ДУБЛИ dnsmasq_default: $DUPES шт. — убиваю все, PassWall2 поднимет один"
		pgrep -f dnsmasq_default | xargs -r kill
		sleep 2
		pgrep -f dnsmasq_default | xargs -r kill -9 2>/dev/null
		KILLED_DUPES=1
	fi
elif [ "$DUPES" -eq 1 ]; then
	say "OK: dnsmasq_default запущен в одном экземпляре"
else
	say "ВНИМАНИЕ: dnsmasq_default не запущен вовсе"
fi

# --- 3. UDP-сокет на tproxy-порту ---
if udp_socket_present; then
	say "OK: xray слушает UDP на порту $PORT"
else
	PROBLEM="${PROBLEM:+$PROBLEM, }нет UDP-сокета на $PORT"
	[ "$CHECK_ONLY" = "1" ] && echo "ПРОБЛЕМА: xray НЕ слушает UDP на порту $PORT — UDP и DNS работать не будут"
fi

# --- 4. функциональная проверка DNS ---
if dns_works; then
	say "OK: DNS резолвит ($DNS_PROBE через 127.0.0.1)"
else
	PROBLEM="${PROBLEM:+$PROBLEM, }DNS не резолвит"
	[ "$CHECK_ONLY" = "1" ] && echo "ПРОБЛЕМА: $DNS_PROBE не резолвится через локальный DNS"
fi

if [ "$CHECK_ONLY" = "1" ]; then
	[ -z "$PROBLEM" ] && exit 0
	exit 1
fi

[ -z "$PROBLEM" ] && exit 0

# --- рестарт с защитой от долбёжки ---
NOW=$(date +%s)
LAST=0
[ -f "$STAMP" ] && LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
AGO=$((NOW - LAST))

if [ "$AGO" -lt "$COOLDOWN" ] && [ "$KILLED_DUPES" = "0" ]; then
	log "$PROBLEM — рестарт пропущен, прошлый был $AGO сек назад (cooldown $COOLDOWN)"
	exit 1
fi

log "$PROBLEM — перезапускаю PassWall2"
echo "$NOW" > "$STAMP"
/etc/init.d/passwall2 restart

# ждём, пока поднимется, и проверяем результат
i=0
while [ "$i" -lt 12 ]; do
	sleep 5
	i=$((i + 1))
	if udp_socket_present && [ "$(dnsmasq_count)" -le 1 ] && dns_works; then
		log "OK: всё поднялось через $((i * 5)) сек после рестарта"
		exit 0
	fi
done

STATE="UDP-сокет: $(udp_socket_present && echo есть || echo НЕТ)"
STATE="$STATE, dnsmasq_default: $(dnsmasq_count) шт."
STATE="$STATE, DNS: $(dns_works && echo резолвит || echo МОЛЧИТ)"
log "ВНИМАНИЕ: после рестарта не всё поднялось — $STATE — нужна ручная разборка"
exit 1
