# joif-smartdns

Servidor **Smart DNS + SNI Proxy Argentino** con sistema de **licencias por IP/CIDR** diseñado para el ecosistema **JOIF VPN** y compatible con **Ubuntu 22.04, 24.04 y 26.04 LTS**.

## Cómo funciona en el ecosistema JOIF VPN

```text
[App Android JOIF (Zeptun / HevSocks5)]
          │  Túnel VPN/SSH de alto ancho de banda
          ▼
[VPS Principal Brasil / USA (ej. br1.joif.net)]
          │
          ├── ~95% tráfico normal (YouTube, TikTok, gaming, descargas)
          │        └─► Resuelto via 1.1.1.1/8.8.8.8 ─► Sale directo por Brasil/USA
          │
          └── ~5% dominios geo-restringidos AR (Mercado Pago, bancos, .gob.ar, streaming AR)
                   ├─► DNS (53/udp+tcp) ─► VPS Argentina (dnsmasq) devuelve IP pública VPS AR
                   │                        (A = IP AR, AAAA = NODATA, HTTPS/SVCB filtrado)
                   └─► TLS/HTTP (443/80) ─► VPS Argentina (nginx ssl_preread)
                                            Reenvío transparente extremo a extremo SIN descifrar TLS
```

## Características principales

- **Motor DNS Selectivo (`dnsmasq` puerto 53 TCP/UDP):**
  - Libera el puerto 53 de forma segura mediante `/etc/systemd/resolved.conf.d/99-joif-smartdns.conf` (`DNSStubListener=no`) y deja `/etc/resolv.conf` del propio host apuntando a `1.1.1.1` / `8.8.8.8`.
  - **Anti-fuga IPv6 y HTTPS/SVCB:** los dominios interceptados devuelven `A = <IP_VPS_AR>` y `AAAA = NODATA`, y en `dnsmasq` con soporte (`>= 2.90` en Ubuntu 24.04/26.04 o builds parcheadas `>= 2.87`, detectado dinámicamente con `--test`) habilita `filter-rr=HTTPS,SVCB` para evitar fugas por `ipv4hint`/`ECH`.
- **Proxy Transparente TLS/HTTP (`nginx` + `libnginx-mod-stream`):**
  - Usa `ngx_stream_ssl_preread_module` oficial (sin depender del antiguo `sniproxy`).
  - **Puerto 443 (`stream`):** lee únicamente `$ssl_preread_server_name` sin terminar ni descifrar TLS; los certificados originales de bancos, Mercado Pago, Mi Argentina y Netflix llegan intactos al dispositivo.
  - **Puerto 80 (`http`):** reenvía por cabecera `$host` validada hacia puerto 80 con resolver externo (`1.1.1.1` / `8.8.8.8`, nunca `127.0.0.1`).
  - **Anti-abuso estricto:** solo permite dominios de las listas habilitadas; SNI vacío o dominios fuera de lista se rechazan localmente (`127.0.0.1:18443` `deny all` en 443 y `return 444` en 80).
- **Licencias por IP/CIDR + Firewall seguro (`ipset` + `iptables` + `systemd`):**
  - Whitelist en `ipset joif_smartdns_allow` (`hash:net`) con recarga atómica (`swap`, cero cortes).
  - Cadena dedicada `JOIF_SMARTDNS` (y bloqueo IPv6 `JOIF_SMARTDNS6`) aplicada **exclusivamente** a `53/udp`, `53/tcp`, `80/tcp` y `443/tcp`. **Nunca modifica ni bloquea SSH (`22/tcp`).**
  - Persistencia tras reinicios vía `joif-smartdns-firewall.service` y purga horaria automática de licencias vencidas vía `joif-smartdns-expire.timer`.
- **Listas modulares de dominios argentinos (`/etc/joif-smartdns/domains.d/`):**
  - `01-fintech-bancos.list`: Mercado Pago/Libre, Ualá, Brubank, Naranja X, MODO, Personal Pay, Prex, Lemon, Belo, Ripio, BNA, Banco Provincia/Cuenta DNI, Galicia, Santander, BBVA, Macro, Link, Banelco/Prisma, etc.
  - `02-gobierno-ar.list`: `argentina.gob.ar`, `miargentina.gob.ar`, `afip.gob.ar`, `arca.gob.ar`, `anses.gob.ar`, `renaper.gob.ar`, `pami.org.ar`, `buenosaires.gob.ar`, `gba.gob.ar`, etc.
  - `03-streaming-ar.list`: Netflix, Flow, TyC Sports Play, Telefe, El Trece, DGO, Disney+, Max, Prime Video.
  - `99-custom.list`: dominios personalizados agregados por el administrador.
- **Panel CLI (`smartdns`) con validación previa y rollback automático:**
  - Antes de aplicar cambios ejecuta `dnsmasq --test` y `nginx -t`; si algo falla, restaura automáticamente la configuración anterior.

## Estructura del proyecto

