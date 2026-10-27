use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::{distributions::Alphanumeric, Rng};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tauri_plugin_opener::OpenerExt;
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::TcpListener, sync::Mutex};
use tokio_util::sync::CancellationToken;
use url::Url;

const KEYRING_SERVICE: &str = "SOQL Quick";
const KEYRING_USER: &str = "salesforce-oauth";
const DEFAULT_LOGIN_URL: &str = "https://login.salesforce.com";
const DEFAULT_CALLBACK_URL: &str = "http://localhost:1410/callback";
const DEFAULT_API_VERSION: &str = "66.0";

#[derive(Clone)]
struct Config {
    client_id: String,
    login_url: String,
    callback_url: String,
    api_version: String,
}

impl Config {
    fn from_build() -> Self {
        Self {
            client_id: option_env!("SALESFORCE_CLIENT_ID").unwrap_or("").trim().to_string(),
            login_url: option_env!("SALESFORCE_LOGIN_URL").unwrap_or(DEFAULT_LOGIN_URL).trim_end_matches('/').to_string(),
            callback_url: option_env!("SALESFORCE_CALLBACK_URL").unwrap_or(DEFAULT_CALLBACK_URL).to_string(),
            api_version: option_env!("SALESFORCE_API_VERSION").unwrap_or(DEFAULT_API_VERSION).trim_start_matches('v').to_string(),
        }
    }

