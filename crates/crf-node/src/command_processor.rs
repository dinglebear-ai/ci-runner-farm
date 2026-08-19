use crf_protocol::{
    valid_identifier,
    wire::{CommandAckStatus, ControllerEnvelope},
};

use crate::command_ledger::{CommandDisposition, CommandLedger, CommandLedgerError, CommittedAck};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ExecutionResult {
    Applied,
    Rejected(String),
    Deferred(String),
}

pub trait CommandExecutor {
    fn execute_new(&mut self, command: &ControllerEnvelope) -> ExecutionResult;
    fn reconcile_pending(&mut self, command: &ControllerEnvelope) -> ExecutionResult;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProcessDecision {
    Ack(CommittedAck),
    Deferred { detail_code: String },
}

pub struct CommandProcessor<E> {
    ledger: CommandLedger,
    executor: E,
}

impl<E: CommandExecutor> CommandProcessor<E> {
    pub fn new(ledger: CommandLedger, executor: E) -> Self {
        Self { ledger, executor }
    }

    pub fn process(&mut self, command: &ControllerEnvelope, now_unix_ms: u64) -> ProcessDecision {
        match self.ledger.prepare(command, now_unix_ms) {
            Ok(CommandDisposition::Duplicate(ack)) => ProcessDecision::Ack(ack),
            Ok(CommandDisposition::New) => {
                let result = self.executor.execute_new(command);
                self.finish(command, result, now_unix_ms)
            }
            Ok(CommandDisposition::Pending) => {
                let result = self.executor.reconcile_pending(command);
                self.finish(command, result, now_unix_ms)
            }
            Err(CommandLedgerError::LedgerFull) => deferred("command_ledger_full"),
            Err(error) => ProcessDecision::Ack(rejected_ack(ledger_error_code(error))),
        }
    }

    pub fn ledger(&self) -> &CommandLedger {
        &self.ledger
    }

    pub fn executor(&self) -> &E {
        &self.executor
    }

    pub fn executor_mut(&mut self) -> &mut E {
        &mut self.executor
    }

    fn finish(
        &mut self,
        command: &ControllerEnvelope,
        result: ExecutionResult,
        now_unix_ms: u64,
    ) -> ProcessDecision {
        match result {
            ExecutionResult::Applied => {
                self.commit(command, CommandAckStatus::Accepted, None, now_unix_ms)
            }
            ExecutionResult::Rejected(detail_code) => {
                if !valid_identifier(&detail_code) {
                    return deferred("invalid_executor_detail_code");
                }
                self.commit(
                    command,
                    CommandAckStatus::Rejected,
                    Some(detail_code),
                    now_unix_ms,
                )
            }
            ExecutionResult::Deferred(detail_code) => {
                if valid_identifier(&detail_code) {
                    ProcessDecision::Deferred { detail_code }
                } else {
                    deferred("invalid_executor_detail_code")
                }
            }
        }
    }

