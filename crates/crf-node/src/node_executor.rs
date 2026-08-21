use std::collections::BTreeSet;

use crf_protocol::wire::ControllerEnvelope;
use crf_protocol::{ExecutionBackend, Resources};

use crate::{
    agent::{AgentRuntimeError, PlacementRuntime},
    command_processor::{CommandExecutor, ExecutionResult},
    container_executor::ContainerRunnerExecutor,
    native_executor::NativeRunnerExecutor,
    placement_state::TerminalReport,
};

pub enum NodeExecutor {
    Native(Box<NativeRunnerExecutor>),
    Container(ContainerRunnerExecutor),
}

impl NodeExecutor {
    pub fn execution_backend(&self) -> ExecutionBackend {
        match self {
            Self::Native(_) => ExecutionBackend::NativeProcess,
            Self::Container(_) => ExecutionBackend::Container,
        }
    }

    pub fn capabilities(&self) -> BTreeSet<String> {
        match self {
            Self::Native(_) => BTreeSet::from(["github-actions".into(), "native-process".into()]),
            Self::Container(_) => BTreeSet::from(["github-actions".into(), "container".into()]),
        }
    }
}

impl CommandExecutor for NodeExecutor {
    fn execute_new(&mut self, command: &ControllerEnvelope) -> ExecutionResult {
        match self {
            Self::Native(executor) => executor.execute_new(command),
            Self::Container(executor) => executor.execute_new(command),
        }
    }

    fn reconcile_pending(&mut self, command: &ControllerEnvelope) -> ExecutionResult {
        match self {
            Self::Native(executor) => executor.reconcile_pending(command),
            Self::Container(executor) => executor.reconcile_pending(command),
        }
    }
}

impl PlacementRuntime for NodeExecutor {
    fn poll_runtime(&mut self) -> Result<(), AgentRuntimeError> {
        match self {
            Self::Native(executor) => executor.poll_runtime(),
            Self::Container(executor) => executor.poll_runtime(),
        }
    }

    fn reserved_resources(&self) -> Result<Resources, AgentRuntimeError> {
        match self {
            Self::Native(executor) => PlacementRuntime::reserved_resources(executor.as_ref()),
            Self::Container(executor) => PlacementRuntime::reserved_resources(executor),
        }
    }

    fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, AgentRuntimeError> {
        match self {
            Self::Native(executor) => PlacementRuntime::pending_terminal_reports(executor.as_ref()),
            Self::Container(executor) => PlacementRuntime::pending_terminal_reports(executor),
        }
    }

    fn mark_terminal_reported(&self, placement_id: &str) -> Result<(), AgentRuntimeError> {
        match self {
            Self::Native(executor) => {
                PlacementRuntime::mark_terminal_reported(executor.as_ref(), placement_id)
            }
            Self::Container(executor) => {
                PlacementRuntime::mark_terminal_reported(executor, placement_id)
            }
        }
    }

    fn active_placements(&self) -> Result<BTreeSet<String>, AgentRuntimeError> {
        match self {
            Self::Native(executor) => PlacementRuntime::active_placements(executor.as_ref()),
            Self::Container(executor) => PlacementRuntime::active_placements(executor),
        }
    }
}
