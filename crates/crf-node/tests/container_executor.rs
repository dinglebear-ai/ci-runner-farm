#![cfg(unix)]

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crf_node::{
    command_processor::{CommandExecutor, ExecutionResult},
    container_adapter::ProcessContainerAdapter,
    container_executor::{ContainerExecutorError, ContainerRunnerExecutor},
    placement_state::{LocalPlacementState, PlacementStore, RuntimeIdentity, TerminalOutcome},
    process_identity::ProcessIdentity,
};
use crf_protocol::wire::{ControllerCommand, ControllerEnvelope, PROTOCOL_VERSION, SecretString};
use crf_protocol::{ExecutionBackend, Resources};

static TEST_COUNTER: AtomicU64 = AtomicU64::new(1);
const NOW: u64 = 1_787_200_000_000;

struct TestRoot {
    root: PathBuf,
}

impl TestRoot {
    fn new() -> Self {
        let counter = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "crf-container-executor-{}-{counter}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&root).expect("test root");
        Self { root }
    }

    fn store(&self) -> PlacementStore {
        PlacementStore::new(self.root.join("state")).expect("placement store")
    }

    fn script(&self, name: &str, body: &str) -> PathBuf {
        let path = self.root.join(name);
        fs::write(
            &path,
            format!(
                "#!/bin/sh
set -eu
{body}
"
            ),
        )
        .expect("script");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).expect("script mode");
        path
    }

    fn executor(&self, script: PathBuf) -> ContainerRunnerExecutor {
        let adapter =
            ProcessContainerAdapter::new(script, Duration::from_secs(2)).expect("adapter");
        ContainerRunnerExecutor::new(adapter, self.store())
    }
}

impl Drop for TestRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn start_command() -> ControllerEnvelope {
    ControllerEnvelope {
        protocol_version: PROTOCOL_VERSION,
        command_id: "command-start-1".into(),
        idempotency_key: "idem-start-1".into(),
        node_id: "node-1".into(),
        node_generation: 1,
        issued_at_unix_ms: NOW - 1_000,
        expires_at_unix_ms: NOW + 30_000,
        payload: ControllerCommand::StartPlacement {
            placement_id: "placement-1".into(),
            work_id: "work-1".into(),
            pool_id: "build".into(),
            runner_name: "crf-container-1".into(),
            resources: Resources::new(2_000, 4 * 1024 * 1024 * 1024),
            execution_backend: ExecutionBackend::Container,
            jit_config: SecretString::new("jit-config-abc123==").expect("secret"),
        },
    }
}

fn cancel_command() -> ControllerEnvelope {
    ControllerEnvelope {
        protocol_version: PROTOCOL_VERSION,
        command_id: "command-cancel-1".into(),
        idempotency_key: "idem-cancel-1".into(),
        node_id: "node-1".into(),
        node_generation: 1,
        issued_at_unix_ms: NOW - 1_000,
        expires_at_unix_ms: NOW + 30_000,
        payload: ControllerCommand::CancelPlacement {
            placement_id: "placement-1".into(),
        },
    }
}

#[test]
fn intent_recovery_adopts_existing_container_without_second_start() {
    let root = TestRoot::new();
    let log = root.root.join("adapter.log");
    let script = root.script(
        "adapter.sh",
        &format!(
            r#"
req=$(cat)
printf '%s
' "$req" >> '{}'
case "$req" in
  *'"action":"inspect"'*) printf '%s
' '{{"schema_version":1,"payload":{{"result":"running","id":"container-abc"}}}}' ;;
  *'"action":"start"'*) printf '%s
' '{{"schema_version":1,"payload":{{"result":"rejected","detail_code":"duplicate_start"}}}}' ;;
  *) exit 2 ;;
