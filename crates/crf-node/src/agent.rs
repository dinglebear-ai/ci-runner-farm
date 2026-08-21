use std::collections::BTreeSet;

use crf_protocol::wire::{
    ControllerEnvelope, MessageResponseStatus, NodeEnvelope, NodeMessage, NodeMessageResponse,
    PROTOCOL_VERSION, PlacementState, WireError,
};
use crf_protocol::{NodeSnapshot, Resources, ValidationError};

use crate::{
    command_ledger::CommittedAck,
    command_processor::{CommandExecutor, CommandProcessor, ProcessDecision},
    placement_state::{TerminalOutcome, TerminalReport},
    transport::{NodeTransportError, TlsSession},
};

const MAX_IMMEDIATE_ACK_CHAIN: usize = 32;
const MAX_TERMINAL_REPORT_BATCH: usize = 32;

pub trait NodeExchange {
    type Error;

    fn exchange(
        &mut self,
        request: &NodeEnvelope,
        now_unix_ms: u64,
    ) -> Result<NodeMessageResponse, Self::Error>;
}

impl NodeExchange for TlsSession {
    type Error = NodeTransportError;

    fn exchange(
        &mut self,
        request: &NodeEnvelope,
        now_unix_ms: u64,
    ) -> Result<NodeMessageResponse, Self::Error> {
        TlsSession::exchange(self, request, now_unix_ms)
    }
}

