mod alerts;
mod config;
mod handlers;
mod runner;
mod telegram;

use crate::config::BotConfig;
use crate::handlers::{handle_callback, handle_message, main_menu_keyboard};
use crate::telegram::TelegramClient;
use std::env;
use std::process;
use std::thread;
use std::time::Duration;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("joif-tgbot {}", env!("CARGO_PKG_VERSION"));
        return;
    }

    let cfg = match BotConfig::load() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[ERR ] {}", e);
            process::exit(1);
        }
    };

    let tg = TelegramClient::new(&cfg.token);

    // Modo prueba puntual (--test-ping): envia saludo a los admins y sale con codigo 0
    if args.iter().any(|a| a == "--test-ping") {
        let mut ok_any = false;
        for &admin_id in &cfg.admin_ids {
            match tg.send_html(
                admin_id,
                "✅ <b>JOIF Smart DNS Bot conectado</b>\nBot Rust ultraliviano activo. Tocá /menu cuando quieras administrar tu VPS.",
                Some(main_menu_keyboard()),
            ) {
                Ok(_) => ok_any = true,
                Err(e) => eprintln!("[ERR ] Fallo envio a {}: {}", admin_id, e),
            }
        }
        process::exit(if ok_any { 0 } else { 1 });
    }

    eprintln!(
        "[INFO] joif-tgbot v{} iniciado (admins: {:?}, alerta Mbps: {:.1}, alerta disco: {}%)",
        env!("CARGO_PKG_VERSION"),
        cfg.admin_ids,
        cfg.alert_mbps,
        cfg.alert_disk_pct
    );

    // Hilo de alertas automaticas en segundo plano
    alerts::spawn_alert_loop(cfg.clone(), tg.clone());

    // Bucle principal de long-polling (saliente HTTPS, cero puertos abiertos)
    let mut offset: i64 = 0;
    loop {
        match tg.get_updates(offset, 25) {
            Ok(updates) => {
                for upd in updates {
                    offset = upd.update_id + 1;
                    if let Some(msg) = upd.message {
                        handle_message(&cfg, &tg, &msg);
                    }
                    if let Some(cb) = upd.callback_query {
                        handle_callback(&cfg, &tg, &cb);
                    }
                }
            }
            Err(e) => {
                eprintln!("[WARN] Error en getUpdates: {} (reintento en 5s)", e);
                thread::sleep(Duration::from_secs(5));
            }
        }
    }
}
