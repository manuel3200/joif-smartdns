use crate::config::BotConfig;
use crate::runner::{
    is_safe_token, parse_categories_output, parse_licenses_file, run_smartdns,
};
use crate::telegram::{
    build_keyboard, escape_html, truncate_chars, CallbackQuery, InlineButton, Message,
    TelegramClient,
};
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn main_menu_keyboard() -> Value {
    build_keyboard(vec![
        vec![
            InlineButton::new("📊 Estado", "cb:status"),
            InlineButton::new("📈 Métricas / Mbps", "cb:metrics"),
        ],
        vec![
            InlineButton::new("🔑 Licencias IP", "cb:ips"),
            InlineButton::new("🌐 Dominios AR", "cb:domains"),
        ],
        vec![
            InlineButton::new("💾 Backup al chat", "cb:backup"),
            InlineButton::new("🧹 Limpiar 10 GB", "cb:cleanup"),
        ],
        vec![
            InlineButton::new("🔄 Actualizar", "cb:update"),
            InlineButton::new("❓ Comandos y Guía", "cb:help"),
        ],
    ])
}

pub fn back_menu_keyboard() -> Value {
    build_keyboard(vec![vec![InlineButton::new("⬅️ Volver al menú", "cb:menu")]])
}

fn main_menu_text() -> String {
    "🛰️ <b>JOIF Smart DNS — Panel Telegram</b>\nElegí una opción o escribí un comando directo (/help):".to_string()
}

