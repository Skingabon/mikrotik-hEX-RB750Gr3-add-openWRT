# hEX + OpenWrt + VPN — состояние на 2026-09-04, утро

## 🔴 С ЧЕГО НАЧАТЬ ВЕЧЕРОМ

Провайдер утром что-то перезагрузил — **интернет дома вернулся, Wi-Fi работает,
но VPN не поднялся.** Проверка со стороны сервера в 10:52: xray и nginx активны,
соединений из домашней сети **ноль** — роутер до сервера не достучался.

### Порядок действий

1. Подключиться к роутеру: `ssh root@192.168.1.1` (ключ ПК1 прописан) —
   с ПК2 по Wi-Fi Archer, либо кабелем в ПК1 со статикой 192.168.1.50.
2. Снять картину одной пачкой:
   ```sh
   date -u                                   # часы (должен быть UTC, +3 = Москва)
   ip -4 addr show wan; ip route             # адрес и маршрут WAN
   ping -c 3 -W 2 8.8.8.8 | tail -3          # есть ли интернет у роутера вообще
   uci get network.wan.proto                 # должно быть dhcp
   uci get network.wan.macaddr               # должно быть пусто (не задано)
   uci get passwall2.LgCRCnyE.fingerprint    # должно быть safari
   /etc/init.d/passwall2 status              # запущен ли
   curl -s --max-time 15 https://ifconfig.me; echo   # ждём <SERVER_IP>
   ```
3. **Вероятнее всего останутся ночные правки WAN** — ночью пробовали клонировать
   MAC и статический IP. Если `proto` не `dhcp` или задан `macaddr`, вернуть:
   ```sh
   uci set network.wan.proto='dhcp'
   uci -q delete network.wan.macaddr
   uci -q delete network.wan.ipaddr
   uci -q delete network.wan.netmask
   uci -q delete network.wan.gateway
   uci -q delete network.wan.dns
   uci commit network && /etc/init.d/network restart
   sleep 25 && ping -c 3 8.8.8.8 | tail -3
   ```
4. Когда у роутера появится интернет — `/etc/init.d/passwall2 restart`, подождать
   25 секунд, проверить `curl -s https://ifconfig.me`.

## 🌙 ЧТО СДЕЛАНО В НОЧЬ 03→04.09

### Найдена и вылечена главная причина пятидневных мучений

`fingerprint='chrome'` включает в TLS ClientHello постквантовый ключ
**X25519MLKEM768** (+1216 байт). Рукопожатие вырастало до **1728–1824 байт**,
не влезало в один TCP-сегмент, разбивалось на два — московский DPI разорванные
рукопожатия отбрасывает. TCP при этом устанавливался: рвался первый пакет с данными.

Подпись: Send-Q застревает на ~1800, **85% ретрансмиссий** (59309 из 70112),
на сервере в nginx stream — `sni=[] recv=0 sess=30.000` (таймаут ssl_preread).
Обычный `curl` к тому же серверу работал — его рукопожатие ~700 байт, один сегмент.

**Применено:** `uci set passwall2.LgCRCnyE.fingerprint='safari'`.
Результат — **15 замеров подряд без единого срыва**, трафик всех домашних
устройств пошёл через Франкфурт, на сервере 90 активных соединений, ретрансов 0.
Запасные варианты отпечатка: `firefox`, `ios`.

### Попутно вылечено

- **Часы.** У hEX нет батарейки RTC, после ребута отставание доходило до 18 ч 42 мин,
  Reality из-за этого не вставал. NTP переведён на голые IP (Google + Cloudflare),
  чтобы не зависеть от DNS. Проверено перезагрузкой.
- **`tcp_max_orphans=1024`** — ядро рубило соединения через 2–4 минуты.
  Поднято до 8192 в `/etc/sysctl.d/99-xray-tuning.conf`, пережило ребут.
- **Сторож `psw2-udp-guard.sh` ОТКЛЮЧЁН** — перезапускал PassWall2 по ложной
  тревоге каждые 10 минут, а рестарт сам ронял туннель. Цикл самосбывающегося
  пророчества. В `/etc/crontabs/root` закомментирован. **Обратно не включать.**
- **Лог ноды отключён** (`log_node='0'`) — `/tmp` это RAM, не забивать.

### Ночной обрыв — это был провайдер, не мы

После перезагрузки роутера пропал интернет целиком. Шлюз `10.76.0.1` пинговался
за 2 мс, DNS провайдера `77.37.251.33` отвечал и резолвил имена — а наружу
не проходило ничего. Классический «карантин»: доступ только внутрь сети провайдера.
При этом с ПК по тому же кабелю Яндекс открывался.

Пробовали и не помогло: остановка PassWall2, `nft delete table inet passwall2`,
перезапуск файрвола, `ifup wan`, клонирование MAC обоих ПК, MTU 1400/1280.
Утром провайдер перезагрузил своё оборудование — интернет вернулся сам.

**Вывод на будущее:** при «не доходит до сервера» первым делом
`ping` шлюза провайдера и стороннего адреса, и только потом выводы о блокировке.

## ⛔ ПРОВЕРЕНО И ИСКЛЮЧЕНО — не тратить время заново

| Версия | Как проверено | Итог |
|---|---|---|
| MTU | 1500 / 1400 / 1280 → MSS 1448 / 1348 / 1228 | картина одна, не оно |
| Ключи Reality | `xray x25519 -i <priv>` на сервере | публичный ключ совпал точно |
| Часы | роутер 21:12:10 UTC, сервер 21:12:17 | расхождение 7 секунд |
| conntrack | 824 из 31744, дропов нет | не оно |
| Версии xray | сервер 26.3.27, роутер 26.3.27 | одинаковые |
| Блокировка по SNI | 5 разных SNI на сервер, все долетели | не оно |
| Файрвол сервера | ufw активен, 443 открыт, fail2ban выключен | чист |
| Archer AX12 | DHCP-шторм оказался следствием, не причиной | оправдан |
| Память роутера | после ребута 143 МБ свободно, /tmp занят на 292 КБ | не оно |
| Привязка по MAC | клонировали MAC обоих ПК — провайдер дал новые IP | не оно |

## 🔧 КОНФИГУРАЦИЯ

**Нода** `passwall2.LgCRCnyE` → `<SERVER_IP>:443`, VLESS + Reality,
SNI `www.cloudflare.com`, fingerprint **`safari`**, transport raw, flow пустой.

