#!/bin/sh
# psw2-portguard.sh — следит за доступностью порта VPN-ноды и переключает на запасной.
# Ставится в cron раз в 5 минут. Переключает порт ТОЛЬКО при подтверждённой
# недоступности текущего; если туннель жив — не делает ничего.
# Ручная проверка без изменений:  psw2-portguard.sh --check

CANDIDATES="443 2053 2083 993 8080"   # порядок перебора, первым — предпочтительный
STATE=/tmp/psw2-portguard.state
LOG=/tmp/psw2-portguard.log
FAILS_NEEDED=2        # столько запусков подряд должны провалиться (≈10 мин)
COOLDOWN=1200         # не переключать чаще, чем раз в 20 минут
PROBES=3              # попыток за один запуск
PROBE_GAP=3           # пауза между попытками, сек

CHECK_ONLY=0
[ "$1" = "--check" ] && CHECK_ONLY=1

log() {
    [ "$CHECK_ONLY" = "1" ] && echo "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 51200 ]; then
        tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

NODE=$(uci -q get passwall2.@global[0].node)
if [ -z "$NODE" ]; then log "активная нода не задана — выход"; exit 1; fi
# если активная нода — шунт (_shunt), реальный прокси-узел лежит в default_node
if [ "$(uci -q get passwall2."$NODE".protocol)" = "_shunt" ]; then
    NODE=$(uci -q get passwall2."$NODE".default_node)
fi
ADDR=$(uci -q get passwall2."$NODE".address)
PORT=$(uci -q get passwall2."$NODE".port)
if [ -z "$ADDR" ] || [ -z "$PORT" ]; then log "у ноды $NODE нет адреса или порта"; exit 1; fi

tcp_ok() {
    T=$(curl -s -m 4 -k -o /dev/null -w '%{time_connect}' "https://$ADDR:$1" 2>/dev/null)
    case "$T" in ""|0.000000|0) return 1 ;; *) return 0 ;; esac
}

tunnel_ok() {
    curl -s -m 8 -x socks5h://127.0.0.1:1070 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q '^ip='
}

# --- режим проверки: только показать картину ---
if [ "$CHECK_ONLY" = "1" ]; then
    echo "нода:   $NODE  ->  $ADDR:$PORT"
    tunnel_ok && echo "туннель: РАБОТАЕТ" || echo "туннель: НЕ РАБОТАЕТ"
    for P in $CANDIDATES; do
        printf "порт %-5s " "$P"
        tcp_ok "$P" && echo "доступен" || echo "не доходит"
    done
    [ -f "$STATE" ] && { echo "--- состояние ---"; cat "$STATE"; }
    exit 0
fi

FAILS=0; LAST=0
[ -f "$STATE" ] && . "$STATE"

# --- проверяем текущий порт ---
ok=0; i=1
while [ "$i" -le "$PROBES" ]; do
    if tcp_ok "$PORT"; then ok=1; break; fi
    i=$((i + 1))
    [ "$i" -le "$PROBES" ] && sleep "$PROBE_GAP"
done

if [ "$ok" = "1" ]; then
    [ "$FAILS" -gt 0 ] && log "порт $PORT снова доступен — счётчик сброшен"
    printf 'FAILS=0\nLAST=%s\n' "$LAST" > "$STATE"
    exit 0
fi

# страховка от ложной тревоги: если туннель жив — ничего не трогаем
if tunnel_ok; then
    log "порт $PORT не отвечает на проверку, но туннель работает — пропускаю"
    printf 'FAILS=0\nLAST=%s\n' "$LAST" > "$STATE"
    exit 0
fi

FAILS=$((FAILS + 1))
log "порт $PORT недоступен ($FAILS из $FAILS_NEEDED)"
printf 'FAILS=%s\nLAST=%s\n' "$FAILS" "$LAST" > "$STATE"
[ "$FAILS" -lt "$FAILS_NEEDED" ] && exit 0

NOW=$(date +%s)
if [ $((NOW - LAST)) -lt "$COOLDOWN" ]; then
    log "переключение отложено: с прошлого прошло $((NOW - LAST)) сек из $COOLDOWN"
    exit 0
fi

# --- ищем живой порт и переключаемся ---
for P in $CANDIDATES; do
    [ "$P" = "$PORT" ] && continue
    if tcp_ok "$P"; then
        log "порт $P доступен — переключаю ноду с $PORT на $P"
        uci set passwall2."$NODE".port="$P"
        uci commit passwall2
        /etc/init.d/passwall2 restart >/dev/null 2>&1
        sleep 25
        if tunnel_ok; then
            log "ГОТОВО: туннель поднялся на порту $P"
        else
            log "порт $P доступен, но туннель не поднялся — попробую следующий при новой проверке"
        fi
        printf 'FAILS=0\nLAST=%s\n' "$NOW" > "$STATE"
        exit 0
    fi
done

log "ни один порт не доступен — похоже, заблокирован весь адрес $ADDR"
printf 'FAILS=%s\nLAST=%s\n' "$FAILS" "$LAST" > "$STATE"
exit 1
