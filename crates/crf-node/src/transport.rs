use std::{
    fs::File,
    io::{BufReader, Read, Write},
    net::{SocketAddr, TcpStream},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use crf_protocol::wire::{
    MAX_WIRE_MESSAGE_BYTES, NodeEnvelope, NodeMessageResponse, WireError, decode_node_response,
    encode_frame, encode_node_message,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};

const MAX_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TlsClientSettings {
    pub controller_addr: SocketAddr,
    pub server_name: String,
    pub ca_cert_path: PathBuf,
    pub client_cert_path: PathBuf,
    pub client_key_path: PathBuf,
    pub connect_timeout: Duration,
    pub io_timeout: Duration,
}

impl TlsClientSettings {
    pub fn validate(&self) -> Result<(), NodeTransportError> {
        if self.controller_addr.port() == 0
            || self.server_name.is_empty()
            || self.server_name.len() > 253
            || self.ca_cert_path.as_os_str().is_empty()
            || self.client_cert_path.as_os_str().is_empty()
            || self.client_key_path.as_os_str().is_empty()
        {
            return Err(NodeTransportError::InvalidConfiguration);
        }
        if !valid_timeout(self.connect_timeout) || !valid_timeout(self.io_timeout) {
            return Err(NodeTransportError::InvalidTimeout);
        }
        Ok(())
    }
}

#[derive(Clone)]
pub struct TlsClient {
    settings: TlsClientSettings,
    config: Arc<ClientConfig>,
    server_name: ServerName<'static>,
}

impl TlsClient {
    pub fn new(settings: TlsClientSettings) -> Result<Self, NodeTransportError> {
        settings.validate()?;

        let ca_certificates =
            load_certificates(&settings.ca_cert_path, CertificateKind::Authority)?;
        let client_certificates =
            load_certificates(&settings.client_cert_path, CertificateKind::Client)?;
        let client_key = load_private_key(&settings.client_key_path)?;

        let mut roots = RootCertStore::empty();
        for certificate in ca_certificates {
            roots
                .add(certificate)
                .map_err(|_| NodeTransportError::InvalidAuthorityCertificate)?;
        }

        let config = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_client_auth_cert(client_certificates, client_key)
            .map_err(|_| NodeTransportError::InvalidClientIdentity)?;

        let server_name = ServerName::try_from(settings.server_name.clone())
            .map_err(|_| NodeTransportError::InvalidServerName)?;

        Ok(Self {
            settings,
            config: Arc::new(config),
            server_name,
        })
    }

    pub fn connect(&self) -> Result<TlsSession, NodeTransportError> {
        let socket = TcpStream::connect_timeout(
            &self.settings.controller_addr,
            self.settings.connect_timeout,
        )
        .map_err(|_| NodeTransportError::ConnectFailed)?;
        socket
            .set_read_timeout(Some(self.settings.io_timeout))
            .map_err(|_| NodeTransportError::SocketConfigurationFailed)?;
        socket
            .set_write_timeout(Some(self.settings.io_timeout))
            .map_err(|_| NodeTransportError::SocketConfigurationFailed)?;
        socket
            .set_nodelay(true)
            .map_err(|_| NodeTransportError::SocketConfigurationFailed)?;

        let connection = ClientConnection::new(self.config.clone(), self.server_name.clone())
            .map_err(|_| NodeTransportError::TlsConnectionFailed)?;

        Ok(TlsSession {
            stream: StreamOwned::new(connection, socket),
        })
    }
}

pub struct TlsSession {
    stream: StreamOwned<ClientConnection, TcpStream>,
}

impl TlsSession {
    pub fn exchange(
        &mut self,
        request: &NodeEnvelope,
        now_unix_ms: u64,
    ) -> Result<NodeMessageResponse, NodeTransportError> {
        exchange_stream(&mut self.stream, request, now_unix_ms)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NodeTransportError {
    InvalidConfiguration,
    InvalidTimeout,
    ReadAuthorityCertificate,
    InvalidAuthorityCertificate,
    ReadClientCertificate,
    InvalidClientCertificate,
    ReadPrivateKey,
    MissingPrivateKey,
    InvalidClientIdentity,
    InvalidServerName,
    ConnectFailed,
    SocketConfigurationFailed,
    TlsConnectionFailed,
    EncodeRequest(WireError),
    EncodeFrame(WireError),
    WriteFailed,
    FlushFailed,
    ReadFailed,
    InvalidResponseFrame,
    DecodeResponse(WireError),
    ResponseMessageMismatch,
    CommandIdentityMismatch,
}

fn exchange_stream<S: Read + Write>(
    stream: &mut S,
    request: &NodeEnvelope,
    now_unix_ms: u64,
) -> Result<NodeMessageResponse, NodeTransportError> {
    let payload = encode_node_message(request).map_err(NodeTransportError::EncodeRequest)?;
    let frame = encode_frame(&payload).map_err(NodeTransportError::EncodeFrame)?;
    stream
        .write_all(&frame)
        .map_err(|_| NodeTransportError::WriteFailed)?;
    stream
        .flush()
        .map_err(|_| NodeTransportError::FlushFailed)?;

    let mut header = [0_u8; 4];
    stream
        .read_exact(&mut header)
        .map_err(|_| NodeTransportError::ReadFailed)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_WIRE_MESSAGE_BYTES {
        return Err(NodeTransportError::InvalidResponseFrame);
    }

    let mut response_payload = vec![0_u8; length];
    stream
        .read_exact(&mut response_payload)
        .map_err(|_| NodeTransportError::ReadFailed)?;
    let response = decode_node_response(&response_payload, now_unix_ms)
        .map_err(NodeTransportError::DecodeResponse)?;

    if response.message_id != request.message_id {
        return Err(NodeTransportError::ResponseMessageMismatch);
    }
    if response.command.as_ref().is_some_and(|command| {
        command.node_id != request.node_id || command.node_generation != request.node_generation
    }) {
        return Err(NodeTransportError::CommandIdentityMismatch);
    }

    Ok(response)
}

#[derive(Clone, Copy)]
enum CertificateKind {
    Authority,
    Client,
}

fn load_certificates(
    path: &Path,
    kind: CertificateKind,
) -> Result<Vec<CertificateDer<'static>>, NodeTransportError> {
    let file = File::open(path).map_err(|_| match kind {
        CertificateKind::Authority => NodeTransportError::ReadAuthorityCertificate,
        CertificateKind::Client => NodeTransportError::ReadClientCertificate,
    })?;
    let mut reader = BufReader::new(file);
    let certificates: Result<Vec<_>, _> = rustls_pemfile::certs(&mut reader).collect();
    let certificates = certificates.map_err(|_| match kind {
        CertificateKind::Authority => NodeTransportError::InvalidAuthorityCertificate,
        CertificateKind::Client => NodeTransportError::InvalidClientCertificate,
    })?;
    if certificates.is_empty() {
        return Err(match kind {
            CertificateKind::Authority => NodeTransportError::InvalidAuthorityCertificate,
            CertificateKind::Client => NodeTransportError::InvalidClientCertificate,
        });
    }
    Ok(certificates)
}

fn load_private_key(path: &Path) -> Result<PrivateKeyDer<'static>, NodeTransportError> {
    let file = File::open(path).map_err(|_| NodeTransportError::ReadPrivateKey)?;
    let mut reader = BufReader::new(file);
    rustls_pemfile::private_key(&mut reader)
        .map_err(|_| NodeTransportError::ReadPrivateKey)?
        .ok_or(NodeTransportError::MissingPrivateKey)
}

fn valid_timeout(timeout: Duration) -> bool {
    !timeout.is_zero() && timeout <= MAX_TIMEOUT
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeSet, io::Cursor};

    use crf_protocol::wire::{
        ControllerCommand, ControllerEnvelope, MessageResponseStatus, NodeMessage,
        NodeMessageResponse, PROTOCOL_VERSION, SecretString, decode_frame, decode_node_message,
        encode_node_response,
    };
    use crf_protocol::{ExecutionBackend, Resources};

    use super::*;

    const GIB: u64 = 1024 * 1024 * 1024;
    const NOW: u64 = 1_787_070_001_000;

    struct ScriptedStream {
        input: Cursor<Vec<u8>>,
        output: Vec<u8>,
    }

    impl ScriptedStream {
        fn new(input: Vec<u8>) -> Self {
            Self {
                input: Cursor::new(input),
                output: Vec::new(),
            }
        }
    }

    impl Read for ScriptedStream {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.input.read(buffer)
        }
    }

    impl Write for ScriptedStream {
        fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
            self.output.extend_from_slice(buffer);
            Ok(buffer.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn request(message_id: &str) -> NodeEnvelope {
        NodeEnvelope {
            protocol_version: PROTOCOL_VERSION,
            message_id: message_id.into(),
            node_id: "steamy".into(),
            node_generation: 3,
            sent_at_unix_ms: NOW,
            payload: NodeMessage::Heartbeat {
                available: Resources::new(8_000, 16 * GIB),
                active_placements: BTreeSet::new(),
            },
        }
    }

    fn command(node_id: &str, generation: u64) -> ControllerEnvelope {
        ControllerEnvelope {
            protocol_version: PROTOCOL_VERSION,
            command_id: "command-1".into(),
            idempotency_key: "idempotency-1".into(),
            node_id: node_id.into(),
            node_generation: generation,
            issued_at_unix_ms: NOW - 1_000,
            expires_at_unix_ms: NOW + 30_000,
            payload: ControllerCommand::StartPlacement {
                placement_id: "placement-1".into(),
                work_id: "work-1".into(),
                pool_id: "build".into(),
                runner_name: "crf-steamy-1".into(),
                resources: Resources::new(2_000, 4 * GIB),
                execution_backend: ExecutionBackend::NativeProcess,
                jit_config: SecretString::new("jit-config-abc123==").expect("secret"),
            },
        }
    }

    fn response_frame(message_id: &str, command: Option<ControllerEnvelope>) -> Vec<u8> {
        let response = NodeMessageResponse {
            protocol_version: PROTOCOL_VERSION,
            message_id: message_id.into(),
            status: MessageResponseStatus::Accepted,
            code: None,
            command,
        };
        let payload = encode_node_response(&response, NOW).expect("response encodes");
        encode_frame(&payload).expect("response frame encodes")
    }

    #[test]
    fn framed_exchange_round_trips_request_and_attached_command() {
        let request = request("message-1");
        let mut stream =
            ScriptedStream::new(response_frame("message-1", Some(command("steamy", 3))));

        let response = exchange_stream(&mut stream, &request, NOW).expect("exchange succeeds");
        assert_eq!(response.command, Some(command("steamy", 3)));

        let written = decode_frame(&stream.output).expect("written frame decodes");
        assert_eq!(
            decode_node_message(written).expect("written request decodes"),
            request
        );
    }

    #[test]
    fn response_message_id_must_match_request() {
        let request = request("message-2");
        let mut stream = ScriptedStream::new(response_frame("different-message", None));

        assert_eq!(
            exchange_stream(&mut stream, &request, NOW),
            Err(NodeTransportError::ResponseMessageMismatch)
        );
    }

    #[test]
    fn attached_command_is_fenced_to_request_node_and_generation() {
        let request = request("message-3");
        let mut stream =
            ScriptedStream::new(response_frame("message-3", Some(command("dookie", 7))));

        assert_eq!(
            exchange_stream(&mut stream, &request, NOW),
            Err(NodeTransportError::CommandIdentityMismatch)
        );
    }

    #[test]
    fn oversized_response_header_fails_before_body_allocation() {
        let request = request("message-4");
        let length = u32::try_from(MAX_WIRE_MESSAGE_BYTES + 1).expect("wire ceiling fits u32");
        let mut stream = ScriptedStream::new(length.to_be_bytes().to_vec());

        assert_eq!(
            exchange_stream(&mut stream, &request, NOW),
            Err(NodeTransportError::InvalidResponseFrame)
        );
    }
}
