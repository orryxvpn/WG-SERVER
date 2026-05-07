# wg-tunnel-setup

Автоматизированная установка туннеля **INGRESS (RU) → EGRESS** одним
интерактивным bash-скриптом. С версии **1.1.0** поддерживаются три
транспортных протокола на выбор:

| Протокол                | Транспорт | Движок    | Когда выбрать                                    |
| ----------------------- | --------- | --------- | ------------------------------------------------ |
| **WireGuard**           | UDP       | kernel    | простой, быстрый, минимум зависимостей           |
| **Hysteria 2**          | UDP/QUIC  | sing-box  | быстрее всего на потерях/высоком RTT, FEC, BBR   |
| **VLESS+Reality+Vision**| TCP/TLS   | sing-box  | max stealth — снаружи неотличим от обычного HTTPS|

Все три варианта дают одинаковый результат: на INGRESS поднимается
туннельный интерфейс (`wg0` для WG, `singtun0` для HY2/VLESS), и трафик
с **`fwmark 0x1`** уходит через него; всё остальное идёт обычным маршрутом.

```
   клиент (мобильник, ноут)
            │
            │  Reality / Vless
            ▼
   ┌───────────────────────┐         ┌───────────────────────┐
   │      INGRESS (RU)     │ wg0:51820 → │      EGRESS           │
   │  10.66.66.2/24        │ ◄───────────► │  10.66.66.1/24        │
   │  Table = off          │  WireGuard  │  MASQUERADE → eth0    │
   │  fwmark 0x1 → wgout   │             │                       │
   └───────────┬───────────┘             └───────────┬───────────┘
               │                                     │
   локальный uplink (RU)                       внешний uplink (выход в интернет)
```

На стороне INGRESS дефолтный маршрут **не** меняется: туннель используется
выборочно, по `fwmark 0x1` (например, со стороны Xray Reality `outbound` с
`sockopt.mark = 1`).

## Что делает скрипт

### EGRESS

- ставит `wireguard wireguard-tools iptables iptables-persistent`
- включает форвардинг и `rp_filter=2` через `/etc/sysctl.d/99-wg-egress.conf`
- генерирует ключевую пару и preshared-ключ
- пишет `/etc/wireguard/wg0.conf` с `MASQUERADE` для `10.66.66.0/24` через
  внешний интерфейс и правилами `FORWARD`
- запускает `wg-quick@wg0`

### INGRESS

- ставит `wireguard wireguard-tools` (без iptables-persistent)
- включает `rp_filter=2` и `src_valid_mark=1` через
  `/etc/sysctl.d/99-wg-ingress.conf`
- регистрирует таблицу маршрутизации `200 wgout` в `/etc/iproute2/rt_tables`
- генерирует ключевую пару (preshared берёт от пользователя — введёт
  с EGRESS)
- пишет `/etc/wireguard/wg0.conf` с `Table = off` и policy routing
  (`ip rule fwmark 0x1 lookup wgout`, дефолт в таблице через `wg0`)
- запускает `wg-quick@wg0` и автоматически проверяет:
  - handshake с egress
  - что дефолтный маршрут НЕ ушёл в `wg0`
  - что `ip route get 1.1.1.1 mark 1` идёт через `wg0`
  - что `curl --interface wg0 ifconfig.me` возвращает IP egress (главная
    проверка цепочки NAT)

### Что скрипт НЕ делает

- не ставит и не настраивает Xray
- не ставит и не настраивает Remnawave
- не настраивает фаервол сверх правил, нужных для NAT/forward
- не открывает порты, кроме UDP 51820 на egress (на ingress — ничего)

Это намеренно: цель — поднять только транспортный туннель. Всё, что выше
(reality / vless / маршрутизация трафика клиентов в туннель), —
конфигурируется отдельно.

## Требования

- Два сервера (egress и ingress) с публичными IPv4
- Ubuntu 20.04+ или Debian 11+
- Root (sudo)
- На egress: открытый **UDP 51820** (входящий)
- Доступ в интернет с обоих серверов

## Установка

### Шаг 1. На EGRESS-сервере

```bash
# Pinned-версия (рекомендуется):
curl -fsSL https://raw.githubusercontent.com/orryxvpn/wg-server/v1.0.0/setup.sh -o setup.sh
sudo bash setup.sh
# Выберите 1) EGRESS, скопируйте PUBLIC KEY и PSK.
```

Скрипт остановится и попросит запустить вторую часть на ingress.

### Шаг 2. На INGRESS-сервере

