# Домашний VPN на hEX + PassWall2 — инструкция на будущее

> Свод самого важного из настройки 2026-09-01 → 2026-09-04. Если VPN снова
> сломается через месяцы — начинать отсюда, не изобретать заново.

## Архитектура (как это устроено)

```
провайдер (Москва, AS42610, CGNAT) → ETHER1 hEX (WAN)
hEX [OpenWrt 25.12 + PassWall2 + xray] → ETHER2 hEX
Archer AX12 в режиме точки доступа (мост) → устройства по Wi-Fi
```

- **Роутер:** MikroTik hEX RB750Gr3, OpenWrt 25.12, `ssh root@192.168.1.1`.
  extroot на USB-флешке (`/overlay` ~3.6 ГБ), NAND всего 16 МБ.
- **VPN-сервер:** `<SERVER_IP>` (Франкфурт, хостинг GhostNET, hostname
  `<HOSTING_HOSTNAME>`), `ssh root@<SERVER_IP>`, пароль по SSH_ASKPASS (см. ниже).
  На сервере же крутятся сайты `eco-dev.ru`, `event-horosho.ru`.
- **Протокол:** VLESS + Reality, порт 443. На сервере порт 443 держит
  **nginx** (не xray!) — `stream` + `ssl_preread` разбирает SNI:
  `www.cloudflare.com` → `127.0.0.1:8444` (xray), всё остальное →
  `127.0.0.1:8443` (сайты). Конфиг: `/etc/nginx/stream.d/vpn-sni.conf`.
- **Резервные порты на сервере** (уже открыты и проверены):
  `2053, 2083, 993, 8080`, все ведут в тот же xray на 8444.
  Конфиг: `/etc/nginx/stream.d/alt-ports.conf`, открыты в `ufw`.
- **Нода в PassWall2:** `LgCRCnyE` (remarks `reality-server`).

## Параметры подключения (VLESS-Reality)

| Параметр | Значение |
|---|---|
| Адрес | `<SERVER_IP>`, порт `443` (запасные: 2053/2083/993/8080) |
| UUID | `<VLESS_UUID>` |
| Security | reality, SNI `www.cloudflare.com` |
| Public Key | `<REALITY_PUBLIC_KEY>` |
| Short ID | `<REALITY_SHORT_ID>` |
| **Fingerprint** | **`safari`** (НЕ chrome! см. ниже почему) |
| Network / Flow | raw / tcp, flow пустой, encryption none |

## ⚠️ ГЛАВНЫЕ УРОКИ — 4 причины падений, все независимые

Все давали один и тот же симптом «VPN то работает, то нет» — не путать их
между собой, диагностировать по порядку.

### 1. Fingerprint `chrome` → DPI режет рукопожатие (держалась 5 дней, главная)

`fingerprint='chrome'` добавляет в TLS ClientHello постквантовый ключ
X25519MLKEM768 (+1216 байт). Рукопожатие вырастает до 1728–1824 байт, не
влезает в один TCP-сегмент — московский DPI такие обрывает. TCP при этом
устанавливается, рвётся именно первый пакет с данными.

**Подпись:** `netstat -tn | grep :443` → Send-Q застревает на ~1800 у всех
соединений; `awk '/^Tcp:/{if(++n==2) print $12,$13}' /proc/net/snmp` →
огромный % ретрансмиссий.

**Лечение:**
```sh
uci set passwall2.LgCRCnyE.fingerprint='safari'
uci commit passwall2 && /etc/init.d/passwall2 restart
```
Запасные варианты: `firefox`, `ios`. Сервер трогать не нужно.

### 2. Часы уезжают после ребута → Reality не встаёт

У hEX нет батарейки RTC. После перезагрузки время может отставать на
десятки часов (был случай 18ч42м) — Reality использует временную метку
хендшейка, при таком расхождении он не проходит. Замкнутый круг: без
времени нет туннеля → без туннеля нет DNS → без DNS не резолвится
`pool.ntp.org`.

**Лечение — NTP по голым IP, DNS не нужен:**
```sh
uci -q delete system.ntp.server
uci add_list system.ntp.server='216.239.35.0'
uci add_list system.ntp.server='216.239.35.4'
uci add_list system.ntp.server='162.159.200.1'
uci add_list system.ntp.server='162.159.200.123'
uci set system.ntp.enabled='1'
uci commit system && /etc/init.d/sysntpd restart
```
Первая проверка при любом «не работает»: `date -u` на роутере.

