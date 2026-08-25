pub mod host;
pub mod protocol;

pub use host::{HostError, HostResult, PsHost, SidecarSpec};
pub use protocol::{RpcError, RpcEvent, RpcRequest, RpcResponse, SidecarMessage};

#[cfg(test)]
mod tests {
    use super::protocol::SidecarMessage;

    #[test]
    fn decodes_response_message() {
        let raw = r#"{"id":17,"ok":true,"result":{"cpu":42},"ms":3.5}"#;
        let msg: SidecarMessage = serde_json::from_str(raw).unwrap();
        match msg {
            SidecarMessage::Response(r) => {
                assert_eq!(r.id, 17);
                assert!(r.ok);
                assert_eq!(r.result.unwrap()["cpu"], 42);
            }
            SidecarMessage::Event(_) => panic!("expected Response variant"),
        }
    }

    #[test]
    fn decodes_error_response() {
        let raw = r#"{"id":3,"ok":false,"error":{"kind":"ToolFailed","message":"boom"}}"#;
        let msg: SidecarMessage = serde_json::from_str(raw).unwrap();
        match msg {
            SidecarMessage::Response(r) => {
                assert!(!r.ok);
                let e = r.error.unwrap();
                assert_eq!(e.kind, "ToolFailed");
                assert_eq!(e.message, "boom");
            }
            SidecarMessage::Event(_) => panic!("expected Response variant"),
        }
    }

    #[test]
    fn decodes_event_message() {
        let raw = r#"{"event":"tool.output","runId":"a1","stream":"stdout","line":"Killed PID 4821"}"#;
        let msg: SidecarMessage = serde_json::from_str(raw).unwrap();
        match msg {
            SidecarMessage::Event(e) => {
                assert_eq!(e.event, "tool.output");
                assert_eq!(e.run_id.as_deref(), Some("a1"));
                assert_eq!(e.line.as_deref(), Some("Killed PID 4821"));
            }
            SidecarMessage::Response(_) => panic!("expected Event variant"),
        }
    }
}