**Сервер `<HOSTING_HOSTNAME>` (<SERVER_IP>)**, root по паролю. nginx на 443 разбирает SNI:
`www.cloudflare.com` → `127.0.0.1:8444` (xray), остальное → `127.0.0.1:8443` (сайты).
Xray 26.3.27, слушает только localhost.

**Запасные порты** (`/etc/nginx/stream.d/alt-ports.conf`), все ведут в xray на 8444,
ufw открыт: **2053, 2083, 993, 8080**.

**Второй IP на сервере: `<SERVER_IP_2>`** — куплен по моей ошибочной наводке
(преждевременно объявил блокировку адреса). Пригодится как запасная точка входа.

**Скорость.** Потолок ~15 Мбит/с задаёт зарубежный канал провайдера, не роутер:
тот же сервер в Европе отдаёт 14 Мбит **и без VPN**, CPU роутера 95% idle.
Апгрейд на Xiaomi AX3000T скорость VPN не поднимет.

**Сеть.** Archer AX12 работает мостом (режим AP): ПК2, телефон REDMI, планшет
Galaxy Tab получают адреса напрямую от hEX 192.168.1.x и ходят через туннель.
Отдельно настраивать точку доступа не нужно — уже сделано.

## 📋 НЕЗАКОНЧЕННОЕ

**Скрипт `psw2-portguard.sh`** — лежит в `D:\JS\event\psw2-portguard.sh`, написан
и проверен на синтаксис, но не установлен и не испытан. Перебирает порты
443 → 2053 → 2083 → 993 → 8080 и переключает `uci set passwall2.<node>.port`.
Предохранители: 3 пробы за запуск, 2 провальных запуска подряд, 20 минут между
переключениями, и главное — если туннель жив, не трогает ничего.
**Доработать:** добавить перебор второго IP `<SERVER_IP_2>`.

**Вариант с Cloudflare** (если DPI снова начнёт давить): VLESS поверх WebSocket
за проксированием Cloudflare — провайдер видит соединение с адресами Cloudflare,
а не с сервером. Час-полтора работы. При потолке 15 Мбит/с лишнее звено
на скорости не скажется.

## 🛠 ПОЛЕЗНЫЕ КОМАНДЫ

```sh
curl -s --max-time 15 https://ifconfig.me; echo          # жив ли туннель
curl -s -x socks5h://127.0.0.1:1070 https://1.1.1.1/cdn-cgi/trace   # нода напрямую
netstat -tn | grep '<SERVER_IP>:443' | head            # Send-Q ~1800 → отпечаток
awk '/^Tcp:/{if(++n==2) print "Out="$12" Retrans="$13}' /proc/net/snmp
date -u                                                   # часы
ping -c 3 -W 2 10.76.0.1                                  # шлюз провайдера
logread | grep -iE "wan|udhcpc|lease" | tail
```

⚠️ **Не включать `loglevel=debug` у PassWall2** — `/tmp` это RAM (121 МБ),
debug-лог её съедает и роутер виснет.

---
---

# АРХИВ: состояние на 2026-09-04, 02:00

## 🔴 С ЧЕГО НАЧАТЬ ЗАВТРА

**Сейчас интернета нет вообще — и это провайдер, не мы.**
Шлюз провайдера `10.76.0.1` пингуется за 2 мс, дальше не проходит ничего:
ни `8.8.8.8`, ни `77.88.8.8`, ни один порт любого сервера.

Всё, что могло быть виновато на нашей стороне, исключено прямыми проверками:
PassWall2 остановлен → не помогло; `nft delete table inet passwall2` → не помогло;
`/etc/init.d/firewall restart` → не помогло; `ifup wan` (переполучение аренды) →
не помогло. WAN при этом поднят, адрес `10.76.164.87/16` получен, маршрут
по умолчанию на месте, ARP шлюза REACHABLE.

### Порядок действий

1. **Проверить в лоб:** кабель провайдера напрямую в ноутбук, мимо hEX.
   Нет интернета и так → вопрос к роутеру снят окончательно.
2. **Звонок в поддержку провайдера.** Формулировка: «с моего подключения
   не проходит ничего дальше вашего шлюза 10.76.0.1, сам шлюз пингуется за 2 мс,
   оборудование перезагружено, адрес по DHCP получен». **Про VPN не упоминать.**
   Просить проверить, нет ли ограничения на подключении.
3. **Когда связь вернут — ничего настраивать не надо.** Все исправления записаны
   в постоянную память и переживают перезагрузку. Проверка одной командой:
   ```sh
   curl -s --max-time 15 https://ifconfig.me; echo    # ждём <SERVER_IP>
   ```
4. Если туннель не поднимется сам — по порядку:
   `date -u` (часы) → `uci get passwall2.LgCRCnyE.fingerprint` (должно быть `safari`)
   → `netstat -tn | grep :443` (Send-Q застрял ~1800 → снова отпечаток)
   → `/etc/init.d/passwall2 restart`.

## ✅ ЧТО ВЫЛЕЧЕНО 2026-09-03/04

Четыре независимые причины, все давали один симптом «VPN не работает».

### 1. Отпечаток `chrome` — главная причина, держалась 5 дней

`fingerprint='chrome'` включает в TLS ClientHello постквантовый ключ
**X25519MLKEM768** (+1216 байт). Рукопожатие вырастало до **1728–1824 байт**,
не влезало в один TCP-сегмент, разбивалось на два — а московский DPI разорванные
рукопожатия отбрасывает. TCP-соединение при этом устанавливалось: рвался именно
первый пакет с данными.

Подпись: Send-Q застревает на ~1800 на всех соединениях, **85% ретрансмиссий**
(59309 из 70112), на сервере в nginx stream — `sni=[] recv=0 sess=30.000`
(таймаут ssl_preread). При этом обычный `curl` к тому же серверу работал —
его рукопожатие ~700 байт, один сегмент.

**Лечение (уже применено):**
```sh
uci set passwall2.LgCRCnyE.fingerprint='safari'   # нет постквантового расширения
uci commit passwall2 && /etc/init.d/passwall2 restart
```
Запасные варианты: `firefox`, `ios`. После смены — 15 замеров подряд без сбоя,
трафик всех домашних устройств пошёл через Франкфурт.

### 2. Часы уезжают после перезагрузки → Reality не встаёт
У hEX нет батарейки RTC. Отставание доходило до 18 ч 42 мин. NTP переведён
на голые IP (Google + Cloudflare), чтобы не зависеть от DNS. Проверено ребутом.

