use std::collections::{BTreeMap, BTreeSet};

use crf_protocol::wire::{ControllerCommand, ControllerEnvelope};
use crf_protocol::{ExecutionBackend, OperatingSystem, valid_identifier};

use crate::{
    agent::{AgentRuntimeError, PlacementRuntime},
    command_processor::{CommandExecutor, ExecutionResult},
    native_materializer::{MaterializerError, RunnerMaterializer},
    placement_state::{
        LocalPlacementState, PlacementStore, PlacementStoreError, TerminalOutcome, TerminalReport,
    },
    process_identity::ProcessIdentity,
    process_tree::ManagedProcess,
    runtime::NativeRunnerInvocation,
    system_probe::SystemProbe,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlacementProcessUpdate {
    pub placement_id: String,
    pub outcome: TerminalOutcome,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeExecutorError {
    PlatformMismatch,
    PollFailed,
    PlacementStateUnavailable,
    SystemProbeUnavailable,
}

struct ManagedChild {
    process: ManagedProcess,
    identity: ProcessIdentity,
}

pub struct NativeRunnerExecutor {
    os: OperatingSystem,
    materializer: RunnerMaterializer,
    store: PlacementStore,
    children: BTreeMap<String, ManagedChild>,
    system: SystemProbe,
    draining: bool,
}

impl NativeRunnerExecutor {
    pub fn new(
        os: OperatingSystem,
        materializer: RunnerMaterializer,
        store: PlacementStore,
    ) -> Result<Self, NativeExecutorError> {
        if materializer.os() != &os {
            return Err(NativeExecutorError::PlatformMismatch);
        }
        let system = SystemProbe::new().map_err(|_| NativeExecutorError::SystemProbeUnavailable)?;
        Ok(Self {
            os,
            materializer,
            store,
            children: BTreeMap::new(),
            system,
            draining: false,
        })
    }

    pub fn active_placements(&self) -> Result<BTreeSet<String>, NativeExecutorError> {
        self.store
            .active_placements()
            .map_err(|_| NativeExecutorError::PlacementStateUnavailable)
    }

    pub fn is_draining(&self) -> bool {
        self.draining
    }

    pub fn reserved_resources(&self) -> Result<crf_protocol::Resources, NativeExecutorError> {
        self.store
            .reserved_resources()
            .map_err(|_| NativeExecutorError::PlacementStateUnavailable)
    }

    pub fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, NativeExecutorError> {
        self.store
            .pending_terminal_reports()
            .map_err(|_| NativeExecutorError::PlacementStateUnavailable)
    }

    pub fn mark_terminal_reported(&self, placement_id: &str) -> Result<(), NativeExecutorError> {
        self.store
            .mark_terminal_reported(placement_id)
            .map_err(|_| NativeExecutorError::PlacementStateUnavailable)
    }

    pub fn managed_count(&self) -> usize {
        self.children.len()
    }

    pub fn placement_state(
        &self,
        placement_id: &str,
    ) -> Result<LocalPlacementState, NativeExecutorError> {
        self.store
            .inspect(placement_id)
            .map_err(|_| NativeExecutorError::PlacementStateUnavailable)
    }

    pub fn poll_terminal_updates(
        &mut self,
    ) -> Result<Vec<PlacementProcessUpdate>, NativeExecutorError> {
        let mut completed = Vec::new();
        let mut remove = Vec::new();
        let placement_ids: Vec<String> = self.children.keys().cloned().collect();

        for placement_id in placement_ids {
            let status = self
                .children
                .get_mut(&placement_id)
                .ok_or(NativeExecutorError::PollFailed)?
                .process
                .try_wait()
                .map_err(|_| NativeExecutorError::PollFailed)?;
            let Some(status) = status else {
                continue;
            };
            let outcome = if status.success() {
                TerminalOutcome::Finished
            } else {
                TerminalOutcome::Failed {
                    detail_code: "runner_exit_nonzero".into(),
                }
            };
            self.store
                .record_terminal(&placement_id, outcome.clone())
                .map_err(|_| NativeExecutorError::PlacementStateUnavailable)?;
            completed.push(PlacementProcessUpdate {
                placement_id: placement_id.clone(),
                outcome,
            });
            remove.push(placement_id);
        }

        for placement_id in remove {
            self.children.remove(&placement_id);
        }

        for placement_id in self
            .store
            .active_placements()
            .map_err(|_| NativeExecutorError::PlacementStateUnavailable)?
        {
            if self.children.contains_key(&placement_id) {
                continue;
            }
            let LocalPlacementState::Spawned { process } = self
                .store
                .inspect(&placement_id)
                .map_err(|_| NativeExecutorError::PlacementStateUnavailable)?
            else {
                continue;
            };
            if self.system.process_matches(process) {
                continue;
            }
            let outcome = TerminalOutcome::Failed {
                detail_code: "runner_process_lost".into(),
            };
            self.store
                .record_terminal(&placement_id, outcome.clone())
                .map_err(|_| NativeExecutorError::PlacementStateUnavailable)?;
            completed.push(PlacementProcessUpdate {
                placement_id,
                outcome,
            });
        }
        Ok(completed)
    }

    fn start_placement(&mut self, command: &ControllerEnvelope) -> ExecutionResult {
        let ControllerCommand::StartPlacement {
            placement_id,
            execution_backend,
            jit_config,
            ..
        } = &command.payload
        else {
            return ExecutionResult::Rejected("invalid_start_command".into());
        };
        if self.draining {
            return ExecutionResult::Rejected("node_draining".into());
        }
        if execution_backend != &ExecutionBackend::NativeProcess {
            return ExecutionResult::Rejected("backend_unsupported".into());
        }
        if self.children.contains_key(placement_id) {
            return ExecutionResult::Deferred("placement_already_managed".into());
        }
        if let Err(error) = self.store.begin(command) {
            return map_begin_error(error);
        }

        let runner_root = match self.materializer.prepare(placement_id) {
            Ok(path) => path,
            Err(MaterializerError::MaterializationConflict) => {
                return ExecutionResult::Deferred("runner_materialization_uncertain".into());
            }
            Err(_) => return self.fail_before_spawn(placement_id, "runner_materialize_failed"),
        };
        let (stdout, stderr) = match self.materializer.open_logs(placement_id) {
            Ok(logs) => logs,
            Err(_) => return self.fail_before_spawn(placement_id, "runner_log_open_failed"),
        };
        let invocation = match NativeRunnerInvocation::for_platform(&runner_root, &self.os) {
            Ok(invocation) => invocation,
            Err(_) => return self.fail_before_spawn(placement_id, "native_runtime_unsupported"),
        };
        let mut process =
            match invocation.spawn_with_logs(jit_config.expose_secret(), stdout, stderr) {
                Ok(process) => process,
                Err(_) => return self.fail_before_spawn(placement_id, "runner_spawn_failed"),
            };
        let identity = match ProcessIdentity::capture(process.id()) {
            Ok(identity) => identity,
            Err(_) => {
                let _ = process.terminate_tree();
                return self.fail_before_spawn(placement_id, "runner_identity_unavailable");
            }
        };
        self.children
            .insert(placement_id.clone(), ManagedChild { process, identity });
        if self.store.record_spawned(placement_id, identity).is_err() {
            return ExecutionResult::Deferred("spawn_state_unavailable".into());
        }
        ExecutionResult::Applied
    }

    fn reconcile_start(&mut self, command: &ControllerEnvelope) -> ExecutionResult {
        let ControllerCommand::StartPlacement { placement_id, .. } = &command.payload else {
            return ExecutionResult::Rejected("invalid_start_command".into());
        };
        if let Some(managed) = self.children.get(placement_id) {
            if self
                .store
                .record_spawned(placement_id, managed.identity)
                .is_err()
            {
                return ExecutionResult::Deferred("spawn_state_unavailable".into());
            }
            return ExecutionResult::Applied;
        }
        match self.store.inspect(placement_id) {
            Ok(LocalPlacementState::Spawned { .. }) => ExecutionResult::Applied,
            Ok(LocalPlacementState::IntentOnly) => {
                ExecutionResult::Deferred("start_uncertain".into())
            }
            Ok(LocalPlacementState::Terminal {
                outcome: TerminalOutcome::Finished,
            }) => ExecutionResult::Applied,
            Ok(LocalPlacementState::Terminal {
                outcome: TerminalOutcome::Failed { detail_code },
            }) => ExecutionResult::Rejected(detail_code),
            Ok(LocalPlacementState::Terminal {
                outcome: TerminalOutcome::Cancelled,
            }) => ExecutionResult::Rejected("placement_cancelled".into()),
            Err(_) => ExecutionResult::Deferred("placement_state_unavailable".into()),
        }
    }

    fn cancel_placement(&mut self, placement_id: &str) -> ExecutionResult {
        if !valid_identifier(placement_id) {
            return ExecutionResult::Rejected("invalid_placement_id".into());
        }
        if let Some(mut managed) = self.children.remove(placement_id) {
            match managed.process.try_wait() {
                Ok(Some(status)) => {
                    let outcome = if status.success() {
                        TerminalOutcome::Finished
                    } else {
                        TerminalOutcome::Failed {
                            detail_code: "runner_exit_nonzero".into(),
                        }
                    };
                    if self.store.record_terminal(placement_id, outcome).is_err() {
                        self.children.insert(placement_id.to_owned(), managed);
                        return ExecutionResult::Deferred("placement_state_unavailable".into());
                    }
                    return ExecutionResult::Applied;
                }
                Ok(None) => {}
                Err(_) => {
                    self.children.insert(placement_id.to_owned(), managed);
                    return ExecutionResult::Deferred("cancel_uncertain".into());
                }
            }
            if managed.process.terminate_tree().is_err() {
                self.children.insert(placement_id.to_owned(), managed);
                return ExecutionResult::Deferred("cancel_uncertain".into());
            }
            if self
                .store
                .record_terminal(placement_id, TerminalOutcome::Cancelled)
                .is_err()
            {
                self.children.insert(placement_id.to_owned(), managed);
                return ExecutionResult::Deferred("placement_state_unavailable".into());
            }
            return ExecutionResult::Applied;
        }

        match self.store.inspect(placement_id) {
            Ok(LocalPlacementState::Terminal { .. }) => ExecutionResult::Applied,
            Ok(LocalPlacementState::Spawned { .. } | LocalPlacementState::IntentOnly) => {
                ExecutionResult::Deferred("cancel_uncertain".into())
            }
            Err(_) => ExecutionResult::Deferred("placement_state_unavailable".into()),
        }
    }

    fn fail_before_spawn(&self, placement_id: &str, detail_code: &str) -> ExecutionResult {
        let outcome = TerminalOutcome::Failed {
            detail_code: detail_code.to_owned(),
        };
        if self.store.record_terminal(placement_id, outcome).is_ok() {
            ExecutionResult::Rejected(detail_code.to_owned())
        } else {
            ExecutionResult::Deferred("placement_state_unavailable".into())
        }
    }
}

impl PlacementRuntime for NativeRunnerExecutor {
    fn poll_runtime(&mut self) -> Result<(), AgentRuntimeError> {
        self.poll_terminal_updates()
            .map(|_| ())
            .map_err(|error| match error {
                NativeExecutorError::PollFailed => AgentRuntimeError::PollFailed,
                NativeExecutorError::PlatformMismatch
                | NativeExecutorError::PlacementStateUnavailable
                | NativeExecutorError::SystemProbeUnavailable => {
                    AgentRuntimeError::PlacementStateUnavailable
                }
            })
    }

    fn reserved_resources(&self) -> Result<crf_protocol::Resources, AgentRuntimeError> {
        NativeRunnerExecutor::reserved_resources(self)
            .map_err(|_| AgentRuntimeError::PlacementStateUnavailable)
    }

    fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, AgentRuntimeError> {
        NativeRunnerExecutor::pending_terminal_reports(self)
            .map_err(|_| AgentRuntimeError::PlacementStateUnavailable)
    }

    fn mark_terminal_reported(&self, placement_id: &str) -> Result<(), AgentRuntimeError> {
        NativeRunnerExecutor::mark_terminal_reported(self, placement_id)
            .map_err(|_| AgentRuntimeError::PlacementStateUnavailable)
    }

    fn active_placements(&self) -> Result<BTreeSet<String>, AgentRuntimeError> {
        NativeRunnerExecutor::active_placements(self)
            .map_err(|_| AgentRuntimeError::PlacementStateUnavailable)
    }
}

impl CommandExecutor for NativeRunnerExecutor {
    fn execute_new(&mut self, command: &ControllerEnvelope) -> ExecutionResult {
        match &command.payload {
            ControllerCommand::StartPlacement { .. } => self.start_placement(command),
            ControllerCommand::CancelPlacement { placement_id } => {
                self.cancel_placement(placement_id)
            }
            ControllerCommand::SetDrain { draining } => {
                self.draining = *draining;
                ExecutionResult::Applied
            }
        }
    }

    fn reconcile_pending(&mut self, command: &ControllerEnvelope) -> ExecutionResult {
        match &command.payload {
            ControllerCommand::StartPlacement { .. } => self.reconcile_start(command),
            ControllerCommand::CancelPlacement { placement_id } => {
                self.cancel_placement(placement_id)
            }
            ControllerCommand::SetDrain { draining } => {
                self.draining = *draining;
                ExecutionResult::Applied
            }
        }
    }
}

fn map_begin_error(error: PlacementStoreError) -> ExecutionResult {
    match error {
        PlacementStoreError::PlacementConflict => {
            ExecutionResult::Rejected("placement_conflict".into())
        }
        PlacementStoreError::InvalidPlacement | PlacementStoreError::UnsupportedCommand => {
            ExecutionResult::Rejected("invalid_placement".into())
        }
        _ => ExecutionResult::Deferred("placement_state_unavailable".into()),
    }
}
