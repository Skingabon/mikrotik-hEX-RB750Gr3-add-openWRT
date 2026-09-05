# MikroTik RB750Gr3 → OpenWrt + PassWall2: журнал настройки

> Файл для продолжения настройки дома. Открыть на домашнем ПК, показать Claude, продолжить с раздела **«ЧТО ОСТАЛОСЬ»**.

## Железо

- MikroTik RB750Gr3 (hEX), revision **r4**, куплен б/у за 6500 ₽
- SoC MediaTek MT7621, target OpenWrt `ramips/mt7621`, архитектура пакетов `mipsel_24kc`
- 16 МБ NAND (мало → пришлось делать extroot на USB), 256 МБ RAM
- Заводской RouterBOOT/RouterOS: **7.19.6** (это загрузчик **v7**)
- USB-флешка 4 ГБ воткнута в USB-порт роутера — на ней overlay (extroot)

## ЧТО УЖЕ СДЕЛАНО

### 1. Прошивка OpenWrt (заняла несколько часов, куча граблей)

**Главная грабля:** RouterBOOT v7 (7.19.6) НЕ грузит современные initramfs OpenWrt (24.10, 25.12) по netboot — образ передаётся целиком, но ядро не стартует, LAN не поднимается.

**Рабочий путь оказался такой:**
1. netboot **именно `openwrt-23.05.0-rc3` initramfs** (sha256 `f03592dcd1b75947bb0f51af5bb430a4b6ab3292451e37d22ea397a8fd1b31d2`, ~5.4 МБ) — эта версия на плате r4 заводится и поднимает LAN на 192.168.1.1
2. из неё через LuCI (System → Backup/Flash Firmware) прошит в NAND образ **`openwrt-25.12.0-ramips-mt7621-mikrotik_routerboard-750gr3-squashfs-sysupgrade-v7.bin`** (sha256 `c5cd067d2a1d4c3244edd0be7b0479b5347e4bf4d813f599828b33eca4fe965d`) — обязательно вариант с суффиксом **`-v7`**, обычный даёт bootloop

**Как делали netboot (Windows):**
- Восстановление в заводское состояние: **MikroTik NetInstall** + `routeros-7.24.1-mmips.npk` (архитектура hEX = `mmips`)
- В RouterOS: `/system routerboard settings set boot-device=try-ethernet-once-then-nand boot-protocol=bootp`
  (после NetInstall сбрасывается в `nand-if-fail-then-ethernet` — вернуть в `try-ethernet-once-then-nand`)
- DHCP/BOOTP — **tinyPXE Server** (в `config.ini`: `tftpd=0`, только DHCP; `Next-Server`/`Option 54` = IP ПК; `Filename=vmlinux`; убрать `--force-reinstall` не тут). Свой TFTP у tinyPXE НЕ работает — отдаёт `tsize 0`, RouterBOOT отклоняет.
- TFTP — **отдельно Tftpd64** (только TFTP, DHCP выключить). `Server interfaces` = IP ПК, Base Directory = папка с файлом
- Файл образа на TFTP назвать **`vmlinux`** (без расширения) — RouterBOOT запрашивает именно это имя
- Брандмауэр Windows — **полностью выключить** (`netsh advfirewall set allprofiles state off`), иначе режет входящие TFTP ACK
- ПК статикой `192.168.1.2/24`, кабель в **ETHER1** для netboot; после загрузки initramfs LAN на ETHER2–5 / 192.168.1.1
- Триггер netboot из RouterOS: кабель в порт 2, `/system reboot` в Winbox-терминале, сразу переткнуть кабель в порт 1
- Winbox по MAC-адресу («Neighbors») — спасение, когда IP не совпадают
- MAC ether1 роутера: `04:F4:1C:D8:38:DB`

### 2. extroot на USB (16 МБ NAND мало для PassWall2)

Сделано на работающем OpenWrt 25.12:
```
apk add block-mount kmod-usb-storage kmod-usb2 kmod-fs-ext4 e2fsprogs
DEV=/dev/sda1
mkfs.ext4 -F $DEV
mount $DEV /mnt && cp -a /overlay/. /mnt/ && umount /mnt
eval $(block info $DEV | grep -o 'UUID="\S*"')
uci set fstab.extroot="mount"
uci set fstab.extroot.uuid="$UUID"
uci set fstab.extroot.target="/overlay"
uci set fstab.extroot.enabled="1"
uci commit fstab
reboot
```
Результат: `/overlay` теперь ~3.6 ГБ на `/dev/sda1` (ext4). Проверка: `df -h`, `mount | grep overlay`.

