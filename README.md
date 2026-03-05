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

### 1. Настрой DNS

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

| Поле | Пример |
|---|---|
| Домен Reality/Nginx | `domain1.ru` |
| Домен панели | `domain2.ru` |
| Email Let's Encrypt | `you@gmail.com` |
| Секретный путь | `/xk92mf` |
| Логин панели | `admin` |
| Пароль панели | минимум 8 символов |

Установка занимает ~5 минут. В конце скрипт показывает URL панели и credentials.

---

## Настройка инбаундов

### Вход в панель

```
https://domain2.ru/xk92mf
```

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
