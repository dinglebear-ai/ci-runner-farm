use std::{
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use crf_protocol::wire::{ControllerCommand, ControllerEnvelope, SecretString};
use crf_protocol::{ExecutionBackend, Resources, valid_identifier};
use serde::{Deserialize, Serialize};

use crate::{placement_state::TerminalOutcome, process_tree::ManagedProcess};

const ADAPTER_SCHEMA_VERSION: u8 = 1;
const MAX_ADAPTER_FRAME_BYTES: usize = 128 * 1024;
const POLL_INTERVAL: Duration = Duration::from_millis(10);
const MIN_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContainerAdapterEnvelope<T> {
    pub schema_version: u8,
    pub payload: T,
}

impl<T> ContainerAdapterEnvelope<T> {
    fn new(payload: T) -> Self {
        Self {
            schema_version: ADAPTER_SCHEMA_VERSION,
            payload,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum ContainerAdapterRequest {
    Start {
        placement_id: String,
        command_id: String,
        pool_id: String,
        runner_name: String,
        resources: Resources,
        jit_config: SecretString,
    },
    Inspect {
        placement_id: String,
        expected_id: Option<String>,
    },
    Cancel {
        placement_id: String,
        expected_id: Option<String>,
    },
}

impl ContainerAdapterRequest {
    pub fn start_from(command: &ControllerEnvelope) -> Result<Self, ContainerAdapterError> {
        let ControllerCommand::StartPlacement {
            placement_id,
            pool_id,
            runner_name,
            resources,
            execution_backend,
            jit_config,
            ..
        } = &command.payload
        else {
            return Err(ContainerAdapterError::UnsupportedCommand);
        };
        if execution_backend != &ExecutionBackend::Container {
            return Err(ContainerAdapterError::UnsupportedBackend);
        }
        let request = Self::Start {
            placement_id: placement_id.clone(),
            command_id: command.command_id.clone(),
            pool_id: pool_id.clone(),
            runner_name: runner_name.clone(),
            resources: *resources,
            jit_config: jit_config.clone(),
        };
        request.validate()?;
        Ok(request)
    }

    pub fn validate(&self) -> Result<(), ContainerAdapterError> {
        match self {
            Self::Start {
                placement_id,
                command_id,
                pool_id,
                runner_name,
                resources,
                ..
            } => {
                if [placement_id, command_id, pool_id, runner_name]
                    .into_iter()
                    .any(|value| !valid_identifier(value))
                    || resources.cpu_millis == 0
                    || resources.memory_bytes == 0
                {
                    return Err(ContainerAdapterError::InvalidRequest);
                }
            }
            Self::Inspect {
                placement_id,
                expected_id,
            }
            | Self::Cancel {
                placement_id,
                expected_id,
            } => {
                if !valid_identifier(placement_id)
                    || expected_id.as_ref().is_some_and(|id| !valid_identifier(id))
                {
                    return Err(ContainerAdapterError::InvalidRequest);
                }
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case", deny_unknown_fields)]
pub enum ContainerAdapterResponse {
    Started { id: String },
    Running { id: String },
    Terminal { outcome: TerminalOutcome },
    Absent,
    Cancelled,
    Rejected { detail_code: String },
    Deferred { detail_code: String },
}

impl ContainerAdapterResponse {
    pub fn validate(&self) -> Result<(), ContainerAdapterError> {
        match self {
            Self::Started { id } | Self::Running { id } if !valid_identifier(id) => {
                Err(ContainerAdapterError::InvalidResponse)
            }
            Self::Terminal {
                outcome: TerminalOutcome::Failed { detail_code },
            } if !valid_identifier(detail_code) => Err(ContainerAdapterError::InvalidResponse),
            Self::Rejected { detail_code } | Self::Deferred { detail_code }
                if !valid_identifier(detail_code) =>
            {
                Err(ContainerAdapterError::InvalidResponse)
            }
            _ => Ok(()),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContainerAdapterError {
    InvalidProgram,
    InvalidTimeout,
    UnsupportedCommand,
    UnsupportedBackend,
    InvalidRequest,
    RequestTooLarge,
    SpawnFailed,
    StdinUnavailable,
    StdoutUnavailable,
    WriteFailed,
    PollFailed,
    TimedOut,
    ProcessFailed,
    ResponseTooLarge,
    ReadFailed,
    InvalidResponse,
}

#[derive(Clone, Debug)]
pub struct ProcessContainerAdapter {
    program: PathBuf,
    timeout: Duration,
}

impl ProcessContainerAdapter {
    pub fn new(
        program: impl Into<PathBuf>,
        timeout: Duration,
    ) -> Result<Self, ContainerAdapterError> {
        let program = program.into();
        if !safe_absolute_path(&program) {
            return Err(ContainerAdapterError::InvalidProgram);
        }
        if !(MIN_TIMEOUT..=MAX_TIMEOUT).contains(&timeout) {
            return Err(ContainerAdapterError::InvalidTimeout);
        }
        Ok(Self { program, timeout })
    }

    pub fn call(
        &self,
        request: &ContainerAdapterRequest,
    ) -> Result<ContainerAdapterResponse, ContainerAdapterError> {
        request.validate()?;
        let mut encoded = serde_json::to_vec(&ContainerAdapterEnvelope::new(request))
            .map_err(|_| ContainerAdapterError::InvalidRequest)?;
        encoded.push(b'\n');
        if encoded.len() > MAX_ADAPTER_FRAME_BYTES {
            return Err(ContainerAdapterError::RequestTooLarge);
        }

        // Anonymous private files prevent adapter pipe backpressure and ensure
        // an escaped descendant cannot retain a node-side I/O thread or JIT
        // descriptor after the deadline.
        let mut request_file =
            tempfile::tempfile().map_err(|_| ContainerAdapterError::WriteFailed)?;
        request_file
            .write_all(&encoded)
            .and_then(|()| request_file.seek(SeekFrom::Start(0)).map(|_| ()))
            .map_err(|_| ContainerAdapterError::WriteFailed)?;
        let mut response_file =
            tempfile::tempfile().map_err(|_| ContainerAdapterError::ReadFailed)?;

        let mut command = Command::new(&self.program);
        command
            .stdin(Stdio::from(
                request_file
                    .try_clone()
                    .map_err(|_| ContainerAdapterError::StdinUnavailable)?,
            ))
            .stdout(Stdio::from(
                response_file
                    .try_clone()
                    .map_err(|_| ContainerAdapterError::StdoutUnavailable)?,
            ))
            .stderr(Stdio::null());
        let deadline = Instant::now() + self.timeout;
        let mut process =
            ManagedProcess::spawn(&mut command).map_err(|_| ContainerAdapterError::SpawnFailed)?;
        let status = loop {
            match process.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) if Instant::now() < deadline => thread::sleep(POLL_INTERVAL),
                Ok(None) => {
                    let _ = process.terminate_tree_now();
                    return Err(ContainerAdapterError::TimedOut);
                }
                Err(_) => {
                    let _ = process.terminate_tree_now();
                    return Err(ContainerAdapterError::PollFailed);
                }
            }
        };
        response_file
            .seek(SeekFrom::Start(0))
            .map_err(|_| ContainerAdapterError::ReadFailed)?;
        let mut bytes = Vec::new();
        response_file
            .take((MAX_ADAPTER_FRAME_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| ContainerAdapterError::ReadFailed)?;
        if !status.success() {
            return Err(ContainerAdapterError::ProcessFailed);
        }
        if bytes.len() > MAX_ADAPTER_FRAME_BYTES {
            return Err(ContainerAdapterError::ResponseTooLarge);
        }
        let envelope: ContainerAdapterEnvelope<ContainerAdapterResponse> =
            serde_json::from_slice(&bytes).map_err(|_| ContainerAdapterError::InvalidResponse)?;
        if envelope.schema_version != ADAPTER_SCHEMA_VERSION {
            return Err(ContainerAdapterError::InvalidResponse);
        }
        envelope.payload.validate()?;
        Ok(envelope.payload)
    }

    pub fn timeout(&self) -> Duration {
        self.timeout
    }
}

fn safe_absolute_path(path: &Path) -> bool {
    path.is_absolute()
        && !path
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crf_protocol::wire::{ControllerCommand, PROTOCOL_VERSION};

    #[cfg(unix)]
    static ADAPTER_PROCESS_TEST: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[cfg(unix)]
    struct TestAdapterScript {
        root: PathBuf,
        path: PathBuf,
    }

    #[cfg(unix)]
    impl TestAdapterScript {
        fn new(body: &str) -> Self {
            use std::os::unix::fs::PermissionsExt;
            use std::time::{SystemTime, UNIX_EPOCH};

            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "crf-container-adapter-{}-{nonce}",
                std::process::id()
            ));
            std::fs::create_dir(&root).expect("adapter temp dir");
            let path = root.join("adapter.sh");
            std::fs::write(&path, format!("#!/bin/sh\nset -eu\n{body}\n")).expect("adapter script");
            let mut permissions = std::fs::metadata(&path).expect("metadata").permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(&path, permissions).expect("permissions");
            Self { root, path }
        }
    }

    #[cfg(unix)]
    impl Drop for TestAdapterScript {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn start_command(backend: ExecutionBackend, secret: &str) -> ControllerEnvelope {
        ControllerEnvelope {
            protocol_version: PROTOCOL_VERSION,
            command_id: "command-1".into(),
            idempotency_key: "idem-1".into(),
            node_id: "node-1".into(),
            node_generation: 1,
            issued_at_unix_ms: 1,
            expires_at_unix_ms: 2,
            payload: ControllerCommand::StartPlacement {
                placement_id: "placement-1".into(),
                work_id: "work-1".into(),
                pool_id: "pool-1".into(),
                runner_name: "runner-1".into(),
                resources: Resources::new(1_000, 1024),
                execution_backend: backend,
                jit_config: SecretString::new(secret).expect("valid test secret"),
            },
        }
    }

    #[test]
    fn start_request_accepts_only_container_backend_and_redacts_secret_debug() {
        let secret = "jit-super-secret==";
        let request = ContainerAdapterRequest::start_from(&start_command(
            ExecutionBackend::Container,
            secret,
        ))
        .expect("request");
        assert!(!format!("{request:?}").contains(secret));
        assert_eq!(
            ContainerAdapterRequest::start_from(&start_command(
                ExecutionBackend::NativeProcess,
                secret
            )),
            Err(ContainerAdapterError::UnsupportedBackend)
        );
    }

    #[test]
    fn wire_round_trip_preserves_secret_without_logging_it() {
        let secret = "jit-super-secret==";
        let request = ContainerAdapterRequest::start_from(&start_command(
            ExecutionBackend::Container,
            secret,
        ))
        .expect("request");
        let bytes = serde_json::to_vec(&ContainerAdapterEnvelope::new(&request)).expect("json");
        assert!(String::from_utf8_lossy(&bytes).contains(secret));
        let decoded: ContainerAdapterEnvelope<ContainerAdapterRequest> =
            serde_json::from_slice(&bytes).expect("decode");
        assert_eq!(decoded.schema_version, ADAPTER_SCHEMA_VERSION);
        assert_eq!(decoded.payload, request);
    }

    #[test]
    fn invalid_response_identity_and_detail_codes_fail_closed() {
        assert_eq!(
            ContainerAdapterResponse::Started {
                id: "../bad".into()
            }
            .validate(),
            Err(ContainerAdapterError::InvalidResponse)
        );
        assert_eq!(
            ContainerAdapterResponse::Deferred {
                detail_code: "bad detail".into()
            }
            .validate(),
            Err(ContainerAdapterError::InvalidResponse)
        );
    }

    #[test]
    fn client_rejects_relative_program_and_extreme_timeouts() {
        assert_eq!(
            ProcessContainerAdapter::new("relative-helper", Duration::from_secs(1)).unwrap_err(),
            ContainerAdapterError::InvalidProgram
        );
        #[cfg(windows)]
        let absolute_program = r"C:\crf-test\adapter.exe";
        #[cfg(not(windows))]
        let absolute_program = "/bin/true";
        assert_eq!(
            ProcessContainerAdapter::new(absolute_program, Duration::from_millis(1)).unwrap_err(),
            ContainerAdapterError::InvalidTimeout
        );
    }

    #[cfg(unix)]
    #[test]
    fn process_client_keeps_jit_secret_on_stdin_only() {
        let _process_test = ADAPTER_PROCESS_TEST.lock().expect("process test lock");
        let script = TestAdapterScript::new(
            r#"
[ "$#" -eq 0 ] || exit 21
if env | grep -Fq "jit-super-secret=="; then exit 22; fi
dir=$(dirname "$0")
cat > "$dir/input.json"
grep -Fq "jit-super-secret==" "$dir/input.json" || exit 23
printf "%s\n" '{"schema_version":1,"payload":{"result":"started","id":"container-0123456789abcdef"}}'
"#,
        );
        let client =
            ProcessContainerAdapter::new(&script.path, Duration::from_secs(2)).expect("client");
        let request = ContainerAdapterRequest::start_from(&start_command(
            ExecutionBackend::Container,
            "jit-super-secret==",
        ))
        .expect("request");
        assert_eq!(
            client.call(&request),
            Ok(ContainerAdapterResponse::Started {
                id: "container-0123456789abcdef".into(),
            })
        );
        let captured =
            std::fs::read_to_string(script.root.join("input.json")).expect("captured stdin");
        assert!(captured.contains("jit-super-secret=="));
    }

    #[cfg(unix)]
    #[test]
    fn process_client_rejects_oversized_response() {
        let _process_test = ADAPTER_PROCESS_TEST.lock().expect("process test lock");
        let script = TestAdapterScript::new(
            r#"
yes x | head -c 131073
"#,
        );
        let client =
            ProcessContainerAdapter::new(&script.path, Duration::from_secs(2)).expect("client");
        let request = ContainerAdapterRequest::Inspect {
            placement_id: "placement-1".into(),
            expected_id: None,
        };
        assert_eq!(
            client.call(&request),
            Err(ContainerAdapterError::ResponseTooLarge)
        );
    }

    #[cfg(unix)]
    #[test]
    fn process_client_does_not_wait_for_escaped_descendant_holding_output() {
        let _process_test = ADAPTER_PROCESS_TEST.lock().expect("process test lock");
        let script = TestAdapterScript::new(
            r#"
cat >/dev/null
setsid sh -c 'sleep 10' &
printf "%s\n" '{"schema_version":1,"payload":{"result":"started","id":"container-0123456789abcdef"}}'
"#,
        );
        let client =
            ProcessContainerAdapter::new(&script.path, Duration::from_millis(250)).expect("client");
        let request = ContainerAdapterRequest::Inspect {
            placement_id: "placement-1".into(),
            expected_id: None,
        };
        let started = Instant::now();
        assert_eq!(
            client.call(&request),
            Ok(ContainerAdapterResponse::Started {
                id: "container-0123456789abcdef".into(),
            })
        );
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[cfg(unix)]
    #[test]
    fn process_client_timeout_terminates_helper_tree() {
        let _process_test = ADAPTER_PROCESS_TEST.lock().expect("process test lock");
        let script = TestAdapterScript::new(
            r#"
dir=$(dirname "$0")
sleep 30 &
echo $! > "$dir/child.pid"
wait
"#,
        );
        // Give the helper enough time to create its descendant before exercising the
        // timeout path. Under a fully parallel test suite, 150 ms can expire before
        // the shell is scheduled at all, which tests scheduler latency instead of
        // process-tree containment.
        let client =
            ProcessContainerAdapter::new(&script.path, Duration::from_secs(1)).expect("client");
        let request = ContainerAdapterRequest::Inspect {
            placement_id: "placement-1".into(),
            expected_id: None,
        };
        assert_eq!(client.call(&request), Err(ContainerAdapterError::TimedOut));
        let child_pid: i32 = std::fs::read_to_string(script.root.join("child.pid"))
            .expect("child pid")
            .trim()
            .parse()
            .expect("numeric child pid");
        for _ in 0..50 {
            if unsafe { libc::kill(child_pid, 0) } != 0 {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("timed out adapter child process remained alive");
    }

    #[cfg(unix)]
    #[test]
    fn process_client_timeout_covers_blocked_maximum_request_write() {
        let _process_test = ADAPTER_PROCESS_TEST.lock().expect("process test lock");
        let script = TestAdapterScript::new(
            r#"
dir=$(dirname "$0")
if [ ! -e "$dir/blocked-once" ]; then
  : > "$dir/blocked-once"
  sleep 30
  exit 24
fi
cat >/dev/null
printf "%s\n" '{"schema_version":1,"payload":{"result":"started","id":"container-after-timeout"}}'
"#,
        );
        let client =
            ProcessContainerAdapter::new(&script.path, Duration::from_millis(250)).expect("client");
        let maximum_secret = "A".repeat(64 * 1024);
        let request = ContainerAdapterRequest::start_from(&start_command(
            ExecutionBackend::Container,
            &maximum_secret,
        ))
        .expect("maximum request");

        let started = Instant::now();
        assert_eq!(client.call(&request), Err(ContainerAdapterError::TimedOut));
        assert!(started.elapsed() < Duration::from_secs(2));

        assert_eq!(
            client.call(&request),
            Ok(ContainerAdapterResponse::Started {
                id: "container-after-timeout".into(),
            })
        );
    }
}
