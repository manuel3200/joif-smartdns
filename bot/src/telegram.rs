use serde::Deserialize;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;
use std::time::Duration;
use ureq::{Agent, AgentBuilder};

#[derive(Clone)]
pub struct TelegramClient {
    base_url: String,
    poll_agent: Agent,
    api_agent: Agent,
}

#[derive(Debug, Deserialize)]
pub struct ApiResponse<T> {
    pub ok: bool,
    pub result: Option<T>,
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Update {
    pub update_id: i64,
    pub message: Option<Message>,
    pub callback_query: Option<CallbackQuery>,
}

#[derive(Debug, Deserialize)]
pub struct Message {
    pub message_id: i64,
    pub from: Option<User>,
    pub chat: Chat,
    pub text: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CallbackQuery {
    pub id: String,
    pub from: User,
    pub message: Option<Message>,
    pub data: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct User {
    pub id: i64,
}

#[derive(Debug, Deserialize)]
pub struct Chat {
    pub id: i64,
}

#[derive(Debug, Clone)]
pub struct InlineButton {
    pub text: String,
    pub callback_data: String,
}

impl InlineButton {
    pub fn new(text: impl Into<String>, callback_data: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            callback_data: callback_data.into(),
        }
    }
}

pub fn build_keyboard(rows: Vec<Vec<InlineButton>>) -> Value {
    let json_rows: Vec<Value> = rows
        .into_iter()
        .map(|row| {
            Value::Array(
                row.into_iter()
                    .map(|b| json!({ "text": b.text, "callback_data": b.callback_data }))
                    .collect(),
            )
        })
        .collect();
    json!({ "inline_keyboard": json_rows })
}

pub fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(ch),
        }
    }
    out
}

pub fn truncate_chars(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max_chars.saturating_sub(24)).collect();
    out.push_str("\n... (salida recortada)");
    out
}

impl TelegramClient {
    pub fn new(token: &str) -> Self {
        let poll_agent = AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(40))
            .build();
        let api_agent = AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(20))
            .build();

        Self {
            base_url: format!("https://api.telegram.org/bot{}", token),
            poll_agent,
            api_agent,
        }
    }

    pub fn get_updates(&self, offset: i64, timeout_sec: u64) -> Result<Vec<Update>, String> {
        let url = format!("{}/getUpdates", self.base_url);
        let payload = json!({
            "offset": offset,
            "timeout": timeout_sec,
            "allowed_updates": ["message", "callback_query"]
        });
        let resp = self
            .poll_agent
            .post(&url)
            .send_json(payload)
            .map_err(|e| format!("HTTP getUpdates error: {}", e))?;
        let text = resp
            .into_string()
            .map_err(|e| format!("Body read error: {}", e))?;
        let parsed: ApiResponse<Vec<Update>> =
            serde_json::from_str(&text).map_err(|e| format!("JSON parse error: {}", e))?;
        if !parsed.ok {
            return Err(parsed
                .description
                .unwrap_or_else(|| "Telegram API ok=false".to_string()));
        }
        Ok(parsed.result.unwrap_or_default())
    }

    pub fn send_html(
        &self,
        chat_id: i64,
        html: &str,
        reply_markup: Option<Value>,
    ) -> Result<(), String> {
        let url = format!("{}/sendMessage", self.base_url);
        let mut payload = json!({
            "chat_id": chat_id,
            "text": html,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        });
        if let Some(kb) = reply_markup {
            payload["reply_markup"] = kb;
        }
        let resp = self
            .api_agent
            .post(&url)
            .send_json(payload)
            .map_err(|e| format!("sendMessage error: {}", e))?;
        let _ = resp.into_string();
        Ok(())
    }

    pub fn edit_html(
        &self,
        chat_id: i64,
        message_id: i64,
        html: &str,
        reply_markup: Option<Value>,
    ) -> Result<(), String> {
        let url = format!("{}/editMessageText", self.base_url);
        let mut payload = json!({
            "chat_id": chat_id,
            "message_id": message_id,
            "text": html,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        });
        let kb_fallback = reply_markup.clone();
        if let Some(kb) = reply_markup {
            payload["reply_markup"] = kb;
        }
        match self.api_agent.post(&url).send_json(payload) {
            Ok(resp) => {
                let _ = resp.into_string();
                Ok(())
            }
            Err(_) => {
                // Fallback a mensaje nuevo si Telegram rechaza edit (ej. mensaje sin cambios o muy antiguo)
                self.send_html(chat_id, html, kb_fallback)
            }
        }
    }

    pub fn answer_callback(&self, callback_id: &str, text: Option<&str>) {
        let url = format!("{}/answerCallbackQuery", self.base_url);
        let mut payload = json!({ "callback_query_id": callback_id });
        if let Some(t) = text {
            payload["text"] = json!(t);
        }
        let _ = self.api_agent.post(&url).send_json(payload);
    }

    pub fn send_document(&self, chat_id: i64, file_path: &str, caption: &str) -> Result<(), String> {
        let bytes = fs::read(file_path)
            .map_err(|e| format!("No se pudo leer '{}': {}", file_path, e))?;
        let filename = Path::new(file_path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("joif-backup.tar.gz");

        let boundary = "----JoifSmartDnsBoundary9f8a7b6c";
        let mut body: Vec<u8> = Vec::with_capacity(bytes.len() + 512);

        body.extend_from_slice(
            format!(
                "--{b}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{cid}\r\n",
                b = boundary,
                cid = chat_id
            )
            .as_bytes(),
        );
        body.extend_from_slice(
            format!(
                "--{b}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n{cap}\r\n",
                b = boundary,
                cap = caption
            )
            .as_bytes(),
        );
        body.extend_from_slice(
            format!(
                "--{b}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{fn}\"\r\nContent-Type: application/gzip\r\n\r\n",
                b = boundary,
                fn = filename
            )
            .as_bytes(),
        );
        body.extend_from_slice(&bytes);
        body.extend_from_slice(format!("\r\n--{b}--\r\n", b = boundary).as_bytes());

        let url = format!("{}/sendDocument", self.base_url);
        let content_type = format!("multipart/form-data; boundary={}", boundary);
        let resp = self
            .api_agent
            .post(&url)
            .set("Content-Type", &content_type)
            .send_bytes(&body)
            .map_err(|e| format!("sendDocument error: {}", e))?;
        let _ = resp.into_string();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_escape_html() {
        assert_eq!(escape_html("a < b & c > d"), "a &lt; b &amp; c &gt; d");
    }

    #[test]
    fn test_truncate_chars() {
        let short = "hola";
        assert_eq!(truncate_chars(short, 50), "hola");
        let long = "a".repeat(100);
        let cut = truncate_chars(&long, 40);
        assert!(cut.contains("recortada"));
        assert!(cut.chars().count() <= 45);
    }
}