pub fn handle_message(cfg: &BotConfig, tg: &TelegramClient, msg: &Message) {
    let user_id = match &msg.from {
        Some(u) => u.id,
        None => return,
    };
    if !cfg.is_admin(user_id) {
        // Ignorar silenciosamente cualquier usuario no autorizado
        return;
    }
    let text = match &msg.text {
        Some(t) => t.trim(),
        None => return,
    };
    if text.is_empty() {
        return;
    }

    let chat_id = msg.chat.id;
    let mut parts = text.split_whitespace();
    let raw_cmd = parts.next().unwrap_or("");
    let cmd = raw_cmd.split('@').next().unwrap_or(raw_cmd);
    let rest: Vec<&str> = parts.collect();

    match cmd {
        "/start" | "/menu" => {
            let _ = tg.send_html(chat_id, &main_menu_text(), Some(main_menu_keyboard()));
        }
        "/help" => {
            let _ = tg.send_html(chat_id, &help_text(), Some(back_menu_keyboard()));
        }
        "/status" => send_status(cfg, tg, chat_id, None),
        "/metrics" => send_metrics(cfg, tg, chat_id, None),
        "/ips" => send_ips(cfg, tg, chat_id, None),
        "/domains" => send_domains(cfg, tg, chat_id, None),
        "/backup" => send_backup_doc(cfg, tg, chat_id),
        "/cleanup" => send_cleanup(cfg, tg, chat_id, None),
        "/update" => send_update(cfg, tg, chat_id, None),
        "/add" => {
            // /add <ip/cidr> <dias> <alias...>
            if rest.len() < 2 {
                let _ = tg.send_html(
                    chat_id,
                    "Uso: <code>/add &lt;IP/CIDR&gt; &lt;dias&gt; &lt;alias&gt;</code>\nEjemplo: <code>/add 144.22.167.150 0 Nodo Brasil 01</code>",
                    Some(back_menu_keyboard()),
                );
                return;
            }
            let ip = rest[0];
            let days = rest[1];
            let alias = if rest.len() >= 3 {
                rest[2..].join(" ")
            } else {
                "Sin alias".to_string()
            };
            if !is_safe_token(ip, 32) || !days.chars().all(|c| c.is_ascii_digit()) {
                let _ = tg.send_html(chat_id, "❌ IP o cantidad de días inválida.", None);
                return;
            }
            let res = run_smartdns(&cfg.smartdns_bin, &["ip", "add", ip, &alias, days]);
            let html = format!(
                "{}\n<pre>{}</pre>",
                if res.success { "✅ <b>IP autorizada</b>" } else { "❌ <b>Error</b>" },
                escape_html(&truncate_chars(&res.output, 3500))
            );
            let _ = tg.send_html(chat_id, &html, Some(back_menu_keyboard()));
        }
        "/renew" => {
            if rest.len() != 2 || !is_safe_token(rest[0], 32) || !rest[1].chars().all(|c| c.is_ascii_digit()) {
                let _ = tg.send_html(
                    chat_id,
                    "Uso: <code>/renew &lt;IP/CIDR&gt; &lt;dias&gt;</code> (0 = permanente)",
                    None,
                );
                return;
            }
            let res = run_smartdns(&cfg.smartdns_bin, &["ip", "renew", rest[0], rest[1]]);
            let html = format!(
                "<pre>{}</pre>",
                escape_html(&truncate_chars(&res.output, 3500))
            );
            let _ = tg.send_html(chat_id, &html, Some(back_menu_keyboard()));
        }
        "/suspend" | "/reactivate" | "/del" => {
            if rest.len() != 1 || !is_safe_token(rest[0], 32) {
                let _ = tg.send_html(
                    chat_id,
                    &format!("Uso: <code>{} &lt;IP/CIDR&gt;</code>", escape_html(cmd)),
                    None,
                );
                return;
            }
            let sub = match cmd {
                "/suspend" => "suspend",
                "/reactivate" => "reactivate",
                _ => "remove",
            };
            let res = run_smartdns(&cfg.smartdns_bin, &["ip", sub, rest[0]]);
            let html = format!(
                "<pre>{}</pre>",
                escape_html(&truncate_chars(&res.output, 3500))
            );
            let _ = tg.send_html(chat_id, &html, Some(back_menu_keyboard()));
        }
        "/check" => {
            if rest.len() != 1 || rest[0].len() > 255 || rest[0].starts_with('-') {
                let _ = tg.send_html(
                    chat_id,
                    "Uso: <code>/check &lt;dominio o URL&gt;</code>\nEjemplo: <code>/check api.brubank.com.ar</code>",
                    None,
                );
                return;
            }
            let res = run_smartdns(&cfg.smartdns_bin, &["domains", "check", rest[0]]);
            let html = format!(
                "🔍 <b>Consulta de dominio</b>\n<pre>{}</pre>",
                escape_html(&truncate_chars(&res.output, 3500))
            );
            let _ = tg.send_html(chat_id, &html, Some(back_menu_keyboard()));
        }
        "/adddom" | "/deldom" => {
            if rest.len() != 1 || !is_safe_token(rest[0], 253) {
                let _ = tg.send_html(
                    chat_id,
                    &format!("Uso: <code>{} &lt;dominio&gt;</code>", escape_html(cmd)),
                    None,
                );
                return;
            }
            let sub = if cmd == "/adddom" { "add" } else { "remove" };
            let res = run_smartdns(&cfg.smartdns_bin, &["domains", sub, rest[0]]);
            let html = format!(
                "<pre>{}</pre>",
                escape_html(&truncate_chars(&res.output, 3500))
            );
            let _ = tg.send_html(chat_id, &html, Some(back_menu_keyboard()));
        }
        _ => {
            let _ = tg.send_html(
                chat_id,
                "Comando no reconocido. Usá /menu o /help.",
                Some(main_menu_keyboard()),
            );
        }
    }
}

