use std::fs;
use std::process::Command;

#[derive(Debug, Clone)]
pub struct CmdResult {
    pub success: bool,
    pub output: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LicenseRow {
    pub ip: String,
    pub alias: String,
    #[allow(dead_code)]
    pub created_at: i64,
    pub expires_at: i64,
    pub status: String,
    pub geo: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CategoryRow {
    pub slug: String,
    pub label: String,
    pub status: String,
    pub count: String,
}

/// Ejecuta /usr/local/bin/smartdns pasando argumentos directos sin invocar shell (cero inyeccion)
pub fn run_smartdns(bin: &str, args: &[&str]) -> CmdResult {
    match Command::new(bin).args(args).env("NO_COLOR", "1").output() {
        Ok(out) => {
            let mut combined = String::from_utf8_lossy(&out.stdout).to_string();
            let err = String::from_utf8_lossy(&out.stderr);
            if !err.trim().is_empty() {
                if !combined.is_empty() && !combined.ends_with('\n') {
                    combined.push('\n');
                }
                combined.push_str(&err);
            }
            CmdResult {
                success: out.status.success(),
                output: strip_ansi(combined.trim()),
            }
        }
        Err(e) => CmdResult {
            success: false,
            output: format!("Error ejecutando '{}': {}", bin, e),
        },
    }
}

/// Limpia codigos de color ANSI residuales
pub fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' && chars.peek() == Some(&'[') {
            chars.next();
            for next in chars.by_ref() {
                if next.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Valida argumentos basicos para prevenir opciones malformadas
pub fn is_safe_token(s: &str, max_len: usize) -> bool {
    !s.is_empty()
        && s.len() <= max_len
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '/' | '-' | '_' | ':'))
}

pub fn parse_licenses_file(path: &str) -> Vec<LicenseRow> {
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    parse_licenses_str(&content)
}

pub fn parse_licenses_str(content: &str) -> Vec<LicenseRow> {
    let mut rows = Vec::new();
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() < 5 {
            continue;
        }
        rows.push(LicenseRow {
            ip: parts[0].to_string(),
            alias: parts[1].to_string(),
            created_at: parts[2].parse::<i64>().unwrap_or(0),
            expires_at: parts[3].parse::<i64>().unwrap_or(0),
            status: parts[4].to_string(),
            geo: parts.get(6).copied().unwrap_or("-").to_string(),
        });
    }
    rows
}

pub fn parse_categories_output(output: &str) -> Vec<CategoryRow> {
    let mut rows = Vec::new();
    for raw in output.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() < 4 {
            continue;
        }
        rows.push(CategoryRow {
            slug: parts[0].to_string(),
            label: parts[1].to_string(),
            status: parts[2].to_string(),
            count: parts[3].to_string(),
        });
    }
    rows
}

pub fn is_service_active(service: &str) -> bool {
    Command::new("systemctl")
        .args(["is-active", "--quiet", service])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_strip_ansi() {
        assert_eq!(strip_ansi("\x1b[0;32m[ OK ]\x1b[0m listo"), "[ OK ] listo");
    }

    #[test]
    fn test_is_safe_token() {
        assert!(is_safe_token("144.22.167.150/32", 32));
        assert!(is_safe_token("personalpay.dev", 64));
        assert!(!is_safe_token("--help", 32));
        assert!(!is_safe_token("bad;rm -rf /", 64));
        assert!(!is_safe_token("", 32));
    }

    #[test]
    fn test_parse_licenses_str() {
        let data = "# header\n144.22.167.150/32|Nodo Brasil 01|1700000000|0|activa|1700000000|BR/Sao Paulo (Oracle)\n";
        let rows = parse_licenses_str(data);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].ip, "144.22.167.150/32");
        assert_eq!(rows[0].alias, "Nodo Brasil 01");
        assert_eq!(rows[0].geo, "BR/Sao Paulo (Oracle)");
    }

    #[test]
    fn test_parse_categories_output() {
        let out = "01-fintech-bancos|Fintech, Billeteras y Bancos AR|activa|55|/etc/joif-smartdns/domains.d/01-fintech-bancos.list\n";
        let cats = parse_categories_output(out);
        assert_eq!(cats.len(), 1);
        assert_eq!(cats[0].slug, "01-fintech-bancos");
        assert_eq!(cats[0].status, "activa");
        assert_eq!(cats[0].count, "55");
    }
}
