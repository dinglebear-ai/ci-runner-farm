use std::{
    collections::BTreeSet,
    thread,
    time::{Duration, Instant},
};

use crf_protocol::wire::{ControllerCommand, ControllerEnvelope};
use crf_protocol::{ExecutionBackend, Resources, valid_identifier};

use crate::{
    agent::{AgentRuntimeError, PlacementRuntime},
    command_processor::{CommandExecutor, ExecutionResult},
    container_adapter::{
        ContainerAdapterError, ContainerAdapterRequest, ContainerAdapterResponse,
        ProcessContainerAdapter,
    },
    placement_state::{
        LocalPlacementState, PlacementStore, PlacementStoreError, RuntimeIdentity, TerminalOutcome,
        TerminalReport,
    },
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContainerExecutorError {
    PlacementStateUnavailable,
    AdapterUnavailable,
    RuntimeIdentityMismatch,
}

const ADAPTER_BACKOFF_BASE: Duration = Duration::from_secs(1);
const ADAPTER_BACKOFF_CAP: Duration = Duration::from_secs(300);
pub const ADAPTER_BACKOFF_DETAIL_CODE: &str = "container_adapter_backoff";

/// Tracks consecutive adapter process failures so a broken container runtime
/// is probed at a bounded, exponentially decaying rate instead of on every
/// heartbeat. Without this, each retry spawns a fresh adapter process tree;
/// against a hung runtime those trees accumulate until the host exhausts
/// memory (observed as 100+ leaked nerdctl clients on a Windows node).
#[derive(Debug, Default)]
struct AdapterHealth {
    consecutive_failures: u32,
    retry_after: Option<Instant>,
}

impl AdapterHealth {
    fn in_backoff(&self) -> bool {
        self.retry_after
            .is_some_and(|deadline| Instant::now() < deadline)
    }

    fn record_failure(&mut self) {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let exponent = self.consecutive_failures.saturating_sub(1).min(16);
        let delay = ADAPTER_BACKOFF_BASE
            .saturating_mul(1u32 << exponent)
            .min(ADAPTER_BACKOFF_CAP);
        self.retry_after = Some(Instant::now() + delay);
    }

    fn record_success(&mut self) {
        self.consecutive_failures = 0;
        self.retry_after = None;
    }
}

pub struct ContainerRunnerExecutor {
    adapter: ProcessContainerAdapter,
    store: PlacementStore,
    draining: bool,
    poll_cursor: usize,
    adapter_health: AdapterHealth,
}

impl ContainerRunnerExecutor {
    pub fn new(adapter: ProcessContainerAdapter, store: PlacementStore) -> Self {
        Self {
            adapter,
            store,
            draining: false,
            poll_cursor: 0,
            adapter_health: AdapterHealth::default(),
        }
    }

    fn call_adapter(
        &mut self,
        request: &ContainerAdapterRequest,
    ) -> Result<ContainerAdapterResponse, ContainerAdapterError> {
        let result = self.adapter.call(request);
        match &result {
            Ok(_) => self.adapter_health.record_success(),
            Err(_) => self.adapter_health.record_failure(),
        }
        result
    }

    pub fn is_draining(&self) -> bool {
        self.draining
    }

    pub fn image_capabilities(&self) -> BTreeSet<String> {
        self.adapter.image_capabilities()
    }

    pub fn active_placements(&self) -> Result<BTreeSet<String>, ContainerExecutorError> {
        self.store
            .active_placements()
            .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)
    }

    pub fn reserved_resources(&self) -> Result<Resources, ContainerExecutorError> {
        self.store
            .reserved_resources()
            .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)
    }

    pub fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, ContainerExecutorError> {
        self.store
            .pending_terminal_reports()
            .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)
    }

    pub fn mark_terminal_reported(&self, placement_id: &str) -> Result<(), ContainerExecutorError> {
        self.store
            .mark_terminal_reported(placement_id)
            .and_then(|()| self.store.prune_reported(placement_id))
            .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)
    }

    pub fn placement_state(
        &self,
        placement_id: &str,
    ) -> Result<LocalPlacementState, ContainerExecutorError> {
        self.store
            .inspect(placement_id)
            .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)
    }

    fn start_placement(&mut self, command: &ControllerEnvelope) -> ExecutionResult {
        let ControllerCommand::StartPlacement {
            placement_id,
            execution_backend,
            ..
        } = &command.payload
        else {
            return ExecutionResult::Rejected("invalid_start_command".into());
        };
        if self.draining {
            return ExecutionResult::Rejected("node_draining".into());
        }
        if execution_backend != &ExecutionBackend::Container {
            return ExecutionResult::Rejected("backend_unsupported".into());
        }
        if let Err(error) = self.store.begin(command) {
            return map_begin_error(error);
        }
        let request = match ContainerAdapterRequest::start_from(command) {
            Ok(request) => request,
            Err(_) => return ExecutionResult::Rejected("invalid_container_request".into()),
        };
        if self.adapter_health.in_backoff() {
            return ExecutionResult::Deferred(ADAPTER_BACKOFF_DETAIL_CODE.into());
        }
        match self.call_adapter(&request) {
            Ok(response) => self.handle_start_response(placement_id, response),
            Err(error) => map_adapter_error(error),
        }
    }

    fn reconcile_start(&mut self, command: &ControllerEnvelope) -> ExecutionResult {
        let ControllerCommand::StartPlacement { placement_id, .. } = &command.payload else {
            return ExecutionResult::Rejected("invalid_start_command".into());
        };
        match self.store.inspect(placement_id) {
            Ok(LocalPlacementState::Spawned {
                runtime: RuntimeIdentity::Container { .. },
            }) => ExecutionResult::Applied,
            Ok(LocalPlacementState::Spawned {
                runtime: RuntimeIdentity::NativeProcess { .. },
            }) => ExecutionResult::Rejected("runtime_identity_mismatch".into()),
            Ok(LocalPlacementState::IntentOnly) => self.recover_intent_start(command, placement_id),
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

    fn recover_intent_start(
        &mut self,
        command: &ControllerEnvelope,
        placement_id: &str,
    ) -> ExecutionResult {
        let inspect = ContainerAdapterRequest::Inspect {
            placement_id: placement_id.to_owned(),
            expected_id: None,
        };
        if self.adapter_health.in_backoff() {
            return ExecutionResult::Deferred(ADAPTER_BACKOFF_DETAIL_CODE.into());
        }
        match self.call_adapter(&inspect) {
            Ok(ContainerAdapterResponse::Running { id })
            | Ok(ContainerAdapterResponse::Started { id }) => {
                self.record_container_started(placement_id, id)
            }
            Ok(ContainerAdapterResponse::Terminal { outcome }) => {
                self.record_terminal_applied(placement_id, outcome)
            }
            Ok(ContainerAdapterResponse::Cancelled) => self.record_terminal_rejected(
                placement_id,
                TerminalOutcome::Cancelled,
                "placement_cancelled",
            ),
            Ok(ContainerAdapterResponse::Rejected { detail_code }) => self
                .record_terminal_rejected(
                    placement_id,
                    TerminalOutcome::Failed {
                        detail_code: detail_code.clone(),
                    },
                    &detail_code,
                ),
            Ok(ContainerAdapterResponse::Deferred { detail_code })
                if detail_code == "container_secret_pending"
                    || detail_code == "container_start_prepared" =>
            {
                let request = match ContainerAdapterRequest::start_from(command) {
                    Ok(request) => request,
                    Err(_) => {
                        return ExecutionResult::Rejected("invalid_container_request".into());
                    }
                };
                match self.call_adapter(&request) {
                    Ok(response) => self.handle_start_response(placement_id, response),
                    Err(error) => map_adapter_error(error),
                }
            }
            Ok(ContainerAdapterResponse::Deferred { detail_code }) => {
                ExecutionResult::Deferred(detail_code)
            }
            Ok(ContainerAdapterResponse::Absent) => {
                let request = match ContainerAdapterRequest::start_from(command) {
                    Ok(request) => request,
                    Err(_) => {
                        return ExecutionResult::Rejected("invalid_container_request".into());
                    }
                };
                match self.call_adapter(&request) {
                    Ok(response) => self.handle_start_response(placement_id, response),
                    Err(error) => map_adapter_error(error),
                }
            }
            Err(error) => map_adapter_error(error),
        }
    }

    fn handle_start_response(
        &self,
        placement_id: &str,
        response: ContainerAdapterResponse,
    ) -> ExecutionResult {
        match response {
            ContainerAdapterResponse::Started { id } | ContainerAdapterResponse::Running { id } => {
                self.record_container_started(placement_id, id)
            }
            ContainerAdapterResponse::Terminal { outcome } => {
                self.record_terminal_applied(placement_id, outcome)
            }
            ContainerAdapterResponse::Rejected { detail_code } => self.record_terminal_rejected(
                placement_id,
                TerminalOutcome::Failed {
                    detail_code: detail_code.clone(),
                },
                &detail_code,
            ),
            ContainerAdapterResponse::Deferred { detail_code } => {
                ExecutionResult::Deferred(detail_code)
            }
            ContainerAdapterResponse::Absent => {
                ExecutionResult::Deferred("container_start_absent".into())
            }
            ContainerAdapterResponse::Cancelled => self.record_terminal_rejected(
                placement_id,
                TerminalOutcome::Cancelled,
                "placement_cancelled",
            ),
        }
    }

    fn record_container_started(&self, placement_id: &str, id: String) -> ExecutionResult {
        match self
            .store
            .record_runtime_started(placement_id, RuntimeIdentity::Container { id })
        {
            Ok(()) => ExecutionResult::Applied,
            Err(_) => ExecutionResult::Deferred("placement_state_unavailable".into()),
        }
    }

    fn record_terminal_applied(
        &self,
        placement_id: &str,
        outcome: TerminalOutcome,
    ) -> ExecutionResult {
        match self.store.record_terminal(placement_id, outcome) {
            Ok(()) => ExecutionResult::Applied,
            Err(_) => ExecutionResult::Deferred("placement_state_unavailable".into()),
        }
    }

    fn record_terminal_rejected(
        &self,
        placement_id: &str,
        outcome: TerminalOutcome,
        detail_code: &str,
    ) -> ExecutionResult {
        match self.store.record_terminal(placement_id, outcome) {
            Ok(()) => ExecutionResult::Rejected(detail_code.to_owned()),
            Err(_) => ExecutionResult::Deferred("placement_state_unavailable".into()),
        }
    }
}

impl ContainerRunnerExecutor {
    fn cancel_placement(&mut self, placement_id: &str) -> ExecutionResult {
        if !valid_identifier(placement_id) {
            return ExecutionResult::Rejected("invalid_placement_id".into());
        }
        let expected_id = match self.store.inspect(placement_id) {
            Ok(LocalPlacementState::Terminal { .. }) => return ExecutionResult::Applied,
            Ok(LocalPlacementState::IntentOnly) => None,
            Ok(LocalPlacementState::Spawned {
                runtime: RuntimeIdentity::Container { id },
            }) => Some(id),
            Ok(LocalPlacementState::Spawned {
                runtime: RuntimeIdentity::NativeProcess { .. },
            }) => return ExecutionResult::Rejected("runtime_identity_mismatch".into()),
            Err(_) => return ExecutionResult::Deferred("placement_state_unavailable".into()),
        };
        let request = ContainerAdapterRequest::Cancel {
            placement_id: placement_id.to_owned(),
            expected_id,
        };
        if self.adapter_health.in_backoff() {
            return ExecutionResult::Deferred(ADAPTER_BACKOFF_DETAIL_CODE.into());
        }
        match self.call_adapter(&request) {
            Ok(ContainerAdapterResponse::Cancelled) | Ok(ContainerAdapterResponse::Absent) => {
                self.record_terminal_applied(placement_id, TerminalOutcome::Cancelled)
            }
            Ok(ContainerAdapterResponse::Terminal { outcome }) => {
                self.record_terminal_applied(placement_id, outcome)
            }
            Ok(ContainerAdapterResponse::Deferred { detail_code }) => {
                ExecutionResult::Deferred(detail_code)
            }
            Ok(ContainerAdapterResponse::Rejected { detail_code }) => {
                ExecutionResult::Rejected(detail_code)
            }
            Ok(ContainerAdapterResponse::Running { .. })
            | Ok(ContainerAdapterResponse::Started { .. }) => {
                ExecutionResult::Deferred("container_cancel_uncertain".into())
            }
            Err(error) => map_adapter_error(error),
        }
    }

    pub fn poll_runtime_state(&mut self) -> Result<(), ContainerExecutorError> {
        const MAX_CONCURRENT_POLLS: usize = 8;
        let placements: Vec<_> = self
            .store
            .active_placements()
            .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)?
            .into_iter()
            .collect();
        if placements.is_empty() {
            self.poll_cursor = 0;
            return Ok(());
        }
        if self.adapter_health.in_backoff() {
            // The adapter recently failed; skip this poll cycle entirely so a
            // broken runtime is not probed with a fresh process tree on every
            // heartbeat. Still report the backend as unavailable so the
            // session stays visibly degraded until a probe succeeds.
            return Err(ContainerExecutorError::AdapterUnavailable);
        }
        let start = self.poll_cursor % placements.len();
        let selected: Vec<_> = (0..placements.len().min(MAX_CONCURRENT_POLLS))
            .map(|offset| placements[(start + offset) % placements.len()].clone())
            .collect();
        self.poll_cursor = (start + selected.len()) % placements.len();

        let mut requests = Vec::with_capacity(selected.len());
        for placement_id in selected {
            let expected_id = match self
                .store
                .inspect(&placement_id)
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)?
            {
                LocalPlacementState::IntentOnly => None,
                LocalPlacementState::Spawned {
                    runtime: RuntimeIdentity::Container { id },
                } => Some(id),
                LocalPlacementState::Spawned {
                    runtime: RuntimeIdentity::NativeProcess { .. },
                } => return Err(ContainerExecutorError::RuntimeIdentityMismatch),
                LocalPlacementState::Terminal { .. } => continue,
            };
            requests.push((placement_id, expected_id));
        }

        let handles: Vec<_> = requests
            .into_iter()
            .map(|(placement_id, expected_id)| {
                let adapter = self.adapter.clone();
                thread::spawn(move || {
                    let request = ContainerAdapterRequest::Inspect {
                        placement_id: placement_id.clone(),
                        expected_id: expected_id.clone(),
                    };
                    (placement_id, expected_id, adapter.call(&request))
                })
            })
            .collect();
        let mut adapter_failed = false;
        let mut adapter_succeeded = false;
        for handle in handles {
            let (placement_id, expected_id, response) = handle
                .join()
                .map_err(|_| ContainerExecutorError::AdapterUnavailable)?;
            match response {
                Ok(response) => {
                    adapter_succeeded = true;
                    self.apply_poll_response(&placement_id, expected_id, response)?;
                }
                Err(_) => adapter_failed = true,
            }
        }
        if adapter_failed {
            self.adapter_health.record_failure();
            Err(ContainerExecutorError::AdapterUnavailable)
        } else {
            if adapter_succeeded {
                self.adapter_health.record_success();
            }
            Ok(())
        }
    }

    fn apply_poll_response(
        &self,
        placement_id: &str,
        expected_id: Option<String>,
        response: ContainerAdapterResponse,
    ) -> Result<(), ContainerExecutorError> {
        match expected_id {
            Some(id) => self.apply_container_response(placement_id, id, response),
            None => self.apply_intent_response(placement_id, response),
        }
    }

    fn apply_intent_response(
        &self,
        placement_id: &str,
        response: ContainerAdapterResponse,
    ) -> Result<(), ContainerExecutorError> {
        match response {
            ContainerAdapterResponse::Running { id } | ContainerAdapterResponse::Started { id } => {
                self.store
                    .record_runtime_started(placement_id, RuntimeIdentity::Container { id })
                    .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)
            }
            ContainerAdapterResponse::Terminal { outcome } => self
                .store
                .record_terminal(placement_id, outcome)
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable),
            ContainerAdapterResponse::Cancelled => self
                .store
                .record_terminal(placement_id, TerminalOutcome::Cancelled)
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable),
            ContainerAdapterResponse::Rejected { detail_code } => self
                .store
                .record_terminal(placement_id, TerminalOutcome::Failed { detail_code })
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable),
            ContainerAdapterResponse::Absent | ContainerAdapterResponse::Deferred { .. } => Ok(()),
        }
    }

    fn apply_container_response(
        &self,
        placement_id: &str,
        expected_id: String,
        response: ContainerAdapterResponse,
    ) -> Result<(), ContainerExecutorError> {
        match response {
            ContainerAdapterResponse::Running { id } | ContainerAdapterResponse::Started { id } => {
                if id == expected_id {
                    Ok(())
                } else {
                    Err(ContainerExecutorError::RuntimeIdentityMismatch)
                }
            }
            ContainerAdapterResponse::Terminal { outcome } => self
                .store
                .record_terminal(placement_id, outcome)
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable),
            ContainerAdapterResponse::Absent => self
                .store
                .record_terminal(
                    placement_id,
                    TerminalOutcome::Failed {
                        detail_code: "container_lost".into(),
                    },
                )
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable),
            ContainerAdapterResponse::Cancelled => self
                .store
                .record_terminal(placement_id, TerminalOutcome::Cancelled)
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable),
            ContainerAdapterResponse::Rejected { detail_code } => self
                .store
                .record_terminal(placement_id, TerminalOutcome::Failed { detail_code })
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable),
            ContainerAdapterResponse::Deferred { .. } => Ok(()),
        }
    }
}