**ВНИМАНИЕ:** явная строка `extroot` в `/etc/config/fstab` при вводе команд не записалась (uci commit слился с выводом mkfs). Overlay подхватывается автоопределением block-mount. Дома стоит дописать явно:
```
DEV=/dev/sda1
eval $(block info $DEV | grep -o 'UUID="\S*"')
uci set fstab.extroot="mount"
uci set fstab.extroot.uuid="$UUID"
uci set fstab.extroot.target="/overlay"
uci set fstab.extroot.enabled="1"
uci commit fstab
cat /etc/config/fstab   # проверить, что появился блок config mount 'extroot'
```

### 3. PassWall2 установлен

- Автоскрипт: `enxy0/passwall2_install` (`https://raw.githubusercontent.com/enxy0/passwall2_install/main/passwall2.sh`)
- **Баг скрипта:** вызывает `apk add --force-reinstall`, а apk в 25.12 такого флага не знает. Фикс перед запуском:
  ```
  sed -i 's/ --force-reinstall//g' passwall2.sh
  ```
- **Баг скрипта 2:** подменяет DNS на 9.9.9.9/1.1.1.1 (в офисе заблокированы). Обход — до запуска подсунуть рабочий DNS:
  ```
  echo "nameserver 192.168.0.1" > /tmp/resolv.conf   # дома подставить домашний, напр. 192.168.1.1 или ISP
  ```
  после — `/etc/init.d/dnsmasq restart`
- Скрипт ставит только утилиты (chinadns-ng, geoview, shadowsocks*, v2ray-geoip/geosite и т.п.), **само ядро xray НЕ ставит**. Доставлено вручную:
  ```
  apk add xray-core     # /usr/bin/xray, ~34 МБ, версия 26.3.27
  ```
- Установленная версия PassWall2: **26.8.27-1**

### 4. Нода VLESS-Reality создана в PassWall2

`uci show passwall2.LgCRCnyE` (нода `reality-server`, id `LgCRCnyE`):
```
type='Xray'  protocol='vless'
address='<SERVER_IP>'  port='443'
uuid='<VLESS_UUID>'
encryption='none'
tls='1'  reality='1'
tls_serverName='www.cloudflare.com'
reality_publicKey='<REALITY_PUBLIC_KEY>'
reality_shortId='<REALITY_SHORT_ID>'
fingerprint='chrome'
transport='raw'
```
Сгенерированный xray outbound (`/tmp/etc/passwall2/acl/default.json`) — корректный, Reality-параметры на месте, `flow` отсутствует (как на сервере).

В Basic Settings → Main: `Main switch` включался, `Node` = `reality-server`, Core показывал `RUNNING`.

## ПАРАМЕТРЫ VLESS-СЕРВЕРА (с сервера, для клиента)

| Параметр | Значение |
|---|---|
| Адрес | `<SERVER_IP>` |
| Порт | `443` |
| Протокол | VLESS |
| UUID | `<VLESS_UUID>` |
| Flow | **(пусто)** |
| Network | tcp / raw |
| Security | reality |
| SNI / serverName | `www.cloudflare.com` |
| Public Key | `<REALITY_PUBLIC_KEY>` |
| Short ID | `<REALITY_SHORT_ID>` |
| Fingerprint | chrome |

Сервер: SSH к `<SERVER_IP>`, конфиг `/usr/local/etc/xray/config.json`.
Публичный ключ считается: `xray x25519 -i <privateKey из config.json>` (в новом xray строка вывода `Password:`).
(Первый присланный privateKey `<REALITY_PRIVATE_KEY_truncated_in_original_note>` был обрезан — 42 символа вместо 43.)

## ПОЧЕМУ НЕ ЗАРАБОТАЛО НА РАБОТЕ

Офисный интернет (WAN получил `192.168.0.101`, шлюз/DNS `192.168.0.1`) — корпоративный фильтр:
- рвёт большие загрузки (`wget error 4`, `unexpected end of file`)
- блокирует внешний DNS (9.9.9.9 / 1.1.1.1 недоступны)
- **`nc -w5 <SERVER_IP> 443` → `rc=1` (зависает)** — блокирует исходящие на произвольные VPS

Reality-соединение до сервера не устанавливается вообще (лог ноды пустой). Дома на обычном провайдерском канале должно заработать.

Перед уходом PassWall2 выключен, чтобы не ломать DNS роутера:
```
uci set passwall2.@global[0].enabled='0'
uci commit passwall2
/etc/init.d/passwall2 restart
```

## WI-FI (важно!)

