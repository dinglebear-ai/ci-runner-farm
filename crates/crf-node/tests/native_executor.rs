use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crf_node::{
    command_processor::{CommandExecutor, ExecutionResult},
    current_os,
    native_executor::NativeRunnerExecutor,
    native_materializer::RunnerMaterializer,
    placement_state::{LocalPlacementState, PlacementStore, TerminalOutcome},
    process_identity::ProcessIdentity,
};
use crf_protocol::wire::{ControllerCommand, ControllerEnvelope, PROTOCOL_VERSION, SecretString};
use crf_protocol::{ExecutionBackend, OperatingSystem, Resources};

static TEST_COUNTER: AtomicU64 = AtomicU64::new(1);
const NOW: u64 = 1_787_070_001_000;
const GIB: u64 = 1024 * 1024 * 1024;

struct TestRoots {
    root: PathBuf,
    template: PathBuf,
    runtime: PathBuf,
    logs: PathBuf,
    state: PathBuf,
    os: OperatingSystem,
}

impl TestRoots {
    fn success() -> Self {
        Self::new(false)
    }

    #[cfg(unix)]
    fn long_running() -> Self {
        Self::new(true)
    }

    fn new(long_running: bool) -> Self {
        let counter = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "crf-native-executor-{}-{counter}-{nanos}",
            std::process::id()
        ));
        let template = root.join("template");
        let runtime = root.join("runtime");
        let logs = root.join("logs");
        let state = root.join("state");
        fs::create_dir_all(&template).expect("template directory");
        let os = current_os();
        write_runner_script(&template, &os, long_running);
        Self {
            root,
            template,
            runtime,
            logs,
            state,
            os,
        }
    }

    fn store(&self) -> PlacementStore {
        PlacementStore::new(&self.state).expect("placement store")
    }

    fn executor(&self) -> NativeRunnerExecutor {
        let materializer =
            RunnerMaterializer::new(self.os.clone(), &self.template, &self.runtime, &self.logs)
                .expect("materializer");
        NativeRunnerExecutor::new(self.os.clone(), materializer, self.store())
            .expect("native executor")
    }
}

impl Drop for TestRoots {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn write_runner_script(root: &Path, os: &OperatingSystem, long_running: bool) {
    match os {
        OperatingSystem::Windows => {
            let body = if long_running {
                r#"@echo off
if "%ACTIONS_RUNNER_INPUT_JITCONFIG%"=="" exit /b 4
powershell -NoProfile -Command "Start-Sleep -Seconds 30"
"#
            } else {
                r#"@echo off
if "%ACTIONS_RUNNER_INPUT_JITCONFIG%"=="" exit /b 4
exit /b 0
"#
            };
            fs::write(root.join("run.cmd"), body).expect("Windows runner script");
        }
        OperatingSystem::Linux | OperatingSystem::Macos => {
            let body = if long_running {
                r#"#!/bin/sh
test -n "$ACTIONS_RUNNER_INPUT_JITCONFIG" || exit 4
sleep 30
"#
            } else {
                r#"#!/bin/sh
test -n "$ACTIONS_RUNNER_INPUT_JITCONFIG" || exit 4
exit 0
"#
            };
            let path = root.join("run.sh");
            fs::write(&path, body).expect("Unix runner script");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o755))
                    .expect("executable runner script");
            }
        }
        OperatingSystem::Other => panic!("unsupported test platform"),
    }
}

fn start_command(node_id: &str, generation: u64) -> ControllerEnvelope {
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
            runner_name: "crf-native-1".into(),
            resources: Resources::new(2_000, 4 * GIB),
            execution_backend: ExecutionBackend::NativeProcess,
            jit_config: SecretString::new("jit-config-abc123==").expect("secret"),
        },
    }
}

#[test]
fn native_start_materializes_private_runner_and_records_spawn_before_ack() {
    let roots = TestRoots::success();
    let mut executor = roots.executor();
    let command = start_command("node-1", 1);

    assert_eq!(executor.execute_new(&command), ExecutionResult::Applied);
    assert!(matches!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::Spawned { .. })
    ));
    assert_eq!(executor.managed_count(), 1);
    assert!(roots.runtime.join("placement-1").exists());
    assert!(roots.logs.join("placement-1/runner.stdout.log").exists());
    assert!(roots.logs.join("placement-1/runner.stderr.log").exists());

    let updates = wait_for_terminal(&mut executor);
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0].outcome, TerminalOutcome::Finished);
    assert_eq!(executor.managed_count(), 0);
}

#[test]
fn intent_only_reconciliation_never_spawns_a_second_runner() {
    let roots = TestRoots::success();
    let store = roots.store();
    let command = start_command("node-1", 1);
    store.begin(&command).expect("intent");

    let materializer = RunnerMaterializer::new(
        roots.os.clone(),
        &roots.template,
        &roots.runtime,
        &roots.logs,
    )
    .expect("materializer");
    let mut executor =
        NativeRunnerExecutor::new(roots.os.clone(), materializer, store).expect("executor");

    assert_eq!(
        executor.reconcile_pending(&command),
        ExecutionResult::Deferred("start_uncertain".into())
    );
    assert_eq!(executor.managed_count(), 0);
    assert!(!roots.runtime.join("placement-1").exists());
}

