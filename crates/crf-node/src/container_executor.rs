use std::collections::BTreeSet;

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

pub struct ContainerRunnerExecutor {
    adapter: ProcessContainerAdapter,
    store: PlacementStore,
    draining: bool,
}

impl ContainerRunnerExecutor {
    pub fn new(adapter: ProcessContainerAdapter, store: PlacementStore) -> Self {
        Self {
            adapter,
            store,
            draining: false,
        }
    }

    pub fn is_draining(&self) -> bool {
        self.draining
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
        match self.adapter.call(&request) {
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
        match self.adapter.call(&inspect) {
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
                match self.adapter.call(&request) {
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
                match self.adapter.call(&request) {
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
        match self.adapter.call(&request) {
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
        for placement_id in self
            .store
            .active_placements()
            .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)?
        {
            match self
                .store
                .inspect(&placement_id)
                .map_err(|_| ContainerExecutorError::PlacementStateUnavailable)?
            {
                LocalPlacementState::IntentOnly => {
                    self.poll_intent(&placement_id)?;
                }
                LocalPlacementState::Spawned {
                    runtime: RuntimeIdentity::Container { id },
                } => {
                    self.poll_container(&placement_id, id)?;
                }
                LocalPlacementState::Spawned {
                    runtime: RuntimeIdentity::NativeProcess { .. },
                } => return Err(ContainerExecutorError::RuntimeIdentityMismatch),
                LocalPlacementState::Terminal { .. } => {}
            }
        }
        Ok(())
    }

    fn poll_intent(&self, placement_id: &str) -> Result<(), ContainerExecutorError> {
        let request = ContainerAdapterRequest::Inspect {
            placement_id: placement_id.to_owned(),
            expected_id: None,
        };
        match self
            .adapter
            .call(&request)
            .map_err(|_| ContainerExecutorError::AdapterUnavailable)?
        {
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

    fn poll_container(
        &self,
        placement_id: &str,
        expected_id: String,
    ) -> Result<(), ContainerExecutorError> {
        let request = ContainerAdapterRequest::Inspect {
            placement_id: placement_id.to_owned(),
            expected_id: Some(expected_id.clone()),
        };
        match self
            .adapter
            .call(&request)
            .map_err(|_| ContainerExecutorError::AdapterUnavailable)?
        {
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
