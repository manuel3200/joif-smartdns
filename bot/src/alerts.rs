use crate::config::BotConfig;
use crate::runner::{is_service_active, parse_licenses_file};
use crate::telegram::{escape_html, TelegramClient};
use std::collections::HashMap;
use std::fs;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub fn spawn_alert_loop(cfg: BotConfig, tg: TelegramClient) {
    thread::spawn(move || {
        // Espera breve inicial para no disparar alertas justo durante un arranque del sistema
        thread::sleep(Duration::from_secs(20));

        let mut cooldowns: HashMap<String, Instant> = HashMap::new();
        let mut down_services: HashMap<String, bool> = HashMap::new();

        loop {
            check_services(&cfg, &tg, &mut cooldowns, &mut down_services);
            check_disk(&cfg, &tg, &mut cooldowns);
            check_bandwidth(&cfg, &tg, &mut cooldowns);
            check_licenses(&cfg, &tg, &mut cooldowns);

            thread::sleep(Duration::from_secs(cfg.alert_check_sec));
        }
    });
}

fn can_alert(cooldowns: &mut HashMap<String, Instant>, key: &str, min_gap_sec: u64) -> bool {
    let now = Instant::now();
    if let Some(&last) = cooldowns.get(key) {
        if now.duration_since(last).as_secs() < min_gap_sec {
            return false;
        }
    }
    cooldowns.insert(key.to_string(), now);
    true
}

fn broadcast(cfg: &BotConfig, tg: &TelegramClient, html: &str) {
    for &admin_id in &cfg.admin_ids {
        let _ = tg.send_html(admin_id, html, None);
    }
}

fn check_services(
    cfg: &BotConfig,
    tg: &TelegramClient,
    cooldowns: &mut HashMap<String, Instant>,
    down_services: &mut HashMap<String, bool>,
) {
    for svc in ["dnsmasq", "nginx", "joif-smartdns-firewall.service"] {
        let active = is_service_active(svc);
        let was_down = *down_services.get(svc).unwrap_or(&false);

        if !active {
            down_services.insert(svc.to_string(), true);
            let key = format!("svc_down:{}", svc);
            if can_alert(cooldowns, &key, 1800) {
                let msg = format!(
                    "🚨 <b>ALERTA SERVICIO CAÍDO</b>\nEl servicio <code>{}</code> está INACTIVO en tu VPS Smart DNS.",
                    escape_html(svc)
                );
                broadcast(cfg, tg, &msg);
            }
        } else if was_down {
            down_services.insert(svc.to_string(), false);
            let msg = format!(
                "✅ <b>SERVICIO RECUPERADO</b>\n<code>{}</code> volvió a estar ACTIVO.",
                escape_html(svc)
            );
            broadcast(cfg, tg, &msg);
        }
    }
}

fn check_disk(cfg: &BotConfig, tg: &TelegramClient, cooldowns: &mut HashMap<String, Instant>) {
    if cfg.alert_disk_pct == 0 {
        return;
    }
    let out = match Command::new("df").args(["-P", "-h", "/"]).output() {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
        _ => return,
    };
    if let Some((pct, avail)) = parse_df_root(&out) {
        if pct >= cfg.alert_disk_pct && can_alert(cooldowns, "disk_high", 21600) {
            let msg = format!(
                "⚠️ <b>ALERTA DISCO (10 GB)</b>\nDisco raíz al <b>{}%</b> ({} libre).\nEjecutá /cleanup desde este chat para liberar caché APT y logs.",
                pct,
                escape_html(&avail)
            );
            broadcast(cfg, tg, &msg);
        }
    }
}

pub fn parse_df_root(df_output: &str) -> Option<(u8, String)> {
    let line = df_output.lines().nth(1)?;
    let cols: Vec<&str> = line.split_whitespace().collect();
    if cols.len() < 5 {
        return None;
    }
    let avail = cols[3].to_string();
    let pct = cols[4].trim_end_matches('%').parse::<u8>().ok()?;
    Some((pct, avail))
}

