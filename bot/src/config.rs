use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone)]
pub struct BotConfig {
    pub token: String,
    pub admin_ids: Vec<i64>,
    pub admin_set: HashSet<i64>,
    pub smartdns_bin: String,
    pub licenses_db: String,
    pub alert_mbps: f64,
    pub alert_disk_pct: u8,
    pub alert_check_sec: u64,
}

impl BotConfig {
    pub fn load() -> Result<Self, String> {
        // Optional .env fallback if not loaded via systemd EnvironmentFile
        let env_path = env::var("JOIF_TELEGRAM_ENV")
            .unwrap_or_else(|_| "/etc/joif-smartdns/telegram.env".to_string());
        if Path::new(&env_path).is_file() {
            if let Ok(content) = fs::read_to_string(&env_path) {
                for (k, v) in parse_env_pairs(&content) {
                    if env::var_os(&k).is_none() {
                        env::set_var(k, v);
                    }
                }
            }
        }

        let token = env::var("TELEGRAM_BOT_TOKEN")
            .map_err(|_| "Falta TELEGRAM_BOT_TOKEN en /etc/joif-smartdns/telegram.env".to_string())?
            .trim()
            .to_string();
        if token.is_empty() || !token.contains(':') {
            return Err("TELEGRAM_BOT_TOKEN invalido (esperado formato 123456:ABC...).".to_string());
        }

        let raw_admins = env::var("TELEGRAM_ADMIN_IDS")
            .map_err(|_| "Falta TELEGRAM_ADMIN_IDS en /etc/joif-smartdns/telegram.env".to_string())?;
        let admin_ids = parse_admin_ids(&raw_admins)?;
        let admin_set: HashSet<i64> = admin_ids.iter().copied().collect();

        let smartdns_bin = env::var("JOIF_SMARTDNS_BIN")
            .unwrap_or_else(|_| "/usr/local/bin/smartdns".to_string());
        let licenses_db = env::var("JOIF_LICENSES_DB")
            .unwrap_or_else(|_| "/etc/joif-smartdns/licenses.db".to_string());
        let alert_mbps = env::var("TELEGRAM_ALERT_MBPS")
            .ok()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .unwrap_or(8.5);
        let alert_disk_pct = env::var("TELEGRAM_ALERT_DISK_PCT")
            .ok()
            .and_then(|v| v.trim().parse::<u8>().ok())
            .unwrap_or(85);
        let alert_check_sec = env::var("TELEGRAM_ALERT_CHECK_SEC")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .filter(|&s| s >= 30)
            .unwrap_or(300);

        Ok(Self {
            token,
            admin_ids,
            admin_set,
            smartdns_bin,
            licenses_db,
            alert_mbps,
            alert_disk_pct,
            alert_check_sec,
        })
    }

    pub fn is_admin(&self, user_id: i64) -> bool {
        self.admin_set.contains(&user_id)
    }
}

pub fn parse_env_pairs(content: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let key = k.trim().to_string();
            let mut val = v.trim().to_string();
            if (val.starts_with('"') && val.ends_with('"') && val.len() >= 2)
                || (val.starts_with('\'') && val.ends_with('\'') && val.len() >= 2)
            {
                val = val[1..val.len() - 1].to_string();
            }
            if !key.is_empty() {
                out.push((key, val));
            }
        }
    }
    out
}

pub fn parse_admin_ids(raw: &str) -> Result<Vec<i64>, String> {
    let mut ids = Vec::new();
    for part in raw.split([',', ' ', ';']) {
        let p = part.trim();
        if p.is_empty() {
            continue;
        }
        let id = p
            .parse::<i64>()
            .map_err(|_| format!("ID de administrador Telegram invalido: '{}'", p))?;
        if !ids.contains(&id) {
            ids.push(id);
        }
    }
    if ids.is_empty() {
        return Err("TELEGRAM_ADMIN_IDS debe contener al menos un ID numerico.".to_string());
    }
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_env_pairs() {
        let raw = r#"
# Comentario
TELEGRAM_BOT_TOKEN="12345:abcDEF"
TELEGRAM_ADMIN_IDS='111222, 333444'
TELEGRAM_ALERT_MBPS=8.5
"#;
        let pairs = parse_env_pairs(raw);
        assert_eq!(pairs.len(), 3);
        assert_eq!(pairs[0], ("TELEGRAM_BOT_TOKEN".into(), "12345:abcDEF".into()));
        assert_eq!(pairs[1], ("TELEGRAM_ADMIN_IDS".into(), "111222, 333444".into()));
        assert_eq!(pairs[2], ("TELEGRAM_ALERT_MBPS".into(), "8.5".into()));
    }

    #[test]
    fn test_parse_admin_ids() {
        let ids = parse_admin_ids("123456, 789012, 123456").unwrap();
        assert_eq!(ids, vec![123456, 789012]);
        assert!(parse_admin_ids("   ").is_err());
        assert!(parse_admin_ids("abc").is_err());
    }
}
