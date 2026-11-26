# joif-smartdns

Servidor **Smart DNS + SNI Proxy Argentino** (`dnsmasq` + `nginx ssl_preread`) con **licencias por IP/CIDR**, métricas livianas, asistente descubridor de dominios de apps y protección de disco para VPS de 10 GB.

Compatible con **Ubuntu 22.04, 24.04 y 26.04 LTS** (incluyendo VPS con **NAT 1:1 / DHCP**).

> **Manual completo paso a paso:** [docs/GUIA-COMPLETA.md](docs/GUIA-COMPLETA.md)

---

## Instalación rápida (1 sola línea en tu VPS Argentina)

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq git && git clone https://github.com/manuel3200/joif-smartdns.git && cd joif-smartdns && sudo ./install.sh
```

Luego abrí el panel visual interactivo (adaptado a PC y celular SSH):

```bash
sudo smartdns
```

---

## Cómo funciona (resumen en 10 segundos)

- **~95% del tráfico normal** (YouTube, TikTok, WhatsApp, gaming, descargas) resuelve normal por `1.1.1.1`/`8.8.8.8` y sale directo por tu VPS de Brasil/USA sin consumir ancho de banda en Argentina.
- **~5% de dominios argentinos** (Mercado Pago, billeteras, bancos, `.gob.ar`, streaming AR) resuelven a la IP pública de tu VPS AR (bloqueando fugas `AAAA` y `HTTPS/SVCB`) y pasan por `nginx stream` (`ssl_preread`) **sin descifrar TLS** (certificados originales intactos).
- **Seguridad:** solo IPs autorizadas en `ipset joif_smartdns_allow` (con vencimiento horario automático) acceden a `53/80/443`. **El puerto SSH (`22/tcp`) jamás se toca.**

---

## Comandos principales (`smartdns`)

| Comando | Qué hace |
| :--- | :--- |
| `sudo smartdns` | Abre el panel visual interactivo (dashboard + menús numerados) |
| `sudo smartdns status` | Diagnóstico completo en vivo (DNS, anti-fuga, SNI 443, firewall) |
| `sudo smartdns metrics` | Mbps en vivo, disco/RAM, origen Geo/ISP y tráfico kernel por IP |
| `sudo smartdns monitor` | Monitor SNI en tiempo real con alias y colores (`Ctrl+C` seguro) |
| `sudo smartdns discover` | Asistente DNS para descubrir dominios nuevos de una app Android |
| `sudo smartdns ip add <IP> "<Alias>" 0` | Autoriza una VPS VPN permanente (`0`) o cliente por `N` días |
| `sudo smartdns domains check <dom\|url>` | Verifica por dónde sale un dominio y prueba DNS/SNI en vivo |
| `sudo smartdns update` | Actualiza atómicamente desde GitHub conservando licencias y listas |
| `sudo smartdns cleanup` | Libera caché APT, `journald` y logs rotados (VPS de 10 GB) |
| `sudo smartdns backup` | Respaldo liviano (~3 KB) de licencias, listas y configuración |
| `sudo smartdns uninstall` | Desinstalación limpia restaurando `systemd-resolved` (SSH intacto) |

---

## Guías por tema ([docs/GUIA-COMPLETA.md](docs/GUIA-COMPLETA.md))

- [Instalación y VPS con NAT 1:1 / DHCP](docs/GUIA-COMPLETA.md#instalacion)
- [Conectar tus VPS de Brasil / USA y Android](docs/GUIA-COMPLETA.md#conectar-vps-vpn)
- [Gestión de Clientes y Licencias IP (Geo/ISP y contadores)](docs/GUIA-COMPLETA.md#licencias-ip)
- [Dominios, Categorías y Buscador](docs/GUIA-COMPLETA.md#dominios)
- [Diagnóstico, Métricas y Monitor SNI en vivo](docs/GUIA-COMPLETA.md#diagnostico)
- [Descubrir dominios de una app argentina nueva](docs/GUIA-COMPLETA.md#descubrir-apps)
- [Mantenimiento, Ahorro de Disco (10 GB), Backups y Update](docs/GUIA-COMPLETA.md#mantenimiento)
- [Limitaciones conocidas (ej. detección `TRANSPORT_VPN` / DoH)](docs/GUIA-COMPLETA.md#limitaciones)

---

## Utilidad incluida: habilitar acceso SSH `root` con clave

Compatible con Ubuntu 22.04/24.04/26.04 y `cloud-init` (prioridad `00-joif-root.conf`, validación `sshd -t` con rollback automático):

```bash
curl -fsSL https://raw.githubusercontent.com/manuel3200/joif-smartdns/main/tools/acceso-root.sh -o acceso-root.sh && chmod +x acceso-root.sh && sudo ./acceso-root.sh
```

---

## Estructura del repositorio

```text
joif-smartdns/
├── install.sh                       # Instalador idempotente Ubuntu 22.04 / 24.04 / 26.04 LTS
├── uninstall.sh                     # Desinstalador limpio (restaura systemd-resolved, SSH intacto)
├── menu.sh                          # Panel visual interactivo y CLI (/usr/local/bin/smartdns)
├── core/
│   ├── common.sh                    # Rutas, validadores, Geo/ISP liviano, helpers y bloqueo flock
│   ├── ui.sh                        # Interfaz compacta <=74 cols, UTF-8/ASCII y Ctrl+C seguro
│   ├── domains.sh                   # Parser, deduplicación, categorías y buscador/probador live
│   ├── dnsmasq_gen.sh               # Generador dnsmasq (filter-rr=AAAA,HTTPS,SVCB) con rollback
│   ├── nginx_gen.sh                 # Generador nginx stream (443) + http (80) con allowlist/rollback
│   ├── licenses.sh                  # CRUD de licencias IP/CIDR, origen Geo/ISP y expiración
│   ├── firewall.sh                  # ipset con counters (migración sin cortes) + iptables JOIF_SMARTDNS
│   ├── expire-licenses.sh           # Tarea horaria: purga vencidas y tope de tamaño de logs
│   ├── diagnostics.sh               # Diagnóstico integral en vivo (DNS, anti-fuga, SNI, firewall)
│   ├── metrics.sh                   # Mbps en vivo, disco/RAM, tráfico por IP y Top dominios
│   ├── maintenance.sh               # logrotate, tope journald 80MB, limpieza 10GB y backup/restore
│   ├── updater.sh                   # Actualizador atómico desde GitHub sin depender de .git
│   └── monitor.sh                   # Monitor SNI formateado y asistente descubridor de apps DNS
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
│   └── acceso-root.sh               # Utilidad para habilitar SSH root con clave (cloud-init safe)
├── docs/
│   └── GUIA-COMPLETA.md             # Manual operativo completo con anclas enlazadas desde el menú
└── tests/
    └── run_tests.sh                 # Suite de pruebas automatizadas locales
```

## Pruebas automatizadas locales

```bash
bash tests/run_tests.sh
```