### 3. `tcp_max_orphans=1024` → туннель умирал за 2–4 минуты
Поднято до 8192 в `/etc/sysctl.d/99-xray-tuning.conf`. Пережило перезагрузку.

### 4. Сторож `psw2-udp-guard.sh` делал хуже — ОТКЛЮЧЁН
Перезапускал PassWall2 по ложной тревоге каждые 10 минут, а рестарт сам ронял
туннель на минуту. Цикл самосбывающегося пророчества. В `/etc/crontabs/root`
закомментирован как `#DISABLED`. **Обратно не включать.**

## ⛔ ЧТО ПРОВЕРЕНО И ИСКЛЮЧЕНО — не тратить время заново

| Версия | Как проверено | Итог |
|---|---|---|
| MTU | 1500 / 1400 / 1280 → MSS 1448 / 1348 / 1228 | картина одна, не оно |
| Ключи Reality | `xray x25519 -i <priv>` на сервере | публичный ключ совпал точно |
| Часы | роутер 21:12:10 UTC, сервер 21:12:17 | расхождение 7 секунд |
| conntrack | 824 из 31744, дропов нет | не оно |
| Версии xray | сервер 26.3.27, роутер 26.3.27 | одинаковые |
| Блокировка по SNI | 5 разных SNI на сервер, все долетели | не оно |
| Файрвол сервера | ufw активен, 443 открыт, fail2ban выключен, банов нет | чист |
| Канал до сервера | Send-Q 0, bytes_acked растёт, ретрансов нет | был исправен |
| Archer AX12 | DHCP-шторм оказался следствием, не причиной | оправдан |
| Память роутера | после ребута 143 МБ свободно, /tmp занят на 292 КБ | не оно |
| PassWall2 как причина обрыва | остановлен + таблица снесена | интернет не вернулся |

## 🔧 КОНФИГУРАЦИЯ

**Нода** `passwall2.LgCRCnyE` → `<SERVER_IP>:443`, VLESS + Reality,
SNI `www.cloudflare.com`, fingerprint **`safari`**, transport raw, flow пустой.

**Сервер `<HOSTING_HOSTNAME>` (<SERVER_IP>), root-доступ по паролю.**
nginx на 443 разбирает SNI: `www.cloudflare.com` → `127.0.0.1:8444` (xray),
остальное → `127.0.0.1:8443` (сайты). Xray 26.3.27, слушает только localhost.

**Добавлены запасные порты** (`/etc/nginx/stream.d/alt-ports.conf`), все ведут
прямо в xray на 8444, ufw открыт: **2053, 2083, 993, 8080**.

**Второй IP на сервере: `<SERVER_IP_2>`** — куплен по моей ошибочной наводке
(я преждевременно объявил блокировку адреса, хотя у роутера просто пропал канал).
Не пропадёт: пригодится как запасная точка входа для скрипта подмены.

**Скорость.** Потолок ~15 Мбит/с задаёт зарубежный канал провайдера, не роутер:
тот же сервер в Европе отдаёт 14 Мбит **и без VPN**, CPU роутера при замере
95% idle. Апгрейд на Xiaomi AX3000T скорость VPN не поднимет.

**Сеть.** Archer AX12 работает мостом (режим AP): ПК2, телефон REDMI, планшет
Galaxy Tab получают адреса напрямую от hEX 192.168.1.x и ходят через туннель.
Отдельно настраивать точку доступа не нужно — уже сделано.

## 📋 НЕЗАКОНЧЕННОЕ

**Скрипт `psw2-portguard.sh`** — написан, синтаксис проверен, но не установлен
и не испытан (нет канала). Умеет: проверять доступность порта ноды, при
подтверждённой недоступности перебирать 443 → 2053 → 2083 → 993 → 8080
и переключать `uci set passwall2.<node>.port`. Предохранители: 3 пробы за запуск,
2 провальных запуска подряд, 20 минут между переключениями, и главное — если
туннель жив, не трогает ничего (ошибка прошлого сторожа).
**Доработать:** добавить перебор второго IP `<SERVER_IP_2>`.

**Вариант с Cloudflare** (если провайдер продолжит давить): VLESS поверх
WebSocket за проксированием Cloudflare — провайдер видит соединение с адресами
Cloudflare, а не с сервером, точечно заблокировать невозможно. На сервере уже
есть домены. Час-полтора работы. При потолке 15 Мбит/с лишнее звено в маршруте
на скорости не скажется.

## 🛠 ПОЛЕЗНЫЕ КОМАНДЫ

```sh
curl -s --max-time 15 https://ifconfig.me; echo          # жив ли туннель
curl -s -x socks5h://127.0.0.1:1070 https://1.1.1.1/cdn-cgi/trace   # нода напрямую
netstat -tn | grep '<SERVER_IP>:443' | head            # Send-Q ~1800 → отпечаток
awk '/^Tcp:/{if(++n==2) print "Out="$12" Retrans="$13}' /proc/net/snmp
date -u                                                   # часы (должен быть UTC)
logread | grep -iE "wan|dhcp|link is" | tail
```

⚠️ **Не включать `loglevel=debug` у PassWall2** — `/tmp` это RAM (121 МБ),
debug-лог её съедает и роутер виснет. Лог ноды (`log_node`) отключён.

---
---

# АРХИВ: предыдущее состояние на 2026-09-03, 01:00 (устарело)

## 🔴 С ЧЕГО НАЧАТЬ ЗАВТРА

**Что случилось:** VPN был полностью рабочим (Франкфурт на ПК и обоих телефонах), потом страницы перестали грузиться — сначала на Wi-Fi клиентах, затем и на проводном ПК.

**Что при этом ИСПРАВНО (проверено):**
- сервер: соединения с домашнего IP `<OLD_HOME_WAN_IP_1>` принимает, ошибок нет, load 0.24
- UDP через туннель идёт — NTP роутера доходит до сервера (`accepted udp:...:123`)
- DNS резолвит: `nslookup cloudflare.com 127.0.0.1` → 104.16.132.229
- UDP-сокет xray на 2001 на месте, патч `network` цел, память и CPU в норме (131 МБ свободно, 97% idle)
- `psw2-udp-guard.sh --check` — все OK

**Что сломано:** `curl -s https://1.1.1.1/cdn-cgi/trace` **с самого роутера** возвращает пусто. То есть TCP через туннель не завершается, хотя UDP идёт.