esac
"#,
            log.display()
        ),
    );
    let store = root.store();
    let command = start_command();
    store.begin(&command).expect("intent");
    let mut executor = ContainerRunnerExecutor::new(
        ProcessContainerAdapter::new(script, Duration::from_secs(2)).expect("adapter"),
        store,
    );

    assert_eq!(
        executor.reconcile_pending(&command),
        ExecutionResult::Applied
    );
    assert_eq!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::Spawned {
            runtime: RuntimeIdentity::Container {
                id: "container-abc".into(),
            },
        })
    );
    let calls = fs::read_to_string(log).expect("adapter log");
    assert!(calls.contains(r#""action":"inspect""#));
    assert!(!calls.contains(r#""action":"start""#));
}

#[test]
fn cancellation_targets_exact_persisted_container_id() {
    let root = TestRoot::new();
    let log = root.root.join("adapter.log");
    let script = root.script(
        "adapter.sh",
        &format!(
            r#"
req=$(cat)
printf '%s
' "$req" >> '{}'
case "$req" in
  *'"action":"start"'*) printf '%s
' '{{"schema_version":1,"payload":{{"result":"started","id":"container-exact"}}}}' ;;
  *'"action":"cancel"'*) printf '%s
' '{{"schema_version":1,"payload":{{"result":"cancelled"}}}}' ;;
  *) exit 2 ;;
esac
"#,
            log.display()
        ),
    );
    let mut executor = root.executor(script);

    assert_eq!(
        executor.execute_new(&start_command()),
        ExecutionResult::Applied
    );
    assert_eq!(
        executor.execute_new(&cancel_command()),
        ExecutionResult::Applied
    );
    assert_eq!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::Terminal {
            outcome: TerminalOutcome::Cancelled,
        })
    );
    let calls = fs::read_to_string(log).expect("adapter log");
    let cancel = calls
        .lines()
        .find(|line| line.contains(r#""action":"cancel""#))
        .expect("cancel call");
    assert!(cancel.contains(r#""expected_id":"container-exact""#));
}

#[test]
fn uncertain_start_remains_intent_only_and_never_claims_absence() {
    let root = TestRoot::new();
    let script = root.script(
        "adapter.sh",
        r#"
req=$(cat)
case "$req" in
  *'"action":"start"'*) exit 9 ;;
  *'"action":"inspect"'*) printf '%s
' '{"schema_version":1,"payload":{"result":"deferred","detail_code":"runtime_uncertain"}}' ;;
  *) exit 2 ;;
esac
"#,
    );
    let mut executor = root.executor(script);
    let command = start_command();

    assert_eq!(
        executor.execute_new(&command),
        ExecutionResult::Deferred("container_adapter_uncertain".into())
    );
    assert_eq!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::IntentOnly)
    );
    assert_eq!(
        executor.reconcile_pending(&command),
        ExecutionResult::Deferred("runtime_uncertain".into())
    );
    assert_eq!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::IntentOnly)
    );
}

#[test]
fn lost_container_becomes_terminal_and_enters_report_outbox() {
    let root = TestRoot::new();
    let script = root.script(
        "adapter.sh",
        r#"
cat >/dev/null
printf '%s
' '{"schema_version":1,"payload":{"result":"absent"}}'
"#,
    );
    let store = root.store();
    let command = start_command();
    store.begin(&command).expect("intent");
    store
        .record_runtime_started(
            "placement-1",
            RuntimeIdentity::Container {
                id: "container-lost".into(),
            },
        )
        .expect("spawned");
    let mut executor = ContainerRunnerExecutor::new(
        ProcessContainerAdapter::new(script, Duration::from_secs(2)).expect("adapter"),
        store,
    );

    executor.poll_runtime_state().expect("poll");
    assert_eq!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::Terminal {
            outcome: TerminalOutcome::Failed {
                detail_code: "container_lost".into(),
            },
        })
    );
    let reports = executor.pending_terminal_reports().expect("reports");
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0].placement_id, "placement-1");
    assert_eq!(
        reports[0].outcome,
        TerminalOutcome::Failed {
            detail_code: "container_lost".into(),
        }
    );
}

#[test]
fn native_runtime_identity_is_preserved_under_container_executor() {
    let root = TestRoot::new();
    let marker = root.root.join("adapter-called");
    let script = root.script(
        "adapter.sh",
        &format!("touch '{}'; exit 44", marker.display()),
    );
    let store = root.store();
    let command = start_command();
    store.begin(&command).expect("intent");
    let process = ProcessIdentity::capture(std::process::id()).expect("process identity");
    store
        .record_spawned("placement-1", process)
        .expect("native state");
    let mut executor = ContainerRunnerExecutor::new(
        ProcessContainerAdapter::new(script, Duration::from_secs(2)).expect("adapter"),
        store,
    );

    assert_eq!(
        executor.reconcile_pending(&command),
        ExecutionResult::Rejected("runtime_identity_mismatch".into())
    );
    assert_eq!(
        executor.poll_runtime_state(),
        Err(ContainerExecutorError::RuntimeIdentityMismatch)
    );
    assert_eq!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::Spawned {
            runtime: RuntimeIdentity::NativeProcess { process },
        })
    );
    assert!(
        !marker.exists(),
        "mismatched runtime must not call container adapter"
    );
}
