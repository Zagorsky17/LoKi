# Туннели

Туннели работают внутри ядра, без дополнительных пакетов. Здесь описаны WireGuard, OpenVPN, OpenConnect и JSON endpoint, а у [AmneziaWG](/tunnels/amneziawg), [Cloudflare WARP](/tunnels/warp) и [Tailscale](/tunnels/tailscale) свои страницы.

В [сборке ядра](/guide/install#сборки-ядра) tiny туннелей нет, а OpenConnect и Tailscale есть только в full.

## WireGuard

**Импортировать** принимает файл `.conf` или ссылку `wireguard://`.

Если провайдер режет WireGuard, включите **Обфускацию трафика** и нажмите **Сгенерировать параметры**. Сервер настраивать не нужно, см. [одностороннюю обфускацию](/tunnels/amneziawg#односторонняя-обфускация).

## OpenVPN

**Импортировать** принимает профиль `.ovpn` вместе с файлами сертификатов и ключей, если он на них ссылается. Если сервер спрашивает логин, заполните **Имя пользователя** и **Пароль**. Режим TAP не поддерживается.

## OpenConnect

Корпоративные SSL VPN: Cisco AnyConnect и ocserv, GlobalProtect, Fortinet, Pulse, F5. **Импортировать** принимает профиль AnyConnect `.xml`, ссылку `anyconnect://` и экспорт NetworkManager `.nmconnection`.

## JSON endpoint

Клиентский endpoint sing-box, описанный вручную, например WireGuard с параметрами, которых нет в окне туннеля. Поле `tag` обязательно, оно становится именем туннеля. Серверный тип `openvpn-server` в LoKi не поддерживается и отклоняется до применения настроек.

```json
{
  "type": "wireguard",
  "tag": "my-endpoint",
  "address": ["10.0.0.2/32"],
  "private_key": "…",
  "peers": [
    {
      "address": "203.0.113.20",
      "port": 51820,
      "public_key": "…",
      "allowed_ips": ["0.0.0.0/0", "::/0"]
    }
  ]
}
```

## Каскадное подключение

WireGuard, AmneziaWG, WARP, OpenVPN и OpenConnect можно подключить через другую секцию, так же как [ссылку](/connections/links#каскадное-подключение).