**Главный подозреваемый — Archer AX12.** В логе видно, что он непрерывно долбит DHCP (несколько запросов в секунду):
```
21:51:55 DHCPREQUEST ... 21:51:57 DHCPREQUEST ... 21:51:58 DHCPDISCOVER, DHCPOFFER, DHCPREQUEST, DHCPACK
```
Нормальное устройство обновляет аренду раз в часы. Так бывает при петле — например, если Archer соединён с hEX двумя кабелями (второй случайно в порт «Интернет») или у него включён ещё какой-то режим моста поверх AP.

**Первые шаги завтра (по порядку):**
1. Проверить физически: из Archer в hEX идёт **ровно один** кабель, порт «Интернет» на Archer пустой.
2. Вынуть кабель Archer из порта 2 hEX и проверить с роутера:
   `curl -s --max-time 15 https://1.1.1.1/cdn-cgi/trace | head -4`
   Заработало без Archer → виноват он. Не заработало → копаем xray.
3. Посмотреть, на каком шаге виснет запрос:
   `curl -sv --max-time 15 https://1.1.1.1/cdn-cgi/trace 2>&1 | tail -12`
   (не устанавливается TCP или не завершается TLS-рукопожатие)
4. Проверить прямое соединение мимо туннеля:
   `curl -s --max-time 10 -o /dev/null -w "%{http_code} %{time_total}s\n" -k https://<SERVER_IP>`
5. `grep -c '5\.231\.205\.193' /proc/net/nf_conntrack` — сколько соединений роутер держит к серверу.

**⚠️ НЕ ВКЛЮЧАТЬ `loglevel=debug` у PassWall2.** `/tmp` на роутере — это tmpfs, то есть оперативная память (248 МБ). Debug-лог xray раздувается и съедает её, роутер начинает еле шевелиться, SSH тормозит. Если всё же включили — вернуть `uci set passwall2.@global[0].loglevel='error'`, очистить `: > /tmp/etc/passwall2/acl/default.log`, перезагрузиться. Для отладки хватает счётчиков nftables и `/proc/net/nf_conntrack`.

**Ещё в работе (не начато):** сторож `/usr/bin/psw2-udp-guard.sh` установлен и проверен вручную, но **в cron не добавлен**:
```sh
echo '*/10 * * * * /usr/bin/psw2-udp-guard.sh' >> /etc/crontabs/root
/etc/init.d/cron enable && /etc/init.d/cron restart
```
Ставить после того, как VPN снова заработает.

---

# ✅ ЧТО УЖЕ РЕШЕНО И РАБОТАЛО (2026-09-02)

> История 2026-09-01 и 2026-09-02 ниже по тексту, с пометками где выводы оказались неверными.

## КОРОТКО — VPN ЗАПУЩЕН

**Всё работает.** Подтверждено с ПК №2 (`192.168.1.136`):
```
curl.exe -s https://1.1.1.1/cdn-cgi/trace
→ ip=<SERVER_IP>   colo=FRA   loc=DE
```
DNS резолвит честно, подмена провайдера больше не действует:
`youtube.com` → `142.251.14.93` и др., `rutracker.org` → `172.67.182.196` (Cloudflare), вместо прежних NXDOMAIN.

### Что оказалось причиной (два дня искали)

**Баг связки PassWall2 26.8.27-1 + xray 26.3.27:** PassWall2 генерирует у инбаунда поле `allowedNetwork`, которого xray 26.x **не знает**. Конфиг проходит проверку без ошибок, но инбаунд откатывается к дефолту `tcp` — «UDP-инбаунд» на порту 2001 поднимался вторым TCP-сокетом, и весь UDP, который nft гонит в `tproxy ip to :2001`, уходил в пустоту. Отсюда и «UDP через туннель не ходит», и мёртвый DNS. Подробности и доказательство — раздел «БАГ allowedNetwork».

### Финальная рабочая конфигурация

```sh
# 1. Правка генератора конфига xray (ГЛАВНОЕ, слетает при обновлении passwall2)
sed -i 's/allowedNetwork/network/g' /usr/lib/lua/luci/passwall2/util_xray.lua
#    бэкап оригинала: /usr/lib/lua/luci/passwall2/util_xray.lua.bak

# 2. PassWall2 — только транспорт, DNS он не трогает
uci set passwall2.@global[0].dns_redirect='0'
uci set passwall2.@global[0].remote_dns_protocol='udp'
uci commit passwall2

# 3. Резолвит https-dns-proxy (DoH через туннель), апстримы прописаны ЯВНО
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp

/etc/init.d/passwall2 restart && sleep 25 && /etc/init.d/dnsmasq restart
```

**Почему DNS отдан https-dns-proxy, а не встроенному DNS PassWall2.** Пробовали и `dns_redirect=1`: тогда все запросы шли `redirect to :2003` в PassWall2-dnsmasq, тот форвардил на `127.0.0.1#2002` (xray `dns-in`), а дальше цепочка **обрывалась в `dns-out`** — запросы в лог xray приходили (`accepted udp:127.0.0.1:2002 [dns-in -> dns-out]`), ответы не возвращались. Диагностика по звеньям:

| Звено | Результат |
|---|---|
| `nslookup cloudflare.com 127.0.0.1:5053` (DoH-прокси) | ✅ резолвит |
| `nslookup cloudflare.com 127.0.0.1:2002` (xray dns-out) | ❌ No answer |
| `nslookup cloudflare.com 127.0.0.1:2003` (PassWall2-dnsmasq) | ❌ No answer, следствие |

Копать внутренний DNS-модуль xray не стали — рядом было звено, которое уже работает. `https-dns-proxy` ходит к `1.1.1.1` по HTTPS, его TCP-соединение идёт через туннель, поэтому ответы приходят такие же, как их видит немецкий сервер, без подмены провайдера.

**Важно:** ранее `dns_redirect=0` ломал DNS потому, что PassWall2 вычищал у dnsmasq апстримы и своих не ставил — тот оставался с `no-resolv` и без единого общего `server=`. Теперь апстримы прописаны через `uci` в постоянный конфиг и переживают любые рестарты PassWall2.

Проверка, что всё поднялось:
```sh
grep -i 07D1 /proc/net/udp6                    # UDP-сокет на 2001 должен быть
nslookup youtube.com 192.168.1.1               # настоящие адреса, не NXDOMAIN
grep -rhE '^server=' /var/etc/dnsmasq.conf.*   # должны быть 127.0.0.1#5053 и #5054
nft list chain inet passwall2 PSW2_DNS         # должно быть 'return', а не 'redirect to :2003'
```