pub fn handle_callback(cfg: &BotConfig, tg: &TelegramClient, cb: &CallbackQuery) {
    if !cfg.is_admin(cb.from.id) {
        return;
    }
    let data = match &cb.data {
        Some(d) => d.as_str(),
        None => {
            tg.answer_callback(&cb.id, None);
            return;
        }
    };
    let (chat_id, msg_id) = match &cb.message {
        Some(m) => (m.chat.id, Some(m.message_id)),
        None => {
            tg.answer_callback(&cb.id, None);
            return;
        }
    };

    match data {
        "cb:menu" => {
            tg.answer_callback(&cb.id, None);
            send_or_edit(tg, chat_id, msg_id, &main_menu_text(), Some(main_menu_keyboard()));
        }
        "cb:status" => {
            tg.answer_callback(&cb.id, Some("Ejecutando diagnóstico..."));
            send_status(cfg, tg, chat_id, msg_id);
        }
        "cb:metrics" => {
            tg.answer_callback(&cb.id, Some("Midiendo Mbps y tráfico..."));
            send_metrics(cfg, tg, chat_id, msg_id);
        }
        "cb:ips" => {
            tg.answer_callback(&cb.id, None);
            send_ips(cfg, tg, chat_id, msg_id);
        }
        "cb:domains" => {
            tg.answer_callback(&cb.id, None);
            send_domains(cfg, tg, chat_id, msg_id);
        }
        "cb:backup" => {
            tg.answer_callback(&cb.id, Some("Generando backup..."));
            send_backup_doc(cfg, tg, chat_id);
        }
        "cb:cleanup" => {
            tg.answer_callback(&cb.id, Some("Limpiando disco..."));
            send_cleanup(cfg, tg, chat_id, msg_id);
        }
        "cb:update" => {
            tg.answer_callback(&cb.id, Some("Actualizando desde GitHub..."));
            send_update(cfg, tg, chat_id, msg_id);
        }
        "cb:help" => {
            tg.answer_callback(&cb.id, None);
            send_or_edit(tg, chat_id, msg_id, &help_text(), Some(back_menu_keyboard()));
        }
        "cb:add_hint" => {
            tg.answer_callback(&cb.id, None);
            let txt = "➕ <b>Autorizar nueva IP</b>\nEnviá este comando en el chat:\n<code>/add 203.0.113.10 0 Nodo Brasil 02</code>\n(<code>0</code> = permanente, o cantidad de días ej. <code>30</code>).";
            send_or_edit(tg, chat_id, msg_id, txt, Some(back_menu_keyboard()));
        }
        _ if data.starts_with("dom:t:") => {
            let slug = &data[6..];
            if !is_safe_token(slug, 64) {
                tg.answer_callback(&cb.id, Some("Categoría inválida"));
                return;
            }
            let cats = parse_categories_output(&run_smartdns(&cfg.smartdns_bin, &["domains", "list"]).output);
            let is_active = cats.iter().any(|c| c.slug == slug && c.status == "activa");
            let action = if is_active { "disable" } else { "enable" };
            tg.answer_callback(&cb.id, Some("Aplicando cambio..."));
            let _ = run_smartdns(&cfg.smartdns_bin, &["domains", action, slug]);
            send_domains(cfg, tg, chat_id, msg_id);
        }
        _ if data.starts_with("ip:s:") => {
            let ip = &data[5..];
            if is_safe_token(ip, 32) {
                let _ = run_smartdns(&cfg.smartdns_bin, &["ip", "suspend", ip]);
                tg.answer_callback(&cb.id, Some("IP suspendida"));
            }
            send_ips(cfg, tg, chat_id, msg_id);
        }
        _ if data.starts_with("ip:a:") => {
            let ip = &data[5..];
            if is_safe_token(ip, 32) {
                let res = run_smartdns(&cfg.smartdns_bin, &["ip", "reactivate", ip]);
                if res.success {
                    tg.answer_callback(&cb.id, Some("IP reactivada"));
                } else {
                    tg.answer_callback(&cb.id, Some("Vencida: usá +30d para renovar"));
                }
            }
            send_ips(cfg, tg, chat_id, msg_id);
        }
        _ if data.starts_with("ip:r30:") => {
            let ip = &data[7..];
            if is_safe_token(ip, 32) {
                let _ = run_smartdns(&cfg.smartdns_bin, &["ip", "renew", ip, "30"]);
                tg.answer_callback(&cb.id, Some("Renovada +30 días"));
            }
            send_ips(cfg, tg, chat_id, msg_id);
        }
        _ if data.starts_with("ip:delq:") => {
            let ip = &data[8..];
            tg.answer_callback(&cb.id, None);
            let kb = build_keyboard(vec![
                vec![
                    InlineButton::new("✅ Sí, eliminar", format!("ip:delc:{}", ip)),
                    InlineButton::new("❌ Cancelar", "cb:ips"),
                ],
            ]);
            let txt = format!(
                "⚠️ ¿Confirmás eliminar definitivamente la licencia de <code>{}</code>?",
                escape_html(ip)
            );
            send_or_edit(tg, chat_id, msg_id, &txt, Some(kb));
        }
        _ if data.starts_with("ip:delc:") => {
            let ip = &data[8..];
            if is_safe_token(ip, 32) {
                let _ = run_smartdns(&cfg.smartdns_bin, &["ip", "remove", ip]);
                tg.answer_callback(&cb.id, Some("Licencia eliminada"));
            }
            send_ips(cfg, tg, chat_id, msg_id);
        }
        _ => {
            tg.answer_callback(&cb.id, None);
        }
    }
}

fn send_or_edit(
    tg: &TelegramClient,
    chat_id: i64,
    msg_id: Option<i64>,
    html: &str,
    kb: Option<Value>,
) {
    if let Some(mid) = msg_id {
        let _ = tg.edit_html(chat_id, mid, html, kb);
    } else {
        let _ = tg.send_html(chat_id, html, kb);
    }
}

