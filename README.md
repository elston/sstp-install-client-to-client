# sstp-setup

Bash-скрипт для установки и настройки **SSTP VPN-клиента** на AlmaLinux 9
(совместим с Rocky Linux / RHEL / CentOS Stream 9).

Под капотом — `sstp-client` (sstpc) + `pppd` с плагином `sstp-pppd-plugin.so`.
Транспорт: TLS поверх TCP/443 — проходит через любой firewall, который пропускает HTTPS.

## Что внутри

- **Сборка из исходников** в Docker/Podman контейнере (или нативно на хосте)
- **SHA256-верификация** скачиваемого архива
- **Управляющие команды**: `sstp-up`, `sstp-down`, `sstp-status`, `sstp-route`
- **Маршруты per-subnet**, без `defaultroute` — SSH-сессия не теряется
- **Dry-run режим** для проверки что будет сделано
- **Чистый uninstall** — удаляет всё что поставил, ничего системного не трогает

## Быстрый старт

```bash
# 1) Скачать
git clone https://github.com/elston/sstp-install-client-to-client
cd sstp-install-client-to-client
chmod +x sstp-setup.sh

# 2) Установить через Docker (рекомендуется — на хост попадает только бинарник)
sudo ./sstp-setup.sh install --docker

# 3) Подключиться
sudo sstp-up
sudo sstp-status

# 4) Маршруты добавляются на лету (можно при пустом списке на старте)
sudo sstp-route add 192.168.88.0/24
sudo sstp-route list

# 5) Отключиться
sudo sstp-down
```

Для удаления:

```bash
sudo ./sstp-setup.sh uninstall          # интерактивно, по шагам
sudo ./sstp-setup.sh uninstall --purge  # без вопросов, всё сразу
```

## Архитектура

### Каноническая схема запуска (важно!)

`sstp-client` поддерживает два режима запуска. Скрипт использует **canonical**, потому
что только он реально работает в актуальных версиях:

```
                     CANONICAL (наш режим)
        ┌──────────────────────────────────────────────┐
        │                                              │
        │   sstp-up                                    │
        │      │                                       │
        │      ▼                                       │
        │   pppd call sstp-vpn updetach                │
        │      │                                       │
        │      │ читает /etc/ppp/peers/sstp-vpn:       │
        │      │   pty "sstpc --nolaunchpppd ..."      │
        │      │   plugin sstp-pppd-plugin.so          │
        │      │   sstp-sock /var/run/sstpc/...        │
        │      │   name <user>                         │
        │      ▼                                       │
        │   pppd создаёт pty, форкает sstpc            │
        │      │                                       │
        │      ▼                                       │
        │   sstpc                                      │
        │      ├──► TLS-handshake до сервера (443)     │
        │      ├──► SSTP Connect-Request               │
        │      ├──► создаёт unix-socket                │
        │      │   /var/run/sstpc/sstpc-sstp-vpn       │
        │      └──► пробрасывает PPP кадры через pty   │
        │                                              │
        │   pppd на pty:                               │
        │      ├──► LCP, MS-CHAPv2 (имя из peer,       │
        │      │   пароль из /etc/ppp/chap-secrets)    │
        │      ├──► плагин подключается к unix-socket  │
        │      │   и забирает MPPE-ключи               │
        │      ├──► IPCP — получает IP                 │
        │      ├──► создаёт ppp0                       │
        │      └──► запускает /etc/ppp/ip-up.d/*       │
        │              ▲                               │
        │              └─ наш hook добавляет           │
        │                 маршруты через ppp0          │
        └──────────────────────────────────────────────┘
```

**Альтернативный (experimental) режим** — `sstpc → pppd` (sstpc запускает pppd сам)
**не работает** в `sstp-client 1.0.20`: sstpc в этом режиме не создаёт unix-сокет,
плагин в pppd падает с `Could not connect to sstp-client (...) No such file or directory`.

Подробности: см. раздел «Грабли» ниже.

### Файлы которые создаёт скрипт

```
/etc/sstp-setup/
├── installed.conf              # маркер установки + метаданные
├── sstp-vpn.creds              # сервер, логин, пароль, маршруты, путь к CA
└── sstp-vpn.pid                # PID живого pppd

/etc/ppp/
├── peers/sstp-vpn              # PPP peer-конфиг с pty-командой sstpc
├── chap-secrets                # пароль (мы дописываем нашу запись с маркером)
├── ip-up.d/sstp-vpn-routes     # хук: добавляет маршруты при подъёме
└── ip-down.d/sstp-vpn-routes   # хук: удаляет маршруты при опускании

/usr/local/sbin/sstpc                              # бинарник sstp-client
/usr/lib64/pppd/<version>/sstp-pppd-plugin.so      # плагин для pppd
/var/run/sstpc/                                    # runtime-каталог для unix-сокета

/usr/local/bin/
├── sstp-up                     # запуск туннеля
├── sstp-down                   # остановка
├── sstp-status                 # статус
└── sstp-route                  # add/del/list/reload/flush маршрутов
```