### Ещё две ловушки, найденные по дороге

1. **Дубли `dnsmasq_default`.** После серии рестартов PassWall2 старый процесс не умирает, два экземпляра дерутся за порт 2003 — DNS у клиентов молчит. Проверка: `pgrep -f dnsmasq_default | wc -l` должно быть не больше 1. Лечение: `/etc/init.d/passwall2 stop; pgrep -f dnsmasq_default | xargs -r kill; /etc/init.d/passwall2 start`.
2. **Два активных интерфейса на клиенте.** У ПК №2 был включён Wi-Fi в чужую сеть (`172.19.181.6`, свой шлюз и свой DNS) параллельно с Ethernet — часть трафика уходила мимо VPN, показания плавали. При диагностике лишние интерфейсы отключать: `netsh interface set interface "Беспроводная сеть" admin=disable`.

### ✅ Перезагрузку прошли (2026-09-02, 22:10)

После `reboot` всё поднялось само, без вмешательства:
- прозрачный путь с роутера: `curl -s https://1.1.1.1/cdn-cgi/trace` → `ip=<SERVER_IP>` за 0.77 сек
- ПК №2 в туннеле: `from 192.168.1.136:56600 accepted tcp:... [tcp_redir -> default:reality-server]`
- **UDP реально работает**: `from 10.76.96.65:58024 accepted udp:83.237.235.30:123 [udp_redir -> default:reality-server]` (NTP роутера через туннель)
- ресурсы: RAM 135 МБ свободно из 248, conntrack 109/31744, CPU 97% idle, OOM в dmesg нет

Учитывать: PassWall2 стартует **через 60 сек** после загрузки (`@global_delay[0].start_delay=60`). В этом окне трафик не идёт — не пугаться.

### ❗ Как правильно проверять туннель (важно!)

**Проверять обычным `curl -s https://1.1.1.1/cdn-cgi/trace`, а НЕ через `--socks5-hostname 127.0.0.1:1070`.**

Socks-путь на 1070 висит по 20 сек и таймаутит, хотя туннель полностью исправен. Причина: при `localhost_proxy=1` исходящий трафик самого роутера тоже заворачивается в прозрачный прокси (`from 10.76.96.65:52972 accepted tcp:1.1.1.1:443 [tcp_redir -> ...]`), поэтому соединение, которое xray открывает по socks-запросу, попадает обратно в его же inbound — петля. Прозрачный путь чист, потому что адрес сервера исключён через nftset `psw2_vps`.

**Вероятно, вчерашняя «деградация туннеля» была именно этим** — отваливался socks-тест, а не сам туннель.

### Осталось сделать

1. **Подключить домашний Wi-Fi роутер точкой доступа** — см. раздел «ПОСЛЕ ТОГО КАК VPN ЗАРАБОТАЕТ». Кратко: кабель LAN→LAN в порт 2 hEX (WAN-порт домашнего роутера НЕ используется), DHCP на нём выключить, статический IP `192.168.1.2`, шлюз и DNS `192.168.1.1`, IPv6 выключить.
2. Помнить: **обновление пакета passwall2 сотрёт правку `util_xray.lua`** и всё сломает снова. Поставлен сторож `/usr/bin/psw2-udp-guard.sh` (копия в `D:\JS\event\psw2-udp-guard.sh`), в cron каждые 10 минут: проверяет патч и наличие UDP-сокета на 2001, при пропаже чинит и перезапускает PassWall2. Ручная проверка — `psw2-udp-guard.sh --check`, лог — `/var/log/psw2-udp-guard.log`.
3. Время на роутере в UTC (показывает на 3 часа меньше московского) — при сверке логов роутера и сервера учитывать сдвиг.

---

## ПРОВЕРКА СЕРВЕРА (2026-09-02) — ВСЁ ИСПРАВНО

Доступ: `ssh root@<SERVER_IP>`, пароль из панели хостинга (<HOSTING_PANEL_ID>, hostname `<HOSTING_HOSTNAME>`, Ubuntu, ядро 7.0.0-15-generic, 4 CPU / 4 ГБ / 120 ГБ).
С Windows без `sshpass` пароль подаётся через `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` (plink зависает на запросе host key).

### Архитектура на сервере (выяснилось только сейчас)

На 443 слушает **nginx** (stream + `ssl_preread`), xray сидит ЗА НИМ на `127.0.0.1:8444`.
`/etc/nginx/stream.d/vpn-sni.conf`:
```
map $ssl_preread_server_name $sni_upstream {
    www.cloudflare.com  127.0.0.1:8444;   # → xray VLESS-Reality
    default             127.0.0.1:8443;   # → сайты eco-dev.ru / event-horosho.ru
}
server { listen 443; listen [::]:443; proxy_pass $sni_upstream; ssl_preread on; }
```
Маскировка корректная: с чужим SNI отдаются обычные сайты, а не reset.
Конфиг xray: `/usr/local/etc/xray/config.json`, inbound `listen 127.0.0.1:8444`, sniffing http+tls, outbounds только `freedom`/`blackhole`, секций routing/dns нет.

### Что проверено

| Проверка | Результат |
|---|---|
| xray 26.3.27 | `active` + `enabled`, `error.log` чист (только «started») |
| privateKey в config.json | `<REALITY_PRIVATE_KEY>` — **43 символа, целый**; обрезан был только в записи |
| publicKey (`xray x25519 -i`) | `<REALITY_PUBLIC_KEY>` — совпадает с нодой в PassWall2 |
| Время (критично для Reality) | NTP active, `System clock synchronized: yes`, дрейфа нет |
| UFW | 22/80/443 ALLOW, INPUT DROP, **OUTPUT ACCEPT** — исходящий UDP не режется |
| UDP наружу с сервера | `dig @1.1.1.1` отвечает |
| Сеть | congestion control **bbr**, `LimitNOFILE=1000000`, conntrack 65536, somaxconn 4096 |
| Ресурсы | RAM 1.7 ГБ свободно, диск 8 ГБ свободно, load 0.5 |
| nginx | переполнений нет (0 записей «worker_connections are not enough»), но `worker_connections 768` — держать в виду |

### ❗ ГЛАВНОЕ ОПРОВЕРЖЕНИЕ: UDP ЧЕРЕЗ ТУННЕЛЬ РАБОТАЕТ

