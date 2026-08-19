use std::{collections::BTreeSet, fmt};

use serde::{Deserialize, Serialize};

use crate::{ExecutionBackend, NodeSnapshot, Resources, valid_identifier};

pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_WIRE_MESSAGE_BYTES: usize = 256 * 1024;
pub const MAX_COMMAND_TTL_MS: u64 = 5 * 60 * 1000;
pub const MAX_JIT_CONFIG_BYTES: usize = 64 * 1024;
pub const MAX_ACTIVE_PLACEMENTS: usize = 1024;

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SecretString(String);

impl SecretString {
    pub fn new(value: impl Into<String>) -> Result<Self, WireError> {
        let value = value.into();
        if !valid_jit_config(&value) {
            return Err(WireError::InvalidSecret);
        }
        Ok(Self(value))
    }

    pub fn expose_secret(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for SecretString {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretString([REDACTED])")
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NodeEnvelope {
    pub protocol_version: u16,
    pub message_id: String,
    pub node_id: String,
    pub node_generation: u64,
    pub sent_at_unix_ms: u64,
    pub payload: NodeMessage,
}

impl NodeEnvelope {
    pub fn validate(&self) -> Result<(), WireError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(WireError::UnsupportedProtocolVersion);
        }
        if !valid_identifier(&self.message_id) {
            return Err(WireError::InvalidMessageId);
        }
        if !valid_identifier(&self.node_id) {
            return Err(WireError::InvalidNodeId);
        }
        if self.node_generation == 0 || self.sent_at_unix_ms == 0 {
            return Err(WireError::InvalidEnvelope);
        }
        self.payload.validate(&self.node_id, self.node_generation)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum NodeMessage {
    Register {
        node: NodeSnapshot,
        agent_version: String,
    },
    Heartbeat {
        available: Resources,
        active_placements: BTreeSet<String>,
    },
    CommandAck {
        command_id: String,
        idempotency_key: String,
        status: CommandAckStatus,
        detail_code: Option<String>,
    },
    PlacementUpdate {
        placement_id: String,
        command_id: String,
        state: PlacementState,
        detail_code: Option<String>,
    },
}

impl NodeMessage {
    fn validate(&self, node_id: &str, node_generation: u64) -> Result<(), WireError> {
        match self {
            Self::Register {
                node,
                agent_version,
            } => {
                node.validate()
                    .map_err(|_| WireError::InvalidNodeSnapshot)?;
                if node.node_id != node_id || node.generation != node_generation {
                    return Err(WireError::IdentityMismatch);
                }
                if !valid_version(agent_version) {
                    return Err(WireError::InvalidAgentVersion);
                }
            }
            Self::Heartbeat {
                available: _,
                active_placements,
            } => {
                if active_placements.len() > MAX_ACTIVE_PLACEMENTS
                    || active_placements
                        .iter()
                        .any(|placement| !valid_identifier(placement))
                {
                    return Err(WireError::InvalidPlacementId);
                }
            }
            Self::CommandAck {
                command_id,
                idempotency_key,
                detail_code,
                ..
            } => {
                validate_command_identity(command_id, idempotency_key)?;
                validate_detail_code(detail_code)?;
            }
            Self::PlacementUpdate {
                placement_id,
                command_id,
                detail_code,
                ..
            } => {
                if !valid_identifier(placement_id) || !valid_identifier(command_id) {
                    return Err(WireError::InvalidPlacementId);
                }
                validate_detail_code(detail_code)?;
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NodeMessageResponse {
    pub protocol_version: u16,
    pub message_id: String,
    pub status: MessageResponseStatus,
    pub code: Option<String>,
    pub command: Option<ControllerEnvelope>,
}

impl NodeMessageResponse {
    pub fn validate(&self, now_unix_ms: u64) -> Result<(), WireError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(WireError::UnsupportedProtocolVersion);
        }
        if !valid_identifier(&self.message_id) {
            return Err(WireError::InvalidMessageId);
        }
        validate_detail_code(&self.code)?;
        match self.status {
            MessageResponseStatus::Rejected if self.code.is_none() || self.command.is_some() => {
                return Err(WireError::InvalidResponse);
            }
            MessageResponseStatus::Accepted | MessageResponseStatus::Duplicate
                if self.code.is_some() =>
            {
                return Err(WireError::InvalidResponse);
            }
            _ => {}
        }
        if let Some(command) = &self.command {
            command.validate(now_unix_ms)?;
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageResponseStatus {
    Accepted,
    Duplicate,
    Rejected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandAckStatus {
    Accepted,
    Duplicate,
    Rejected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlacementState {
    Accepted,
    Starting,
    Observed,
    Running,
    Finished,
    Failed,
    Cancelled,
}

impl PlacementState {
    pub const fn terminal(self) -> bool {
        matches!(self, Self::Finished | Self::Failed | Self::Cancelled)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ControllerEnvelope {
    pub protocol_version: u16,
    pub command_id: String,
    pub idempotency_key: String,
    pub node_id: String,
    pub node_generation: u64,
    pub issued_at_unix_ms: u64,
    pub expires_at_unix_ms: u64,
    pub payload: ControllerCommand,
}

impl ControllerEnvelope {
    pub fn validate(&self, now_unix_ms: u64) -> Result<(), WireError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(WireError::UnsupportedProtocolVersion);
        }
        validate_command_identity(&self.command_id, &self.idempotency_key)?;
        if !valid_identifier(&self.node_id) || self.node_generation == 0 {
            return Err(WireError::InvalidNodeId);
        }
        if self.issued_at_unix_ms == 0
            || self.expires_at_unix_ms < self.issued_at_unix_ms
            || self.expires_at_unix_ms - self.issued_at_unix_ms > MAX_COMMAND_TTL_MS
        {
            return Err(WireError::InvalidCommandLifetime);
        }
        if now_unix_ms > self.expires_at_unix_ms {
            return Err(WireError::ExpiredCommand);
        }
        self.payload.validate()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ControllerCommand {
    StartPlacement {
        placement_id: String,
        work_id: String,
        pool_id: String,
        runner_name: String,
        resources: Resources,
        execution_backend: ExecutionBackend,
        jit_config: SecretString,
    },
    CancelPlacement {
        placement_id: String,
    },
    SetDrain {
        draining: bool,
    },
}

impl ControllerCommand {
    fn validate(&self) -> Result<(), WireError> {
        match self {
            Self::StartPlacement {
                placement_id,
                work_id,
                pool_id,
                runner_name,
                resources,
                jit_config,
                ..
            } => {
                if [placement_id, work_id, pool_id, runner_name]
                    .into_iter()
                    .any(|value| !valid_identifier(value))
                {
                    return Err(WireError::InvalidPlacementId);
                }
                if resources.cpu_millis == 0 || resources.memory_bytes == 0 {
                    return Err(WireError::InvalidResources);
                }
                if !valid_jit_config(jit_config.expose_secret()) {
                    return Err(WireError::InvalidSecret);
                }
            }
            Self::CancelPlacement { placement_id } => {
                if !valid_identifier(placement_id) {
                    return Err(WireError::InvalidPlacementId);
                }
            }
            Self::SetDrain { .. } => {}
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WireError {
    TooLarge,
    InvalidJson,
    InvalidFrame,
    InvalidResponse,
    UnsupportedProtocolVersion,
    InvalidEnvelope,
    InvalidMessageId,
    InvalidNodeId,
    InvalidNodeSnapshot,
    InvalidAgentVersion,
    InvalidResources,
    InvalidPlacementId,
    InvalidCommandId,
    InvalidIdempotencyKey,
    InvalidCommandLifetime,
    ExpiredCommand,
    IdentityMismatch,
    InvalidDetailCode,
    InvalidSecret,
}

pub fn encode_frame(payload: &[u8]) -> Result<Vec<u8>, WireError> {
    if payload.is_empty() || payload.len() > MAX_WIRE_MESSAGE_BYTES {
        return Err(WireError::TooLarge);
    }
    let length = u32::try_from(payload.len()).map_err(|_| WireError::TooLarge)?;
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(payload);
    Ok(frame)
}

pub fn decode_frame(frame: &[u8]) -> Result<&[u8], WireError> {
    if frame.len() < 4 {
        return Err(WireError::InvalidFrame);
    }
    let length =
        u32::from_be_bytes(frame[..4].try_into().map_err(|_| WireError::InvalidFrame)?) as usize;
    if length == 0 || length > MAX_WIRE_MESSAGE_BYTES || frame.len() != length + 4 {
        return Err(WireError::InvalidFrame);
    }
    Ok(&frame[4..])
}

pub fn encode_node_message(message: &NodeEnvelope) -> Result<Vec<u8>, WireError> {
    message.validate()?;
    encode(message)
}

pub fn decode_node_message(bytes: &[u8]) -> Result<NodeEnvelope, WireError> {
    let message: NodeEnvelope = decode(bytes)?;
    message.validate()?;
    Ok(message)
}

pub fn encode_node_response(
    response: &NodeMessageResponse,
    now_unix_ms: u64,
) -> Result<Vec<u8>, WireError> {
    response.validate(now_unix_ms)?;
    encode(response)
}

pub fn decode_node_response(
    bytes: &[u8],
    now_unix_ms: u64,
) -> Result<NodeMessageResponse, WireError> {
    let response: NodeMessageResponse = decode(bytes)?;
    response.validate(now_unix_ms)?;
    Ok(response)
}

pub fn encode_controller_command(
    command: &ControllerEnvelope,
    now_unix_ms: u64,
) -> Result<Vec<u8>, WireError> {
    command.validate(now_unix_ms)?;
    encode(command)
}

pub fn decode_controller_command(
    bytes: &[u8],
    now_unix_ms: u64,
) -> Result<ControllerEnvelope, WireError> {
    let command: ControllerEnvelope = decode(bytes)?;
    command.validate(now_unix_ms)?;
    Ok(command)
}

fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, WireError> {
    let encoded = serde_json::to_vec(value).map_err(|_| WireError::InvalidJson)?;
    if encoded.len() > MAX_WIRE_MESSAGE_BYTES {
        return Err(WireError::TooLarge);
    }
    Ok(encoded)
}

fn decode<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T, WireError> {
    if bytes.is_empty() || bytes.len() > MAX_WIRE_MESSAGE_BYTES {
        return Err(WireError::TooLarge);
    }
    serde_json::from_slice(bytes).map_err(|_| WireError::InvalidJson)
}

fn validate_command_identity(command_id: &str, idempotency_key: &str) -> Result<(), WireError> {
    if !valid_identifier(command_id) {
        return Err(WireError::InvalidCommandId);
    }
    if !valid_identifier(idempotency_key) {
        return Err(WireError::InvalidIdempotencyKey);
    }
    Ok(())
}

fn validate_detail_code(detail_code: &Option<String>) -> Result<(), WireError> {
    if detail_code
        .as_deref()
        .is_some_and(|detail| !valid_identifier(detail))
    {
        return Err(WireError::InvalidDetailCode);
    }
    Ok(())
}

fn valid_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '+'))
}

fn valid_jit_config(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_JIT_CONFIG_BYTES
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'.' | b'_' | b'+' | b'/' | b'=' | b':' | b'-')
        })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use crate::{Architecture, OperatingSystem};

    use super::*;

    const GIB: u64 = 1024 * 1024 * 1024;

    fn node() -> NodeSnapshot {
        NodeSnapshot {
            node_id: "dookie".into(),
            generation: 7,
            os: OperatingSystem::Linux,
            arch: Architecture::X86_64,
            execution_backends: BTreeSet::from([ExecutionBackend::Container]),
            capabilities: BTreeSet::from(["github-actions".into(), "x64".into()]),
            total: Resources::new(20_000, 48 * GIB),
            available: Resources::new(18_000, 40 * GIB),
            draining: false,
        }
    }

    #[test]
    fn node_registration_round_trips_with_versioned_identity() {
        let envelope = NodeEnvelope {
            protocol_version: PROTOCOL_VERSION,
            message_id: "msg-register-1".into(),
            node_id: "dookie".into(),
            node_generation: 7,
            sent_at_unix_ms: 1_787_070_000_000,
            payload: NodeMessage::Register {
                node: node(),
                agent_version: "0.1.0".into(),
            },
        };
        let encoded = encode_node_message(&envelope).expect("registration encodes");
        assert_eq!(decode_node_message(&encoded), Ok(envelope));
    }

    #[test]
    fn registration_cannot_claim_a_different_authenticated_identity() {
        let envelope = NodeEnvelope {
            protocol_version: PROTOCOL_VERSION,
            message_id: "msg-register-1".into(),
            node_id: "steamy".into(),
            node_generation: 7,
            sent_at_unix_ms: 1_787_070_000_000,
            payload: NodeMessage::Register {
                node: node(),
                agent_version: "0.1.0".into(),
            },
        };
        assert_eq!(envelope.validate(), Err(WireError::IdentityMismatch));
    }

    #[test]
    fn command_debug_output_never_contains_jit_secret() {
        let secret = "super-secret-jit-config";
        let command = ControllerEnvelope {
            protocol_version: PROTOCOL_VERSION,
            command_id: "cmd-1".into(),
            idempotency_key: "idem-1".into(),
            node_id: "steamy".into(),
            node_generation: 3,
            issued_at_unix_ms: 1_787_070_000_000,
            expires_at_unix_ms: 1_787_070_030_000,
            payload: ControllerCommand::StartPlacement {
                placement_id: "placement-1".into(),
                work_id: "work-1".into(),
                pool_id: "windows".into(),
                runner_name: "crf-steamy-1".into(),
                resources: Resources::new(4_000, 8 * GIB),
                execution_backend: ExecutionBackend::NativeProcess,
                jit_config: SecretString::new(secret).expect("valid secret"),
            },
        };
        let debug = format!("{command:?}");
        assert!(!debug.contains(secret));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn expired_commands_fail_closed() {
        let command = ControllerEnvelope {
            protocol_version: PROTOCOL_VERSION,
            command_id: "cmd-1".into(),
            idempotency_key: "idem-1".into(),
            node_id: "dookie".into(),
            node_generation: 7,
            issued_at_unix_ms: 1_000,
            expires_at_unix_ms: 2_000,
            payload: ControllerCommand::SetDrain { draining: true },
        };
        assert_eq!(command.validate(2_001), Err(WireError::ExpiredCommand));
    }

    #[test]
    fn oversized_wire_messages_are_rejected_before_json_decode() {
        let bytes = vec![b' '; MAX_WIRE_MESSAGE_BYTES + 1];
        assert_eq!(decode_node_message(&bytes), Err(WireError::TooLarge));
    }

    #[test]
    fn length_prefixed_frames_round_trip() {
        let payload = br#"{"protocol_version":1}"#;
        let frame = encode_frame(payload).expect("frame encodes");
        assert_eq!(&frame[..4], &(payload.len() as u32).to_be_bytes());
        assert_eq!(decode_frame(&frame), Ok(payload.as_slice()));
    }

    #[test]
    fn malformed_or_oversized_frames_fail_before_payload_processing() {
        assert_eq!(decode_frame(&[0, 0, 0]), Err(WireError::InvalidFrame));
        assert_eq!(
            decode_frame(&[0, 0, 0, 5, b'a']),
            Err(WireError::InvalidFrame)
        );
        assert_eq!(encode_frame(&[]), Err(WireError::TooLarge));
        assert_eq!(
            encode_frame(&vec![b'x'; MAX_WIRE_MESSAGE_BYTES + 1]),
            Err(WireError::TooLarge)
        );
    }

    #[test]
    fn rust_wire_decoder_rejects_unknown_envelope_payload_and_nested_fields() {
        let envelope = NodeEnvelope {
            protocol_version: PROTOCOL_VERSION,
            message_id: "msg-strict-1".into(),
            node_id: "dookie".into(),
            node_generation: 7,
            sent_at_unix_ms: 1_787_070_000_000,
            payload: NodeMessage::Register {
                node: node(),
                agent_version: "0.1.0".into(),
            },
        };
        let encoded = encode_node_message(&envelope).expect("registration encodes");
        let value: serde_json::Value = serde_json::from_slice(&encoded).expect("valid json");

        let mut envelope_extra = value.clone();
        envelope_extra
            .as_object_mut()
            .expect("envelope object")
            .insert("surprise".into(), serde_json::Value::Bool(true));
        assert_eq!(
            decode_node_message(&serde_json::to_vec(&envelope_extra).expect("json")),
            Err(WireError::InvalidJson)
        );

        let mut payload_extra = value.clone();
        payload_extra["payload"]
            .as_object_mut()
            .expect("payload object")
            .insert("surprise".into(), serde_json::Value::Bool(true));
        assert_eq!(
            decode_node_message(&serde_json::to_vec(&payload_extra).expect("json")),
            Err(WireError::InvalidJson)
        );

        let mut node_extra = value;
        node_extra["payload"]["node"]
            .as_object_mut()
            .expect("node object")
            .insert("surprise".into(), serde_json::Value::Bool(true));
        assert_eq!(
            decode_node_message(&serde_json::to_vec(&node_extra).expect("json")),
            Err(WireError::InvalidJson)
        );
    }

    #[test]
    fn response_status_cannot_contradict_code_or_attached_command() {
        let command = decode_controller_command(
            include_bytes!("../../../tests/fixtures/distributed-controller-command-v1.json"),
            1_787_070_001_000,
        )
        .expect("fixture command");

        let rejected_with_command = NodeMessageResponse {
            protocol_version: PROTOCOL_VERSION,
            message_id: "message-1".into(),
            status: MessageResponseStatus::Rejected,
            code: Some("controller_rejected".into()),
            command: Some(command),
        };
        assert_eq!(
            rejected_with_command.validate(1_787_070_001_000),
            Err(WireError::InvalidResponse)
        );

        let accepted_with_code = NodeMessageResponse {
            protocol_version: PROTOCOL_VERSION,
            message_id: "message-2".into(),
            status: MessageResponseStatus::Accepted,
            code: Some("unexpected_code".into()),
            command: None,
        };
        assert_eq!(
            accepted_with_code.validate(1_787_070_001_000),
            Err(WireError::InvalidResponse)
        );

        let rejected_without_code = NodeMessageResponse {
            protocol_version: PROTOCOL_VERSION,
            message_id: "message-3".into(),
            status: MessageResponseStatus::Rejected,
            code: None,
            command: None,
        };
        assert_eq!(
            rejected_without_code.validate(1_787_070_001_000),
            Err(WireError::InvalidResponse)
        );
    }

    #[test]
    fn shared_elixir_controller_fixture_decodes_in_rust() {
        let bytes =
            include_bytes!("../../../tests/fixtures/distributed-controller-command-v1.json");
        let command = decode_controller_command(bytes, 1_787_070_001_000)
            .expect("shared controller command fixture decodes");

        assert_eq!(command.command_id, "command-1");
        assert_eq!(command.idempotency_key, "idempotency-1");
        assert_eq!(command.node_id, "steamy");
        assert_eq!(command.node_generation, 3);
        match command.payload {
            ControllerCommand::StartPlacement {
                placement_id,
                work_id,
                pool_id,
                runner_name,
                resources,
                execution_backend,
                jit_config,
            } => {
                assert_eq!(placement_id, "placement-1");
                assert_eq!(work_id, "work-1");
                assert_eq!(pool_id, "build");
                assert_eq!(runner_name, "crf-steamy-1");
                assert_eq!(resources, Resources::new(2_000, 4 * GIB));
                assert_eq!(execution_backend, ExecutionBackend::NativeProcess);
                assert_eq!(jit_config.expose_secret(), "jit-config-abc123==");
            }
            other => panic!("unexpected command payload: {other:?}"),
        }
    }
}