### Безопасность процессов (PID-файл)

Простой `pkill -f sstpc` опасен — он убьёт ВСЕ sstpc-процессы на машине,
если их несколько (несколько SSTP-туннелей). Скрипт использует точечное управление:

1. **При запуске** `sstp-up` пишет PID родительского `pppd` в `/etc/sstp-setup/sstp-vpn.pid`.
   После того как pppd детачится по `updetach`, скрипт переписывает PID-файл
   на PID живого детач'нутого pppd (находит его через `/proc/*/cmdline` по `call sstp-vpn`).

2. **При остановке** `sstp-down` сначала пытается `kill` по PID из файла, проверяя
   что это именно `pppd` (через `ps -p $PID -o comm=`). Если PID-файла нет —
   fallback ищет `pppd` по `/proc/*/cmdline` где есть `call sstp-vpn`.
   На всякий случай добивает `sstpc` с нашим `ipparam`.

Чужие туннели не трогаются никогда.

## Шпаргалка по командам

| Команда | Что делает |
|---------|------------|
| `sudo sstp-up` | Поднять туннель (запускает `pppd call sstp-vpn updetach`) |
| `sudo sstp-down` | Опустить туннель (kill pppd по PID) |
| `sudo sstp-status` | Процессы, ppp-интерфейс, маршруты, внешний IP |
| `sudo sstp-route add 10.0.0.0/24` | Добавить маршрут (применить + сохранить в creds) |
| `sudo sstp-route del 10.0.0.0/24` | Удалить маршрут |
| `sudo sstp-route list` | Сохранённые + активные маршруты |
| `sudo sstp-route reload` | Перечитать сохранённые и применить (после reconnect) |
| `sudo sstp-route flush` | Очистить все маршруты |
| `journalctl -t pppd -f` | Логи pppd в реальном времени |
| `journalctl -t sstpc -f` | Логи sstpc |

## Опции скрипта

```
sudo ./sstp-setup.sh                    — интерактивное меню
sudo ./sstp-setup.sh install            — установка с интерактивным вопросом метода
sudo ./sstp-setup.sh install --docker   — сборка в контейнере
sudo ./sstp-setup.sh install --native   — сборка на хосте
sudo ./sstp-setup.sh install --dry-run  — что будет сделано (без реальных действий)
sudo ./sstp-setup.sh uninstall          — удаление с подтверждениями
sudo ./sstp-setup.sh uninstall --purge  — удалить всё без вопросов
sudo ./sstp-setup.sh uninstall --dry-run
```

## Грабли (на чём мы наступили)

Этот раздел — самое ценное, что есть в README. Ниже — все реальные проблемы,
с которыми мы столкнулись при отладке, и как они решены.

### 1. CRB не включён по умолчанию на AlmaLinux 9 → `ppp-devel` не находится

**Симптом** при сборке (Docker или native):

```
No match for argument: ppp-devel
Error: Unable to find a match: ppp-devel
```

**Причина.** На AlmaLinux/Rocky/RHEL/CentOS 9 репозиторий **CRB** (CodeReady Builder),
где живут все `*-devel` пакеты, выключен по умолчанию. EPEL сам по себе `ppp-devel`
не содержит. Включат CRB по дефолту только в AlmaLinux 10.

**Решение в скрипте.** Перед `dnf install ppp-devel` каскадно пробуем включить:

```bash
dnf config-manager --set-enabled crb           # AlmaLinux/Rocky/CentOS 9
dnf config-manager --set-enabled powertools    # EL 8 fallback
subscription-manager repos --enable codeready-builder-for-rhel-9-$(arch)-rpms  # RHEL 9
```

То же продублировано внутри Dockerfile.

### 2. IPv6-резолв ломал подключение

**Симптом.** `sstpc` стартует, через секунду тихо умирает. `journalctl -t sstpc` пуст.
В `sstp-status` внешний IP показывается v6.

**Причина.** `getaddrinfo()` на Linux по умолчанию предпочитает IPv6, если у хоста
есть AAAA-запись (RFC 3484, `/etc/gai.conf`). У нашего сервера IPv6-маршрут до
конкретной сети был broken (blackhole). Sstpc получал IPv6 из DNS, пытался открыть
TCP-сокет на `[2a06:...]:443`, ловил timeout/ENETUNREACH и падал ДО того как
успевал что-либо записать в syslog.

**Решение.** Хост-override в `/etc/hosts`:

```bash
echo "123.123.123.123  vpn.your-domain.tld" | sudo tee -a /etc/hosts
```

Важно: следить чтобы предыдущая строка в `/etc/hosts` оканчивалась переводом строки.
SolusVM-сгенерированный hosts может не иметь финального `\n`, тогда `tee -a` склеит
строку с предыдущей. Проверка после:

```bash
getent ahosts vpn.your-domain.tld
# должен вернуть только 123.123.123.123, без AAAA
```