Вывод от 2026-09-01 «через этот туннель UDP не ходит, только TCP» — **НЕВЕРЕН**.
`/var/log/xray/access.log` за 3 дня: **23 936 UDP-сессий** против 32 676 TCP, в том числе прямо сейчас:
```
accepted udp:1.1.1.1:53 [direct]
accepted udp:142.250.130.95:443 [direct]   ← QUIC
```
Значит серверный VLESS-inbound проксирует и TCP, и UDP. Причина проблем с DNS — целиком на стороне роутера.
**Следствие:** пункт «альтернатива: DoT/DoH ради TCP» перестаёт быть обязательным, обычный UDP-DNS через туннель должен работать.

### Замечания по серверу (не блокеры)

1. xray видит все соединения как `127.0.0.1` — nginx не передаёт proxy_protocol (`xver: 0`). Лечится `proxy_protocol on` + `"xver": 1`, нужно только ради логов.
2. Сервер общий с продакшн-сайтами eco-dev.ru и event-horosho.ru — VPN делит с ними канал и nginx-воркеры.
3. 25-й порт закрыт хостером — к VPN отношения не имеет.

---

## СОСТОЯНИЕ РОУТЕРА (2026-09-02, вечер)

### ⚠️ Ловушка диагностики: правила PassWall2 НЕ в таблице fw4

`nft list chain inet fw4 PSW2_MANGLE` возвращает пустоту — и это НЕ значит, что правил нет.
При `prefer_nft=1` PassWall2 создаёт **свою таблицу `inet passwall2`**. Правильные команды:
```sh
nft list tables                       # → inet fw4, inet https_dns_proxy_notrack, inet passwall2
nft list table inet passwall2
cat /var/etc/passwall2/PSW2_RULE.nft  # исходник правил, который грузит PassWall2
```
На эту ловушку потеряли один заход диагностики — не повторять.

### Что реально настроено (проверено)

- Правила на месте: цепочки `PSW2_MANGLE`, `PSW2_NAT`, `PSW2_DNS`, `PSW2_RULE`, `PSW2_OUTPUT_*`, сеты `psw2_direct/local/vps/wan`
- Из лога `/tmp/log/passwall2.log`: `nftables firewall rules load complete!`, `[Default] Use the TCP node [reality-server](REDIRECT:2001)`, `Use the UDP node [reality-server](TPROXY:2001)`
- `kmod-nft-tproxy`, `kmod-nf-tproxy`, `kmod-nft-socket`, `kmod-nft-nat` установлены, модули `nft_tproxy`/`nf_socket_ipv4` загружены — с ядром всё в порядке
- Нода работает: `curl --socks5-hostname 127.0.0.1:1070 https://ipinfo.io/json` → Frankfurt / DE / <SERVER_IP>
- `uci show passwall2.@global_forwarding[0]`: `tcp_proxy_way=redirect`, `prefer_nft=1`, `tcp_redir_ports=1:65535`, `udp_redir_ports=1:65535`, `ipv6_tproxy=0`
- WAN IP сменился на `10.76.96.65` (CGNAT, lease 1ч)

### ❗ НАЙДЕННАЯ ПРИЧИНА: xray не слушает UDP на 2001

```
netstat -lntp | grep xray
tcp  127.0.0.1:2002   LISTEN  xray
tcp  127.0.0.1:1070   LISTEN  xray      ← socks
tcp  :::2001          LISTEN  xray      ← TCP redirect-инбаунд, есть
netstat -lnup | grep xray
udp  127.0.0.1:1070           xray      ← и ВСЁ. UDP на 2001 НЕТ
```
А nft-правило отправляет туда весь UDP:
```
ip protocol udp counter meta mark 0x50535732 tproxy ip to :2001 comment "Default"
```
UDP уходит на порт, где нет слушателя → теряется. Поэтому DNS молчит даже на самом роутере:
`nslookup youtube.com 192.168.1.1` → `connection timed out`.

Счётчики в цепочках нулевые — но это ожидаемо после рестарта сервиса, не признак неработающих правил.

### Побочная зацепка по DNS

PassWall2 в лог пишет:
```
- Add ISP IPv4 DNS to the whitelist: 77.37.251.33 / 77.37.255.30
- Add direct DNS to nftables: 127.0.0.1:5053 / 127.0.0.1:5054
```
То есть DNS провайдера он сознательно выпускает мимо туннеля (а провайдер его травит), и DoH-прокси помечен как direct. Разбираться после того, как поднимется UDP-инбаунд.

### ❗ БАГ allowedNetwork — корень проблемы с UDP/DNS

В `/tmp/etc/passwall2/acl/default.json` PassWall2 генерирует:
```json
{ "port": 2001, "protocol": "tunnel",
  "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
  "settings": {"allowedNetwork": "udp", "followRedirect": true},
  "tag": "udp_redir" }
```
Xray 26.3.27 поля `allowedNetwork` **не знает** — принимает конфиг без ошибок (`Configuration OK`), но открывает TCP.

Проверено экспериментально на сервере (xray той же версии 26.3.27), 4 варианта:

| Конфиг инбаунда | Что открывает xray |
|---|---|
| `protocol: tunnel` + `allowedNetwork: udp` | TCP ❌ |
| `protocol: dokodemo-door` + `allowedNetwork: udp` | TCP ❌ |
| `protocol: tunnel` + `network: udp` | **UDP** ✅ |
| `protocol: dokodemo-door` + `network: udp` | **UDP** ✅ |

Подтверждение на роутере: `grep -i 07D1 /proc/net/udp /proc/net/udp6 /proc/net/tcp /proc/net/tcp6` →
на порту 2001 (hex 07D1) **только два сокета в `/proc/net/tcp6`**, в UDP — ничего.

### ЛЕЧЕНИЕ

Найти, где PassWall2 пишет это поле, и заменить на `network`:
```sh
grep -rn 'allowedNetwork' /usr/lib/lua/luci/passwall2/ /usr/share/passwall2/ 2>/dev/null
cp <найденный_файл> <найденный_файл>.bak
sed -i 's/allowedNetwork/network/g' <найденный_файл>
/etc/init.d/passwall2 restart
sleep 25
grep -n '"network"' /tmp/etc/passwall2/acl/default.json      # должно появиться в инбаундах
grep -i 07D1 /proc/net/udp /proc/net/udp6                    # должен появиться UDP-сокет на 2001
nslookup youtube.com 192.168.1.1                             # должен ответить
```
**Правка слетит при обновлении пакета passwall2** — после каждого обновления повторять.

---