pub trait PlacementRuntime {
    fn poll_runtime(&mut self) -> Result<(), AgentRuntimeError>;
    fn reserved_resources(&self) -> Result<Resources, AgentRuntimeError>;
    fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, AgentRuntimeError>;
    fn mark_terminal_reported(&self, placement_id: &str) -> Result<(), AgentRuntimeError>;
    fn active_placements(&self) -> Result<BTreeSet<String>, AgentRuntimeError>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentRuntimeError {
    PollFailed,
    PlacementStateUnavailable,
    ReservedResourcesExceedTotal,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentError {
    InvalidNode(ValidationError),
    InvalidAgentVersion,
    InvalidTimestamp,
    AvailableExceedsTotal,
    InvalidMessage(WireError),
    SequenceExhausted,
    ControllerRejected { code: String },
    CommandIdentityMismatch,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentAction {
    None,
    Send(NodeEnvelope),
    Deferred {
        command_id: String,
        detail_code: String,
    },
}

pub struct AgentCore<E> {
    node: NodeSnapshot,
    agent_version: String,
    sequence: u64,
    processor: CommandProcessor<E>,
}

impl<E: CommandExecutor> AgentCore<E> {
    pub fn new(
        node: NodeSnapshot,
        agent_version: impl Into<String>,
        processor: CommandProcessor<E>,
    ) -> Result<Self, AgentError> {
        node.validate().map_err(AgentError::InvalidNode)?;
        let agent_version = agent_version.into();
        if !valid_agent_version(&agent_version) {
            return Err(AgentError::InvalidAgentVersion);
        }
        Ok(Self {
            node,
            agent_version,
            sequence: 0,
            processor,
        })
    }

    pub fn registration(&mut self, sent_at_unix_ms: u64) -> Result<NodeEnvelope, AgentError> {
        if sent_at_unix_ms == 0 {
            return Err(AgentError::InvalidTimestamp);
        }
        self.message(
            sent_at_unix_ms,
            NodeMessage::Register {
                node: self.node.clone(),
                agent_version: self.agent_version.clone(),
            },
        )
    }

    pub fn heartbeat(
        &mut self,
        available: Resources,
        active_placements: BTreeSet<String>,
        sent_at_unix_ms: u64,
    ) -> Result<NodeEnvelope, AgentError> {
        if sent_at_unix_ms == 0 {
            return Err(AgentError::InvalidTimestamp);
        }
        if !self.node.total.fits(available) {
            return Err(AgentError::AvailableExceedsTotal);
        }
        self.node.available = available;
        self.message(
            sent_at_unix_ms,
            NodeMessage::Heartbeat {
                available,
                active_placements,
            },
        )
    }

    pub fn handle_response(
        &mut self,
        response: &NodeMessageResponse,
        now_unix_ms: u64,
    ) -> Result<AgentAction, AgentError> {
        response
            .validate(now_unix_ms)
            .map_err(AgentError::InvalidMessage)?;

        if response.status == MessageResponseStatus::Rejected {
            return Err(AgentError::ControllerRejected {
                code: response
                    .code
                    .clone()
                    .unwrap_or_else(|| "controller_rejected".into()),
            });
        }

        let Some(command) = &response.command else {
            return Ok(AgentAction::None);
        };
        if command.node_id != self.node.node_id || command.node_generation != self.node.generation {
            return Err(AgentError::CommandIdentityMismatch);
        }

        match self.processor.process(command, now_unix_ms) {
            ProcessDecision::Ack(ack) => Ok(AgentAction::Send(self.ack_message(
                command,
                ack,
                now_unix_ms,
            )?)),
            ProcessDecision::Deferred { detail_code } => Ok(AgentAction::Deferred {
                command_id: command.command_id.clone(),
                detail_code,
            }),
        }
    }

    pub fn placement_update(
        &mut self,
        report: &TerminalReport,
        sent_at_unix_ms: u64,
    ) -> Result<NodeEnvelope, AgentError> {
        if sent_at_unix_ms == 0 {
            return Err(AgentError::InvalidTimestamp);
        }
        let (state, detail_code) = match &report.outcome {
            TerminalOutcome::Finished => (PlacementState::Finished, None),
            TerminalOutcome::Failed { detail_code } => {
                (PlacementState::Failed, Some(detail_code.clone()))
            }
            TerminalOutcome::Cancelled => (PlacementState::Cancelled, None),
        };
        self.message(
            sent_at_unix_ms,
            NodeMessage::PlacementUpdate {
                placement_id: report.placement_id.clone(),
                command_id: report.command_id.clone(),
                state,
                detail_code,
            },
        )
    }

    pub fn node(&self) -> &NodeSnapshot {
        &self.node
    }

    pub fn processor(&self) -> &CommandProcessor<E> {
        &self.processor
    }

    pub fn processor_mut(&mut self) -> &mut CommandProcessor<E> {
        &mut self.processor
    }

    fn ack_message(
        &mut self,
        command: &ControllerEnvelope,
        ack: CommittedAck,
        sent_at_unix_ms: u64,
    ) -> Result<NodeEnvelope, AgentError> {
        self.message(
            sent_at_unix_ms,
            NodeMessage::CommandAck {
                command_id: command.command_id.clone(),
                idempotency_key: command.idempotency_key.clone(),
                status: ack.status,
                detail_code: ack.detail_code,
            },
        )
    }

    fn message(
        &mut self,
        sent_at_unix_ms: u64,
        payload: NodeMessage,
    ) -> Result<NodeEnvelope, AgentError> {
        let sequence = self
            .sequence
            .checked_add(1)
            .ok_or(AgentError::SequenceExhausted)?;
        let message = NodeEnvelope {
            protocol_version: PROTOCOL_VERSION,
            message_id: format!("msg-{}-{sequence}", self.node.generation),
            node_id: self.node.node_id.clone(),
            node_generation: self.node.generation,
            sent_at_unix_ms,
            payload,
        };
        message.validate().map_err(AgentError::InvalidMessage)?;
        self.sequence = sequence;
        Ok(message)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionOutcome {
    pub immediate_acks: usize,
    pub deferred: Option<(String, String)>,
    pub operator_projection: Option<serde_json::Value>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimeSyncOutcome {
    pub reports_sent: usize,
    pub immediate_acks: usize,
    pub deferred_commands: Vec<(String, String)>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeHeartbeatOutcome {
    pub terminal_sync: RuntimeSyncOutcome,
    pub heartbeat: SessionOutcome,
}

#[derive(Debug)]
pub enum AgentSessionError<T> {
    Agent(AgentError),
    Runtime(AgentRuntimeError),
    Transport(T),
    ImmediateAckLimit,
}

pub struct AgentSession<T, E> {
    transport: T,
    core: AgentCore<E>,
}

impl<T, E> AgentSession<T, E>
where
    T: NodeExchange,
    E: CommandExecutor,
{
    pub fn new(transport: T, core: AgentCore<E>) -> Self {
        Self { transport, core }
    }

    pub fn register(
        &mut self,
        now_unix_ms: u64,
    ) -> Result<SessionOutcome, AgentSessionError<T::Error>> {
        let request = self
            .core
            .registration(now_unix_ms)
            .map_err(AgentSessionError::Agent)?;
        self.exchange_and_drain(request, now_unix_ms)
    }

    pub fn heartbeat(
        &mut self,
        available: Resources,
        active_placements: BTreeSet<String>,
        now_unix_ms: u64,
    ) -> Result<SessionOutcome, AgentSessionError<T::Error>> {
        let request = self
            .core
            .heartbeat(available, active_placements, now_unix_ms)
            .map_err(AgentSessionError::Agent)?;
        self.exchange_and_drain(request, now_unix_ms)
    }

    pub fn core(&self) -> &AgentCore<E> {
        &self.core
    }

    pub fn core_mut(&mut self) -> &mut AgentCore<E> {
        &mut self.core
    }

    pub fn transport(&self) -> &T {
        &self.transport
    }

    pub fn into_core(self) -> AgentCore<E> {
        self.core
    }

    fn exchange_and_drain(
        &mut self,
        mut request: NodeEnvelope,
        now_unix_ms: u64,
    ) -> Result<SessionOutcome, AgentSessionError<T::Error>> {
        let mut immediate_acks = 0_usize;
        let mut operator_projection = None;
        loop {
            let response = self
                .transport
                .exchange(&request, now_unix_ms)
                .map_err(AgentSessionError::Transport)?;
            if response.operator_projection.is_some() {
                operator_projection = response.operator_projection.clone();
            }
            match self
                .core
                .handle_response(&response, now_unix_ms)
                .map_err(AgentSessionError::Agent)?
            {
                AgentAction::None => {
                    return Ok(SessionOutcome {
                        immediate_acks,
                        deferred: None,
                        operator_projection,
                    });
                }
                AgentAction::Deferred {
                    command_id,
                    detail_code,
                } => {
                    return Ok(SessionOutcome {
                        immediate_acks,
                        deferred: Some((command_id, detail_code)),
                        operator_projection,
                    });
                }
                AgentAction::Send(ack) => {
                    immediate_acks = immediate_acks.saturating_add(1);
                    if immediate_acks > MAX_IMMEDIATE_ACK_CHAIN {
                        return Err(AgentSessionError::ImmediateAckLimit);
                    }
                    request = ack;
                }
            }
        }
    }
}

impl<T, E> AgentSession<T, E>
where
    T: NodeExchange,
    E: CommandExecutor + PlacementRuntime,
{
    pub fn sync_runtime(
        &mut self,
        now_unix_ms: u64,
    ) -> Result<RuntimeSyncOutcome, AgentSessionError<T::Error>> {
        self.core
            .processor_mut()
            .executor_mut()
            .poll_runtime()
            .map_err(AgentSessionError::Runtime)?;

        let reports = self
            .core
            .processor()
            .executor()
            .pending_terminal_reports()
            .map_err(AgentSessionError::Runtime)?;
        let mut outcome = RuntimeSyncOutcome::default();

        for report in reports.into_iter().take(MAX_TERMINAL_REPORT_BATCH) {
            let request = self
                .core
                .placement_update(&report, now_unix_ms)
                .map_err(AgentSessionError::Agent)?;
            let report_outcome = self.exchange_and_drain(request, now_unix_ms)?;

            self.core
                .processor()
                .executor()
                .mark_terminal_reported(&report.placement_id)
                .map_err(AgentSessionError::Runtime)?;

            outcome.reports_sent = outcome.reports_sent.saturating_add(1);
            outcome.immediate_acks = outcome
                .immediate_acks
                .saturating_add(report_outcome.immediate_acks);
            if let Some(deferred) = report_outcome.deferred {
                outcome.deferred_commands.push(deferred);
            }
        }

        Ok(outcome)
    }

    pub fn runtime_heartbeat(
        &mut self,
        now_unix_ms: u64,
    ) -> Result<RuntimeHeartbeatOutcome, AgentSessionError<T::Error>> {
        let terminal_sync = self.sync_runtime(now_unix_ms)?;
        let active_placements = self
            .core
            .processor()
            .executor()
            .active_placements()
            .map_err(AgentSessionError::Runtime)?;
        let reserved = self
            .core
            .processor()
            .executor()
            .reserved_resources()
            .map_err(AgentSessionError::Runtime)?;
        let mut available = self.core.node().total;
        if !available.subtract(reserved) {
            return Err(AgentSessionError::Runtime(
                AgentRuntimeError::ReservedResourcesExceedTotal,
            ));
        }
        let heartbeat = self.heartbeat(available, active_placements, now_unix_ms)?;
        Ok(RuntimeHeartbeatOutcome {
            terminal_sync,
            heartbeat,
        })
    }
}

fn valid_agent_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '+'))
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeSet, VecDeque};

    use crf_protocol::wire::{CommandAckStatus, ControllerCommand, SecretString};
    use crf_protocol::{Architecture, ExecutionBackend, OperatingSystem};

    use crate::{command_ledger::CommandLedger, command_processor::ExecutionResult};

    use super::*;

    const GIB: u64 = 1024 * 1024 * 1024;
    const NOW: u64 = 1_787_070_001_000;

    struct FakeExecutor {
        new_result: ExecutionResult,
        pending_result: ExecutionResult,
    }

    impl CommandExecutor for FakeExecutor {
        fn execute_new(&mut self, _command: &ControllerEnvelope) -> ExecutionResult {
            self.new_result.clone()
        }

        fn reconcile_pending(&mut self, _command: &ControllerEnvelope) -> ExecutionResult {
            self.pending_result.clone()
        }
    }

    struct FakeTransport {
        responses: VecDeque<NodeMessageResponse>,
        requests: Vec<NodeEnvelope>,
    }

    impl NodeExchange for FakeTransport {
        type Error = &'static str;

        fn exchange(
            &mut self,
            request: &NodeEnvelope,
            _now_unix_ms: u64,
        ) -> Result<NodeMessageResponse, Self::Error> {
            self.requests.push(request.clone());
            self.responses.pop_front().ok_or("missing_response")
        }
    }

    fn node() -> NodeSnapshot {
        NodeSnapshot {
            node_id: "dookie".into(),
            generation: 7,
            os: OperatingSystem::Linux,
            arch: Architecture::X86_64,
            execution_backends: BTreeSet::from([ExecutionBackend::Container]),
            capabilities: BTreeSet::from(["github-actions".into(), "x64".into()]),
            total: Resources::new(8_000, 16 * GIB),
            available: Resources::new(8_000, 16 * GIB),
            draining: false,
        }
    }

    fn command() -> ControllerEnvelope {
        ControllerEnvelope {
            protocol_version: PROTOCOL_VERSION,
            command_id: "command-1".into(),
            idempotency_key: "idempotency-1".into(),
            node_id: "dookie".into(),
            node_generation: 7,
            issued_at_unix_ms: NOW - 1_000,
            expires_at_unix_ms: NOW + 30_000,
            payload: ControllerCommand::StartPlacement {
                placement_id: "placement-1".into(),
                work_id: "work-1".into(),
                pool_id: "build".into(),
                runner_name: "crf-dookie-1".into(),
                resources: Resources::new(2_000, 4 * GIB),
                execution_backend: ExecutionBackend::Container,
                jit_config: SecretString::new("jit-config-abc123==").expect("secret"),
            },
        }
    }

    fn response(message_id: &str, command: Option<ControllerEnvelope>) -> NodeMessageResponse {
        NodeMessageResponse {
            protocol_version: PROTOCOL_VERSION,
            message_id: message_id.into(),
            status: MessageResponseStatus::Accepted,
            code: None,
            command,
            operator_projection: None,
        }
    }

    fn session(
        executor: FakeExecutor,
        responses: Vec<NodeMessageResponse>,
    ) -> AgentSession<FakeTransport, FakeExecutor> {
        let processor = CommandProcessor::new(
            CommandLedger::new("dookie", 7, 16).expect("ledger"),
            executor,
        );
        let core = AgentCore::new(node(), "0.1.0", processor).expect("agent core");
        AgentSession::new(
            FakeTransport {
                responses: responses.into(),
                requests: Vec::new(),
            },
            core,
        )
    }

    #[test]
    fn heartbeat_executes_attached_command_and_immediately_acks_it() {
        let executor = FakeExecutor {
            new_result: ExecutionResult::Applied,
            pending_result: ExecutionResult::Applied,
        };
        let mut session = session(
            executor,
            vec![
                response("msg-7-1", Some(command())),
                response("msg-7-2", None),
            ],
        );

        let outcome = session
            .heartbeat(Resources::new(8_000, 16 * GIB), BTreeSet::new(), NOW)
            .expect("heartbeat succeeds");
        assert_eq!(outcome.immediate_acks, 1);
        assert_eq!(outcome.deferred, None);
        assert_eq!(session.transport().requests.len(), 2);
        assert!(matches!(
            session.transport().requests[0].payload,
            NodeMessage::Heartbeat { .. }
        ));
        match &session.transport().requests[1].payload {
            NodeMessage::CommandAck {
                command_id,
                status,
                detail_code,
                ..
            } => {
                assert_eq!(command_id, "command-1");
                assert_eq!(*status, CommandAckStatus::Accepted);
                assert_eq!(detail_code, &None);
            }
            other => panic!("expected command ack, got {other:?}"),
        }
    }

    #[test]
    fn heartbeat_returns_latest_authenticated_operator_projection() {
        let executor = FakeExecutor {
            new_result: ExecutionResult::Applied,
            pending_result: ExecutionResult::Applied,
        };
        let projection = serde_json::json!({"schema_version": 1, "nodes": []});
        let mut projected = response("msg-7-1", None);
        projected.operator_projection = Some(projection.clone());
        let mut session = session(executor, vec![projected]);

        let outcome = session
            .heartbeat(Resources::new(8_000, 16 * GIB), BTreeSet::new(), NOW)
            .expect("heartbeat succeeds");

        assert_eq!(outcome.operator_projection, Some(projection));
    }

    #[test]
    fn deferred_execution_leaves_command_unacked_for_future_reconciliation() {
        let executor = FakeExecutor {
            new_result: ExecutionResult::Deferred("start_uncertain".into()),
            pending_result: ExecutionResult::Applied,
        };
        let mut session = session(executor, vec![response("msg-7-1", Some(command()))]);

        let outcome = session
            .heartbeat(Resources::new(8_000, 16 * GIB), BTreeSet::new(), NOW)
            .expect("heartbeat succeeds");
        assert_eq!(outcome.immediate_acks, 0);
        assert_eq!(
            outcome.deferred,
            Some(("command-1".into(), "start_uncertain".into()))
        );
        assert_eq!(session.transport().requests.len(), 1);
        assert_eq!(
            session.core().processor().ledger().len(),
            1,
            "prepared command stays in ledger"
        );
    }

    #[test]
    fn controller_rejection_is_not_treated_as_success() {
        let executor = FakeExecutor {
            new_result: ExecutionResult::Applied,
            pending_result: ExecutionResult::Applied,
        };
        let mut rejected = response("msg-7-1", None);
        rejected.status = MessageResponseStatus::Rejected;
        rejected.code = Some("node_not_registered".into());
        let mut session = session(executor, vec![rejected]);

        assert!(matches!(
            session.heartbeat(Resources::new(8_000, 16 * GIB), BTreeSet::new(), NOW),
            Err(AgentSessionError::Agent(AgentError::ControllerRejected { ref code }))
                if code == "node_not_registered"
        ));
    }

    #[test]
    fn heartbeat_never_advertises_more_resources_than_node_total() {
        let executor = FakeExecutor {
            new_result: ExecutionResult::Applied,
            pending_result: ExecutionResult::Applied,
        };
        let mut session = session(executor, vec![]);

        assert!(matches!(
            session.heartbeat(Resources::new(9_000, 16 * GIB), BTreeSet::new(), NOW),
            Err(AgentSessionError::Agent(AgentError::AvailableExceedsTotal))
        ));
    }

    struct RuntimeExecutor {
        reports: Vec<TerminalReport>,
        reported: BTreeSet<String>,
        active: BTreeSet<String>,
        reserved: Resources,
        poll_calls: usize,
    }

    impl CommandExecutor for RuntimeExecutor {
        fn execute_new(&mut self, _command: &ControllerEnvelope) -> ExecutionResult {
            ExecutionResult::Applied
        }

        fn reconcile_pending(&mut self, _command: &ControllerEnvelope) -> ExecutionResult {
            ExecutionResult::Applied
        }
    }

    impl PlacementRuntime for RuntimeExecutor {
        fn poll_runtime(&mut self) -> Result<(), AgentRuntimeError> {
            self.poll_calls += 1;
            Ok(())
        }

        fn reserved_resources(&self) -> Result<Resources, AgentRuntimeError> {
            Ok(self.reserved)
        }

        fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, AgentRuntimeError> {
            Ok(self
                .reports
                .iter()
                .filter(|report| !self.reported.contains(&report.placement_id))
                .cloned()
                .collect())
        }

        fn mark_terminal_reported(&self, _placement_id: &str) -> Result<(), AgentRuntimeError> {
            unreachable!("runtime test uses interior mark helper")
        }

        fn active_placements(&self) -> Result<BTreeSet<String>, AgentRuntimeError> {
            Ok(self.active.clone())
        }
    }

    struct SharedRuntimeExecutor {
        inner: std::sync::Arc<std::sync::Mutex<RuntimeExecutor>>,
    }

    impl CommandExecutor for SharedRuntimeExecutor {
        fn execute_new(&mut self, _command: &ControllerEnvelope) -> ExecutionResult {
            ExecutionResult::Applied
        }

        fn reconcile_pending(&mut self, _command: &ControllerEnvelope) -> ExecutionResult {
            ExecutionResult::Applied
        }
    }

    impl PlacementRuntime for SharedRuntimeExecutor {
        fn poll_runtime(&mut self) -> Result<(), AgentRuntimeError> {
            self.inner.lock().expect("runtime lock").poll_calls += 1;
            Ok(())
        }

        fn reserved_resources(&self) -> Result<Resources, AgentRuntimeError> {
            Ok(self.inner.lock().expect("runtime lock").reserved)
        }

        fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, AgentRuntimeError> {
            let runtime = self.inner.lock().expect("runtime lock");
            Ok(runtime
                .reports
                .iter()
                .filter(|report| !runtime.reported.contains(&report.placement_id))
                .cloned()
                .collect())
        }

        fn mark_terminal_reported(&self, placement_id: &str) -> Result<(), AgentRuntimeError> {
            self.inner
                .lock()
                .expect("runtime lock")
                .reported
                .insert(placement_id.to_owned());
            Ok(())
        }

        fn active_placements(&self) -> Result<BTreeSet<String>, AgentRuntimeError> {
            Ok(self.inner.lock().expect("runtime lock").active.clone())
        }
    }

    fn terminal_report() -> TerminalReport {
        TerminalReport {
            placement_id: "placement-1".into(),
            command_id: "command-1".into(),
            outcome: TerminalOutcome::Finished,
        }
    }

    fn runtime_session(
        responses: Vec<NodeMessageResponse>,
    ) -> (
        AgentSession<FakeTransport, SharedRuntimeExecutor>,
        std::sync::Arc<std::sync::Mutex<RuntimeExecutor>>,
    ) {
        let state = std::sync::Arc::new(std::sync::Mutex::new(RuntimeExecutor {
            reports: vec![terminal_report()],
            reported: BTreeSet::new(),
            active: BTreeSet::new(),
            reserved: Resources::default(),
            poll_calls: 0,
        }));
        let executor = SharedRuntimeExecutor {
            inner: state.clone(),
        };
        let processor = CommandProcessor::new(
            CommandLedger::new("dookie", 7, 16).expect("ledger"),
            executor,
        );
        let core = AgentCore::new(node(), "0.1.0", processor).expect("agent core");
        (
            AgentSession::new(
                FakeTransport {
                    responses: responses.into(),
                    requests: Vec::new(),
                },
                core,
            ),
            state,
        )
    }

    #[test]
    fn terminal_report_transport_failure_keeps_report_pending() {
        let (mut session, state) = runtime_session(vec![]);

        assert!(matches!(
            session.sync_runtime(NOW),
            Err(AgentSessionError::Transport("missing_response"))
        ));
        let state = state.lock().expect("runtime lock");
        assert!(state.reported.is_empty());
        assert_eq!(state.poll_calls, 1);
        assert_eq!(session.transport().requests.len(), 1);
        assert!(matches!(
            session.transport().requests[0].payload,
            NodeMessage::PlacementUpdate {
                state: PlacementState::Finished,
                ..
            }
        ));
    }

    #[test]
    fn runtime_heartbeat_subtracts_durable_reserved_resources() {
        let (mut session, state) = runtime_session(vec![response("msg-7-1", None)]);
        {
            let mut state = state.lock().expect("runtime lock");
            state.reports.clear();
            state.reserved = Resources::new(2_000, 4 * GIB);
            state.active = BTreeSet::from(["placement-1".into()]);
        }

        session.runtime_heartbeat(NOW).expect("heartbeat");
        assert_eq!(session.transport().requests.len(), 1);
        assert!(matches!(
            &session.transport().requests[0].payload,
            NodeMessage::Heartbeat { available, active_placements }
                if *available == Resources::new(6_000, 12 * GIB)
                    && active_placements == &BTreeSet::from(["placement-1".into()])
        ));
    }

    #[test]
    fn runtime_heartbeat_fails_closed_when_reservations_exceed_budget() {
        let (mut session, state) = runtime_session(vec![]);
        {
            let mut state = state.lock().expect("runtime lock");
            state.reports.clear();
            state.reserved = Resources::new(9_000, 17 * GIB);
        }

        assert!(matches!(
            session.runtime_heartbeat(NOW),
            Err(AgentSessionError::Runtime(
                AgentRuntimeError::ReservedResourcesExceedTotal
            ))
        ));
        assert!(session.transport().requests.is_empty());
    }

    #[test]
    fn accepted_terminal_report_is_marked_before_post_terminal_heartbeat() {
        let (mut session, state) =
            runtime_session(vec![response("msg-7-1", None), response("msg-7-2", None)]);

        let outcome = session
            .runtime_heartbeat(NOW)
            .expect("runtime heartbeat succeeds");
        assert_eq!(outcome.terminal_sync.reports_sent, 1);
        assert_eq!(outcome.heartbeat.immediate_acks, 0);
        assert_eq!(session.transport().requests.len(), 2);
        assert!(matches!(
            session.transport().requests[0].payload,
            NodeMessage::PlacementUpdate { .. }
        ));
        assert!(matches!(
            &session.transport().requests[1].payload,
            NodeMessage::Heartbeat { active_placements, .. } if active_placements.is_empty()
        ));
        let state = state.lock().expect("runtime lock");
        assert_eq!(state.reported, BTreeSet::from(["placement-1".into()]));
        assert_eq!(state.poll_calls, 1);
    }
}
