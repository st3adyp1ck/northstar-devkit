//! Wire format for the NDJSON-RPC channel between the Rust host process
//! (Tauri app or `devkit` CLI) and the long-lived PowerShell sidecar
//! (`core/Invoke-DevKitRpc.ps1`).
//!
//! One JSON object per line, UTF-8, `\n`-terminated, both directions.
//! Requests carry an `id`; responses echo it back. The sidecar may also
//! emit unsolicited `event` lines (e.g. streamed tool stdout) that carry
//! no `id` and expect no response.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
pub struct RpcRequest {
    pub id: u64,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum SidecarMessage {
    Response(RpcResponse),
    Event(RpcEvent),
}

#[derive(Debug, Clone, Deserialize)]
pub struct RpcResponse {
    pub id: u64,
    pub ok: bool,
    #[serde(default)]
    pub result: Option<Value>,
    #[serde(default)]
    pub error: Option<RpcError>,
    #[serde(default)]
    pub ms: Option<f64>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RpcError {
    pub kind: String,
    pub message: String,
    #[serde(default)]
    pub detail: Option<Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RpcEvent {
    pub event: String,
    #[serde(default)]
    #[serde(rename = "runId")]
    pub run_id: Option<String>,
    #[serde(default)]
    pub stream: Option<String>,
    #[serde(default)]
    pub line: Option<String>,
    #[serde(default)]
    pub data: Option<Value>,
    /// Catch-all for event fields not declared above (`exitCode` on
    /// `tool.finished`, `pid` on `tool.started`, ...). Without this, serde
    /// silently drops unknown fields on deserialize, and since the app
    /// re-serializes this typed struct to the frontend, those fields would
    /// never reach it. `#[serde(flatten)]` both captures them on
    /// deserialize and re-emits them flat (top-level) on serialize.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl RpcRequest {
    pub fn new(id: u64, method: impl Into<String>, params: Option<Value>) -> Self {
        Self {
            id,
            method: method.into(),
            params,
        }
    }
}