### 3. `tcp_max_orphans` слишком мал → туннель умирает за 2–4 минуты

Xray без mux открывает много отдельных TCP; лимит `net.ipv4.tcp_max_orphans`
(дефолт может быть занижен, был 1024) исчерпывается, ядро рубит новые
соединения. Симптом: работает после старта, через пару минут всё умирает,
хотя ресурсы (RAM/CPU) в норме. Ищется в `dmesg | grep orphan`.

**Лечение — `/etc/sysctl.d/99-xray-tuning.conf`:**
```
net.ipv4.tcp_max_orphans=8192
net.ipv4.tcp_max_tw_buckets=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_orphan_retries=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_syncookies=1
```

### 4. Баг PassWall2 `allowedNetwork` → UDP-инбаунд не поднимается

PassWall2 26.8.27-1 генерирует инбаунду поле `allowedNetwork`, которого
xray 26.x не знает — конфиг проходит проверку, но инбаунд откатывается к
`tcp`. Весь UDP (в т.ч. DNS), который nft шлёт в tproxy, теряется.

**Лечение (слетает при обновлении пакета passwall2):**
```sh
grep -rn 'allowedNetwork' /usr/lib/lua/luci/passwall2/ /usr/share/passwall2/
sed -i 's/allowedNetwork/network/g' <найденный_файл>
/etc/init.d/passwall2 restart
```
Проверка: `grep -i 07D1 /proc/net/udp /proc/net/udp6` должен показать сокет.

## ⛔ Проверено и ИСКЛЮЧЕНО — не тратить время заново

MTU (1500/1400/1280 — без разницы), ключи Reality (сходятся точно),
расхождение часов после NTP-фикса (секунды, не часы), conntrack-лимиты,
версии xray (совпадают на роутере и сервере), блокировка по SNI (все SNI
долетают), файрвол сервера (ufw чист), DHCP-петля на Archer (следствие,
не причина), сторож `psw2-udp-guard.sh` (сам был причиной ложных
рестартов — навсегда отключён, `#DISABLED` в `/etc/crontabs/root`).

## Как проверять, что всё живо

```sh
ssh root@192.168.1.1
date -u                                            # часы (UTC)
uci get passwall2.LgCRCnyE.fingerprint             # должно быть safari
/etc/init.d/passwall2 status                       # ('status' не даёт статуса — юзать ps)
ps w | grep xray                                   # процесс должен быть
curl -s --max-time 15 https://ifconfig.me; echo    # должен вернуть <SERVER_IP>
curl -s https://1.1.1.1/cdn-cgi/trace              # colo=FRA, loc=DE
netstat -tn | grep :443 | head                     # Send-Q не должен застревать на ~1800
/usr/bin/psw2-portguard.sh --check                 # доступность резервных портов
```

⚠️ **НЕ включать `loglevel=debug` у PassWall2** — `/tmp` это RAM (120–250 МБ),
debug-лог xray её съедает, роутер виснет.

## Обход провайдерской подмены/блокировки

- **Смена отпечатка** (safari/firefox/ios) — против DPI, разобрано выше.
- **Автосмена портов** — `psw2-portguard.sh` в cron каждые 5 минут
  (`/usr/bin/psw2-portguard.sh`, копия в `D:\JS\event\psw2-portguard.sh`).
  При 2 провалах проверки подряд и вне 20-минутного окна перебирает
  `443 → 2053 → 2083 → 993 → 8080`. Если туннель жив — не трогает ничего
  (важно: старый сторож делал наоборот и сам всё ломал, этот — с оглядкой).
  Использует реальный узел `LgCRCnyE`, даже когда активна нода-шунт —
  подстава для этого зашита в скрипт (`protocol=_shunt` → берём
  `default_node`).
- **Резервный IP `<SERVER_IP_2>`** — куплен, но НЕ настроен и НЕ проверен.
  Доступ пока только через VNC-консоль `<VNC_HOST_IP>:10311`
  (не SSH — обычный SSH порт 22 не отвечает). Настройка отложена.
