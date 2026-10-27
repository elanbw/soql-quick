mod salesforce;

use salesforce::{AppState, ConnectionStatus, QueryResult, SchemaField, SchemaObject};
use tauri::Manager;
use tauri_plugin_opener::OpenerExt;

const NEW_GOOGLE_SHEET_URL: &str = "https://sheet.new";

#[tauri::command]
async fn restore_session(state: tauri::State<'_, AppState>) -> Result<ConnectionStatus, String> {
    state.restore_session().await
}

#[tauri::command]
async fn connect_salesforce(app: tauri::AppHandle, state: tauri::State<'_, AppState>) -> Result<ConnectionStatus, String> {
    state.connect(&app).await
}

#[tauri::command]
async fn cancel_connection(state: tauri::State<'_, AppState>) -> Result<(), String> {
    state.cancel_connection().await;
    Ok(())
}

#[tauri::command]
async fn sign_out(state: tauri::State<'_, AppState>) -> Result<(), String> {
    state.sign_out().await
}

#[tauri::command]
async fn run_query(query: String, state: tauri::State<'_, AppState>) -> Result<QueryResult, String> {
    state.run_query(&query).await
}

#[tauri::command]
async fn open_record(record_id: String, app: tauri::AppHandle, state: tauri::State<'_, AppState>) -> Result<(), String> {
    state.open_record(&app, &record_id).await
}

#[tauri::command]
fn open_new_google_sheet(app: tauri::AppHandle) -> Result<(), String> {
    app.opener().open_url(NEW_GOOGLE_SHEET_URL, None::<&str>).map_err(|error| format!("A new Google Sheet could not be opened: {error}"))
}

#[tauri::command]
async fn cancel_query(state: tauri::State<'_, AppState>) -> Result<(), String> {
    state.cancel_query().await;
    Ok(())
}

#[tauri::command]
async fn list_objects(state: tauri::State<'_, AppState>) -> Result<Vec<SchemaObject>, String> {
    state.list_objects().await
}

#[tauri::command]
async fn describe_object(object_api_name: String, state: tauri::State<'_, AppState>) -> Result<Vec<SchemaField>, String> {
    state.describe_object(&object_api_name).await
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(AppState::new())
        .setup(|app| {
            if let Some(window) = app.get_webview_window("main") {
                window.show()?;
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            restore_session,
            connect_salesforce,
            cancel_connection,
            sign_out,
            run_query,
            open_record,
            open_new_google_sheet,
            cancel_query,
            list_objects,
            describe_object
        ])
        .run(tauri::generate_context!())
        .expect("error while running SOQL Quick");
}
