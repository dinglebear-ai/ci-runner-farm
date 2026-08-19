use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};

use crf_protocol::{
    Resources, valid_identifier,
    wire::{ControllerCommand, ControllerEnvelope},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const SCHEMA_VERSION: u8 = 1;
const MAX_STATE_BYTES: u64 = 16 * 1024;
const MAX_PLACEMENTS: usize = 4096;

#[derive(Clone, Debug)]
pub struct PlacementStore {
    root: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LocalPlacementState {
    IntentOnly,
    Spawned { pid: u32 },
    Terminal { outcome: TerminalOutcome },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalReport {
    pub placement_id: String,
    pub command_id: String,
    pub outcome: TerminalOutcome,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalOutcome {
    Finished,
    Failed { detail_code: String },
    Cancelled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlacementStoreError {
    InvalidRoot,
    InvalidPlacement,
    UnsupportedCommand,
    CreateRoot,
    CreatePlacementDirectory,
    PlacementConflict,
    CorruptState,
    ReadState,
    WriteState,
    SyncState,
    TooManyPlacements,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct IntentRecord {
    schema_version: u8,
    placement_id: String,
    command_id: String,
    idempotency_key: String,
    node_generation: u64,
    resources: Resources,
    command_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SpawnedRecord {
    schema_version: u8,
    pid: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct TerminalRecord {
    schema_version: u8,
    outcome: TerminalOutcome,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReportedRecord {
    schema_version: u8,
}

impl PlacementStore {
    pub fn new(root: impl Into<PathBuf>) -> Result<Self, PlacementStoreError> {
        let root = root.into();
        if root.as_os_str().is_empty() {
            return Err(PlacementStoreError::InvalidRoot);
        }
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn begin(&self, command: &ControllerEnvelope) -> Result<(), PlacementStoreError> {
        let placement_id = start_placement_id(command)?;
        self.ensure_root()?;
        let directory = self.placement_directory(placement_id)?;
        let intent = intent_record(command, placement_id)?;

        match fs::create_dir(&directory) {
            Ok(()) => {
                sync_directory(&self.root)?;
                write_new_json(&directory.join("intent.json"), &intent)?;
                sync_directory(&directory)?;
                Ok(())
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let existing: IntentRecord = read_json(&directory.join("intent.json"))?;
                if existing == intent {
                    Ok(())
                } else {
                    Err(PlacementStoreError::PlacementConflict)
                }
            }
            Err(_) => Err(PlacementStoreError::CreatePlacementDirectory),
        }
    }

    pub fn record_spawned(&self, placement_id: &str, pid: u32) -> Result<(), PlacementStoreError> {
        if pid == 0 {
            return Err(PlacementStoreError::CorruptState);
        }
        let directory = self.placement_directory(placement_id)?;
        let record = SpawnedRecord {
            schema_version: SCHEMA_VERSION,
            pid,
        };
        write_idempotent_json(&directory.join("spawned.json"), &record)?;
        sync_directory(&directory)
    }

    pub fn record_terminal(
        &self,
        placement_id: &str,
        outcome: TerminalOutcome,
    ) -> Result<(), PlacementStoreError> {
        validate_terminal_outcome(&outcome)?;
        let directory = self.placement_directory(placement_id)?;
        let record = TerminalRecord {
            schema_version: SCHEMA_VERSION,
            outcome,
        };
        write_idempotent_json(&directory.join("terminal.json"), &record)?;
        sync_directory(&directory)
    }

    pub fn inspect(&self, placement_id: &str) -> Result<LocalPlacementState, PlacementStoreError> {
        let directory = self.placement_directory(placement_id)?;
        let _: IntentRecord = read_json(&directory.join("intent.json"))?;

        let terminal_path = directory.join("terminal.json");
        if terminal_path.exists() {
            let terminal: TerminalRecord = read_json(&terminal_path)?;
            if terminal.schema_version != SCHEMA_VERSION {
                return Err(PlacementStoreError::CorruptState);
            }
            validate_terminal_outcome(&terminal.outcome)?;
            return Ok(LocalPlacementState::Terminal {
                outcome: terminal.outcome,
            });
        }

        let spawned_path = directory.join("spawned.json");
        if spawned_path.exists() {
            let spawned: SpawnedRecord = read_json(&spawned_path)?;
            if spawned.schema_version != SCHEMA_VERSION || spawned.pid == 0 {
                return Err(PlacementStoreError::CorruptState);
            }
            return Ok(LocalPlacementState::Spawned { pid: spawned.pid });
        }

        Ok(LocalPlacementState::IntentOnly)
    }

    pub fn active_placements(&self) -> Result<BTreeSet<String>, PlacementStoreError> {
        let mut active = BTreeSet::new();
        for placement_id in self.placement_ids()? {
            match self.inspect(&placement_id)? {
                LocalPlacementState::IntentOnly | LocalPlacementState::Spawned { .. } => {
                    active.insert(placement_id);
                }
                LocalPlacementState::Terminal { .. } => {}
            }
        }
        Ok(active)
    }

    pub fn reserved_resources(&self) -> Result<Resources, PlacementStoreError> {
        let mut reserved = Resources::default();
        for placement_id in self.placement_ids()? {
            if matches!(
                self.inspect(&placement_id)?,
                LocalPlacementState::Terminal { .. }
            ) {
                continue;
            }
            let intent: IntentRecord =
                read_json(&self.placement_directory(&placement_id)?.join("intent.json"))?;
            if intent.schema_version != SCHEMA_VERSION
                || intent.resources.cpu_millis == 0
                || intent.resources.memory_bytes == 0
            {
                return Err(PlacementStoreError::CorruptState);
            }
            reserved.cpu_millis = reserved
                .cpu_millis
                .checked_add(intent.resources.cpu_millis)
                .ok_or(PlacementStoreError::CorruptState)?;
            reserved.memory_bytes = reserved
                .memory_bytes
                .checked_add(intent.resources.memory_bytes)
                .ok_or(PlacementStoreError::CorruptState)?;
        }
        Ok(reserved)
    }

    pub fn pending_terminal_reports(&self) -> Result<Vec<TerminalReport>, PlacementStoreError> {
        let mut reports = Vec::new();
        for placement_id in self.placement_ids()? {
            let directory = self.placement_directory(&placement_id)?;
            let terminal_path = directory.join("terminal.json");
            if !terminal_path.exists() {
                continue;
            }
            let reported_path = directory.join("reported.json");
            if reported_path.exists() {
                let reported: ReportedRecord = read_json(&reported_path)?;
                if reported.schema_version != SCHEMA_VERSION {
                    return Err(PlacementStoreError::CorruptState);
                }
                continue;
            }
            let intent: IntentRecord = read_json(&directory.join("intent.json"))?;
            let terminal: TerminalRecord = read_json(&terminal_path)?;
            if intent.schema_version != SCHEMA_VERSION || terminal.schema_version != SCHEMA_VERSION
            {
                return Err(PlacementStoreError::CorruptState);
            }
            validate_terminal_outcome(&terminal.outcome)?;
            reports.push(TerminalReport {
                placement_id,
                command_id: intent.command_id,
                outcome: terminal.outcome,
            });
        }
        Ok(reports)
    }

    pub fn mark_terminal_reported(&self, placement_id: &str) -> Result<(), PlacementStoreError> {
        let directory = self.placement_directory(placement_id)?;
        match self.inspect(placement_id)? {
            LocalPlacementState::Terminal { .. } => {}
            _ => return Err(PlacementStoreError::CorruptState),
        }
        write_idempotent_json(
            &directory.join("reported.json"),
            &ReportedRecord {
                schema_version: SCHEMA_VERSION,
            },
        )?;
        sync_directory(&directory)
    }

    fn placement_ids(&self) -> Result<Vec<String>, PlacementStoreError> {
        if !self.root.exists() {
            return Ok(Vec::new());
        }
        self.ensure_root()?;
        let mut placements = Vec::new();
        for entry in fs::read_dir(&self.root).map_err(|_| PlacementStoreError::ReadState)? {
            let entry = entry.map_err(|_| PlacementStoreError::ReadState)?;
            let file_type = entry
                .file_type()
                .map_err(|_| PlacementStoreError::ReadState)?;
            if !file_type.is_dir() || file_type.is_symlink() {
                continue;
            }
            let Some(placement_id) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if !valid_identifier(&placement_id) {
                return Err(PlacementStoreError::CorruptState);
            }
            placements.push(placement_id);
            if placements.len() > MAX_PLACEMENTS {
                return Err(PlacementStoreError::TooManyPlacements);
            }
        }
        placements.sort();
        Ok(placements)
    }

    fn ensure_root(&self) -> Result<(), PlacementStoreError> {
        fs::create_dir_all(&self.root).map_err(|_| PlacementStoreError::CreateRoot)?;
        let metadata =
            fs::symlink_metadata(&self.root).map_err(|_| PlacementStoreError::InvalidRoot)?;
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            return Err(PlacementStoreError::InvalidRoot);
        }
        Ok(())
    }

    fn placement_directory(&self, placement_id: &str) -> Result<PathBuf, PlacementStoreError> {
        if !valid_identifier(placement_id) {
            return Err(PlacementStoreError::InvalidPlacement);
        }
        Ok(self.root.join(placement_id))
    }
}

fn start_placement_id(command: &ControllerEnvelope) -> Result<&str, PlacementStoreError> {
    match &command.payload {
        ControllerCommand::StartPlacement { placement_id, .. }
            if valid_identifier(placement_id) =>
        {
            Ok(placement_id)
        }
        ControllerCommand::StartPlacement { .. } => Err(PlacementStoreError::InvalidPlacement),
        _ => Err(PlacementStoreError::UnsupportedCommand),
    }
}

fn intent_record(
    command: &ControllerEnvelope,
    placement_id: &str,
) -> Result<IntentRecord, PlacementStoreError> {
    let resources = match &command.payload {
        ControllerCommand::StartPlacement { resources, .. }
            if resources.cpu_millis > 0 && resources.memory_bytes > 0 =>
        {
            *resources
        }
        ControllerCommand::StartPlacement { .. } => {
            return Err(PlacementStoreError::CorruptState);
        }
        _ => return Err(PlacementStoreError::UnsupportedCommand),
    };
    let encoded = serde_json::to_vec(command).map_err(|_| PlacementStoreError::WriteState)?;
    let fingerprint = Sha256::digest(encoded);
    Ok(IntentRecord {
        schema_version: SCHEMA_VERSION,
        placement_id: placement_id.to_owned(),
        command_id: command.command_id.clone(),
        idempotency_key: command.idempotency_key.clone(),
        node_generation: command.node_generation,
        resources,
        command_sha256: fingerprint
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    })
}

fn validate_terminal_outcome(outcome: &TerminalOutcome) -> Result<(), PlacementStoreError> {
    match outcome {
        TerminalOutcome::Failed { detail_code } if !valid_identifier(detail_code) => {
            Err(PlacementStoreError::CorruptState)
        }
        _ => Ok(()),
    }
}

fn write_new_json<T: Serialize>(path: &Path, value: &T) -> Result<(), PlacementStoreError> {
    let encoded = serde_json::to_vec(value).map_err(|_| PlacementStoreError::WriteState)?;
    if encoded.len() as u64 > MAX_STATE_BYTES {
        return Err(PlacementStoreError::WriteState);
    }
    let mut file = secure_create_new(path)?;
    file.write_all(&encoded)
        .map_err(|_| PlacementStoreError::WriteState)?;
    file.sync_all().map_err(|_| PlacementStoreError::SyncState)
}

fn write_idempotent_json<T>(path: &Path, value: &T) -> Result<(), PlacementStoreError>
where
    T: Serialize + for<'de> Deserialize<'de> + Eq,
{
    match write_new_json(path, value) {
        Ok(()) => Ok(()),
        Err(PlacementStoreError::WriteState) if path.exists() => {
            let existing: T = read_json(path)?;
            if &existing == value {
                Ok(())
            } else {
                Err(PlacementStoreError::PlacementConflict)
            }
        }
        Err(error) => Err(error),
    }
}

fn secure_create_new(path: &Path) -> Result<File, PlacementStoreError> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .map_err(|_| PlacementStoreError::WriteState)
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, PlacementStoreError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| PlacementStoreError::ReadState)?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > MAX_STATE_BYTES
    {
        return Err(PlacementStoreError::CorruptState);
    }
    let mut file = File::open(path).map_err(|_| PlacementStoreError::ReadState)?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes)
        .map_err(|_| PlacementStoreError::ReadState)?;
    serde_json::from_slice(&bytes).map_err(|_| PlacementStoreError::CorruptState)
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), PlacementStoreError> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| PlacementStoreError::SyncState)
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<(), PlacementStoreError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        sync::atomic::{AtomicU64, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    use crf_protocol::wire::{ControllerCommand, PROTOCOL_VERSION, SecretString};
    use crf_protocol::{ExecutionBackend, Resources};

    use super::*;

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(1);
    const NOW: u64 = 1_787_070_001_000;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let counter = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos();
            Self(std::env::temp_dir().join(format!(
                "crf-placement-store-{}-{counter}-{nanos}",
                std::process::id()
            )))
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn command(secret: &str) -> ControllerEnvelope {
        ControllerEnvelope {
            protocol_version: PROTOCOL_VERSION,
            command_id: "command-1".into(),
            idempotency_key: "idempotency-1".into(),
            node_id: "steamy".into(),
            node_generation: 3,
            issued_at_unix_ms: NOW - 1_000,
            expires_at_unix_ms: NOW + 30_000,
            payload: ControllerCommand::StartPlacement {
                placement_id: "placement-1".into(),
                work_id: "work-1".into(),
                pool_id: "build".into(),
                runner_name: "crf-steamy-1".into(),
                resources: Resources::new(2_000, 4 * 1024 * 1024 * 1024),
                execution_backend: ExecutionBackend::NativeProcess,
                jit_config: SecretString::new(secret).expect("secret"),
            },
        }
    }

    #[test]
    fn intent_is_idempotent_but_changed_command_conflicts() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        let original = command("jit-config-abc123==");
        store.begin(&original).expect("begin");
        store.begin(&original).expect("idempotent begin");

        let mut changed = command("different-jit-config==");
        changed.command_id = "command-2".into();
        assert_eq!(
            store.begin(&changed),
            Err(PlacementStoreError::PlacementConflict)
        );
    }

    #[test]
    fn durable_state_never_contains_jit_secret() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        let secret = "jit-config-super-secret==";
        store.begin(&command(secret)).expect("begin");
        store.record_spawned("placement-1", 4242).expect("spawned");

        for entry in fs::read_dir(directory.0.join("placement-1")).expect("state directory") {
            let entry = entry.expect("entry");
            let bytes = fs::read(entry.path()).expect("state bytes");
            let text = String::from_utf8_lossy(&bytes);
            assert!(!text.contains(secret));
        }
    }

    #[test]
    fn phase_files_form_monotonic_local_state() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        assert_eq!(
            store.inspect("placement-1"),
            Ok(LocalPlacementState::IntentOnly)
        );

        store.record_spawned("placement-1", 4242).expect("spawned");
        assert_eq!(
            store.inspect("placement-1"),
            Ok(LocalPlacementState::Spawned { pid: 4242 })
        );

        store
            .record_terminal("placement-1", TerminalOutcome::Finished)
            .expect("terminal");
        assert_eq!(
            store.inspect("placement-1"),
            Ok(LocalPlacementState::Terminal {
                outcome: TerminalOutcome::Finished,
            })
        );
    }

    #[test]
    fn durable_resource_reservations_survive_until_terminal_state() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        assert_eq!(
            store.reserved_resources(),
            Ok(Resources::new(2_000, 4 * 1024 * 1024 * 1024))
        );
        store.record_spawned("placement-1", 4242).expect("spawned");
        assert_eq!(
            store.reserved_resources(),
            Ok(Resources::new(2_000, 4 * 1024 * 1024 * 1024))
        );
        store
            .record_terminal("placement-1", TerminalOutcome::Finished)
            .expect("terminal");
        assert_eq!(store.reserved_resources(), Ok(Resources::default()));
    }

    #[test]
    fn active_inventory_excludes_terminal_placements() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        assert_eq!(
            store.active_placements(),
            Ok(BTreeSet::from(["placement-1".into()]))
        );
        store
            .record_terminal("placement-1", TerminalOutcome::Cancelled)
            .expect("terminal");
        assert_eq!(store.active_placements(), Ok(BTreeSet::new()));
    }

    #[test]
    fn terminal_report_remains_pending_until_explicitly_marked_reported() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        store.record_spawned("placement-1", 4242).expect("spawned");
        store
            .record_terminal(
                "placement-1",
                TerminalOutcome::Failed {
                    detail_code: "runner_exit_nonzero".into(),
                },
            )
            .expect("terminal");

        assert_eq!(
            store.pending_terminal_reports(),
            Ok(vec![TerminalReport {
                placement_id: "placement-1".into(),
                command_id: "command-1".into(),
                outcome: TerminalOutcome::Failed {
                    detail_code: "runner_exit_nonzero".into(),
                },
            }])
        );

        store
            .mark_terminal_reported("placement-1")
            .expect("mark reported");
        assert_eq!(store.pending_terminal_reports(), Ok(Vec::new()));
        store
            .mark_terminal_reported("placement-1")
            .expect("idempotent reported marker");
    }

    #[test]
    fn nonterminal_placement_cannot_be_marked_reported() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        assert_eq!(
            store.mark_terminal_reported("placement-1"),
            Err(PlacementStoreError::CorruptState)
        );
    }

    #[test]
    fn partial_directory_without_intent_fails_closed() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        fs::create_dir_all(directory.0.join("placement-1")).expect("partial directory");
        assert_eq!(
            store.begin(&command("jit-config-abc123==")),
            Err(PlacementStoreError::ReadState)
        );
    }
}
