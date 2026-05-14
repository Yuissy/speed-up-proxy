## Ускорение установки через SOCKS5-прокси

Если Сервер 1 имеет медленный доступ к GitHub и другим ресурсам, можно настроить временный SOCKS5-прокси через Сервер 2 для ускорения скачивания пакетов.

### Как это работает

Сервер 2 добавляет SOCKS5 inbound в Xray и открывает порт 1080 только для IP Сервера 1. Сервер 1 настраивает `apt` и переменные окружения на использование этого прокси. Все пакеты скачиваются через быстрый канал.

### Использование

**Шаг 1: Настройка Сервера 2**

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/speed-up-proxy/main/setup_proxy.sh) --server2 IP_СЕРВЕРА_1
```
**Шаг 2: Настройка Сервера 1**
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/speed-up-proxy/main/setup_proxy.sh) --server1 IP_СЕРВЕРА_2
```
После установки
Настройки apt сохраняются в /etc/apt/apt.conf.d/99-proxy.conf и могут использоваться для будущих обновлений. Удалить их можно командой:
```bash
rm /etc/apt/apt.conf.d/99-proxy.conf
```