#[test]
fn local_drain_rejects_stale_start_without_runner_side_effects() {
    let roots = TestRoots::success();
    let mut executor = roots.executor();
    let drain = ControllerEnvelope {
        protocol_version: PROTOCOL_VERSION,
        command_id: "drain-1".into(),
        idempotency_key: "drain-idem-1".into(),
        node_id: "node-1".into(),
        node_generation: 1,
        issued_at_unix_ms: NOW - 1_000,
        expires_at_unix_ms: NOW + 30_000,
        payload: ControllerCommand::SetDrain { draining: true },
    };

    assert_eq!(executor.execute_new(&drain), ExecutionResult::Applied);
    assert!(executor.is_draining());
    assert_eq!(
        executor.execute_new(&start_command("node-1", 1)),
        ExecutionResult::Rejected("node_draining".into())
    );
    assert!(!roots.runtime.exists());
}

#[cfg(unix)]
#[test]
fn cancel_kills_managed_native_runner_and_persists_terminal_state() {
    let roots = TestRoots::long_running();
    let mut executor = roots.executor();
    let command = start_command("node-1", 1);
    assert_eq!(executor.execute_new(&command), ExecutionResult::Applied);

    let cancel = ControllerEnvelope {
        protocol_version: PROTOCOL_VERSION,
        command_id: "cancel-1".into(),
        idempotency_key: "cancel-idem-1".into(),
        node_id: "node-1".into(),
        node_generation: 1,
        issued_at_unix_ms: NOW - 500,
        expires_at_unix_ms: NOW + 30_000,
        payload: ControllerCommand::CancelPlacement {
            placement_id: "placement-1".into(),
        },
    };
    assert_eq!(executor.execute_new(&cancel), ExecutionResult::Applied);
    assert_eq!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::Terminal {
            outcome: TerminalOutcome::Cancelled,
        })
    );
    assert_eq!(executor.managed_count(), 0);
}

#[test]
fn restarted_executor_marks_missing_spawned_pid_terminal() {
    let roots = TestRoots::success();
    let store = roots.store();
    let command = start_command("node-1", 1);
    store.begin(&command).expect("intent");
    store
        .record_spawned(
            "placement-1",
            ProcessIdentity {
                pid: u32::MAX,
                start_token: 1,
            },
        )
        .expect("spawned state");

    let materializer = RunnerMaterializer::new(
        roots.os.clone(),
        &roots.template,
        &roots.runtime,
        &roots.logs,
    )
    .expect("materializer");
    let mut executor =
        NativeRunnerExecutor::new(roots.os.clone(), materializer, store).expect("executor");

    let updates = executor.poll_terminal_updates().expect("poll recovery");
    assert_eq!(updates.len(), 1);
    assert_eq!(
        updates[0].outcome,
        TerminalOutcome::Failed {
            detail_code: "runner_process_lost".into(),
        }
    );
    assert_eq!(
        executor.placement_state("placement-1"),
        Ok(LocalPlacementState::Terminal {
            outcome: TerminalOutcome::Failed {
                detail_code: "runner_process_lost".into(),
            },
        })
    );
}

#[test]
fn restarted_executor_rejects_reused_pid_with_different_birth_token() {
    let roots = TestRoots::success();
    let store = roots.store();
    let command = start_command("node-1", 1);
    store.begin(&command).expect("intent");

    let current = ProcessIdentity::capture(std::process::id()).expect("current process identity");
    let mismatched = ProcessIdentity {
        pid: current.pid,
        start_token: current.start_token.wrapping_add(1).max(1),
    };
    assert_ne!(current, mismatched);
    store
        .record_spawned("placement-1", mismatched)
        .expect("spawned state");

    let materializer = RunnerMaterializer::new(
        roots.os.clone(),
        &roots.template,
        &roots.runtime,
        &roots.logs,
    )
    .expect("materializer");
    let mut executor =
        NativeRunnerExecutor::new(roots.os.clone(), materializer, store).expect("executor");

    let updates = executor.poll_terminal_updates().expect("poll recovery");
    assert_eq!(updates.len(), 1);
    assert_eq!(
        updates[0].outcome,
        TerminalOutcome::Failed {
            detail_code: "runner_process_lost".into(),
        }
    );
}

#[cfg(unix)]
#[test]
fn symlink_in_runner_template_fails_before_process_creation() {
    use std::os::unix::fs::symlink;

    let roots = TestRoots::success();
    symlink("run.sh", roots.template.join("linked-runner")).expect("runner symlink");
    let mut executor = roots.executor();

    assert_eq!(
        executor.execute_new(&start_command("node-1", 1)),
        ExecutionResult::Rejected("runner_materialize_failed".into())
    );
    assert_eq!(executor.managed_count(), 0);
}

fn wait_for_terminal(
    executor: &mut NativeRunnerExecutor,
) -> Vec<crf_node::native_executor::PlacementProcessUpdate> {
    for _ in 0..100 {
        let updates = executor.poll_terminal_updates().expect("poll child");
        if !updates.is_empty() {
            return updates;
        }
        thread::sleep(Duration::from_millis(20));
    }
    panic!("native runner did not terminate in time");
}