fn send_status(cfg: &BotConfig, tg: &TelegramClient, chat_id: i64, msg_id: Option<i64>) {
    let res = run_smartdns(&cfg.smartdns_bin, &["status"]);
    let html = format!(
        "📊 <b>Estado y Diagnóstico</b>\n<pre>{}</pre>",
        escape_html(&truncate_chars(&res.output, 3700))
    );
    let kb = build_keyboard(vec![vec![
        InlineButton::new("🔄 Actualizar vista", "cb:status"),
        InlineButton::new("⬅️ Menú", "cb:menu"),
    ]]);
    send_or_edit(tg, chat_id, msg_id, &html, Some(kb));
}

fn send_metrics(cfg: &BotConfig, tg: &TelegramClient, chat_id: i64, msg_id: Option<i64>) {
    let res = run_smartdns(&cfg.smartdns_bin, &["metrics"]);
    let html = format!(
        "📈 <b>Métricas y Tráfico en Vivo</b>\n<pre>{}</pre>",
        escape_html(&truncate_chars(&res.output, 3700))
    );
    let kb = build_keyboard(vec![vec![
        InlineButton::new("🔄 Medir de nuevo", "cb:metrics"),
        InlineButton::new("⬅️ Menú", "cb:menu"),
    ]]);
    send_or_edit(tg, chat_id, msg_id, &html, Some(kb));
}

fn send_ips(cfg: &BotConfig, tg: &TelegramClient, chat_id: i64, msg_id: Option<i64>) {
    let rows = parse_licenses_file(&cfg.licenses_db);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let mut text = String::from("🔑 <b>Licencias IP Autorizadas</b>\n\n");
    let mut kb_rows: Vec<Vec<InlineButton>> = Vec::new();

    if rows.is_empty() {
        text.push_str("<i>No hay IPs autorizadas todavía.</i>\n");
    } else {
        for (i, r) in rows.iter().enumerate() {
            let idx = i + 1;
            let rem_str = if r.expires_at == 0 {
                "permanente".to_string()
            } else if r.expires_at <= now {
                "VENCIDA".to_string()
            } else {
                let days = (r.expires_at - now) / 86400;
                let hrs = ((r.expires_at - now) % 86400) / 3600;
                format!("{}d {}h", days, hrs)
            };
            let icon = if rem_str == "VENCIDA" {
                "🔴"
            } else if r.status == "activa" {
                "🟢"
            } else {
                "🟡"
            };
            text.push_str(&format!(
                "{} <b>[{}]</b> <code>{}</code> — {}\n    Origen: {} | {}\n",
                icon,
                idx,
                escape_html(&r.ip),
                escape_html(&r.alias),
                escape_html(&r.geo),
                rem_str
            ));

            // Botones rapidos por IP (max 8 IPs con botones para no saturar el teclado)
            if idx <= 8 {
                let toggle_btn = if r.status == "activa" {
                    InlineButton::new(format!("⏸ #{}", idx), format!("ip:s:{}", r.ip))
                } else {
                    InlineButton::new(format!("▶️ #{}", idx), format!("ip:a:{}", r.ip))
                };
                kb_rows.push(vec![
                    toggle_btn,
                    InlineButton::new(format!("+30d #{}", idx), format!("ip:r30:{}", r.ip)),
                    InlineButton::new(format!("🗑 #{}", idx), format!("ip:delq:{}", r.ip)),
                ]);
            }
        }
    }

    kb_rows.push(vec![
        InlineButton::new("➕ Agregar IP", "cb:add_hint"),
        InlineButton::new("⬅️ Menú", "cb:menu"),
    ]);

    send_or_edit(tg, chat_id, msg_id, &text, Some(build_keyboard(kb_rows)));
}