```bash
curl -fsSL https://raw.githubusercontent.com/orryxvpn/wg-server/v1.0.0/setup.sh -o setup.sh
sudo bash setup.sh
# Выберите 2) INGRESS.
# Введите EGRESS PUBLIC KEY, EGRESS IP, PRESHARED KEY.
# Скрипт покажет INGRESS PUBLIC KEY — скопируйте.
```

### Шаг 3. Возвращаемся на EGRESS

Введите INGRESS PUBLIC KEY в открытое приглашение скрипта на egress.
Скрипт допишет peer'а в `wg0.conf` и поднимет интерфейс.

### Шаг 4. На INGRESS — ENTER

Скрипт на ingress продолжит и прогонит проверки. Если все прошли —
готово.

### Hysteria 2 — установка

На EGRESS:

```bash
curl -fsSL https://raw.githubusercontent.com/orryxvpn/wg-server/main/setup.sh -o setup.sh
sudo WG_REPO_REF=main bash setup.sh
# В меню: 2) Hysteria 2 → 1) EGRESS
# Скрипт покажет HY2_BUNDLE — одну base64-строку.
```

На INGRESS (paste — одной переменной, без интерактивных prompt'ов):

```bash
sudo -E HY2_BUNDLE='<тот самый base64-блок>' WG_REPO_REF=main bash setup.sh
# В меню: 2) Hysteria 2 → 2) INGRESS
```

Скрипт сам распакует `HY2_BUNDLE`, поставит sing-box, поднимет TUN
`singtun0`, добавит `ip rule fwmark 0x1 → table sbox` и прогонит
финальные проверки (включая `curl --interface singtun0 ifconfig.me`).

### VLESS+Reality+Vision — установка

Симметрично:

```bash
# EGRESS:
sudo bash setup.sh         # 3) VLESS+Reality → 1) EGRESS, копируем VLESS_BUNDLE
# INGRESS:
sudo -E VLESS_BUNDLE='<base64-блок>' bash setup.sh   # 3) VLESS+Reality → 2) INGRESS
```

### Альтернативный one-liner

Если вы доверяете тегу и не хотите проверять файл:

```bash
curl -fsSL https://raw.githubusercontent.com/orryxvpn/wg-server/v1.1.0/setup.sh | sudo bash
```

В этом режиме скрипт сам докачает `lib/*.sh` из того же тега во временную
директорию и удалит её после завершения.

> **Не используйте `main`-ветку в production-инструкциях.** Всегда
> закрепляйтесь на теге (`v1.1.0`).

## Проверка после установки

На INGRESS:

```bash
# handshake свежий (последние секунды/минуты):
wg show wg0

# дефолт по-прежнему через основной интерфейс, НЕ через wg0:
ip route show default

# с меткой — уход в туннель:
ip route get 1.1.1.1 mark 1

# реальный публичный IP при использовании туннеля
# (должен совпадать с публичным IP egress):
curl --interface wg0 ifconfig.me
```

На EGRESS:

```bash
wg show wg0           # peer присутствует, latest handshake свежий
iptables -t nat -S POSTROUTING | grep MASQUERADE
ss -ulnp | grep 51820
```

## Использование туннеля из приложения

Туннель сам по себе не маршрутизирует пользовательский трафик: чтобы
данные пошли через wg0, у пакета должен быть `fwmark 0x1`. Самый частый
способ — Xray с `sockopt.mark = 1` в нужном `outbound`:

```jsonc
{
  "outbounds": [
    {
      "tag": "out-wg",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": { "mark": 1 }
      }
    }
  ]
}
```

Проверьте, что клиент, подключённый к Reality на ingress, видит свой IP
как IP **egress**, а не RU-IP.

## Troubleshooting

### Handshake не появляется

- На egress: `journalctl -u wg-quick@wg0 -e`
- Проверьте, что UDP 51820 открыт на egress (cloud security groups, ufw,
  iptables INPUT). Со стороны ingress: `nc -uvz <egress-ip> 51820`.
- Проверьте, что ключи введены правильно (44 символа, заканчиваются на
  `=`). Если есть подозрение — переустановите.

### `curl --interface wg0` зависает или возвращает RU-IP

- На egress нет MASQUERADE: `iptables -t nat -S POSTROUTING`. Должна быть
  строка с `-s 10.66.66.0/24 -o <iface> -j MASQUERADE`.
- На egress не включён forwarding: `sysctl net.ipv4.ip_forward` должен быть
  `1`.
- На ingress `Table = off` не сработал и пакеты ушли мимо туннеля:
  посмотрите `ip route show table wgout` и `ip rule show`.

### NAT работает, но дефолтный маршрут уехал в wg0

Значит `Table = off` не применился. Проверьте, что в `wg0.conf` ровно
эта строка (без `Table = auto`). Поднимите интерфейс заново:
`systemctl restart wg-quick@wg0`.

### Утечка трафика мимо туннеля

В этом дизайне это **штатно**: пакеты без `fwmark=1` уходят через RU-uplink.
Если вы хотите завернуть весь трафик с ingress в туннель, используйте
обычный wg-quick **без** `Table = off` (это другой сценарий, не покрываемый
этим скриптом).

## Безопасность `curl | bash`

Способ запуска через `curl … | bash` удобный, но требует доверия к
источнику. Чтобы снизить риск:

1. **Закрепляйтесь на теге**, не на ветке `main` — содержимое тега
   неизменяемо, ветка может быть обновлена.
2. **Скачивайте отдельно и читайте** перед запуском:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/orryxvpn/wg-server/v1.0.0/setup.sh -o setup.sh
   less setup.sh   # пробежать глазами
   sudo bash setup.sh
   ```

3. Скрипт **никогда не отправляет** ключи или какие-либо данные с
   сервера наружу. Ключи генерируются локально через `wg genkey`. PSK
   передаётся только в stdout/файл — пользователь сам носит его на
   второй сервер.
4. Приватные ключи не попадают в `/var/log/wg-tunnel-setup.log`.
5. Файлы в `/etc/wireguard/` создаются с `umask 077` и явно
   `chmod 600`.

## Non-interactive (через env-переменные)

Если paste в твоём терминале ломает ключ так, что санитайзер не справляется,
либо ты раскатываешь через ansible/cloud-init, всё передаётся через
переменные окружения.

### WireGuard

| Переменная        | Кем читается | Что                          |
| ----------------- | ------------ | ---------------------------- |
| `WG_EGRESS_PUB`   | INGRESS      | публичный ключ EGRESS        |
| `WG_EGRESS_IP`    | INGRESS      | публичный IPv4 EGRESS        |
| `WG_PSK`          | INGRESS      | preshared key                |
| `WG_INGRESS_PUB`  | EGRESS       | публичный ключ INGRESS       |

```bash
sudo -E \
  WG_EGRESS_PUB='abc...=' WG_EGRESS_IP='1.2.3.4' WG_PSK='def...=' \
  bash setup.sh
```

### Hysteria 2 (одна переменная-бандл)

| Переменная     | Кем читается | Что                                                   |
| -------------- | ------------ | ----------------------------------------------------- |
| `HY2_BUNDLE`   | INGRESS      | base64-JSON: `{ip, port, password, sni, proto: hy2}`  |
| `HY2_PORT`     | EGRESS+INGRESS | UDP-порт (по умолчанию 8443)                       |
| `HY2_SNI`      | EGRESS+INGRESS | SNI для self-signed cert (по умолчанию www.bing.com)|
| `HY2_PASSWORD` | INGRESS      | альтернатива бандлу                                   |
| `HY2_EGRESS_IP`| INGRESS      | альтернатива бандлу                                   |

### VLESS+Reality+Vision (одна переменная-бандл)

| Переменная        | Кем читается | Что                                                                  |
| ----------------- | ------------ | -------------------------------------------------------------------- |
| `VLESS_BUNDLE`    | INGRESS      | base64-JSON: `{ip, port, uuid, pub, sid, sni, proto: vless}`         |
| `VLESS_PORT`      | EGRESS+INGRESS | TCP-порт (по умолчанию 443)                                       |
| `VLESS_DEST`      | EGRESS       | reality dest, host:port (по умолчанию www.cloudflare.com:443)        |
| `VLESS_SNI`       | EGRESS+INGRESS | SNI на котором маскируемся (по умолчанию www.cloudflare.com)      |
| `VLESS_UUID`      | INGRESS      | альтернатива бандлу                                                  |
| `VLESS_PUBLIC_KEY`| INGRESS      | альтернатива бандлу                                                  |
| `VLESS_SHORT_ID`  | INGRESS      | альтернатива бандлу                                                  |
| `VLESS_EGRESS_IP` | INGRESS      | альтернатива бандлу                                                  |

> Бандл (`HY2_BUNDLE` / `VLESS_BUNDLE`) — самый удобный путь: на egress
> скрипт его сам выводит после генерации, на ingress подставил в одну
> переменную и всё работает без прomptов.

## Diagnostics

Если ключ упорно не принимается через интерактивный prompt:

1. Скрипт версии 1.0.3+ при отказе валидации печатает hex-дамп raw-байтов
   в stderr (и пишет в `/var/log/wg-tunnel-setup.log`). Скопируй эти строки
   и приложи к bug-репорту — по ним видно, что именно прислал твой терминал.
2. Workaround-ом подставь ключ через env-переменные (см. выше) — это полностью
   обходит чтение из TTY.

## Удаление

```bash
sudo bash uninstall.sh
# или
sudo bash setup.sh   # пункт 3 в меню
```

Скрипт:

- останавливает и отключает `wg-quick@wg0`
- удаляет `/etc/wireguard/wg0.conf`, ключи, PSK
- удаляет `/etc/sysctl.d/99-wg-egress.conf` или `99-wg-ingress.conf`
- (для ingress) удаляет строку `200 wgout` из `/etc/iproute2/rt_tables`,
  снимает live `ip rule` и `ip route`
- спрашивает перед удалением пакетов `wireguard*` — по умолчанию **нет**,
  потому что они могут использоваться чем-то ещё

## Файлы и куда что записывается

| Путь                                | Что                                               |
| ----------------------------------- | ------------------------------------------------- |
| `/etc/wireguard/wg0.conf`           | конфиг интерфейса (с маркером wg-tunnel-setup)    |
| `/etc/wireguard/*.key`              | private/public ключи (mode 600/644)               |
| `/etc/wireguard/wg.psk`             | preshared key                                     |
| `/etc/sysctl.d/99-wg-egress.conf`   | sysctl для egress                                 |
| `/etc/sysctl.d/99-wg-ingress.conf`  | sysctl для ingress                                |
| `/etc/iproute2/rt_tables` (ingress) | строка `200 wgout`                                |
| `/var/log/wg-tunnel-setup.log`      | лог установки (без секретов)                      |

## Разработка

```bash
# Синтаксис:
bash tests/check-syntax.sh

# Линтер:
bash tests/shellcheck.sh

# Всё разом:
bash tests/run-all.sh
```

Перед коммитом запускайте `tests/run-all.sh` — CI-чистого `setup.sh`
надо сохранять.

## Версионирование

Скрипт пишет `# wg-tunnel-setup vX.Y.Z` в первую строку `wg0.conf`.
Это маркер, по которому будущие запуски понимают, что установка уже была.

Текущая версия отображается в баннере при запуске и доступна через
`bash setup.sh --version`.

| Версия  | Дата       | Что                                                                |
| ------- | ---------- | ------------------------------------------------------------------ |
| 1.1.0   | 2026-05-03 | Поддержка двух новых протоколов: **Hysteria 2** (UDP/QUIC) и       |
|         |            | **VLESS+Reality+Vision** (TCP/TLS, max stealth) на sing-box. На    |
|         |            | старте setup.sh теперь меню выбора протокола. Egress→ingress       |
|         |            | секреты передаются одним base64-блоком (`HY2_BUNDLE` /             |
|         |            | `VLESS_BUNDLE`) — paste-ад исключен.                               |
| 1.0.4   | 2026-05-03 | `read_tty` теперь читает из stdin когда тот сам по себе TTY (под   |
|         |            | sudo), и только в `curl\|bash` режиме идёт через `/dev/tty`. Это    |
|         |            | лечит случай провайдеров с двойным pty, где `/dev/tty` указывала   |
|         |            | не туда. Plus expanded read-context logging.                       |
| 1.0.3   | 2026-05-03 | Hex-дамп raw-байтов в stderr+log при провале валидации ключа/IP    |
|         |            | (диагностика того, что реально присылает терминал). Env-var        |
|         |            | bypass: `WG_EGRESS_PUB`, `WG_INGRESS_PUB`, `WG_EGRESS_IP`, `WG_PSK`|
|         |            | — обходной путь, если paste в TTY ломается чем-то экзотическим.    |
| 1.0.2   | 2026-05-03 | Жёсткая санитация ввода: стрипаются все ANSI CSI escape-последо-   |
|         |            | вательности (включая `ESC[?2004h/l`) + alphabet-фильтр в           |
|         |            | `prompt_wg_key` / `prompt_ipv4`. Раньше paste из некоторых         |
|         |            | терминалов / web-страниц приводил к "ключ невалиден".              |
| 1.0.1   | 2026-05-03 | Стрипаются bracketed-paste markers (`ESC[200~`/`ESC[201~`) и CR    |
|         |            | в `read_tty`. Не покрывало toggle-режим и NBSP — поэтому 1.0.2.    |
| 1.0.0   | 2026-05-03 | Первый релиз: интерактивный setup.sh, проверки.                    |

## License

[MIT](LICENSE)