Если `ahosts` всё ещё показывает v6 — проверить:

```bash
grep ^hosts /etc/nsswitch.conf       # должно быть "files dns ..." (files первым)
ls -l /etc/resolv.conf               # обычный файл, не симлинк на systemd-resolved
```

Проблема в том, что у `sstp-client` нет встроенного "happy eyeballs" (RFC 8305) —
он берёт первый адрес из `getaddrinfo` и пробует только его. Альтернативное
решение — починить IPv6-маршрут со стороны провайдера/админа.

### 3. sstpc 1.0.20 не создаёт unix-сокет в режиме `sstpc → pppd`

**Симптом.** `sstpc` стартует, проходит TLS, проходит SSTP Connect-Request, запускает
`pppd`. Pppd проходит LCP, делает MS-CHAPv2 — даже **CHAP Success**. И сразу:

```
Could not connect to sstp-client (/var/run/sstpc/sstpc-sstp-vpn), No such file or directory (2)
PPPd terminated
```

В `/var/run/sstpc/` пусто. `strace` показывает что **sstpc вообще не делает
`bind(AF_UNIX, ...)`** — то есть сокет не создаётся принципиально.

**Причина.** Это **известное ограничение experimental-режима**. README upstream
прямо пишет:

> 1. Run sstpc on the command line
> 2. Have pppd load sstpc via the plugin directive
>
> In the first case... **This is the less ideal way of connecting to your remote,
> and should be considered experimental or testing purposes.**

В этом режиме sstpc и pppd-плагин не могут договориться через сокет.
Канонический способ — наоборот: pppd через `pty` запускает sstpc.

**Решение.** Перевели `sstp-up` на каноническую схему:

```bash
sudo pppd call sstp-vpn updetach
```

В peer-файле — `pty "sstpc --nolaunchpppd ..."`. Тогда sstpc стартует через pty,
правильно создаёт unix-сокет, плагин подключается, обмен MPPE-ключами проходит.

### 4. `require-mppe` ломает соединение с MikroTik (encryption=no)

**Симптом** на этапе CCP (после успешного CHAP):

```
sent [CCP ConfReq id=0x3 <mppe +H -M +S +L -D -C>]
rcvd [LCP ProtRej id=0x2 80 fd 01 03 00 0a 12 06 01 00 00 60]
Protocol-Reject for 'Compression Control Protocol' (0x80fd) received
MPPE required but peer negotiation failed
```

**Причина.** MikroTik в SSTP-профиле может быть с `encryption=no` или
`use-encryption=default`. Тогда он реджектит весь CCP-протокол. С нашим
`require-mppe` pppd говорит «требую MPPE — peer не даёт» и рвёт связь.

**Решение.** В peer-файле по умолчанию:

```
noccp
nomppe
# require-mppe   ← закомментировано
```

Это безопасно: SSTP — это **TLS снаружи**, шифрование уже есть на транспортном уровне.
MPPE поверх TLS — double encryption и для SSTP избыточен.

Если ваш сервер требует MPPE (Windows RAS, MikroTik с encryption=required) —
закомментируйте `noccp/nomppe` и раскомментируйте `require-mppe`.

### 5. Минор: `git: command not found` при clone в минимальной AlmaLinux

Если `git` не установлен — есть два варианта:

```bash
# Вариант 1: поставить git
sudo dnf install -y git

# Вариант 2: скачать архивом
curl -sSL https://github.com/elston/sstp-install-client-to-client/archive/refs/heads/main.tar.gz | tar xz
cd sstp-install-client-to-client
```

## Зависимости

Минимальные runtime (обычно уже установлены):

- `ppp` (содержит `pppd`)
- `openssl-libs`
- `libevent`
- `iproute`, `iptables`

Для сборки **native**:

- `dnf-plugins-core` (для `config-manager`)
- CRB-репо включён
- `Development Tools` group + `ppp-devel`, `openssl-devel`, `libevent-devel`, `autoconf`, `automake`, `libtool`, `wget`, `tar`

Для сборки **docker**:

- `podman` (в base-репе AlmaLinux 9) или `docker`
- 500–700 МБ дискового пространства для промежуточного образа (удаляется после сборки)

## Тестировано

- AlmaLinux 9.7 на Linux KVM
- Сервер: MikroTik RouterOS, SSTP-server, MS-CHAPv2, encryption=no, IPv4-only
- sstp-client 1.0.20
- pppd 2.4.9

## TODO / возможные улучшения

- Параметр encryption в установке (yes/no/auto)
- Автодетект IPv4-only хоста через `ping -6`
- Автоматическое получение и проверка CA-сертификата с сервера через `openssl s_client`
- systemd unit для автозапуска при старте системы
- Поддержка нескольких параллельных подключений (сейчас одно подключение на хост)

## Лицензия

`sstp-client` — GPL-2.0-or-later (https://gitlab.com/sstp-project/sstp-client)

### Благодарности

Sstp-Client (https://gitlab.com/sstp-project/sstp-client)