fn send_domains(cfg: &BotConfig, tg: &TelegramClient, chat_id: i64, msg_id: Option<i64>) {
    let res = run_smartdns(&cfg.smartdns_bin, &["domains", "list"]);
    let cats = parse_categories_output(&res.output);

    let mut text = String::from("🌐 <b>Categorías de Dominios AR</b>\nTocá una categoría para activarla o pausarla:\n\n");
    let mut kb_rows: Vec<Vec<InlineButton>> = Vec::new();

    for c in &cats {
        let icon = if c.status == "activa" { "✅" } else { "⏸️" };
        text.push_str(&format!(
            "{} <b>{}</b> ({} dom.)\n",
            icon,
            escape_html(&c.label),
            escape_html(&c.count)
        ));
        let action_lbl = if c.status == "activa" {
            format!("⏸ Pausar {}", c.slug)
        } else {
            format!("▶️ Activar {}", c.slug)
        };
        kb_rows.push(vec![InlineButton::new(
            action_lbl,
            format!("dom:t:{}", c.slug),
        )]);
    }

    text.push_str("\nComandos: <code>/check dominio</code> | <code>/adddom dominio</code> | <code>/deldom dominio</code>");
    kb_rows.push(vec![InlineButton::new("⬅️ Menú", "cb:menu")]);

    send_or_edit(tg, chat_id, msg_id, &text, Some(build_keyboard(kb_rows)));
}

fn send_backup_doc(cfg: &BotConfig, tg: &TelegramClient, chat_id: i64) {
    let res = run_smartdns(&cfg.smartdns_bin, &["backup"]);
    let archive_path = res
        .output
        .lines()
        .rev()
        .find(|l| l.trim().ends_with(".tar.gz"))
        .map(|l| l.trim().to_string());

    match archive_path {
        Some(path) => {
            if let Err(e) = tg.send_document(
                chat_id,
                &path,
                "💾 Backup joif-smartdns (config.env + licenses.db + domains.d/)",
            ) {
                let _ = tg.send_html(
                    chat_id,
                    &format!("❌ Backup creado en <code>{}</code> pero falló envío: {}", escape_html(&path), escape_html(&e)),
                    Some(back_menu_keyboard()),
                );
            }
        }
        None => {
            let _ = tg.send_html(
                chat_id,
                &format!("❌ No se pudo crear el backup:\n<pre>{}</pre>", escape_html(&truncate_chars(&res.output, 3000))),
                Some(back_menu_keyboard()),
            );
        }
    }
}

fn send_cleanup(cfg: &BotConfig, tg: &TelegramClient, chat_id: i64, msg_id: Option<i64>) {
    let res = run_smartdns(&cfg.smartdns_bin, &["cleanup"]);
    let html = format!(
        "🧹 <b>Limpieza de Disco (VPS 10 GB)</b>\n<pre>{}</pre>",
        escape_html(&truncate_chars(&res.output, 3500))
    );
    send_or_edit(tg, chat_id, msg_id, &html, Some(back_menu_keyboard()));
}

fn send_update(cfg: &BotConfig, tg: &TelegramClient, chat_id: i64, msg_id: Option<i64>) {
    let res = run_smartdns(&cfg.smartdns_bin, &["update"]);
    let html = format!(
        "🔄 <b>Actualización desde GitHub</b>\n<pre>{}</pre>",
        escape_html(&truncate_chars(&res.output, 3500))
    );
    send_or_edit(tg, chat_id, msg_id, &html, Some(back_menu_keyboard()));
}

fn help_text() -> String {
    concat!(
        "❓ <b>Comandos de JOIF Smart DNS Bot</b>\n\n",
        "• <code>/menu</code> — Panel con botones\n",
        "• <code>/status</code> — Diagnóstico en vivo\n",
        "• <code>/metrics</code> — Mbps, disco, RAM y tráfico por IP\n",
        "• <code>/ips</code> — Ver y gestionar licencias IP\n",
        "• <code>/add IP DIAS ALIAS</code> — Autorizar IP (0=permanente)\n",
        "• <code>/renew IP DIAS</code> — Renovar licencia\n",
        "• <code>/suspend IP</code> | <code>/reactivate IP</code> | <code>/del IP</code>\n",
        "• <code>/domains</code> — Activar/pausar categorías AR\n",
        "• <code>/check DOMINIO</code> — Probar por dónde sale un dominio\n",
        "• <code>/adddom DOMINIO</code> | <code>/deldom DOMINIO</code>\n",
        "• <code>/backup</code> — Enviar respaldo .tar.gz al chat\n",
        "• <code>/cleanup</code> — Liberar espacio en VPS 10 GB\n",
        "• <code>/update</code> — Actualizar joif-smartdns desde GitHub\n\n",
        "📖 Guía oficial:\nhttps://github.com/manuel3200/joif-smartdns/blob/main/docs/GUIA-COMPLETA.md"
    )
    .to_string()
}
