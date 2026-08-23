use std::{io, path::Path};

use serde::Serialize;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeStatusState {
    Connecting,
    Ready,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeStatusDetail {
    Starting,
    ControllerUnavailable,
    RegistrationPending,
    ControllerRejected,
}

#[derive(Clone, Eq, PartialEq, Serialize)]
pub struct NodeStatusProjection {
    pub schema_version: u8,
    pub node_id: String,
    pub generation: u64,
    pub launch_token: String,
    pub state: NodeStatusState,
    pub detail_code: Option<NodeStatusDetail>,
    pub observed_at_unix_ms: u64,
}

impl std::fmt::Debug for NodeStatusProjection {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("NodeStatusProjection")
            .field("schema_version", &self.schema_version)
            .field("node_id", &self.node_id)
            .field("generation", &self.generation)
            .field("launch_token", &"[REDACTED]")
            .field("state", &self.state)
            .field("detail_code", &self.detail_code)
            .field("observed_at_unix_ms", &self.observed_at_unix_ms)
            .finish()
    }
}

impl NodeStatusProjection {
    pub fn connecting(
        node_id: &str,
        generation: u64,
        launch_token: &str,
        detail_code: NodeStatusDetail,
        observed_at_unix_ms: u64,
    ) -> Self {
        Self {
            schema_version: 1,
            node_id: node_id.to_owned(),
            generation,
            launch_token: launch_token.to_owned(),
            state: NodeStatusState::Connecting,
            detail_code: Some(detail_code),
            observed_at_unix_ms,
        }
    }

    pub fn ready(
        node_id: &str,
        generation: u64,
        launch_token: &str,
        observed_at_unix_ms: u64,
    ) -> Self {
        Self {
            schema_version: 1,
            node_id: node_id.to_owned(),
            generation,
            launch_token: launch_token.to_owned(),
            state: NodeStatusState::Ready,
            detail_code: None,
            observed_at_unix_ms,
        }
    }

    pub fn failed(
        node_id: &str,
        generation: u64,
        launch_token: &str,
        detail_code: NodeStatusDetail,
        observed_at_unix_ms: u64,
    ) -> Self {
        Self {
            schema_version: 1,
            node_id: node_id.to_owned(),
            generation,
            launch_token: launch_token.to_owned(),
            state: NodeStatusState::Failed,
            detail_code: Some(detail_code),
            observed_at_unix_ms,
        }
    }
}

pub fn write_atomic(path: &Path, status: &NodeStatusProjection) -> io::Result<()> {
    let encoded = serde_json::to_value(status).map_err(io::Error::other)?;
    crate::operator_projection::write_atomic(path, &encoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projection_contains_only_fixed_nonsecret_fields() {
        let status = NodeStatusProjection::connecting(
            "node-1",
            7,
            "abcdefghijklmnopqrstuvwxyzABCDEFGH012345678",
            NodeStatusDetail::ControllerUnavailable,
            42,
        );
        let debug = format!("{status:?}");
        assert!(debug.contains("[REDACTED]"));
        assert!(!debug.contains("abcdefghijklmnopqrstuvwxyzABCDEFGH012345678"));
        let encoded = serde_json::to_value(status).expect("status encodes");

        assert_eq!(
            encoded,
            serde_json::json!({
                "schema_version": 1,
                "node_id": "node-1",
                "generation": 7,
                "launch_token": "abcdefghijklmnopqrstuvwxyzABCDEFGH012345678",
                "state": "connecting",
                "detail_code": "controller_unavailable",
                "observed_at_unix_ms": 42
            })
        );
    }

    #[test]
    fn writes_ready_status_atomically() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("node.json");
        write_atomic(
            &path,
            &NodeStatusProjection::ready(
                "node-1",
                7,
                "abcdefghijklmnopqrstuvwxyzABCDEFGH012345678",
                99,
            ),
        )
        .expect("status writes");

        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&std::fs::read(path).expect("status read"))
                .expect("status json"),
            serde_json::json!({
                "schema_version": 1,
                "node_id": "node-1",
                "generation": 7,
                "launch_token": "abcdefghijklmnopqrstuvwxyzABCDEFGH012345678",
                "state": "ready",
                "detail_code": null,
                "observed_at_unix_ms": 99
            })
        );
    }
}