# ↓↓↓ ИСТОРИЯ ОТ 2026-09-01 (часть выводов устарела) ↓↓↓

## КОРОТКО (было 2026-09-01)

**Работает:** OpenWrt на роутере, нода VLESS-Reality, прозрачный прокси (трафик клиентов реально идёт через сервер в Германии — подтверждено).
**Не работает:** DNS.

---

## ЧТО ПОДТВЕРЖДЕНО РАБОЧИМ

1. **OpenWrt 25.12 на MikroTik hEX RB750Gr3**, extroot на USB-флешке (/overlay ~3.6 ГБ), грузится сам, стабилен.
2. **WAN**: провайдер по DHCP, `10.76.177.126/16` (CGNAT), gw `10.76.0.1`, lease 1ч, стабилен (60 пингов 0% потерь). Провайдер — AS42610 OJSC National Cable Networks (Москва), внешний IP `<OLD_HOME_WAN_IP_2>`.
3. **IPv6 выключен** (`network.wan6.disabled=1`, `dhcp.lan.ra/dhcpv6/ndp=disabled`) — иначе клиенты ходили в обход IPv4-прокси.
4. **Нода VLESS-Reality работает**: `curl --socks5-hostname 127.0.0.1:1070 https://ipinfo.io/json` → `Frankfurt am Main, DE, <SERVER_IP>`.
5. **Прозрачный прокси работает для клиентов** — ГЛАВНОЕ подтверждение, с ПК №2:
   ```
   curl.exe -s https://1.1.1.1/cdn-cgi/trace
   → ip=<SERVER_IP>
     loc=DE
   ```
   Также `curl.exe https://ipinfo.io/json` с ПК №2 однажды вернул полный Frankfurt/DE.
   В логе xray видно: `from 192.168.1.136:xxxxx accepted tcp:<ip>:443 [tcp_redir -> default:reality-server]`.
6. **DoH (https-dns-proxy) обходит подмену провайдера** — при ВЫКЛЮЧЕННОМ PassWall2:
   `nslookup youtube.com` → `142.250.150.190` и др. настоящие Google IP (а не NXDOMAIN).

## ГЛАВНАЯ ПРОБЛЕМА — DNS

**Провайдер перехватывает и травит DNS.** Доказательство: клиент шлёт запрос на `1.1.1.1` напрямую (UDP 53) →
- `youtube.com` → **NXDOMAIN** («Non-existent domain»)
- `api.ipify.org` → `8.6.112.0` / `8.47.69.0` (фейк)
- `ipinfo.io` (не заблокирован) → резолвится нормально и открывается **через Германию**

**Почему DNS не идёт в туннель:**
- В `PSW2_MANGLE` первое правило: `ip protocol udp udp dport 53 counter packets 997 accept` — PassWall2 намеренно ИСКЛЮЧАЕТ порт 53 из туннеля (рассчитывает обработать своим механизмом). При `dns_redirect=0` DNS остаётся без присмотра и утекает провайдеру.
- Если удалить это правило (`nft delete rule ... handle N`) — DNS уходит в UDP-tproxy и не возвращается. ~~Значит UDP через туннель не ходит~~ — неверный вывод, см. проверку сервера выше: дело в локальном UDP-tproxy на роутере, а не в туннеле.

~~**Ключевой вывод дня: TCP через туннель работает отлично, UDP — нет.**~~ — ❌ **ОПРОВЕРГНУТО 2026-09-02**: на сервере в access.log десятки тысяч UDP-сессий. UDP через туннель ходит. Проблема была в отсутствии nft-правил PassWall2 на роутере.

## ГДЕ ОСТАНОВИЛИСЬ

Поставлен `https-dns-proxy` (DoH по TCP/443):
- Cloudflare на `127.0.0.1:5053`, Google на `127.0.0.1:5054`
- `resolver_url` переставлен на голые IP, чтобы не нужен был UDP-бутстрап:
  `https://1.1.1.1/dns-query` и `https://8.8.8.8/dns-query`
- dnsmasq автоматически перенастроен: `server='127.0.0.1#5053' '127.0.0.1#5054'`, `noresolv=1`

**Результат:**
- PassWall2 ВЫКЛ → DoH резолвит правильно ✅
- PassWall2 ВКЛ → DNS таймаутит ❌, но туннель при этом жив (`ip=<SERVER_IP>, loc=DE`)
- В логе xray видно, что DoH-соединение **заходит в туннель**: `from 10.76.177.126:50262 accepted tcp:1.1.1.1:443 [tcp_redir -> default:reality-server]` — но ответ не доходит

### Следующий шаг (с этого продолжать)

Не успели выполнить последнюю диагностику:
```sh
echo "=== DoH через curl (работает ли DoH сквозь туннель вообще) ==="
curl -s --max-time 15 -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=youtube.com&type=A' | head -c 300; echo
echo "=== https-dns-proxy ==="
ps w | grep https-dns-prox | grep -v grep
logread | grep -i 'dns-proxy' | tail -10
echo "=== чем РЕАЛЬНО резолвит запущенный dnsmasq ==="
ps w | grep dnsmasq | grep -v grep
grep -hE '^server=|^no-resolv' /var/etc/dnsmasq.conf.* /tmp/etc/passwall2/acl/*dnsmasq.conf 2>/dev/null
```

Гипотезы, что проверять:
1. **PassWall2 перетирает конфиг dnsmasq** при старте (у него свой `dnsmasq_default`), затирая апстримы DoH `127.0.0.1#5053`. Проверить реальный конфиг работающего dnsmasq.
2. https-dns-proxy работает от юзера `nobody` — возможно, его коннект не проходит там, где проходит root'овый curl.
3. Порядок запуска: https-dns-proxy при рестарте трогает firewall («Updating notrack rules», «Setting trigger for wan») и сбивает правила PassWall2. Нужно, чтобы PassWall2 стартовал ПОСЛЕ него. Закрепить через зависимость в init-скрипте или `START=` приоритет.
4. Альтернатива: `stubby` (DNS-over-TLS, TCP 853) вместо DoH.
5. Альтернатива: вообще отказаться от PassWall2 и собрать минимальный xray + свои nft-правила (см. ниже).

## ТЕКУЩЕЕ СОСТОЯНИЕ РОУТЕРА (как оставили)

PassWall2 включён (`enabled=1`, `dns_redirect=0`), автозапуск включён. **DNS у клиентов не работает.**