- **Российские сайты — в обход VPN** (настроено 2026-09-04, чтобы банки/
  Госуслуги не палили VPN и не требовали его отключить):
  ```sh
  uci set passwall2.rulenode.default_node='LgCRCnyE'
  uci set passwall2.rulenode.Russia='_direct'
  uci set passwall2.rulenode.shunt_group='RU'
  uci set passwall2.@global[0].node='rulenode'
  uci commit passwall2 && /etc/init.d/passwall2 restart
  ```
  Работает через встроенную группу `Russia` (`geoip:ru`) в PassWall2.
  Проверка: `nslookup yandex.ru 127.0.0.1` должен дать настоящий рос. IP,
  а не мимо DNS-подмены. Если что-то из заблокированных в РФ ресурсов
  вдруг перестанет открываться — это нормально (не настроена база
  `ru-blocked`, её нет в текущих geoip/geosite dat-файлах), лечится
  добавлением ручного домена в `ProxyFront`/отдельную группу.

## Полезные команды

```sh
curl -s --max-time 15 https://ifconfig.me; echo          # жив ли туннель
curl -s -x socks5h://127.0.0.1:1070 https://1.1.1.1/cdn-cgi/trace  # нода напрямую (ловушка: если localhost_proxy=1, сам роутер тоже заворачивается — путь может ложно таймаутить, ориентир — curl https:// без socks)
netstat -tn | grep '<SERVER_IP>:443' | head            # Send-Q ~1800 → снова fingerprint
awk '/^Tcp:/{if(++n==2) print "Out="$12" Retrans="$13}' /proc/net/snmp
date -u
nft list tables                                            # должно быть 'inet passwall2'
nft list table inet passwall2                              # правила PassWall2 — своя таблица, НЕ inet fw4!
grep -c '5\.231\.205\.193' /proc/net/nf_conntrack           # сколько соединений держим к серверу
```

## Доступ к серверу с Windows без sshpass/plink

```sh
echo 'пароль' > askpass.sh   # chmod +x
export SSH_ASKPASS=путь_до_askpass.sh
export SSH_ASKPASS_REQUIRE=force
ssh root@<SERVER_IP> "команда" < /dev/null
```
`scp`/sftp на роутере не работают (нет `/usr/libexec/sftp-server`) —
передавать файлы через `ssh root@192.168.1.1 "cat > /путь" < локальный_файл`.

## Известные ограничения

- **Потолок скорости VPN — CPU роутера, НЕ канал провайдера.** Уточнено
  2026-09-04 (вывод от 2026-09-03 про «международный канал провайдера
  ограничен ~15 Мбит» был ОШИБОЧНЫМ — основан на тесте к серверу с плохим
  пирингом). Реальные замеры 2026-09-04:
  - без VPN, 4 параллельных потока на Cloudflare → **~162 Мбит/с суммарно**
    (канал провайдера огромный, не бутылочное горлышко)
  - через VPN, один поток → **8.6–11.8 Мбит/с**, CPU при этом **87% занят**
  - через VPN, spedtest.net (несколько параллельных потоков) →
    **~25 Мбит/с** (пользовательский замер)

  **Причина:** hEX MT7621 — слабый двухъядерный MIPS **без аппаратного
  AES** (нет AES-NI/крипто-блока). VLESS+Reality шифруется программно,
  и это упирается в CPU примерно на 20–30 Мбит/с суммарно (несколько
  параллельных потоков используют оба ядра лучше одного). Добавленный
  шунтинг (см. раздел про обход РФ-сайтов) добавляет ещё нагрузки на CPU
  (проверка каждого соединения по geoip) — с ним просадка примерно на
  четверть по сравнению с тем же тестом без шунта.

  **Диагностика:** если скорость через VPN низкая — смотреть `top -bn1`
  во время передачи. Если `idle` близко к 0% и процесс `xray` жрёт
  70-90%+ — упираемся в CPU, не в канал и не в сервер.
  **Лечение** — только апгрейд роутера на платформу с аппаратным AES
  (x86 мини-ПК, ARM с крипто-расширениями). Программными твиками не
  лечится.
- **У hEX нет Wi-Fi** — обязательно нужна отдельная точка доступа (сейчас
  Archer AX12 в режиме моста).
- **PassWall2 стартует через 60 сек после загрузки роутера**
  (`@global_delay[0].start_delay=60`) — в этом окне трафика не будет,
  это нормально.

## Прошивка (если роутер снова понадобится перепрошить)

Все грабли v7-загрузчика, netboot через 23.05.0-rc3, extroot, установка
PassWall2 — подробно в `D:\JS\event\mikrotik-openwrt-setup-progress.md`.
Инструменты для прошивки (tinyPXE, Tftpd64, образы) больше не нужны —
роутер грузится из NAND сам.