```text
joif-smartdns/
├── install.sh                       # Instalador idempotente Ubuntu 22.04 / 24.04 / 26.04 LTS
├── uninstall.sh                     # Desinstalador limpio (restaura systemd-resolved, SSH intacto)
├── menu.sh                          # Panel interactivo y CLI (/usr/local/bin/smartdns)
├── core/
│   ├── common.sh                    # Rutas, validaciones IPv4/CIDR/dominios, helpers y bloqueo flock
│   ├── domains.sh                   # Parser, deduplicación y gestión de categorías domains.d/
│   ├── dnsmasq_gen.sh               # Generador dnsmasq con detección dinámica filter-rr y rollback
│   ├── nginx_gen.sh                 # Generador nginx stream (443) + http (80) con allowlist y rollback
│   ├── licenses.sh                  # CRUD de licencias IP/CIDR y lógica de vencimiento
│   ├── firewall.sh                  # ipset swap atómico + iptables cadena JOIF_SMARTDNS (SSH seguro)
│   ├── expire-licenses.sh           # Ejecutable horario para desactivar IPs vencidas
│   └── diagnostics.sh               # Diagnóstico integral en vivo (DNS, anti-fuga, SNI, firewall)
├── domains.d/
│   ├── 01-fintech-bancos.list
│   ├── 02-gobierno-ar.list
│   ├── 03-streaming-ar.list
│   └── 99-custom.list
├── systemd/
│   ├── joif-smartdns-firewall.service
│   ├── joif-smartdns-expire.service
│   └── joif-smartdns-expire.timer
├── tools/
│   └── acceso-root.sh               # Utilidad opcional para habilitar acceso SSH root con clave
└── tests/
    └── run_tests.sh                 # Suite de pruebas automatizadas locales
```

## Instalación en VPS Argentina (Ubuntu 22.04 / 24.04 / 26.04 LTS)

```bash
git clone https://github.com/manuel3200/joif-smartdns.git
cd joif-smartdns
chmod +x install.sh
sudo ./install.sh
```

Instalación no interactiva (opcional):

```bash
sudo ./install.sh \
  --public-ip 200.x.x.x \
  --allow-ip 177.x.x.x \
  --allow-alias "Nodo Brasil 01" \
  --non-interactive
```

## Uso diario (`smartdns`)

Abre el panel interactivo:

```bash
sudo smartdns
```

O usa subcomandos directos desde consola/scripts:

```bash
# Autorizar VPS de Brasil de forma permanente (0 días = permanente)
sudo smartdns ip add 177.x.x.x "Nodo Brasil 01" 0

# Autorizar un cliente temporal por 30 días
sudo smartdns ip add 190.x.x.x "Cliente Prueba" 30

# Listar licencias con estado y días restantes
sudo smartdns ip list

# Renovar / suspender / reactivar / eliminar
sudo smartdns ip renew 190.x.x.x 30
sudo smartdns ip suspend 190.x.x.x
sudo smartdns ip reactivate 190.x.x.x
sudo smartdns ip remove 190.x.x.x

# Gestionar listas de dominios y recargar con validación + rollback
sudo smartdns domains list
sudo smartdns domains disable 03-streaming-ar
sudo smartdns domains enable 03-streaming-ar
sudo smartdns domains add midominio.com.ar
sudo smartdns domains remove midominio.com.ar

# Diagnóstico completo en vivo
sudo smartdns status
```

## Utilidad opcional: habilitar acceso SSH `root` con clave

Si tu VPS viene solo con usuario sin `root` (ej. `ubuntu` o `clientXXXX` con `cloud-init`), podés habilitar el acceso `root` por contraseña de forma segura (valida con `sshd -t` antes de reiniciar SSH):

```bash
curl -fsSL https://raw.githubusercontent.com/manuel3200/joif-smartdns/main/tools/acceso-root.sh -o acceso-root.sh && chmod +x acceso-root.sh && sudo ./acceso-root.sh
```

## Desinstalación limpia

```bash
sudo /opt/joif-smartdns/uninstall.sh
# o desde el panel: sudo smartdns -> opción 6
```

Restaura `systemd-resolved` y `/etc/resolv.conf`, elimina únicamente las reglas de firewall de `joif-smartdns` y restaura `/etc/nginx/nginx.conf` original sin tocar el puerto SSH (`22/tcp`).

## Pruebas automatizadas locales

Puedes ejecutar la suite completa de validación local (Linux, macOS o Windows con Git Bash):

```bash
bash tests/run_tests.sh
```

Verifica:
- Finales de línea LF y sintaxis `bash -n` de todos los scripts.
- Validadores de IPv4, CIDR (incluyendo rechazo de `0.0.0.0/0`) y dominios RFC 1123.
- Parser de `domains.d/*.list`, deduplicación entre categorías y activar/desactivar listas.
- Generación de `dnsmasq` con detección dinámica de `filter-rr=HTTPS,SVCB` (v2.90+ vs v2.86) y rollback ante fallo de `--test`.
- Generación de `nginx` `stream` (443 `ssl_preread`) y `http` (80) con allowlist estricta, resolvers externos y rollback ante fallo de `nginx -t`.
- Ciclo de vida de licencias IP, vencimiento automático por fecha, renovación anticipada y bloqueo de reactivación de vencidas.
- Reglas de `firewall.sh` con mocks verificando swap atómico de `ipset` y que SSH (`22/tcp`) jamás se toca.