impl PlacementRuntime for ContainerRunnerExecutor {
    fn poll_runtime(&mut self) -> Result<(), AgentRuntimeError> {
        self.poll_runtime_state().map_err(|error| match error {
            ContainerExecutorError::AdapterUnavailable => AgentRuntimeError::PollFailed,
            ContainerExecutorError::PlacementStateUnavailable
            | ContainerExecutorError::RuntimeIdentityMismatch => {
                AgentRuntimeError::PlacementStateUnavailable
            }
        })
    }

    fn reserved_resources(&self) -> Result<Resources, AgentRuntimeError> {
        ContainerRunnerExecutor::reserved_resources(self)
            .map_err(|_| AgentRuntimeError::PlacementStateUnavailable)
    }

    fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, AgentRuntimeError> {
        ContainerRunnerExecutor::pending_terminal_reports(self)
            .map_err(|_| AgentRuntimeError::PlacementStateUnavailable)
    }

    fn mark_terminal_reported(&self, placement_id: &str) -> Result<(), AgentRuntimeError> {
        ContainerRunnerExecutor::mark_terminal_reported(self, placement_id)
            .map_err(|_| AgentRuntimeError::PlacementStateUnavailable)
    }

    fn active_placements(&self) -> Result<BTreeSet<String>, AgentRuntimeError> {
        ContainerRunnerExecutor::active_placements(self)
            .map_err(|_| AgentRuntimeError::PlacementStateUnavailable)
    }
}

impl CommandExecutor for ContainerRunnerExecutor {
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

fn map_adapter_error(error: ContainerAdapterError) -> ExecutionResult {
    match error {
        ContainerAdapterError::UnsupportedCommand
        | ContainerAdapterError::UnsupportedBackend
        | ContainerAdapterError::InvalidRequest
        | ContainerAdapterError::RequestTooLarge => {
            ExecutionResult::Rejected("invalid_container_request".into())
        }
        ContainerAdapterError::InvalidProgram | ContainerAdapterError::InvalidTimeout => {
            ExecutionResult::Rejected("container_adapter_invalid".into())
        }
        ContainerAdapterError::SpawnFailed
        | ContainerAdapterError::StdinUnavailable
        | ContainerAdapterError::StdoutUnavailable
        | ContainerAdapterError::WriteFailed
        | ContainerAdapterError::PollFailed
        | ContainerAdapterError::TimedOut
        | ContainerAdapterError::ProcessFailed
        | ContainerAdapterError::ResponseTooLarge
        | ContainerAdapterError::ReadFailed
        | ContainerAdapterError::InvalidResponse => {
            ExecutionResult::Deferred("container_adapter_uncertain".into())
        }
    }
}
