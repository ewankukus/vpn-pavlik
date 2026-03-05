# VPN TOPGUN

Автоматическая установка VPN на базе 3X-UI + Xray-core (VLESS+Reality self-steal) + Nginx + Let's Encrypt.

---

## Требования к серверу

| | |
|---|---|
| ОС | Ubuntu 24.04 |
| CPU | 1 ядро |
| ОЗУ | 1 ГБ |
| Диск | 10 ГБ |

---

## Установка

Скрипт поддерживает два режима панели:

- **Domain** — панель за Nginx по домену (`https://domain2.ru`), нужны два домена
- **IP** — панель напрямую по IP (`https://IP:порт/путь`), домен не нужен

### 1. Настрой DNS (только для режима Domain)

Оба домена должны указывать A-записью на IP сервера:

```
domain1.ru   A  → 1.2.3.4
domain2.ru   A  → 1.2.3.4
```

### 2. Запусти скрипт

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ewankukus/vpn-pavlik/main/install.sh)
```

Скрипт задаст вопросы:

| Поле | Описание |
|---|---|
| Домен Reality/Nginx | домен сайта-камуфляжа, например `domain1.ru` |
| Email Let's Encrypt | email для SSL-сертификатов |
| Логин панели | придумай логин, по умолчанию `admin` |
| Пароль панели | придумай пароль, минимум 8 символов |
| Режим панели | `1` — Domain, `2` — IP |
| Домен панели | *(только Domain)* домен для входа в панель, например `domain2.ru` |
| Секретный путь | *(только IP)* произвольный путь, например `/xk92mf` |

Установка занимает ~5 минут. В конце скрипт показывает URL панели и credentials.

---

## Настройка инбаундов

### Вход в панель

**Domain режим:**
```
https://domain2.ru
```

**IP режим:**
```
https://<IP сервера>:<порт>/<секретный путь>
```

URL, логин и пароль скрипт выводит в конце установки и сохраняет в `/root/vpn-install-info.txt`.

### VLESS + Reality

1. **Inbounds → Add Inbound**
2. Заполнить:
   - Remark: `vless-reality`
   - Protocol: `VLESS`
   - Port: `8443`
3. **Transmission → Reality**
   - uTLS: `chrome`
   - Dest: `127.0.0.1:443`
   - SNI: `domain1.ru`
   - Нажать **Get New Cert**
4. **Settings → Clients → Add**
   - Flow: `xtls-rprx-vision`
5. **Save**

### Trojan + Reality

1. **Inbounds → Add Inbound**
2. Заполнить:
   - Remark: `trojan-reality`
   - Protocol: `Trojan`
   - Port: `2053`
3. **Transmission → Reality**
   - uTLS: `chrome`
   - Dest: `127.0.0.1:443`
   - SNI: `domain1.ru`
   - Нажать **Get New Cert**
4. **Settings → Clients → Add**
5. **Save**

### Получение ссылки для клиента

В списке Inbounds нажать иконку **QR** или **Copy** напротив клиента — готовая ссылка для импорта в v2rayN, Hiddify, Shadowrocket.