**У hEX RB750Gr3 НЕТ Wi-Fi** — только 5 портов Ethernet, радиомодуля нет.
Пользователь хочет, чтобы дома устройства подключались по Wi-Fi и весь их трафик шёл через VPN.

**Решение:** hEX = VPN-роутер, отдельная железка = точка доступа.
```
провайдер → ETHER1 hEX (WAN) → hEX [роутинг + PassWall2] → ETHER2 hEX → Wi-Fi роутер в режиме AP → устройства по Wi-Fi
```
Домашний Wi-Fi роутер пользователя перевести в режим точки доступа:
- отключить на нём DHCP-сервер
- LAN-порт домашнего роутера (НЕ WAN) ← кабель от ETHER2 hEX
- статический IP домашнего роутера из подсети hEX (напр. 192.168.1.2), шлюз 192.168.1.1
- Wi-Fi оставить включённым
Тогда весь Wi-Fi трафик проходит через hEX → PassWall2 → сервер.

Обсудить дома конкретную модель домашнего роутера и как в нём включить AP-режим.

## ЧТО ОСТАЛОСЬ (делать дома)

1. **Подключить дома:** порт 1 (WAN) → домашний провайдер/роутер, порт 2 → ноутбук.
2. Зайти в LuCI `http://192.168.1.1` (или `ssh root@192.168.1.1`). Пароль root — тот, что задавал в System → Administration.
3. Проверить WAN получил адрес: Status → Overview. Если WAN-адрес вида `192.168.1.x` — конфликт с LAN, поменять LAN роутера на `192.168.2.1`.
4. Проверить, что порт сервера доступен:
   ```
   nc -w5 <SERVER_IP> 443 </dev/null; echo "rc=$?"
   ```
   `rc=0` → отлично.
5. (Опц.) дописать явную строку extroot в fstab (см. раздел 2).
6. Включить PassWall2:
   ```
   uci set passwall2.@global[0].enabled='1'
   uci commit passwall2
   /etc/init.d/passwall2 restart
   ```
   Или в LuCI: Services → PassWall 2 → Basic Settings → Main → Main switch → Save & Apply.
7. Проверить:
   ```
   curl -s https://ipinfo.io/ip      # должен вернуть <SERVER_IP>
   curl -s https://ipinfo.io/json
   ```
   С ноутбука: открыть `https://ipinfo.io` — тоже IP сервера.
   PassWall2 → Node List → тест задержки ноды `reality-server`.

### Если дома НЕ подключится (curl пустой / Core RUNNING но трафик не идёт)

Разбирать по порядку:
- Лог ноды с debug: PassWall2 → Basic Settings → Main → `Log Level` = `debug` → Save & Apply, потом `curl -s https://ipinfo.io/ip` и `tail -50 /tmp/etc/passwall2/acl/default.log`
- Возможные причины: на сервере в записи клиента стоит `"flow": "xtls-rprx-vision"` (тогда добавить flow в ноду), неверный publicKey (пересчитать на сервере `xray x25519 -i <privateKey>`), serverName/shortId не совпадают с серверным `config.json`
- Сверить серверный конфиг: на сервере `grep -iE 'privateKey|shortIds|serverNames|"id"|flow' /usr/local/etc/xray/config.json`
- `Running in no proxy mode` в `/tmp/log/passwall2.log` — проверить `uci show passwall2.@global[0]`, режим фильтрации трафика в Basic Settings → Main (нужен «Proxy All / Global» или «GFW List»)

## ПОЛЕЗНЫЕ КОМАНДЫ

```
# статус
df -h ; mount | grep overlay
ps w | grep xray
cat /tmp/log/passwall2.log | tail -50
tail -50 /tmp/etc/passwall2/acl/default.log
uci show passwall2.@global[0]
uci show passwall2.LgCRCnyE

# выключить/включить прокси
uci set passwall2.@global[0].enabled='0'   # или '1'
uci commit passwall2 ; /etc/init.d/passwall2 restart

# вернуть DNS если PassWall2 сломал
/etc/init.d/dnsmasq restart
```

## ФАЙЛЫ НА ПК (Windows)

- tinyPXE: `D:\Download\tinypxeserver-main\tinypxeserver-main\pxesrv\` (+ `files\vmlinux`)
- Tftpd64: отдельно
- Образы OpenWrt, NetInstall, `routeros-7.24.1-mmips.npk`: в `D:\Download` / `~\Downloads`
- Эти инструменты для прошивки БОЛЬШЕ НЕ НУЖНЫ — роутер грузится из NAND сам.