    fn validate(&self) -> Result<(), String> {
        if self.client_id.is_empty() {
            return Err("This build is not configured with a Salesforce External Client App. Set SALESFORCE_CLIENT_ID when building the installer.".into());
        }
        if self.client_id == "packaging-validation-only" {
            return Err("This is a packaging-validation build and cannot connect to Salesforce. Rebuild it with your org’s External Client App consumer key.".into());
        }
        let login = Url::parse(&self.login_url).map_err(|_| "The configured Salesforce login URL is invalid.")?;
        if login.scheme() != "https" { return Err("The Salesforce login URL must use HTTPS.".into()); }
        let callback = Url::parse(&self.callback_url).map_err(|_| "The configured OAuth callback URL is invalid.")?;
        if callback.scheme() != "http" || !matches!(callback.host_str(), Some("localhost" | "127.0.0.1")) {
            return Err("The OAuth callback must use http://localhost with a fixed port.".into());
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
struct StoredCredential {
    refresh_token: String,
    instance_url: String,
}

#[derive(Clone)]
struct Session {
    access_token: String,
    refresh_token: String,
    instance_url: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionStatus {
    connected: bool,
    username: Option<String>,
    instance_url: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SchemaObject {
    pub api_name: String,
    pub label: String,
    pub custom: bool,
    pub queryable: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SchemaField {
    pub api_name: String,
    pub label: String,
    #[serde(rename = "type")]
    pub field_type: String,
    pub custom: bool,
    pub calculated: bool,
    pub nillable: bool,
    pub filterable: bool,
    pub sortable: bool,
    pub relationship_name: Option<String>,
    pub reference_to: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct QueryResult {
    pub columns: Vec<String>,
    pub text_columns: Vec<bool>,
    pub rows: Vec<Vec<String>>,
    pub total: usize,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    instance_url: String,
}

pub struct AppState {
    client: Client,
    config: Config,
    credentials: CredentialCache,
    session: Arc<Mutex<Option<Session>>>,
    cancellation: Arc<Mutex<Option<CancellationToken>>>,
    login_cancellation: Arc<Mutex<Option<CancellationToken>>>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            client: Client::builder().timeout(Duration::from_secs(120)).user_agent("SOQL-Quick/2.0").build().expect("HTTP client"),
            config: Config::from_build(),
            credentials: CredentialCache::new(Box::new(KeyringStore)),
            session: Arc::new(Mutex::new(None)),
            cancellation: Arc::new(Mutex::new(None)),
            login_cancellation: Arc::new(Mutex::new(None)),
        }
    }

    pub async fn restore_session(&self) -> Result<ConnectionStatus, String> {
        if self.session.lock().await.is_some() { return Ok(self.status().await); }
        if self.config.client_id.is_empty() { return Ok(self.status().await); }
        // Reads the Keychain at most once per launch; later calls reuse the in-memory copy.
        let Some(stored) = self.credentials.load().await? else { return Ok(self.status().await); };
        match self.refresh(&stored.refresh_token).await {
            Ok(mut session) => {
                if session.refresh_token.is_empty() { session.refresh_token = stored.refresh_token; }
                // No Keychain write unless Salesforce rotated the refresh token or moved the instance.
                self.credentials.save(&StoredCredential { refresh_token: session.refresh_token.clone(), instance_url: session.instance_url.clone() }).await?;
                *self.session.lock().await = Some(session);
                Ok(self.status().await)
            }
            Err(RefreshError::Rejected) => {
                self.credentials.clear().await?;
                Ok(self.status().await)
            }
            // Network or server trouble: keep the saved credential so the next launch can retry without a new login.
            Err(RefreshError::Unavailable(message)) => Err(message),
        }
    }

    pub async fn connect(&self, app: &tauri::AppHandle) -> Result<ConnectionStatus, String> {
        self.config.validate()?;
        let login_cancellation = CancellationToken::new();
        if let Some(previous) = self.login_cancellation.lock().await.replace(login_cancellation.clone()) { previous.cancel(); }
        let callback = Url::parse(&self.config.callback_url).map_err(|_| "Invalid OAuth callback URL.")?;
        let port = callback.port().ok_or("The OAuth callback URL must include a port.")?;
        let callback_host = callback.host_str().ok_or("The OAuth callback URL must include a host.")?;
        let listener = TcpListener::bind((callback_host, port)).await.map_err(|error| {
            if error.kind() == std::io::ErrorKind::AddrInUse {
                format!("Salesforce login could not start because local callback port {port} is already in use. Quit any older SOQL Quick login process, then try again.")
            } else { format!("Salesforce login callback could not start: {error}") }
        })?;

        let verifier = random_urlsafe(64);
        let challenge = pkce_challenge(&verifier);
        let oauth_state = random_urlsafe(40);
        let mut auth_url = Url::parse(&format!("{}/services/oauth2/authorize", self.config.login_url)).map_err(|_| "Invalid Salesforce authorization URL.")?;
        auth_url.query_pairs_mut()
            .append_pair("response_type", "code")
            .append_pair("client_id", &self.config.client_id)
            .append_pair("redirect_uri", &self.config.callback_url)
            .append_pair("scope", "api refresh_token")
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", &oauth_state);
        app.opener().open_url(auth_url.as_str(), None::<&str>).map_err(|error| format!("The Salesforce login page could not be opened: {error}"))?;

        let callback_result = tokio::select! {
            _ = login_cancellation.cancelled() => Err("Salesforce connection cancelled.".to_string()),
            result = tokio::time::timeout(Duration::from_secs(180), receive_oauth_callback(listener, callback.path(), &oauth_state)) => {
                result.map_err(|_| "Salesforce login timed out after 3 minutes. Try connecting again.".to_string())?
            }
        };
        let mut login_slot = self.login_cancellation.lock().await;
        if login_slot.as_ref().is_some_and(|active| active == &login_cancellation) { *login_slot = None; }
        drop(login_slot);
        let callback_result = callback_result?;
        let response = self.client.post(format!("{}/services/oauth2/token", self.config.login_url))
            .form(&[
                ("grant_type", "authorization_code"),
                ("client_id", self.config.client_id.as_str()),
                ("redirect_uri", self.config.callback_url.as_str()),
                ("code", callback_result.as_str()),
                ("code_verifier", verifier.as_str()),
            ])
            .send().await.map_err(network_error)?;
        let token: TokenResponse = decode_response(response, "Salesforce rejected the authorization code").await?;
        let refresh_token = token.refresh_token.ok_or("Salesforce did not return a refresh token. Confirm that the External Client App includes the refresh_token/offline_access scope.")?;
        let session = Session { access_token: token.access_token, refresh_token, instance_url: token.instance_url };
        self.credentials.save(&StoredCredential { refresh_token: session.refresh_token.clone(), instance_url: session.instance_url.clone() }).await?;
        *self.session.lock().await = Some(session);
        Ok(self.status().await)
    }

    pub async fn sign_out(&self) -> Result<(), String> {
        self.cancel_connection().await;
        self.cancel_query().await;
        *self.session.lock().await = None;
        self.credentials.clear().await
    }

    pub async fn cancel_connection(&self) {
        if let Some(token) = self.login_cancellation.lock().await.take() { token.cancel(); }
    }

    async fn status(&self) -> ConnectionStatus {
        let session = self.session.lock().await;
        ConnectionStatus { connected: session.is_some(), username: None, instance_url: session.as_ref().map(|value| value.instance_url.clone()) }
    }

    async fn refresh(&self, refresh_token: &str) -> Result<Session, RefreshError> {
        let response = self.client.post(format!("{}/services/oauth2/token", self.config.login_url))
            .form(&[("grant_type", "refresh_token"), ("client_id", self.config.client_id.as_str()), ("refresh_token", refresh_token)])
            .send().await.map_err(|error| RefreshError::Unavailable(network_error(error)))?;
        let rejected = refresh_was_rejected(response.status());
        let token: TokenResponse = decode_response(response, "The saved Salesforce session could not be refreshed").await
            .map_err(|message| if rejected { RefreshError::Rejected } else { RefreshError::Unavailable(message) })?;
        Ok(Session { access_token: token.access_token, refresh_token: token.refresh_token.unwrap_or_else(|| refresh_token.to_string()), instance_url: token.instance_url })
    }

    async fn active_session(&self) -> Result<Session, String> {
        self.session.lock().await.clone().ok_or_else(|| "Connect Salesforce before using this feature.".into())
    }

    async fn get_json(&self, path: &str) -> Result<Value, String> {
        let mut session = self.active_session().await?;
        let mut response = self.client.get(format!("{}{}", session.instance_url, path)).bearer_auth(&session.access_token).send().await.map_err(network_error)?;
        if response.status() == StatusCode::UNAUTHORIZED {
            session = self.refresh(&session.refresh_token).await.map_err(|_| "Your Salesforce session expired. Reconnect Salesforce and try again.".to_string())?;
            self.credentials.save(&StoredCredential { refresh_token: session.refresh_token.clone(), instance_url: session.instance_url.clone() }).await?;
            *self.session.lock().await = Some(session.clone());
            response = self.client.get(format!("{}{}", session.instance_url, path)).bearer_auth(&session.access_token).send().await.map_err(network_error)?;
        }
        decode_response(response, "Salesforce request failed").await
    }

    pub async fn run_query(&self, query: &str) -> Result<QueryResult, String> {
        validate_read_only_query(query)?;
        let cancellation = CancellationToken::new();
        if let Some(previous) = self.cancellation.lock().await.replace(cancellation.clone()) { previous.cancel(); }
        let result = tokio::select! {
            _ = cancellation.cancelled() => Err("Query cancelled.".to_string()),
            result = self.fetch_query_pages(query) => result,
        };
        let mut slot = self.cancellation.lock().await;
        if slot.as_ref().is_some_and(|active| active == &cancellation) { *slot = None; }
        result
    }

    async fn fetch_query_pages(&self, query: &str) -> Result<QueryResult, String> {
        let projection = parse_projection(query);
        let encoded: String = url::form_urlencoded::byte_serialize(query.as_bytes()).collect();
        let mut path = format!("/services/data/v{}/query?q={encoded}", self.config.api_version);
        let mut records = Vec::new();
        let mut reported_total = None;
        loop {
            let page = self.get_json(&path).await?;
            let parsed = parse_query_page(&page)?;
            if reported_total.is_none() { reported_total = parsed.total; }
            records.extend(parsed.records);
            let Some(next) = parsed.next else { break; };
            path = next;
        }
        Ok(records_to_table(&records, reported_total, projection.as_deref()))
    }

    pub async fn open_record(&self, app: &tauri::AppHandle, record_id: &str) -> Result<(), String> {
        if !is_salesforce_record_id(record_id) { return Err("The selected value is not a valid Salesforce record ID.".into()); }
        let session = self.active_session().await?;
        let mut url = Url::parse(&session.instance_url).map_err(|_| "The Salesforce instance URL is invalid.")?;
        if url.scheme() != "https" { return Err("Salesforce record links must use HTTPS.".into()); }
        url.set_path(&format!("/{record_id}"));
        url.set_query(None); url.set_fragment(None);
        app.opener().open_url(url.as_str(), None::<&str>).map_err(|error| format!("The Salesforce record could not be opened: {error}"))
    }

    pub async fn cancel_query(&self) {
        if let Some(token) = self.cancellation.lock().await.take() { token.cancel(); }
    }

    pub async fn list_objects(&self) -> Result<Vec<SchemaObject>, String> {
        let payload = self.get_json(&format!("/services/data/v{}/sobjects", self.config.api_version)).await?;
        let values = payload.get("sobjects").and_then(Value::as_array).ok_or("Salesforce returned malformed object metadata.")?;
        let mut objects: Vec<_> = values.iter().filter_map(|value| {
            let api_name = value.get("name")?.as_str()?.to_string();
            let label = safe_label(value.get("label").and_then(Value::as_str), &api_name);
            let queryable = value.get("queryable").and_then(Value::as_bool).unwrap_or(false);
            (queryable && !missing_label(&label)).then(|| SchemaObject { api_name, label, custom: value.get("custom").and_then(Value::as_bool).unwrap_or(false), queryable })
        }).collect();
        objects.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase()));
        Ok(objects)
    }

    pub async fn describe_object(&self, object: &str) -> Result<Vec<SchemaField>, String> {
        validate_api_name(object)?;
        let payload = self.get_json(&format!("/services/data/v{}/sobjects/{object}/describe", self.config.api_version)).await?;
        let values = payload.get("fields").and_then(Value::as_array).ok_or("Salesforce returned malformed field metadata.")?;
        Ok(values.iter().filter_map(|value| {
            let api_name = value.get("name")?.as_str()?.to_string();
            Some(SchemaField {
                label: safe_label(value.get("label").and_then(Value::as_str), &api_name), api_name,
                field_type: value.get("type").and_then(Value::as_str).unwrap_or("unknown").to_string(),
                custom: value.get("custom").and_then(Value::as_bool).unwrap_or(false),
                calculated: value.get("calculated").and_then(Value::as_bool).unwrap_or(false),
                nillable: value.get("nillable").and_then(Value::as_bool).unwrap_or(true),
                filterable: value.get("filterable").and_then(Value::as_bool).unwrap_or(false),
                sortable: value.get("sortable").and_then(Value::as_bool).unwrap_or(false),
                relationship_name: value.get("relationshipName").and_then(Value::as_str).map(str::to_string),
                reference_to: value.get("referenceTo").and_then(Value::as_array).map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default(),
            })
        }).collect())
    }
}

fn random_urlsafe(length: usize) -> String {
    rand::thread_rng().sample_iter(&Alphanumeric).take(length).map(char::from).collect()
}

fn pkce_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

struct ParsedQueryPage {
    records: Vec<Value>,
    total: Option<usize>,
    next: Option<String>,
}

fn parse_query_page(value: &Value) -> Result<ParsedQueryPage, String> {
    let records = value.get("records").and_then(Value::as_array).cloned().ok_or("Salesforce returned a malformed query response.")?;
    let total = value.get("totalSize").and_then(Value::as_u64).map(|number| number as usize);
    let done = value.get("done").and_then(Value::as_bool).ok_or("Salesforce returned a malformed query completion flag.")?;
    let next = if done { None } else { Some(value.get("nextRecordsUrl").and_then(Value::as_str).ok_or("Salesforce omitted the next query page URL.")?.to_string()) };
    Ok(ParsedQueryPage { records, total, next })
}

async fn receive_oauth_callback(listener: TcpListener, expected_path: &str, expected_state: &str) -> Result<String, String> {
    let (mut stream, _) = listener.accept().await.map_err(|error| format!("OAuth callback failed: {error}"))?;
    let mut buffer = vec![0_u8; 16_384];
    let size = stream.read(&mut buffer).await.map_err(|error| format!("OAuth callback could not be read: {error}"))?;
    let request = String::from_utf8_lossy(&buffer[..size]);
    let target = request.lines().next().and_then(|line| line.split_whitespace().nth(1)).ok_or("Salesforce returned an unreadable OAuth callback.")?;
    let url = Url::parse(&format!("http://127.0.0.1{target}")).map_err(|_| "Salesforce returned an invalid OAuth callback.")?;
    let values: HashMap<_, _> = url.query_pairs().into_owned().collect();
    let result = if url.path() != expected_path { Err("Salesforce returned OAuth to an unexpected callback path.".to_string()) }
        else if values.get("state").map(String::as_str) != Some(expected_state) { Err("Salesforce login state validation failed. No credentials were saved.".to_string()) }
        else if let Some(error) = values.get("error") { Err(format!("Salesforce authorization was rejected: {}", values.get("error_description").unwrap_or(error))) }
        else { values.get("code").cloned().ok_or_else(|| "Salesforce did not return an authorization code.".to_string()) };
    let (status, title, message) = if result.is_ok() { ("200 OK", "SOQL Quick connected", "You can close this browser tab and return to SOQL Quick.") } else { ("400 Bad Request", "SOQL Quick could not connect", "Return to SOQL Quick for safe error details.") };
    let body = format!("<!doctype html><meta charset=utf-8><title>{title}</title><style>body{{font:16px system-ui;margin:3rem;max-width:42rem}}h1{{color:#1769e0}}</style><h1>{title}</h1><p>{message}</p>");
    let response = format!("HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
    let _ = stream.write_all(response.as_bytes()).await;
    result
}

async fn decode_response<T: for<'de> Deserialize<'de>>(response: reqwest::Response, context: &str) -> Result<T, String> {
    let status = response.status();
    let body = response.text().await.map_err(network_error)?;
    if !status.is_success() {
        let detail = salesforce_error_message(&body).unwrap_or_else(|| status.canonical_reason().unwrap_or("Unknown error").to_string());
        return Err(sanitize_error(&format!("{context}: {detail} (HTTP {})", status.as_u16())));
    }
    serde_json::from_str(&body).map_err(|_| format!("{context}: Salesforce returned unreadable JSON."))
}

fn salesforce_error_message(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    if let Some(array) = value.as_array() {
        return array.first()?.get("message")?.as_str().map(str::to_string);
    }
    value.get("error_description").or_else(|| value.get("message")).and_then(Value::as_str).map(str::to_string)
}

fn network_error(error: reqwest::Error) -> String {
    if error.is_timeout() { "The Salesforce request timed out after 120 seconds.".into() }
    else if error.is_connect() { "SOQL Quick could not reach Salesforce. Check your network connection and Salesforce login domain.".into() }
    else { sanitize_error(&format!("Salesforce network request failed: {error}")) }
}

fn sanitize_error(message: &str) -> String {
    let mut sanitized = message.to_string();
    for key in ["access_token", "refresh_token", "client_secret", "password"] {
        while let Some(start) = sanitized.to_lowercase().find(key) {
            let after = start + key.len();
            let value_start = sanitized[after..].find(|character: char| character == ':' || character == '=').map(|offset| after + offset + 1);
            let Some(value_start) = value_start else { break; };
            let value_end = sanitized[value_start..].find(|character: char| character.is_whitespace() || ",;\"}".contains(character)).map(|offset| value_start + offset).unwrap_or(sanitized.len());
            sanitized.replace_range(value_start..value_end, "[REDACTED]");
            break;
        }
    }
    sanitized.chars().take(4_000).collect()
}

fn validate_read_only_query(query: &str) -> Result<(), String> {
    let trimmed = query.trim_start();
    let first = trimmed.split_whitespace().next().unwrap_or("");
    if !first.eq_ignore_ascii_case("SELECT") { return Err("SOQL Quick is read-only and accepts SELECT queries only.".into()); }
    if query.contains('\0') { return Err("The query contains an invalid null character.".into()); }
    Ok(())
}

fn validate_api_name(value: &str) -> Result<(), String> {
    if value.is_empty() || !value.chars().enumerate().all(|(index, character)| character == '_' || character.is_ascii_alphanumeric() && (index > 0 || character.is_ascii_alphabetic())) {
        return Err("The selected Salesforce object API name is invalid.".into());
    }
    Ok(())
}

fn missing_label(value: &str) -> bool { value.to_ascii_uppercase().replace('_', " ").contains("MISSING LABEL") }
fn safe_label(label: Option<&str>, api_name: &str) -> String { label.map(str::trim).filter(|value| !value.is_empty() && !missing_label(value)).unwrap_or(api_name).to_string() }

fn flatten_value(prefix: &str, value: &Value, output: &mut Vec<(String, Value)>) {
    match value {
        Value::Object(map) if !map.contains_key("records") => {
            for (key, nested) in map {
                if key == "attributes" { continue; }
                let name = if prefix.is_empty() { key.clone() } else { format!("{prefix}.{key}") };
                flatten_value(&name, nested, output);
            }
        }
        _ if !prefix.is_empty() => output.push((prefix.to_string(), value.clone())),
        _ => {}
    }
}

fn display_value(value: &Value) -> String {
    match value { Value::Null => "".into(), Value::String(value) => value.clone(), Value::Bool(value) => value.to_string(), Value::Number(value) => value.to_string(), other => serde_json::to_string(other).unwrap_or_default() }
}

fn is_api_path(value: &str) -> bool {
    !value.is_empty() && value.split('.').all(|part| !part.is_empty() && part.chars().enumerate().all(|(index, character)| character == '_' || character.is_ascii_alphanumeric() && (index > 0 || character.is_ascii_alphabetic())))
}

fn split_top_level(value: &str, delimiter: char) -> Option<Vec<&str>> {
    let mut parts = Vec::new();
    let mut start = 0; let mut depth = 0usize; let mut quoted = false; let mut escaped = false;
    for (index, character) in value.char_indices() {
        if quoted {
            if character == '\'' && !escaped { quoted = false; }
            escaped = character == '\\' && !escaped;
            continue;
        }
        if character == '\'' { quoted = true; escaped = false; continue; }
        match character {
            '(' => depth += 1,
            ')' => depth = depth.checked_sub(1)?,
            _ if character == delimiter && depth == 0 => { parts.push(value[start..index].trim()); start = index + character.len_utf8(); }
            _ => {}
        }
    }
    if quoted || depth != 0 { return None; }
    parts.push(value[start..].trim());
    Some(parts)
}

fn outer_select_list(query: &str) -> Option<&str> {
    let trimmed = query.trim_start();
    if trimmed.get(..6)?.eq_ignore_ascii_case("SELECT") == false { return None; }
    let rest = &trimmed[6..];
    let mut depth = 0usize; let mut quoted = false; let mut escaped = false;
    for (index, character) in rest.char_indices() {
        if quoted {
            if character == '\'' && !escaped { quoted = false; }
            escaped = character == '\\' && !escaped;
            continue;
        }
        if character == '\'' { quoted = true; escaped = false; continue; }
        match character { '(' => depth += 1, ')' => depth = depth.checked_sub(1)?, _ => {} }
        if depth == 0 && rest[index..].get(..4).is_some_and(|word| word.eq_ignore_ascii_case("FROM")) {
            let before_ok = index == 0 || rest[..index].chars().next_back().is_some_and(char::is_whitespace);
            let after_ok = rest[index + 4..].chars().next().is_some_and(char::is_whitespace);
            if before_ok && after_ok { return Some(rest[..index].trim()); }
        }
    }
    None
}

fn parse_projection(query: &str) -> Option<Vec<String>> {
    let items = split_top_level(outer_select_list(query)?, ',')?;
    if items.is_empty() { return None; }
    items.into_iter().map(|item| {
        if is_api_path(item) { return Some(item.to_string()); }
        let alias = item.split_whitespace().next_back()?;
        let expression = item[..item.rfind(alias)?].trim_end();
        (!expression.is_empty() && expression.contains('(') && is_api_path(alias)).then(|| alias.to_string())
    }).collect()
}

fn is_salesforce_record_id(value: &str) -> bool {
    matches!(value.len(), 15 | 18) && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

fn records_to_table(records: &[Value], reported_total: Option<usize>, projection: Option<&[String]>) -> QueryResult {
    let mut columns = Vec::new();
    let mut flattened = Vec::new();
    let mut text_by_column: HashMap<String, bool> = HashMap::new();
    for record in records {
        let mut values = Vec::new(); flatten_value("", record, &mut values);
        for (column, value) in &values {
            if !columns.contains(column) { columns.push(column.clone()); }
            if value.is_string() || value.is_object() || value.is_array() { text_by_column.insert(column.clone(), true); }
        }
        flattened.push(values.into_iter().map(|(key, value)| (key.to_ascii_lowercase(), value)).collect::<HashMap<_, _>>());
    }
    if let Some(requested) = projection { columns = requested.to_vec(); }
    let rows = flattened.iter().map(|record| columns.iter().map(|column| record.get(&column.to_ascii_lowercase()).map(display_value).unwrap_or_default()).collect()).collect();
    let default_text = projection.is_some();
    let text_columns = columns.iter().map(|column| text_by_column.get(column).or_else(|| text_by_column.iter().find(|(key, _)| key.eq_ignore_ascii_case(column)).map(|(_, value)| value)).copied().unwrap_or(default_text)).collect();
    QueryResult { columns, text_columns, rows, total: reported_total.unwrap_or(records.len()) }
}

enum RefreshError {
    /// Salesforce answered and refused the refresh token (revoked, expired, or invalid_grant).
    Rejected,
    /// Network, timeout, or server-side failure; the saved credential may still be valid.
    Unavailable(String),
}

fn refresh_was_rejected(status: StatusCode) -> bool {
    matches!(status, StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED)
}

/// Storage backend for the refresh credential. Production uses the OS credential store.
trait CredentialStore: Send + Sync {
    fn load(&self) -> Result<Option<StoredCredential>, String>;
    fn store(&self, value: &StoredCredential) -> Result<(), String>;
    fn delete(&self) -> Result<(), String>;
}

struct KeyringStore;

impl CredentialStore for KeyringStore {
    fn load(&self) -> Result<Option<StoredCredential>, String> { load_credential() }
    fn store(&self, value: &StoredCredential) -> Result<(), String> { store_credential(value) }
    fn delete(&self) -> Result<(), String> { delete_credential() }
}

enum CachedCredential {
    Unknown,
    Absent,
    Present(StoredCredential),
}

/// Keeps the credential in memory so each Keychain access (and its possible macOS
/// permission prompt) happens only when needed: one read per launch, writes only
/// when the value changes, deletes only when something is stored.
struct CredentialCache {
    store: Box<dyn CredentialStore>,
    state: Mutex<CachedCredential>,
}

impl CredentialCache {
    fn new(store: Box<dyn CredentialStore>) -> Self {
        Self { store, state: Mutex::new(CachedCredential::Unknown) }
    }

    async fn load(&self) -> Result<Option<StoredCredential>, String> {
        let mut state = self.state.lock().await;
        match &*state {
            CachedCredential::Present(value) => return Ok(Some(value.clone())),
            CachedCredential::Absent => return Ok(None),
            CachedCredential::Unknown => {}
        }
        let loaded = self.store.load()?;
        *state = match &loaded { Some(value) => CachedCredential::Present(value.clone()), None => CachedCredential::Absent };
        Ok(loaded)
    }

    async fn save(&self, value: &StoredCredential) -> Result<(), String> {
        let mut state = self.state.lock().await;
        if matches!(&*state, CachedCredential::Present(current) if current == value) { return Ok(()); }
        match self.store.store(value) {
            Ok(()) => { *state = CachedCredential::Present(value.clone()); Ok(()) }
            Err(error) => { *state = CachedCredential::Unknown; Err(error) }
        }
    }

    async fn clear(&self) -> Result<(), String> {
        let mut state = self.state.lock().await;
        if matches!(&*state, CachedCredential::Absent) { return Ok(()); }
        match self.store.delete() {
            Ok(()) => { *state = CachedCredential::Absent; Ok(()) }
            Err(error) => { *state = CachedCredential::Unknown; Err(error) }
        }
    }
}

fn keyring_entry() -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER).map_err(|error| format!("The operating-system credential store is unavailable: {error}"))
}

fn store_credential(value: &StoredCredential) -> Result<(), String> {
    let json = serde_json::to_string(value).map_err(|_| "OAuth credentials could not be prepared for secure storage.")?;
    keyring_entry()?.set_password(&json).map_err(|error| format!("Salesforce credentials could not be saved in the operating-system credential store: {error}"))
}

fn load_credential() -> Result<Option<StoredCredential>, String> {
    match keyring_entry()?.get_password() {
        Ok(value) => serde_json::from_str(&value).map(Some).map_err(|_| "The saved Salesforce credential is unreadable. Sign out and connect again.".into()),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(format!("Salesforce credentials could not be read from the operating-system credential store: {error}")),
    }
}

fn delete_credential() -> Result<(), String> {
    match keyring_entry()?.delete_credential() { Ok(()) | Err(keyring::Error::NoEntry) => Ok(()), Err(error) => Err(format!("Salesforce credentials could not be removed from the operating-system credential store: {error}")) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Default)]
    struct Counts { loads: AtomicUsize, stores: AtomicUsize, deletes: AtomicUsize }

    struct FakeStore { initial: Option<StoredCredential>, counts: Arc<Counts> }

    impl CredentialStore for FakeStore {
        fn load(&self) -> Result<Option<StoredCredential>, String> { self.counts.loads.fetch_add(1, Ordering::SeqCst); Ok(self.initial.clone()) }
        fn store(&self, _: &StoredCredential) -> Result<(), String> { self.counts.stores.fetch_add(1, Ordering::SeqCst); Ok(()) }
        fn delete(&self) -> Result<(), String> { self.counts.deletes.fetch_add(1, Ordering::SeqCst); Ok(()) }
    }

    fn credential(token: &str) -> StoredCredential {
        StoredCredential { refresh_token: token.into(), instance_url: "https://example.my.salesforce.com".into() }
    }

    fn cache(initial: Option<StoredCredential>) -> (CredentialCache, Arc<Counts>) {
        let counts = Arc::new(Counts::default());
        (CredentialCache::new(Box::new(FakeStore { initial, counts: counts.clone() })), counts)
    }

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(future)
    }

    #[test]
    fn credential_is_read_from_the_store_once_per_launch() {
        block_on(async {
            let (cache, counts) = cache(Some(credential("synthetic-a")));
            assert!(cache.load().await.unwrap() == Some(credential("synthetic-a")));
            assert!(cache.load().await.unwrap() == Some(credential("synthetic-a")));
            let (empty, empty_counts) = self::cache(None);
            assert!(empty.load().await.unwrap().is_none());
            assert!(empty.load().await.unwrap().is_none());
            assert_eq!(counts.loads.load(Ordering::SeqCst), 1);
            assert_eq!(empty_counts.loads.load(Ordering::SeqCst), 1);
        });
    }

    #[test]
    fn unchanged_credential_is_not_rewritten() {
        block_on(async {
            let (cache, counts) = cache(Some(credential("synthetic-a")));
            cache.load().await.unwrap();
            cache.save(&credential("synthetic-a")).await.unwrap();
            assert_eq!(counts.stores.load(Ordering::SeqCst), 0);
            cache.save(&credential("synthetic-b")).await.unwrap();
            cache.save(&credential("synthetic-b")).await.unwrap();
            assert_eq!(counts.stores.load(Ordering::SeqCst), 1);
            assert!(cache.load().await.unwrap() == Some(credential("synthetic-b")));
            assert_eq!(counts.loads.load(Ordering::SeqCst), 1);
        });
    }

    #[test]
    fn delete_is_skipped_when_nothing_is_stored() {
        block_on(async {
            let (cache, counts) = cache(None);
            cache.load().await.unwrap();
            cache.clear().await.unwrap();
            assert_eq!(counts.deletes.load(Ordering::SeqCst), 0);
            cache.save(&credential("synthetic-a")).await.unwrap();
            cache.clear().await.unwrap();
            cache.clear().await.unwrap();
            assert_eq!(counts.deletes.load(Ordering::SeqCst), 1);
            assert!(cache.load().await.unwrap().is_none());
            assert_eq!(counts.loads.load(Ordering::SeqCst), 1);
        });
    }

    #[test]
    fn only_token_endpoint_rejections_discard_the_saved_credential() {
        assert!(refresh_was_rejected(StatusCode::BAD_REQUEST));
        assert!(refresh_was_rejected(StatusCode::UNAUTHORIZED));
        assert!(!refresh_was_rejected(StatusCode::INTERNAL_SERVER_ERROR));
        assert!(!refresh_was_rejected(StatusCode::SERVICE_UNAVAILABLE));
    }

    #[test]
    fn query_guard_allows_only_select() {
        assert!(validate_read_only_query(" SELECT Id FROM Account").is_ok());
        assert!(validate_read_only_query("UPDATE Account SET Name = 'x'").is_err());
        assert!(validate_read_only_query("DELETE FROM Account").is_err());
    }

    #[test]
    fn nested_records_flatten_with_stable_union_columns() {
        let records = vec![
            json!({"attributes":{"type":"Contact"},"Id":"003","Account":{"attributes":{"type":"Account"},"Name":"Example"},"Amount":-12.5}),
            json!({"attributes":{"type":"Contact"},"Id":"004","Account":null,"Amount":3,"Extra":"yes"})
        ];
        let table = records_to_table(&records, Some(2), None);
        assert_eq!(table.columns, vec!["Id", "Account.Name", "Amount", "Account", "Extra"]);
        assert_eq!(table.rows[0], vec!["003", "Example", "-12.5", "", ""]);
        assert_eq!(table.rows[1], vec!["004", "", "3", "", "yes"]);
        assert_eq!(table.text_columns, vec![true, true, false, false, true]);
    }

    #[test]
    fn subquery_records_remain_json_text() {
        let table = records_to_table(&[json!({"Id":"001","Contacts":{"totalSize":1,"done":true,"records":[{"Name":"A"}]}})], None, None);
        assert_eq!(table.columns, vec!["Id", "Contacts"]);
        assert!(table.rows[0][1].contains("records"));
        assert_eq!(table.text_columns, vec![true, true]);
    }

    #[test]
    fn common_projection_preserves_order_and_null_columns() {
        let query = "SELECT Name, Id, Account.Name, Optional__c FROM Contact";
        let projection = parse_projection(query).unwrap();
        assert_eq!(projection, vec!["Name", "Id", "Account.Name", "Optional__c"]);
        let records = vec![json!({"attributes":{"type":"Contact"},"Id":"003000000000001AAA","Name":"Example","Account":null})];
        let table = records_to_table(&records, Some(1), Some(&projection));
        assert_eq!(table.columns, projection);
        assert_eq!(table.rows[0], vec!["Example", "003000000000001AAA", "", ""]);
        assert_eq!(table.text_columns, vec![true, true, true, true]);
    }

    #[test]
    fn projection_handles_functions_commas_quotes_and_aliases() {
        assert_eq!(parse_projection("SELECT Name, FORMAT(CreatedDate) created, DISTANCE(Location__c, GEOLOCATION(1, 2), 'mi') miles FROM Account"), Some(vec!["Name".into(), "created".into(), "miles".into()]));
        assert_eq!(parse_projection("SELECT COUNT(Id) FROM Account"), None);
        assert_eq!(parse_projection("SELECT Id, (SELECT Name FROM Contacts) FROM Account"), None);
    }

    #[test]
    fn projected_columns_exist_when_query_returns_no_rows() {
        let projection = parse_projection("SELECT Id, Never_Set__c FROM Account").unwrap();
        let table = records_to_table(&[], Some(0), Some(&projection));
        assert_eq!(table.columns, vec!["Id", "Never_Set__c"]);
        assert!(table.rows.is_empty());
    }

    #[test]
    fn record_id_validation_is_strict() {
        assert!(is_salesforce_record_id("0015g00000ABCDe"));
        assert!(is_salesforce_record_id("0015g00000ABCDeAAH"));
        assert!(!is_salesforce_record_id("0015g00000ABCD!"));
        assert!(!is_salesforce_record_id("Example Account"));
    }

    #[test]
    fn metadata_labels_fall_back_safely() {
        assert_eq!(safe_label(Some("MISSING_LABEL"), "Thing__c"), "Thing__c");
        assert_eq!(safe_label(Some(" Thing "), "Thing__c"), "Thing");
    }

    #[test]
    fn sensitive_error_values_are_redacted() {
        let output = sanitize_error("access_token=secret123 refresh_token:another password=hunter2");
        assert!(!output.contains("secret123")); assert!(!output.contains("another")); assert!(!output.contains("hunter2"));
    }

    #[test]
    fn pkce_uses_the_rfc7636_sha256_example() {
        assert_eq!(pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        let state_a = random_urlsafe(40); let state_b = random_urlsafe(40);
        assert_eq!(state_a.len(), 40); assert_ne!(state_a, state_b);
    }

    #[test]
    fn pagination_requires_a_locator_until_done() {
        let first = parse_query_page(&json!({"totalSize":2,"done":false,"nextRecordsUrl":"/next/1","records":[{"Id":"1"}]})).unwrap();
        assert_eq!(first.total, Some(2)); assert_eq!(first.records.len(), 1); assert_eq!(first.next.as_deref(), Some("/next/1"));
        let last = parse_query_page(&json!({"totalSize":2,"done":true,"records":[{"Id":"2"}]})).unwrap();
        assert!(last.next.is_none());
        assert!(parse_query_page(&json!({"done":false,"records":[]})).is_err());
        assert!(parse_query_page(&json!({"done":true})).is_err());
    }
}
