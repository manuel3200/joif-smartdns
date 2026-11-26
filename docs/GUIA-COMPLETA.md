# Guía Completa de Operación — `joif-smartdns`

Manual práctico para instalar, operar y diagnosticar **JOIF Smart DNS** (Servidor Smart DNS + SNI Proxy Argentino con Licencias por IP/CIDR), optimizado para **Ubuntu 22.04, 24.04 y 26.04 LTS** en VPS livianas (desde 1 vCPU, 1 GB RAM y 10 GB de disco).

## Índice

- [Cómo funciona en el ecosistema JOIF VPN](#como-funciona)
- [1. Instalación paso a paso (y VPS con NAT 1:1)](#instalacion)
- [2. Conectar tus VPS de Brasil / USA y celulares Android](#conectar-vps-vpn)
- [3. Gestión de Clientes y Nodos VPN (Licencias IP)](#licencias-ip)
- [4. Dominios, Categorías y Buscador (`¿Por dónde sale X?`)](#dominios)
- [5. Diagnóstico, Métricas y Monitor SNI en vivo](#diagnostico)
- [6. Descubrir dominios de una app argentina nueva](#descubrir-apps)
- [7. Mantenimiento, Ahorro de Disco (10 GB), Backups y Update](#mantenimiento)
- [8. Limitaciones conocidas y soluciones prácticas](#limitaciones)
- [9. Desinstalación limpia y utilidad `acceso-root.sh`](#desinstalacion)

---

<a id="como-funciona"></a>
## Cómo funciona en el ecosistema JOIF VPN

```text
[Celular Android (JOIF VPN: Zeptun / HevSocks5 + BadVPN UDPGW)]
          │  Túnel VPN/SSH de alta velocidad
          ▼
[VPS Principal Brasil / USA (ej. br1.joif.net)]
          │
          ├─► ~95% tráfico normal (YouTube, TikTok, WhatsApp, descargas, gaming)
          │        └─► Resuelto via 1.1.1.1 / 8.8.8.8 ─► Sale DIRECTO por Brasil/USA
          │
          └─► ~5% dominios argentinos (Mercado Pago, bancos, .gob.ar, streaming AR)
                   ├─► Consulta DNS (53/udp+tcp) ─► VPS Argentina (dnsmasq)
                   │        Devuelve A = <IP_VPS_AR> y bloquea AAAA + HTTPS/SVCB
                   └─► Conexión TLS/HTTP (443/80) ─► VPS Argentina (nginx ssl_preread)
                            Reenvío transparente extremo a extremo SIN descifrar TLS
```

**Ventajas clave:**
- **Cero descifrado TLS:** los certificados SSL originales de bancos, Mercado Pago, Mi Argentina y Netflix llegan intactos al teléfono.
- **Anti-fuga moderno:** en Ubuntu 24.04/26.04 (`dnsmasq >= 2.90`) activa automáticamente `filter-rr=AAAA,HTTPS,SVCB`, evitando que Android/Chrome use IPv6, `ipv4hint` o `ECH` para saltarse el Smart DNS.
- **Cerrado contra abuso:** solo las IPs autorizadas en `ipset joif_smartdns_allow` acceden a los puertos `53/80/443`, y el proxy solo reenvía dominios presentes en las listas habilitadas. **El puerto SSH (`22/tcp`) nunca se toca.**

---

<a id="instalacion"></a>
## 1. Instalación paso a paso (y VPS con NAT 1:1)

### Requisitos recomendados
- **Sistema:** Ubuntu **24.04 LTS** o **26.04 LTS** *(recomendados por traer `dnsmasq >= 2.90` con `filter-rr=AAAA,HTTPS,SVCB`; también compatible con Ubuntu 22.04 LTS)*.
- **Hardware:** 1 vCPU, 1 GB RAM, 10 GB SSD/NVMe (`dnsmasq` + `nginx` consumen menos de 80 MB de RAM).
- **Red:** 1 IPv4 pública dedicada.

> **¿Tu VPS usa NAT 1:1 con IP privada por DHCP (ej. NeaTech, Oracle Cloud, AWS)?**
> Es 100% compatible. Dejá la red en DHCP sin modificar `netplan` ni la MAC. `joif-smartdns` escucha en wildcard (`0.0.0.0`) y devuelve tu **IP pública** en las respuestas DNS.

### Comando de instalación (1 sola línea)

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq git && git clone https://github.com/manuel3200/joif-smartdns.git && cd joif-smartdns && sudo ./install.sh
```

Si querés pasar la IP pública y autorizar tu primera VPS de Brasil de una sola vez:

```bash
sudo ./install.sh --public-ip <IP_VPS_AR> --allow-ip <IP_VPS_BRASIL> --allow-alias "Nodo Brasil 01" --non-interactive
```

Al finalizar, abrí el panel en cualquier momento ejecutando:

```bash
sudo smartdns
```

---

<a id="conectar-vps-vpn"></a>
## 2. Conectar tus VPS de Brasil / USA y celulares Android

### Paso A — Autorizar la IP pública de tu VPS VPN (en la VPS de Argentina)

```bash
sudo smartdns ip add <IP_PUBLICA_VPS_BRASIL> "Nodo Brasil 01" 0
```
*(El `0` significa licencia **permanente**, ideal para tus propios nodos JOIF.)*

### Paso B — Verificar conectividad desde la VPS de Brasil / USA

```bash
dig +short @<IP_VPS_AR> mercadopago.com.ar A      # Debe devolver <IP_VPS_AR>
dig +short @<IP_VPS_AR> mercadopago.com.ar AAAA   # Debe devolver vacío
dig +short @<IP_VPS_AR> mercadopago.com.ar TYPE65 # Debe devolver vacío
dig +short @<IP_VPS_AR> google.com A              # Debe devolver IP normal de Google
```

### Paso C — Redirección transparente de DNS en la VPS VPN (recomendado)

Si tus usuarios Android tienen `8.8.8.8` o `1.1.1.1` como DNS primario/secundario en la app, agregá estas 2 reglas `DNAT` en tu VPS de Brasil/USA (o activalas desde `joif-script`) para que **todas** las consultas puerto 53 de los usuarios pasen automáticamente por tu Smart DNS argentino:

```bash
iptables -t nat -A OUTPUT -p udp --dport 53 ! -o lo ! -d <IP_VPS_AR> -j DNAT --to-destination <IP_VPS_AR>:53
iptables -t nat -A OUTPUT -p tcp --dport 53 ! -o lo ! -d <IP_VPS_AR> -j DNAT --to-destination <IP_VPS_AR>:53
```

> **En el celular Android:**
> - **Ajustes → Red e Internet → DNS privado → Desactivado.**
> - En Chrome (si probás desde navegador): **⋮ → Configuración → Privacidad y seguridad → Usar DNS seguro → Desactivado.**
> - En la app JOIF VPN, si configurás DNS manual, poné **solo `<IP_VPS_AR>`** (no agregues `1.1.1.1`/`8.8.8.8` como secundario, porque desde Brasil respondería más rápido que Argentina).

---

<a id="licencias-ip"></a>
## 3. Gestión de Clientes y Nodos VPN (Licencias IP)

Ingresá a `sudo smartdns` → **Opción 1 (`Clientes / Nodos VPN`)**.

Cada licencia muestra en formato compacto (apto para celular SSH):
- **Número `[1]`, `[2]`...** para operar sin tener que tipear IPs largas.
- **IP o subred CIDR** (`/32` o `/24`, nunca permite `0.0.0.0/0`).
- **Alias / Cliente**, **Estado** (`[ACTIVA]`, `[PAUSADA]`, `[VENCIDA]`) y **Tiempo restante**.
- **Origen (Geo/ISP):** consultado de forma ultraliviana (~150 bytes, 0 KB en disco) al agregar la IP (ej. `BR/Sao Paulo (Oracle Cloud)`).
- **Tráfico kernel:** acumulado en tiempo real mediante `ipset counters` (0 KB en disco), ideal para confirmar en 1 segundo si un nodo está enviando tráfico real.

### Comandos rápidos CLI

```bash
sudo smartdns ip list
sudo smartdns ip add 198.51.100.20 "Cliente Mensual" 30   # 30 días
sudo smartdns ip add 144.22.167.150 "Nodo Brasil 01" 0    # Permanente
sudo smartdns ip edit-alias 144.22.167.150 "BR1 Oracle"   # Renombrar
sudo smartdns ip renew 198.51.100.20 30                   # Suma 30 días (o 0 = permanente)
sudo smartdns ip suspend 198.51.100.20                    # Bloqueo inmediato en ipset
sudo smartdns ip reactivate 198.51.100.20                 # Reactiva si sigue vigente
sudo smartdns ip refresh-geo                              # Completa Geo/ISP faltantes
sudo smartdns ip remove 198.51.100.20                     # Elimina de DB e ipset
```

**Vencimiento automático:** el temporizador `joif-smartdns-expire.timer` corre cada hora, pasa a `suspendida` cualquier IP vencida y la saca del `ipset` automáticamente mediante `swap` atómico (sin cortar a los demás nodos).

---

<a id="dominios"></a>
## 4. Dominios, Categorías y Buscador (`¿Por dónde sale X?`)

Las listas viven en `/etc/joif-smartdns/domains.d/`:
1. `01-fintech-bancos.list`: Mercado Pago/Libre, Personal Pay (`personalpay.dev` + `paygilant.com`), Ualá, Brubank, Naranja X, MODO, Prex, Lemon, Belo, Ripio, BNA, Provincia/Cuenta DNI, Galicia, Santander, BBVA, Macro, Link, Banelco/Prisma, etc.
2. `02-gobierno-ar.list`: `argentina.gob.ar`, `miargentina.gob.ar`, `afip.gob.ar`, `arca.gob.ar`, `anses.gob.ar`, `renaper.gob.ar`, `pami.org.ar`, `buenosaires.gob.ar`, `gba.gob.ar`, etc.
3. `03-streaming-ar.list`: Netflix, Flow, TyC Sports Play, Telefe, El Trece, DGO, Disney+, Max, Prime Video.
4. `99-custom.list`: tus dominios personalizados (nunca se sobreescriben al actualizar).

### Buscador y probador puntual (`¿Por dónde sale X?`)
Desde el menú **Opción 2 → 2** o por consola:

```bash
sudo smartdns domains check api.transfers.prod.personalpay.dev
sudo smartdns domains check https://www.brubank.com.ar/cuentas
```

Te informa al instante si el dominio está **`[AR - INTERCEPTADO]`**, **`[PAUSADA]`** o **`[DIRECTO]`**, qué regla lo cubre, qué devuelve `dnsmasq` (`A`/`AAAA`/`TYPE65`) y prueba el handshake TLS en `127.0.0.1:443`.

### Comandos rápidos de dominios

```bash
sudo smartdns domains list
sudo smartdns domains disable 03-streaming-ar   # Recomendado si tenés enlace de 10 Mbps
sudo smartdns domains enable 03-streaming-ar
sudo smartdns domains add midominio.com.ar
sudo smartdns domains remove midominio.com.ar
sudo smartdns reload                            # Valida dnsmasq --test + nginx -t (rollback si falla)
```

---

<a id="diagnostico"></a>
## 5. Diagnóstico, Métricas y Monitor SNI en vivo

Ingresá a `sudo smartdns` → **Opción 3 (`Diagnóstico, Métricas y Monitores en Vivo`)**.

1. **Diagnóstico integral (`sudo smartdns status`):** verifica IP primaria, los 4 servicios `systemd`, los 4 puertos (`53/udp`, `53/tcp`, `80/tcp`, `443/tcp`), `ipset`/`iptables`, anti-fuga `AAAA`/`TYPE65`, passthrough TLS y rechazo anti-abuso (`example.com`).
2. **Métricas en vivo (`sudo smartdns metrics`):**
   - Velocidad instantánea de red en **Mbps** (clave en VPS de 10 Mbps o 25 Mbps).
   - Espacio libre en disco (`/`) y RAM usada.
   - Tabla de origen Geo/ISP, bytes de kernel (`ipset`) y última conexión por IP.
   - Top 10 dominios SNI por tráfico.
3. **Monitor SNI en vivo (`sudo smartdns monitor`):** muestra en tiempo real cada conexión HTTPS en formato compacto (`HORA [OK]/[BLK] ALIAS DOMINIO BYTES`). Presionar **`Ctrl+C`** te devuelve suavemente al menú sin cerrarlo.

---

<a id="descubrir-apps"></a>
## 6. Descubrir dominios de una app argentina nueva

Si una app bancaria o billetera usa un dominio secundario que aún no está en las listas (por ejemplo, cuando detectamos `personalpay.dev` y `paygilant.com`), usá el asistente guiado:

- En el menú: **Opción 3 → 5 (`Descubrir dominios de una app`)**
- Por CLI: `sudo smartdns discover`

**Cómo usarlo en 30 segundos:**
1. Elegí por número tu nodo VPN (ej. `[1] Nodo Brasil 01`) y dejá `25` segundos.
2. Abrí la app en tu celular conectado a la VPN y hacé la acción que falla (ej. iniciar sesión o transferir).
3. El asistente **oculta automáticamente el ruido de fondo de Android** (Google, Facebook, WhatsApp, Apple, OEMs, CloudFront/AWS) y clasifica en vivo cada consulta como `[AR]`, `[PAUSADA]` o `[NUEVO]`.
4. Al terminar (o al apretar `Ctrl+C`), te muestra una lista numerada de dominios base sugeridos (respetando `.com.ar`, `.gob.ar`, etc.). Escribís los números (ej. `1 2`) y se agregan a `99-custom.list` recargando `dnsmasq` + `nginx` automáticamente.

---

<a id="mantenimiento"></a>
## 7. Mantenimiento, Ahorro de Disco (10 GB), Backups y Update

`joif-smartdns` está pensado para correr años sin llenar una VPS de **10 GB**:

- **Protecciones instaladas automáticamente:**
  - `/etc/logrotate.d/joif-smartdns`: rota logs diarios con tope `maxsize 5M` y máximo `2` copias comprimidas.
  - `/etc/systemd/journald.conf.d/99-joif-smartdns.conf`: limita `journald` a **80 MB**.
  - Guardia horaria en `joif-smartdns-expire.timer`: si algún log de `nginx` supera los `10 MB` en un pico, lo recorta conservando las últimas 500 líneas.
- **Comandos de mantenimiento (también en Menú → Opción 4):**
  ```bash
  sudo smartdns update                  # Actualiza desde GitHub con reemplazo atómico y backup previo
  sudo smartdns cleanup                 # Limpia caché APT, journald y rotados (muestra MB liberados)
  sudo smartdns cleanup --clear-logs    # Limpia todo + vacía el log activo de nginx
  sudo smartdns logs off                # Desactiva access_log de nginx (0 bytes de escritura en disco)
  sudo smartdns logs on                 # Reactiva access_log para usar el monitor y métricas SNI
  sudo smartdns backup                  # Crea respaldo ~3 KB (config.env + licenses.db + domains.d/)
  sudo smartdns restore <archivo.tar.gz># Restaura estado validando rutas seguras
  ```

---

<a id="limitaciones"></a>
## 8. Limitaciones conocidas y soluciones prácticas

1. **Apps fintech con detección local de VPN en Android (`TRANSPORT_VPN` / `tun0`):**
   - Algunas apps (como **Personal Pay** con su SDK antifraude Paygilant) le preguntan directamente a Android si existe una interfaz VPN activa (`tun0`).
   - Aunque el tráfico salga 100% por IP argentina (`186.x.x.x`), la app puede rechazar operaciones sensibles por ver la VPN encendida en el teléfono.
   - **Solución práctica:** excluir esa app puntual mediante **Split Tunneling** en tu app VPN cuando el usuario navegue desde Argentina.
2. **DNS Privado de Android (DoT puerto 853) y DNS Seguro de Chrome (DoH puerto 443):**
   - Si el usuario tiene DoT o DoH activado, las consultas DNS salen cifradas sin pasar por el puerto 53 del Smart DNS. Desactivarlos en el dispositivo resuelve el bypass.
3. **Ancho de banda en VPS de 10 Mbps:**
   - Para **Bancos, Billeteras y `.gob.ar`**, 10 Mbps simétricos alcanzan sobrados para cientos de usuarios.
   - Si habilitás **Streaming (`03-streaming-ar`)**, cada video HD consume 4–8 Mbps. Con 10 Mbps conviene pausar `03-streaming-ar` (`sudo smartdns domains disable 03-streaming-ar`) o subir la VPS a ≥ 25–100 Mbps.
4. **Bloqueos por ASN de datacenter en plataformas de streaming:**
   - Netflix y Disney+ pueden bloquear rangos de IPs de ciertos datacenters comerciales sin importar el país; esto depende exclusivamente de la reputación del rango IP del proveedor de VPS.

---

<a id="desinstalacion"></a>
## 9. Desinstalación limpia y utilidad `acceso-root.sh`

### Desinstalar completamente (sin cortar SSH)
Desde el panel (`Opción 6`) o por consola:
```bash
sudo smartdns uninstall
```
Elimina únicamente las cadenas `JOIF_SMARTDNS`, destruye `joif_smartdns_allow`, quita los drop-ins de `logrotate`/`journald`, restaura `/etc/nginx/nginx.conf`, `systemd-resolved` y `/etc/resolv.conf` verificando conectividad DNS y dejando SSH (`22/tcp`) intacto.

### Utilidad incluida: habilitar acceso SSH `root` con clave
Para VPS nuevas con `cloud-init` (Ubuntu 22.04/24.04/26.04) que solo entregan un usuario sin `root`:
```bash
curl -fsSL https://raw.githubusercontent.com/manuel3200/joif-smartdns/main/tools/acceso-root.sh -o acceso-root.sh && chmod +x acceso-root.sh && sudo ./acceso-root.sh
```
Crea `/etc/ssh/sshd_config.d/00-joif-root.conf` (prioridad sobre `50-cloud-init.conf`), valida con `sshd -t` con rollback automático y muestra la tarjeta con tus datos de acceso.
