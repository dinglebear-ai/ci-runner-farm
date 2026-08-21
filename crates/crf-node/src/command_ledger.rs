use std::collections::{BTreeMap, VecDeque};

use crf_protocol::{
    valid_identifier,
    wire::{CommandAckStatus, ControllerEnvelope, WireError},
};
use sha2::{Digest, Sha256};

const MAX_LEDGER_ENTRIES: usize = 4096;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CommandDisposition {
    New,
    Pending,
    Duplicate(CommittedAck),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommittedAck {
    pub status: CommandAckStatus,
    pub detail_code: Option<String>,
}

impl CommittedAck {
    pub fn new(
        status: CommandAckStatus,
        detail_code: Option<String>,
    ) -> Result<Self, CommandLedgerError> {
        if detail_code
            .as_deref()
            .is_some_and(|detail| !valid_identifier(detail))
        {
            return Err(CommandLedgerError::InvalidDetailCode);
        }
        Ok(Self {
            status,
            detail_code,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum CommandPhase {
    Prepared,
    Committed(CommittedAck),
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct LedgerEntry {
    fingerprint: [u8; 32],
    phase: CommandPhase,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandLedgerError {
    InvalidNodeId,
    InvalidCapacity,
    InvalidCommand(WireError),
    WrongNode,
    GenerationMismatch,
    IdempotencyConflict,
    InvalidDetailCode,
    CommitOutcomeConflict,
    LedgerFull,
    NotPrepared,
    SerializationFailed,
}

#[derive(Clone, Debug)]
pub struct CommandLedger {
    node_id: String,
    generation: u64,
    capacity: usize,
    order: VecDeque<String>,
    entries: BTreeMap<String, LedgerEntry>,
}

impl CommandLedger {
    pub fn new(
        node_id: impl Into<String>,
        generation: u64,
        capacity: usize,
    ) -> Result<Self, CommandLedgerError> {
        let node_id = node_id.into();
        if !valid_identifier(&node_id) || generation == 0 {
            return Err(CommandLedgerError::InvalidNodeId);
        }
        if capacity == 0 || capacity > MAX_LEDGER_ENTRIES {
            return Err(CommandLedgerError::InvalidCapacity);
        }
        Ok(Self {
            node_id,
            generation,
            capacity,
            order: VecDeque::with_capacity(capacity.min(1024)),
            entries: BTreeMap::new(),
        })
    }

    pub fn prepare(
        &mut self,
        command: &ControllerEnvelope,
        now_unix_ms: u64,
    ) -> Result<CommandDisposition, CommandLedgerError> {
        let fingerprint = self.validate_and_fingerprint(command, now_unix_ms)?;

        if let Some(existing) = self.entries.get(&command.idempotency_key) {
            if existing.fingerprint != fingerprint {
                return Err(CommandLedgerError::IdempotencyConflict);
            }
            return Ok(match &existing.phase {
                CommandPhase::Prepared => CommandDisposition::Pending,
                CommandPhase::Committed(ack) => CommandDisposition::Duplicate(ack.clone()),
            });
        }

        self.make_room()?;
        self.order.push_back(command.idempotency_key.clone());
        self.entries.insert(
            command.idempotency_key.clone(),
            LedgerEntry {
                fingerprint,
                phase: CommandPhase::Prepared,
            },
        );
        Ok(CommandDisposition::New)
    }

    pub fn commit(
        &mut self,
        command: &ControllerEnvelope,
        status: CommandAckStatus,
        detail_code: Option<String>,
        now_unix_ms: u64,
    ) -> Result<CommittedAck, CommandLedgerError> {
        let fingerprint = self.validate_and_fingerprint(command, now_unix_ms)?;
        let ack = CommittedAck::new(status, detail_code)?;
        let entry = self
            .entries
            .get_mut(&command.idempotency_key)
            .ok_or(CommandLedgerError::NotPrepared)?;
        if entry.fingerprint != fingerprint {
            return Err(CommandLedgerError::IdempotencyConflict);
        }

        match &entry.phase {
            CommandPhase::Prepared => {
                entry.phase = CommandPhase::Committed(ack.clone());
                Ok(ack)
            }
            CommandPhase::Committed(existing) if existing == &ack => Ok(existing.clone()),
            CommandPhase::Committed(_) => Err(CommandLedgerError::CommitOutcomeConflict),
        }
    }

    pub fn abort(
        &mut self,
        command: &ControllerEnvelope,
        now_unix_ms: u64,
    ) -> Result<(), CommandLedgerError> {
        let fingerprint = self.validate_and_fingerprint(command, now_unix_ms)?;
        match self.entries.get(&command.idempotency_key) {
            Some(entry) if entry.fingerprint != fingerprint => {
                Err(CommandLedgerError::IdempotencyConflict)
            }
            Some(LedgerEntry {
                phase: CommandPhase::Prepared,
                ..
            }) => {
                self.remove(&command.idempotency_key);
                Ok(())
            }
            Some(LedgerEntry {
                phase: CommandPhase::Committed(_),
                ..
            }) => Err(CommandLedgerError::NotPrepared),
            None => Err(CommandLedgerError::NotPrepared),
        }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn validate_and_fingerprint(
        &self,
        command: &ControllerEnvelope,
        now_unix_ms: u64,
    ) -> Result<[u8; 32], CommandLedgerError> {
        command
            .validate(now_unix_ms)
            .map_err(CommandLedgerError::InvalidCommand)?;
        if command.node_id != self.node_id {
            return Err(CommandLedgerError::WrongNode);
        }
        if command.node_generation != self.generation {
            return Err(CommandLedgerError::GenerationMismatch);
        }
        command_fingerprint(command)
    }

    fn make_room(&mut self) -> Result<(), CommandLedgerError> {
        while self.entries.len() >= self.capacity {
            let Some(index) = self.order.iter().position(|key| {
                self.entries
                    .get(key)
                    .is_some_and(|entry| matches!(entry.phase, CommandPhase::Committed(_)))
            }) else {
                return Err(CommandLedgerError::LedgerFull);
            };
            let Some(key) = self.order.remove(index) else {
                return Err(CommandLedgerError::LedgerFull);
            };
            self.entries.remove(&key);
        }
        Ok(())
    }

    fn remove(&mut self, idempotency_key: &str) {
        self.entries.remove(idempotency_key);
        if let Some(index) = self.order.iter().position(|key| key == idempotency_key) {
            self.order.remove(index);
        }
    }
}

fn command_fingerprint(command: &ControllerEnvelope) -> Result<[u8; 32], CommandLedgerError> {
    let encoded =
        serde_json::to_vec(command).map_err(|_| CommandLedgerError::SerializationFailed)?;
    Ok(Sha256::digest(encoded).into())
}

#[cfg(test)]
mod tests {
    use crf_protocol::wire::{ControllerCommand, PROTOCOL_VERSION};

    use super::*;

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

    fn commit_accepted(ledger: &mut CommandLedger, command: &ControllerEnvelope, now: u64) {
        let ack = ledger
            .commit(command, CommandAckStatus::Accepted, None, now)
            .expect("commit accepted");
        assert_eq!(ack.status, CommandAckStatus::Accepted);
        assert_eq!(ack.detail_code, None);
    }

    #[test]
    fn exact_retry_is_pending_until_commit_then_replays_original_ack() {
        let mut ledger = CommandLedger::new("dookie", 7, 16).expect("ledger");
        let command = command("cmd-1", "idem-1", true);
        assert_eq!(ledger.prepare(&command, 2_000), Ok(CommandDisposition::New));
        assert_eq!(
            ledger.prepare(&command, 2_001),
            Ok(CommandDisposition::Pending)
        );
        commit_accepted(&mut ledger, &command, 2_002);
        assert_eq!(
            ledger.prepare(&command, 2_003),
            Ok(CommandDisposition::Duplicate(CommittedAck {
                status: CommandAckStatus::Accepted,
                detail_code: None,
            }))
        );
        assert_eq!(ledger.len(), 1);
    }

    #[test]
    fn rejected_outcome_is_replayed_as_rejected_not_generic_duplicate() {
        let mut ledger = CommandLedger::new("dookie", 7, 16).expect("ledger");
        let command = command("cmd-1", "idem-1", true);
        assert_eq!(ledger.prepare(&command, 2_000), Ok(CommandDisposition::New));
        ledger
            .commit(
                &command,
                CommandAckStatus::Rejected,
                Some("runtime_unavailable".into()),
                2_001,
            )
            .expect("commit rejection");
        assert_eq!(
            ledger.prepare(&command, 2_002),
            Ok(CommandDisposition::Duplicate(CommittedAck {
                status: CommandAckStatus::Rejected,
                detail_code: Some("runtime_unavailable".into()),
            }))
        );
    }

    #[test]
    fn reused_idempotency_key_with_changed_payload_is_rejected() {
        let mut ledger = CommandLedger::new("dookie", 7, 16).expect("ledger");
        assert_eq!(
            ledger.prepare(&command("cmd-1", "idem-1", true), 2_000),
            Ok(CommandDisposition::New)
        );
        assert_eq!(
            ledger.prepare(&command("cmd-1", "idem-1", false), 2_001),
            Err(CommandLedgerError::IdempotencyConflict)
        );
    }

    #[test]
    fn node_identity_and_generation_are_fenced() {
        let mut ledger = CommandLedger::new("dookie", 7, 16).expect("ledger");
        let mut wrong_node = command("cmd-1", "idem-1", true);
        wrong_node.node_id = "steamy".into();
        assert_eq!(
            ledger.prepare(&wrong_node, 2_000),
            Err(CommandLedgerError::WrongNode)
        );

        let mut stale = command("cmd-2", "idem-2", true);
        stale.node_generation = 6;
        assert_eq!(
            ledger.prepare(&stale, 2_000),
            Err(CommandLedgerError::GenerationMismatch)
        );
    }

    #[test]
    fn uncommitted_commands_are_never_evicted_for_capacity() {
        let mut ledger = CommandLedger::new("dookie", 7, 2).expect("ledger");
        let first = command("cmd-1", "idem-1", true);
        let second = command("cmd-2", "idem-2", true);
        let third = command("cmd-3", "idem-3", true);
        assert_eq!(ledger.prepare(&first, 2_000), Ok(CommandDisposition::New));
        assert_eq!(ledger.prepare(&second, 2_000), Ok(CommandDisposition::New));
        assert_eq!(
            ledger.prepare(&third, 2_000),
            Err(CommandLedgerError::LedgerFull)
        );
        assert_eq!(ledger.len(), 2);
    }

    #[test]
    fn committed_entries_may_be_evicted_to_make_room() {
        let mut ledger = CommandLedger::new("dookie", 7, 2).expect("ledger");
        let first = command("cmd-1", "idem-1", true);
        let second = command("cmd-2", "idem-2", true);
        let third = command("cmd-3", "idem-3", true);

        assert_eq!(ledger.prepare(&first, 2_000), Ok(CommandDisposition::New));
        commit_accepted(&mut ledger, &first, 2_001);
        assert_eq!(ledger.prepare(&second, 2_000), Ok(CommandDisposition::New));
        assert_eq!(ledger.prepare(&third, 2_000), Ok(CommandDisposition::New));
        assert_eq!(ledger.len(), 2);
        commit_accepted(&mut ledger, &second, 2_050);
        assert_eq!(ledger.prepare(&first, 2_100), Ok(CommandDisposition::New));
    }

    #[test]
    fn committed_outcome_cannot_be_rewritten() {
        let mut ledger = CommandLedger::new("dookie", 7, 2).expect("ledger");
        let command = command("cmd-1", "idem-1", true);
        assert_eq!(ledger.prepare(&command, 2_000), Ok(CommandDisposition::New));
        commit_accepted(&mut ledger, &command, 2_001);
        assert_eq!(
            ledger.commit(
                &command,
                CommandAckStatus::Rejected,
                Some("late_failure".into()),
                2_002,
            ),
            Err(CommandLedgerError::CommitOutcomeConflict)
        );
    }

    #[test]
    fn abort_removes_only_matching_prepared_command() {
        let mut ledger = CommandLedger::new("dookie", 7, 2).expect("ledger");
        let command = command("cmd-1", "idem-1", true);
        assert_eq!(ledger.prepare(&command, 2_000), Ok(CommandDisposition::New));
        ledger
            .abort(&command, 2_001)
            .expect("abort prepared command");
        assert!(ledger.is_empty());
        assert_eq!(ledger.prepare(&command, 2_002), Ok(CommandDisposition::New));
        commit_accepted(&mut ledger, &command, 2_003);
        assert_eq!(
            ledger.abort(&command, 2_004),
            Err(CommandLedgerError::NotPrepared)
        );
    }
}