    fn commit(
        &mut self,
        command: &ControllerEnvelope,
        status: CommandAckStatus,
        detail_code: Option<String>,
        now_unix_ms: u64,
    ) -> ProcessDecision {
        match self
            .ledger
            .commit(command, status, detail_code, now_unix_ms)
        {
            Ok(ack) => ProcessDecision::Ack(ack),
            Err(_) => deferred("command_commit_failed"),
        }
    }
}

fn rejected_ack(detail_code: &'static str) -> CommittedAck {
    CommittedAck::new(CommandAckStatus::Rejected, Some(detail_code.to_owned()))
        .expect("static command processor detail codes are valid identifiers")
}

fn deferred(detail_code: &'static str) -> ProcessDecision {
    ProcessDecision::Deferred {
        detail_code: detail_code.to_owned(),
    }
}

fn ledger_error_code(error: CommandLedgerError) -> &'static str {
    match error {
        CommandLedgerError::InvalidNodeId => "invalid_node_id",
        CommandLedgerError::InvalidCapacity => "invalid_ledger_capacity",
        CommandLedgerError::InvalidCommand(_) => "invalid_command",
        CommandLedgerError::WrongNode => "wrong_node",
        CommandLedgerError::GenerationMismatch => "generation_mismatch",
        CommandLedgerError::IdempotencyConflict => "idempotency_conflict",
        CommandLedgerError::InvalidDetailCode => "invalid_detail_code",
        CommandLedgerError::CommitOutcomeConflict => "commit_outcome_conflict",
        CommandLedgerError::LedgerFull => "command_ledger_full",
        CommandLedgerError::NotPrepared => "command_not_prepared",
        CommandLedgerError::SerializationFailed => "command_serialization_failed",
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use crf_protocol::wire::{ControllerCommand, PROTOCOL_VERSION};

    use super::*;

    struct FakeExecutor {
        new_results: VecDeque<ExecutionResult>,
        pending_results: VecDeque<ExecutionResult>,
        new_calls: usize,
        pending_calls: usize,
    }

    impl FakeExecutor {
        fn new(new_results: Vec<ExecutionResult>, pending_results: Vec<ExecutionResult>) -> Self {
            Self {
                new_results: new_results.into(),
                pending_results: pending_results.into(),
                new_calls: 0,
                pending_calls: 0,
            }
        }
    }

    impl CommandExecutor for FakeExecutor {
        fn execute_new(&mut self, _command: &ControllerEnvelope) -> ExecutionResult {
            self.new_calls += 1;
            self.new_results
                .pop_front()
                .unwrap_or(ExecutionResult::Deferred("no_new_result".into()))
        }

        fn reconcile_pending(&mut self, _command: &ControllerEnvelope) -> ExecutionResult {
            self.pending_calls += 1;
            self.pending_results
                .pop_front()
                .unwrap_or(ExecutionResult::Deferred("no_pending_result".into()))
        }
    }

    fn command(command_id: &str, idempotency_key: &str, draining: bool) -> ControllerEnvelope {
        ControllerEnvelope {
            protocol_version: PROTOCOL_VERSION,
            command_id: command_id.into(),
            idempotency_key: idempotency_key.into(),
            node_id: "dookie".into(),
            node_generation: 7,
            issued_at_unix_ms: 1_000,
            expires_at_unix_ms: 10_000,
            payload: ControllerCommand::SetDrain { draining },
        }
    }

    fn processor(executor: FakeExecutor, capacity: usize) -> CommandProcessor<FakeExecutor> {
        CommandProcessor::new(
            CommandLedger::new("dookie", 7, capacity).expect("ledger"),
            executor,
        )
    }

    #[test]
    fn applied_command_is_executed_once_and_replays_accepted_ack() {
        let executor = FakeExecutor::new(vec![ExecutionResult::Applied], vec![]);
        let mut processor = processor(executor, 16);
        let command = command("cmd-1", "idem-1", true);

        assert_eq!(
            processor.process(&command, 2_000),
            ProcessDecision::Ack(CommittedAck {
                status: CommandAckStatus::Accepted,
                detail_code: None,
            })
        );
        assert_eq!(
            processor.process(&command, 2_001),
            ProcessDecision::Ack(CommittedAck {
                status: CommandAckStatus::Accepted,
                detail_code: None,
            })
        );
        assert_eq!(processor.executor().new_calls, 1);
        assert_eq!(processor.executor().pending_calls, 0);
    }

    #[test]
    fn rejected_command_replays_the_same_rejection() {
        let executor = FakeExecutor::new(
            vec![ExecutionResult::Rejected("backend_unavailable".into())],
            vec![],
        );
        let mut processor = processor(executor, 16);
        let command = command("cmd-1", "idem-1", true);
        let expected = ProcessDecision::Ack(CommittedAck {
            status: CommandAckStatus::Rejected,
            detail_code: Some("backend_unavailable".into()),
        });

        assert_eq!(processor.process(&command, 2_000), expected);
        assert_eq!(processor.process(&command, 2_001), expected);
        assert_eq!(processor.executor().new_calls, 1);
    }

    #[test]
    fn deferred_command_is_reconciled_before_it_can_be_acknowledged() {
        let executor = FakeExecutor::new(
            vec![ExecutionResult::Deferred("start_uncertain".into())],
            vec![ExecutionResult::Applied],
        );
        let mut processor = processor(executor, 16);
        let command = command("cmd-1", "idem-1", true);

        assert_eq!(
            processor.process(&command, 2_000),
            ProcessDecision::Deferred {
                detail_code: "start_uncertain".into(),
            }
        );
        assert_eq!(
            processor.process(&command, 2_001),
            ProcessDecision::Ack(CommittedAck {
                status: CommandAckStatus::Accepted,
                detail_code: None,
            })
        );
        assert_eq!(processor.executor().new_calls, 1);
        assert_eq!(processor.executor().pending_calls, 1);
    }

    #[test]
    fn full_ledger_defers_new_command_without_calling_executor() {
        let executor = FakeExecutor::new(
            vec![ExecutionResult::Deferred("first_pending".into())],
            vec![],
        );
        let mut processor = processor(executor, 1);
        let first = command("cmd-1", "idem-1", true);
        let second = command("cmd-2", "idem-2", false);

        assert!(matches!(
            processor.process(&first, 2_000),
            ProcessDecision::Deferred { .. }
        ));
        assert_eq!(
            processor.process(&second, 2_001),
            ProcessDecision::Deferred {
                detail_code: "command_ledger_full".into(),
            }
        );
        assert_eq!(processor.executor().new_calls, 1);
    }

    #[test]
    fn conflicting_idempotency_key_is_rejected_before_execution() {
        let executor = FakeExecutor::new(vec![ExecutionResult::Deferred("pending".into())], vec![]);
        let mut processor = processor(executor, 16);
        let first = command("cmd-1", "idem-1", true);
        let conflicting = command("cmd-1", "idem-1", false);

        assert!(matches!(
            processor.process(&first, 2_000),
            ProcessDecision::Deferred { .. }
        ));
        assert_eq!(
            processor.process(&conflicting, 2_001),
            ProcessDecision::Ack(CommittedAck {
                status: CommandAckStatus::Rejected,
                detail_code: Some("idempotency_conflict".into()),
            })
        );
        assert_eq!(processor.executor().new_calls, 1);
    }
}
