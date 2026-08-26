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
    fn event_extra_fields_round_trip() {
        // tool.finished carries exitCode, which is not a declared RpcEvent
        // field - it must survive deserialize -> re-serialize via the
        // #[serde(flatten)] catch-all, or the frontend renders every
        // successful run as "exit -1".
        let raw = r#"{"event":"tool.finished","runId":"a1","exitCode":0}"#;
        let msg: SidecarMessage = serde_json::from_str(raw).unwrap();
        let evt = match msg {
            SidecarMessage::Event(e) => e,
            SidecarMessage::Response(_) => panic!("expected Event variant"),
        };
        assert_eq!(evt.extra.get("exitCode"), Some(&serde_json::json!(0)));

        let reserialized = serde_json::to_value(&evt).unwrap();
        assert_eq!(reserialized["event"], "tool.finished");
        assert_eq!(reserialized["runId"], "a1");
        // exitCode must be back at the TOP level, not nested under "extra".
        assert_eq!(reserialized["exitCode"], 0);
        assert!(reserialized.get("extra").is_none());
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