**Чтобы вернуть нормальный интернет без VPN:**
```sh
ssh root@192.168.1.1
/etc/init.d/passwall2 stop
/etc/init.d/passwall2 disable
uci set passwall2.@global[0].enabled='0'
uci commit passwall2
/etc/init.d/dnsmasq restart
```
После этого DNS работает через DoH, интернет обычный, без VPN.

**Чтобы включить VPN обратно:**
```sh
uci set passwall2.@global[0].enabled='1'
uci commit passwall2
/etc/init.d/passwall2 enable
/etc/init.d/passwall2 restart
```

## КЛЮЧЕВЫЕ НАСТРОЙКИ PassWall2 (что выяснили опытным путём)

| Настройка | Значение | Комментарий |
|---|---|---|
| `enabled` | 1/0 | главный вкл/выкл |
| `node` | `LgCRCnyE` | нода reality-server |
| `dns_redirect` | **1** | `0` ломает DNS и роутеру, и клиентам; при `1` DNS-цепочка работает, но нестабильна и разваливается после рестартов |
| `remote_fakedns` | 1 | без него был DNS-шторм и мелтдаун роутера |
| `remote_dns_protocol` | tcp/udp | пробовали оба |
| `remote_dns` | 1.1.1.1 | |
| `localhost_proxy` / `client_proxy` | 1 | |
| `loglevel` | error/debug | `debug` пишет в `/tmp/etc/passwall2/acl/default.log` |
| `@global_forwarding[0].tcp_proxy_way` | redirect | |
| `@global_delay[0].start_delay` | 60 | PassWall2 стартует через 60 сек после загрузки |

**Осторожно:** `dns_redirect=0` + `remote_dns_protocol=tcp` БЕЗ работающей ноды = DNS-шторм → conntrack переполняется → роутер зависает намертво, нужен power-cycle. Так было в офисе.

## ВАЖНЫЕ ФАКТЫ / ЛОВУШКИ

- **`Running in no proxy mode` в `/tmp/log/passwall2.log` — ЛОЖНЫЙ СЛЕД.** Это строка 697 в `/usr/share/passwall2/app.sh`, относится к блоку автообновления гео-файлов, а не к прокси. Прокси при этом работает.
- **`udhcpc: no lease, failing`** — косметика, лезет только при рестартах PassWall2 (его правила ловят DHCP-пакеты роутера). WAN стабилен.
- **`loopback connection detected`** в логе xray — накапливается (видели до 468). Коррелирует с деградацией. Не докопались до конца.
- **Туннель деградирует со временем**: работает после старта, через несколько минут `curl --socks5` перестаёт отвечать. Ресурсы при этом в норме (conntrack 846/31744, RAM 115 МБ свободно, fd 880 при лимите 65535). Причина не найдена. Возможно: mux выключен → сотни отдельных TCP к серверу → лимит на стороне сервера или CGNAT провайдера.
- В PowerShell `curl` = алиас Invoke-WebRequest, нужен **`curl.exe`**.
- BusyBox `nc` на роутере урезанный, без `-w`. Для проверки TCP использовать `curl`.
- При вставке многострочных блоков в SSH иногда **теряется первый символ строки** (`uci`→`ci`, `cat`→`at`). Всегда проверять, что команда выполнилась.

## СХЕМА ПОДКЛЮЧЕНИЯ СЕЙЧАС

```
провайдер → ПОРТ 1 hEX (WAN)
ПК №2 (DESKTOP-I2PGFTT) → ПОРТ 3 hEX, получает 192.168.1.136
домашний Wi-Fi роутер — ОТКЛЮЧЁН на время настройки
```

Claude Code работает на **ПК №1** (не подключён к роутеру, свой интернет). Пользователь вручную переносит команды на ПК №2 (`ssh root@192.168.1.1`) и возвращает вывод.

## ПАРАМЕТРЫ VLESS-СЕРВЕРА (проверены)

```
address   <SERVER_IP>      port 443
uuid      <VLESS_UUID>
flow      (пусто)
network   tcp / raw          security reality      encryption none
sni       www.cloudflare.com
publicKey <REALITY_PUBLIC_KEY>
shortId   <REALITY_SHORT_ID>   fingerprint chrome
```
Сервер: `ssh root@<SERVER_IP>`, конфиг `/usr/local/etc/xray/config.json`. Хостинг GHOSTnet GmbH, Франкфурт. **Важно:** 443 держит nginx (SNI-роутинг), xray за ним на 127.0.0.1:8444 — см. раздел «ПРОВЕРКА СЕРВЕРА».

## ПЛАН Б — свой минимальный xray + tproxy (если PassWall2 не дожмём)

Отказаться от PassWall2, оставить только `/usr/bin/xray` и свои правила:
- **config.json**: inbound `dokodemo-door` tproxy (порт 12345, tcp+udp, followRedirect, sniffing tls/http) + outbounds: proxy (vless-reality), direct, block. routing: `geoip:private → direct`, остальное → proxy.
- **nft** (таблица `ip xrayvpn`, chain prerouting hook prerouting priority mangle):
  `iifname "br-lan" ip daddr != {приватные} ip protocol tcp tproxy to 127.0.0.1:12345 meta mark set 1 accept`
- `ip rule add fwmark 1 table 100` + `ip route add local default dev lo table 100`
- DNS — только DoH (https-dns-proxy уже стоит), никакого UDP
- свой `/etc/init.d/xrayvpn` для автозапуска

Плюс: всё детерминировано, нет чёрного ящика PassWall2, который перетирает dnsmasq и firewall.

## ПОСЛЕ ТОГО КАК VPN ЗАРАБОТАЕТ

1. Проверить перезагрузкой, что поднимается сам.
2. **Домашний Wi-Fi роутер → режим точки доступа** (у hEX своего Wi-Fi НЕТ):
   - выключить на нём DHCP-сервер
   - кабель из **LAN**-порта домашнего роутера (не WAN) → порт 2 hEX
   - дать ему статический IP `192.168.1.2`, шлюз `192.168.1.1`
   - Wi-Fi оставить включённым
   - весь Wi-Fi трафик пойдёт через hEX → VPN
3. Проверить с телефона по Wi-Fi: `ipinfo.io` → должна быть Германия.

## ИСТОРИЯ ПРОШИВКИ (для справки)

Подробности как прошивали OpenWrt (грабли v7-загрузчика, netboot через 23.05.0-rc3, tinyPXE+Tftpd64, имя файла `vmlinux`, восстановление через NetInstall) — в файле `mikrotik-openwrt-setup-progress.md`.
