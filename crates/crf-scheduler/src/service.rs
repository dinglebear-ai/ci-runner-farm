use std::io::{self, Read, Write};

use crf_protocol::wire::MAX_WIRE_MESSAGE_BYTES;
use crf_protocol::{NodeSnapshot, WorkRequirement, valid_identifier};
use serde::{Deserialize, Serialize};

use crate::{ScheduleResult, schedule};

pub const SCHEDULER_PROTOCOL_VERSION: u16 = 1;
pub const MAX_SCHEDULER_ITEMS: usize = 4096;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SchedulerRequest {
    pub protocol_version: u16,
    pub request_id: String,
    pub requests: Vec<WorkRequirement>,
    pub nodes: Vec<NodeSnapshot>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SchedulerResponseStatus {
    Ok,
    Error,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SchedulerResponse {
    pub protocol_version: u16,
    pub request_id: Option<String>,
    pub status: SchedulerResponseStatus,
    pub code: Option<String>,
    pub result: Option<ScheduleResult>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SchedulerServiceError {
    TooLarge,
    InvalidJson,
    UnsupportedProtocolVersion,
    InvalidRequestId,
    TooManyItems,
    InvalidRequest,
    EncodeFailed,
    Io,
    InvalidFrame,
}

impl SchedulerRequest {
    pub fn validate(&self) -> Result<(), SchedulerServiceError> {
        if self.protocol_version != SCHEDULER_PROTOCOL_VERSION {
            return Err(SchedulerServiceError::UnsupportedProtocolVersion);
        }
        if !valid_identifier(&self.request_id) {
            return Err(SchedulerServiceError::InvalidRequestId);
        }
        if self.requests.len() > MAX_SCHEDULER_ITEMS || self.nodes.len() > MAX_SCHEDULER_ITEMS {
            return Err(SchedulerServiceError::TooManyItems);
        }
        if self.nodes.iter().any(|node| node.validate().is_err()) {
            return Err(SchedulerServiceError::InvalidRequest);
        }
        Ok(())
    }
}

impl SchedulerResponse {
    pub fn validate(&self) -> Result<(), SchedulerServiceError> {
        if self.protocol_version != SCHEDULER_PROTOCOL_VERSION {
            return Err(SchedulerServiceError::UnsupportedProtocolVersion);
        }
        if self
            .request_id
            .as_deref()
            .is_some_and(|id| !valid_identifier(id))
        {
            return Err(SchedulerServiceError::InvalidRequestId);
        }
        match self.status {
            SchedulerResponseStatus::Ok => {
                if self.request_id.is_none() || self.code.is_some() || self.result.is_none() {
                    return Err(SchedulerServiceError::InvalidRequest);
                }
            }
            SchedulerResponseStatus::Error => {
                if self
                    .code
                    .as_deref()
                    .is_none_or(|code| !valid_identifier(code))
                    || self.result.is_some()
                {
                    return Err(SchedulerServiceError::InvalidRequest);
                }
            }
        }
        Ok(())
    }
}

pub fn handle_payload(payload: &[u8]) -> Vec<u8> {
    match decode_request(payload) {
        Ok(request) => {
            let response = SchedulerResponse {
                protocol_version: SCHEDULER_PROTOCOL_VERSION,
                request_id: Some(request.request_id),
                status: SchedulerResponseStatus::Ok,
                code: None,
                result: Some(schedule(&request.requests, &request.nodes)),
            };
            encode_response(&response).unwrap_or_else(|_| fallback_error("encode_failed"))
        }
        Err(error) => fallback_error(error_code(error)),
    }
}

pub fn decode_request(payload: &[u8]) -> Result<SchedulerRequest, SchedulerServiceError> {
    if payload.is_empty() || payload.len() > MAX_WIRE_MESSAGE_BYTES {
        return Err(SchedulerServiceError::TooLarge);
    }
    let request: SchedulerRequest =
        serde_json::from_slice(payload).map_err(|_| SchedulerServiceError::InvalidJson)?;
    request.validate()?;
    Ok(request)
}

pub fn decode_response(payload: &[u8]) -> Result<SchedulerResponse, SchedulerServiceError> {
    if payload.is_empty() || payload.len() > MAX_WIRE_MESSAGE_BYTES {
        return Err(SchedulerServiceError::TooLarge);
    }
    let response: SchedulerResponse =
        serde_json::from_slice(payload).map_err(|_| SchedulerServiceError::InvalidJson)?;
    response.validate()?;
    Ok(response)
}

pub fn encode_response(response: &SchedulerResponse) -> Result<Vec<u8>, SchedulerServiceError> {
    response.validate()?;
    let encoded = serde_json::to_vec(response).map_err(|_| SchedulerServiceError::EncodeFailed)?;
    if encoded.len() > MAX_WIRE_MESSAGE_BYTES {
        return Err(SchedulerServiceError::TooLarge);
    }
    Ok(encoded)
}

pub fn run_framed<R: Read, W: Write>(
    reader: &mut R,
    writer: &mut W,
) -> Result<(), SchedulerServiceError> {
    loop {
        let Some(payload) = read_frame(reader)? else {
            writer.flush().map_err(|_| SchedulerServiceError::Io)?;
            return Ok(());
        };
        let response = handle_payload(&payload);
        write_frame(writer, &response)?;
        writer.flush().map_err(|_| SchedulerServiceError::Io)?;
    }
}

fn read_frame<R: Read>(reader: &mut R) -> Result<Option<Vec<u8>>, SchedulerServiceError> {
    let mut header = [0_u8; 4];
    let mut read = 0_usize;
    while read < header.len() {
        match reader.read(&mut header[read..]) {
            Ok(0) if read == 0 => return Ok(None),
            Ok(0) => return Err(SchedulerServiceError::InvalidFrame),
            Ok(count) => read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(SchedulerServiceError::Io),
        }
    }
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_WIRE_MESSAGE_BYTES {
        return Err(SchedulerServiceError::InvalidFrame);
    }
    let mut payload = vec![0_u8; length];
    reader
        .read_exact(&mut payload)
        .map_err(|_| SchedulerServiceError::Io)?;
    Ok(Some(payload))
}

fn write_frame<W: Write>(writer: &mut W, payload: &[u8]) -> Result<(), SchedulerServiceError> {
    if payload.is_empty() || payload.len() > MAX_WIRE_MESSAGE_BYTES {
        return Err(SchedulerServiceError::TooLarge);
    }
    let length = u32::try_from(payload.len()).map_err(|_| SchedulerServiceError::TooLarge)?;
    writer
        .write_all(&length.to_be_bytes())
        .map_err(|_| SchedulerServiceError::Io)?;
    writer
        .write_all(payload)
        .map_err(|_| SchedulerServiceError::Io)
}

fn fallback_error(code: &str) -> Vec<u8> {
    let response = SchedulerResponse {
        protocol_version: SCHEDULER_PROTOCOL_VERSION,
        request_id: None,
        status: SchedulerResponseStatus::Error,
        code: Some(code.to_owned()),
        result: None,
    };
    serde_json::to_vec(&response).unwrap_or_else(|_| br#"{"protocol_version":1,"request_id":null,"status":"error","code":"encode_failed","result":null}"#.to_vec())
}

fn error_code(error: SchedulerServiceError) -> &'static str {
    match error {
        SchedulerServiceError::TooLarge => "message_too_large",
        SchedulerServiceError::InvalidJson => "invalid_json",
        SchedulerServiceError::UnsupportedProtocolVersion => "unsupported_protocol_version",
        SchedulerServiceError::InvalidRequestId => "invalid_request_id",
        SchedulerServiceError::TooManyItems => "too_many_items",
        SchedulerServiceError::InvalidRequest => "invalid_request",
        SchedulerServiceError::EncodeFailed => "encode_failed",
        SchedulerServiceError::Io => "io_error",
        SchedulerServiceError::InvalidFrame => "invalid_frame",
    }
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeSet, io::Cursor};

    use crf_protocol::{Architecture, ExecutionBackend, OperatingSystem, Resources};

    use super::*;

    fn request() -> SchedulerRequest {
        SchedulerRequest {
            protocol_version: SCHEDULER_PROTOCOL_VERSION,
            request_id: "schedule-1".into(),
            requests: vec![WorkRequirement {
                work_id: "work-1".into(),
                pool_id: "build".into(),
                resources: Resources::new(2_000, 4 * 1024 * 1024 * 1024),
                required_os: Some(OperatingSystem::Windows),
                required_arch: Some(Architecture::X86_64),
                required_backend: Some(ExecutionBackend::NativeProcess),
                required_capabilities: BTreeSet::new(),
            }],
            nodes: vec![NodeSnapshot {
                node_id: "steamy".into(),
                generation: 3,
                os: OperatingSystem::Windows,
                arch: Architecture::X86_64,
                execution_backends: BTreeSet::from([ExecutionBackend::NativeProcess]),
                capabilities: BTreeSet::new(),
                total: Resources::new(12_000, 32 * 1024 * 1024 * 1024),
                available: Resources::new(12_000, 32 * 1024 * 1024 * 1024),
                draining: false,
            }],
        }
    }

    #[test]
    fn valid_request_returns_scheduler_result() {
        let encoded = serde_json::to_vec(&request()).expect("request json");
        let response = decode_response(&handle_payload(&encoded)).expect("response");
        assert_eq!(response.request_id.as_deref(), Some("schedule-1"));
        assert_eq!(response.status, SchedulerResponseStatus::Ok);
        assert_eq!(
            response.result.expect("result").placements[0].node_id,
            "steamy"
        );
    }

    #[test]
    fn unknown_fields_fail_closed_without_killing_service() {
        let mut value = serde_json::to_value(request()).expect("request value");
        value
            .as_object_mut()
            .expect("object")
            .insert("surprise".into(), true.into());
        let response = decode_response(&handle_payload(&serde_json::to_vec(&value).expect("json")))
            .expect("response");
        assert_eq!(response.status, SchedulerResponseStatus::Error);
        assert_eq!(response.code.as_deref(), Some("invalid_json"));
    }

    #[test]
    fn framed_service_handles_multiple_requests_in_one_process() {
        let payload = serde_json::to_vec(&request()).expect("request json");
        let mut input = Vec::new();
        for _ in 0..2 {
            input.extend_from_slice(&(payload.len() as u32).to_be_bytes());
            input.extend_from_slice(&payload);
        }
        let mut reader = Cursor::new(input);
        let mut output = Vec::new();
        run_framed(&mut reader, &mut output).expect("service");

        let mut output = Cursor::new(output);
        for _ in 0..2 {
            let payload = read_frame(&mut output).expect("frame").expect("payload");
            let response = decode_response(&payload).expect("response");
            assert_eq!(response.status, SchedulerResponseStatus::Ok);
        }
        assert_eq!(read_frame(&mut output), Ok(None));
    }

    #[test]
    fn oversized_frame_fails_before_allocation() {
        let mut input = Cursor::new(((MAX_WIRE_MESSAGE_BYTES + 1) as u32).to_be_bytes().to_vec());
        assert_eq!(
            read_frame(&mut input),
            Err(SchedulerServiceError::InvalidFrame)
        );
    }
}