fn detect_default_iface() -> String {
    if let Ok(out) = Command::new("ip").args(["-4", "route", "show", "default"]).output() {
        let s = String::from_utf8_lossy(&out.stdout);
        let words: Vec<&str> = s.split_whitespace().collect();
        for w in words.windows(2) {
            if w[0] == "dev" {
                return w[1].to_string();
            }
        }
    }
    "eth0".to_string()
}

fn sample_iface_mbps(iface: &str) -> Option<f64> {
    let rx_path = format!("/sys/class/net/{}/statistics/rx_bytes", iface);
    let tx_path = format!("/sys/class/net/{}/statistics/tx_bytes", iface);
    let rx1: u64 = fs::read_to_string(&rx_path).ok()?.trim().parse().ok()?;
    let tx1: u64 = fs::read_to_string(&tx_path).ok()?.trim().parse().ok()?;
    thread::sleep(Duration::from_secs(1));
    let rx2: u64 = fs::read_to_string(&rx_path).ok()?.trim().parse().ok()?;
    let tx2: u64 = fs::read_to_string(&tx_path).ok()?.trim().parse().ok()?;

    let drx = rx2.saturating_sub(rx1) as f64;
    let dtx = tx2.saturating_sub(tx1) as f64;
    Some(((drx + dtx) * 8.0) / 1_000_000.0)
}

fn check_bandwidth(
    cfg: &BotConfig,
    tg: &TelegramClient,
    cooldowns: &mut HashMap<String, Instant>,
) {
    if cfg.alert_mbps <= 0.0 {
        return;
    }
    let iface = detect_default_iface();
    let m1 = match sample_iface_mbps(&iface) {
        Some(v) => v,
        None => return,
    };
    if m1 < cfg.alert_mbps {
        return;
    }
    // Segunda lectura tras 2 segundos para confirmar saturacion sostenida (evita falsos picos de 1s)
    thread::sleep(Duration::from_secs(2));
    if let Some(m2) = sample_iface_mbps(&iface) {
        if m2 >= cfg.alert_mbps && can_alert(cooldowns, "bw_high", 1800) {
            let msg = format!(
                "📶 <b>ALERTA ANCHO DE BANDA ({})</b>\nTráfico sostenido en <b>{:.2} Mbps</b> (umbral: {:.1} Mbps).\nUsá /metrics para ver qué IP/dominio está consumiendo o pausá Streaming en /domains.",
                escape_html(&iface),
                m2,
                cfg.alert_mbps
            );
            broadcast(cfg, tg, &msg);
        }
    }
}

fn check_licenses(
    cfg: &BotConfig,
    tg: &TelegramClient,
    cooldowns: &mut HashMap<String, Instant>,
) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    if now == 0 {
        return;
    }

    for row in parse_licenses_file(&cfg.licenses_db) {
        if row.expires_at == 0 {
            continue;
        }
        let rem = row.expires_at - now;
        if row.status == "activa" && rem > 0 && rem <= 86400 {
            let key = format!("lic_soon:{}", row.ip);
            if can_alert(cooldowns, &key, 43200) {
                let hours = (rem / 3600).max(1);
                let msg = format!(
                    "⏳ <b>LICENCIA POR VENCER</b>\nIP: <code>{}</code> ({})\nRestan aprox. <b>{}h</b>. Podés renovarla con /ips.",
                    escape_html(&row.ip),
                    escape_html(&row.alias),
                    hours
                );
                broadcast(cfg, tg, &msg);
            }
        } else if rem <= 0 {
            let key = format!("lic_exp:{}", row.ip);
            if can_alert(cooldowns, &key, 86400) {
                let msg = format!(
                    "⛔ <b>LICENCIA VENCIDA</b>\nIP: <code>{}</code> ({}) está vencida y bloqueada en el firewall.\nUsá /ips o <code>/renew {} 30</code> para reactivarla.",
                    escape_html(&row.ip),
                    escape_html(&row.alias),
                    escape_html(&row.ip)
                );
                broadcast(cfg, tg, &msg);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_df_root() {
        let sample = "Filesystem      Size  Used Avail Use% Mounted on\n/dev/vda1       9.6G  2.0G  6.9G  21% /\n";
        assert_eq!(parse_df_root(sample), Some((21, "6.9G".to_string())));
    }
}
