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

use crate::process_identity::ProcessIdentity;

const SCHEMA_VERSION: u8 = 1;
const SPAWNED_SCHEMA_VERSION: u8 = 2;
const MAX_STATE_BYTES: u64 = 16 * 1024;
const MAX_PLACEMENTS: usize = 4096;
const MAX_GC_SCAN_PLACEMENTS: usize = 65_536;

#[derive(Clone, Debug)]
pub struct PlacementStore {
    root: PathBuf,
    gc_root: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LocalPlacementState {
    IntentOnly,
    Spawned { runtime: RuntimeIdentity },
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
    CreateGcRoot,
    MoveState,
    RemoveState,
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
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum RuntimeIdentity {
    NativeProcess { process: ProcessIdentity },
    Container { id: String },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SpawnedRecord {
    schema_version: u8,
    runtime: RuntimeIdentity,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacySpawnedRecord {
    schema_version: u8,
    process: ProcessIdentity,
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

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct GcRecord {
    schema_version: u8,
    placement_id: String,
    node_generation: u64,
}

fn validate_runtime_identity(runtime: &RuntimeIdentity) -> Result<(), PlacementStoreError> {
    match runtime {
        RuntimeIdentity::NativeProcess { process }
            if process.pid != 0 && process.start_token != 0 =>
        {
            Ok(())
        }
        RuntimeIdentity::Container { id } if valid_identifier(id) => Ok(()),
        _ => Err(PlacementStoreError::CorruptState),
    }
}

fn read_runtime_identity(path: &Path) -> Result<RuntimeIdentity, PlacementStoreError> {
    let value: serde_json::Value = read_json(path)?;
    let version = value
        .get("schema_version")
        .and_then(serde_json::Value::as_u64)
        .ok_or(PlacementStoreError::CorruptState)?;
    let runtime = match version {
        1 => {
            let legacy: LegacySpawnedRecord =
                serde_json::from_value(value).map_err(|_| PlacementStoreError::CorruptState)?;
            RuntimeIdentity::NativeProcess {
                process: legacy.process,
            }
        }
        2 => {
            let record: SpawnedRecord =
                serde_json::from_value(value).map_err(|_| PlacementStoreError::CorruptState)?;
            if record.schema_version != SPAWNED_SCHEMA_VERSION {
                return Err(PlacementStoreError::CorruptState);
            }
            record.runtime
        }
        _ => return Err(PlacementStoreError::CorruptState),
    };
    validate_runtime_identity(&runtime)?;
    Ok(runtime)
}

impl PlacementStore {
    pub fn new(root: impl Into<PathBuf>) -> Result<Self, PlacementStoreError> {
        let root = root.into();
        let gc_root = default_gc_root(&root)?;
        Self::with_gc_root(root, gc_root)
    }

    pub fn with_gc_root(
        root: impl Into<PathBuf>,
        gc_root: impl Into<PathBuf>,
    ) -> Result<Self, PlacementStoreError> {
        let root = root.into();
        let gc_root = gc_root.into();
        if root.as_os_str().is_empty()
            || gc_root.as_os_str().is_empty()
            || root == gc_root
            || root.starts_with(&gc_root)
            || gc_root.starts_with(&root)
        {
            return Err(PlacementStoreError::InvalidRoot);
        }
        Ok(Self { root, gc_root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn gc_root(&self) -> &Path {
        &self.gc_root
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

    pub fn record_spawned(
        &self,
        placement_id: &str,
        process: ProcessIdentity,
    ) -> Result<(), PlacementStoreError> {
        self.record_runtime_started(placement_id, RuntimeIdentity::NativeProcess { process })
    }

    pub fn record_runtime_started(
        &self,
        placement_id: &str,
        runtime: RuntimeIdentity,
    ) -> Result<(), PlacementStoreError> {
        validate_runtime_identity(&runtime)?;
        let directory = self.placement_directory(placement_id)?;
        let record = SpawnedRecord {
            schema_version: SPAWNED_SCHEMA_VERSION,
            runtime,
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
            return Ok(LocalPlacementState::Spawned {
                runtime: read_runtime_identity(&spawned_path)?,
            });
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

    pub fn prune_reported_through_generation(
        &self,
        current_generation: u64,
    ) -> Result<Vec<String>, PlacementStoreError> {
        if current_generation == 0 {
            return Err(PlacementStoreError::CorruptState);
        }
        self.ensure_root()?;
        self.ensure_gc_root()?;
        self.clean_quarantine(current_generation)?;

        let mut pruned = Vec::new();
        for placement_id in self.placement_ids_with_limit(MAX_GC_SCAN_PLACEMENTS)? {
            let directory = self.placement_directory(&placement_id)?;
            let intent: IntentRecord = read_json(&directory.join("intent.json"))?;
            if intent.schema_version != SCHEMA_VERSION
                || intent.placement_id != placement_id
                || intent.node_generation == 0
            {
                return Err(PlacementStoreError::CorruptState);
            }
            if intent.node_generation > current_generation {
                continue;
            }

            let terminal = directory.join("terminal.json");
            let reported = directory.join("reported.json");
            if reported.exists() && !terminal.exists() {
                return Err(PlacementStoreError::CorruptState);
            }
            if !terminal.exists() || !reported.exists() {
                continue;
            }

            validate_gc_candidate(&directory, &placement_id, current_generation)?;
            let quarantine = self.gc_root.join(&placement_id);
            if quarantine.exists() {
                return Err(PlacementStoreError::CorruptState);
            }
            fs::rename(&directory, &quarantine).map_err(|_| PlacementStoreError::MoveState)?;
            sync_directory(&self.root)?;
            prepare_gc_directory(&quarantine, &placement_id, current_generation)?;
            remove_gc_directory(&quarantine)?;
            sync_directory(&self.gc_root)?;
            pruned.push(placement_id);
        }
        self.placement_ids()?;
        Ok(pruned)
    }

    pub fn prune_reported(&self, placement_id: &str) -> Result<(), PlacementStoreError> {
        self.ensure_root()?;
        self.ensure_gc_root()?;
        let directory = self.placement_directory(placement_id)?;
        let intent: IntentRecord = read_json(&directory.join("intent.json"))?;
        if intent.schema_version != SCHEMA_VERSION
            || intent.placement_id != placement_id
            || intent.node_generation == 0
        {
            return Err(PlacementStoreError::CorruptState);
        }
        if !directory.join("terminal.json").exists() || !directory.join("reported.json").exists() {
            return Err(PlacementStoreError::CorruptState);
        }
        validate_gc_candidate(&directory, placement_id, intent.node_generation)?;
        let quarantine = self.gc_root.join(placement_id);
        if quarantine.exists() {
            return Err(PlacementStoreError::CorruptState);
        }
        fs::rename(&directory, &quarantine).map_err(|_| PlacementStoreError::MoveState)?;
        sync_directory(&self.root)?;
        prepare_gc_directory(&quarantine, placement_id, intent.node_generation)?;
        remove_gc_directory(&quarantine)?;
        sync_directory(&self.gc_root)
    }

    fn clean_quarantine(&self, current_generation: u64) -> Result<(), PlacementStoreError> {
        let mut entries = fs::read_dir(&self.gc_root)
            .map_err(|_| PlacementStoreError::ReadState)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| PlacementStoreError::ReadState)?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let file_type = entry
                .file_type()
                .map_err(|_| PlacementStoreError::ReadState)?;
            if !file_type.is_dir() || file_type.is_symlink() {
                return Err(PlacementStoreError::CorruptState);
            }
            let placement_id = entry
                .file_name()
                .to_str()
                .map(str::to_owned)
                .ok_or(PlacementStoreError::CorruptState)?;
            if !valid_identifier(&placement_id) {
                return Err(PlacementStoreError::CorruptState);
            }
            prepare_gc_directory(&entry.path(), &placement_id, current_generation)?;
            remove_gc_directory(&entry.path())?;
        }
        sync_directory(&self.gc_root)
    }

    fn ensure_gc_root(&self) -> Result<(), PlacementStoreError> {
        fs::create_dir_all(&self.gc_root).map_err(|_| PlacementStoreError::CreateGcRoot)?;
        let metadata =
            fs::symlink_metadata(&self.gc_root).map_err(|_| PlacementStoreError::CreateGcRoot)?;
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            return Err(PlacementStoreError::CorruptState);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&self.gc_root, fs::Permissions::from_mode(0o700))
                .map_err(|_| PlacementStoreError::CreateGcRoot)?;
        }
        Ok(())
    }

    fn placement_ids(&self) -> Result<Vec<String>, PlacementStoreError> {
        self.placement_ids_with_limit(MAX_PLACEMENTS)
    }

    fn placement_ids_with_limit(&self, limit: usize) -> Result<Vec<String>, PlacementStoreError> {
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
            if placements.len() > limit {
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

fn default_gc_root(root: &Path) -> Result<PathBuf, PlacementStoreError> {
    let file_name = root.file_name().ok_or(PlacementStoreError::InvalidRoot)?;
    let mut gc_name = file_name.to_os_string();
    gc_name.push(".gc");
    Ok(root.with_file_name(gc_name))
}

fn gc_entry_names(directory: &Path) -> Result<BTreeSet<String>, PlacementStoreError> {
    let metadata = fs::symlink_metadata(directory).map_err(|_| PlacementStoreError::ReadState)?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(PlacementStoreError::CorruptState);
    }
    let allowed = BTreeSet::from([
        "intent.json",
        "spawned.json",
        "terminal.json",
        "reported.json",
        "gc.json",
    ]);
    let mut names = BTreeSet::new();
    for entry in fs::read_dir(directory).map_err(|_| PlacementStoreError::ReadState)? {
        let entry = entry.map_err(|_| PlacementStoreError::ReadState)?;
        let name = entry
            .file_name()
            .to_str()
            .map(str::to_owned)
            .ok_or(PlacementStoreError::CorruptState)?;
        let file_type = entry
            .file_type()
            .map_err(|_| PlacementStoreError::ReadState)?;
        if !allowed.contains(name.as_str()) || !file_type.is_file() || file_type.is_symlink() {
            return Err(PlacementStoreError::CorruptState);
        }
        names.insert(name);
    }
    Ok(names)
}

fn validate_gc_candidate(
    directory: &Path,
    placement_id: &str,
    current_generation: u64,
) -> Result<IntentRecord, PlacementStoreError> {
    let names = gc_entry_names(directory)?;
    if names.contains("gc.json")
        || !names.contains("intent.json")
        || !names.contains("terminal.json")
        || !names.contains("reported.json")
    {
        return Err(PlacementStoreError::CorruptState);
    }
    let intent: IntentRecord = read_json(&directory.join("intent.json"))?;
    if intent.schema_version != SCHEMA_VERSION
        || intent.placement_id != placement_id
        || intent.node_generation == 0
        || intent.node_generation > current_generation
    {
        return Err(PlacementStoreError::CorruptState);
    }
    let terminal: TerminalRecord = read_json(&directory.join("terminal.json"))?;
    let reported: ReportedRecord = read_json(&directory.join("reported.json"))?;
    if terminal.schema_version != SCHEMA_VERSION || reported.schema_version != SCHEMA_VERSION {
        return Err(PlacementStoreError::CorruptState);
    }
    validate_terminal_outcome(&terminal.outcome)?;
    if names.contains("spawned.json") {
        read_runtime_identity(&directory.join("spawned.json"))?;
    }
    Ok(intent)
}

fn prepare_gc_directory(
    directory: &Path,
    placement_id: &str,
    current_generation: u64,
) -> Result<(), PlacementStoreError> {
    let names = gc_entry_names(directory)?;
    if names.is_empty() {
        return Ok(());
    }
    if names.contains("gc.json") {
        let marker: GcRecord = read_json(&directory.join("gc.json"))?;
        if marker.schema_version != SCHEMA_VERSION
            || marker.placement_id != placement_id
            || marker.node_generation == 0
            || marker.node_generation > current_generation
        {
            return Err(PlacementStoreError::CorruptState);
        }
        return Ok(());
    }

    let intent = validate_gc_candidate(directory, placement_id, current_generation)?;
    write_new_json(
        &directory.join("gc.json"),
        &GcRecord {
            schema_version: SCHEMA_VERSION,
            placement_id: placement_id.to_owned(),
            node_generation: intent.node_generation,
        },
    )?;
    sync_directory(directory)
}

fn remove_gc_directory(directory: &Path) -> Result<(), PlacementStoreError> {
    let names = gc_entry_names(directory)?;
    if names.is_empty() {
        fs::remove_dir(directory).map_err(|_| PlacementStoreError::RemoveState)?;
        return Ok(());
    }
    if !names.contains("gc.json") {
        return Err(PlacementStoreError::CorruptState);
    }
    for name in [
        "reported.json",
        "terminal.json",
        "spawned.json",
        "intent.json",
    ] {
        let path = directory.join(name);
        if path.exists() {
            let metadata =
                fs::symlink_metadata(&path).map_err(|_| PlacementStoreError::ReadState)?;
            if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
                return Err(PlacementStoreError::CorruptState);
            }
            fs::remove_file(path).map_err(|_| PlacementStoreError::RemoveState)?;
        }
    }
    sync_directory(directory)?;
    fs::remove_file(directory.join("gc.json")).map_err(|_| PlacementStoreError::RemoveState)?;
    fs::remove_dir(directory).map_err(|_| PlacementStoreError::RemoveState)
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
            if let Ok(gc_root) = default_gc_root(&self.0) {
                let _ = fs::remove_dir_all(gc_root);
            }
        }
    }

    fn process_identity(pid: u32) -> ProcessIdentity {
        ProcessIdentity {
            pid,
            start_token: 99,
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
        store
            .record_spawned("placement-1", process_identity(4242))
            .expect("spawned");

        for entry in fs::read_dir(directory.0.join("placement-1")).expect("state directory") {
            let entry = entry.expect("entry");
            let bytes = fs::read(entry.path()).expect("state bytes");
            let text = String::from_utf8_lossy(&bytes);
            assert!(!text.contains(secret));
        }
    }

    #[test]
    fn legacy_spawned_v1_reads_as_native_runtime_identity() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        let process = process_identity(4242);
        let legacy = serde_json::json!({
            "schema_version": 1,
            "process": {
                "pid": process.pid,
                "start_token": process.start_token
            }
        });
        fs::write(
            directory.0.join("placement-1/spawned.json"),
            serde_json::to_vec(&legacy).expect("legacy json"),
        )
        .expect("legacy spawned state");

        assert_eq!(
            store.inspect("placement-1"),
            Ok(LocalPlacementState::Spawned {
                runtime: RuntimeIdentity::NativeProcess { process },
            })
        );
    }

    #[test]
    fn container_runtime_identity_round_trips() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        let runtime = RuntimeIdentity::Container {
            id: "container-0123456789abcdef".into(),
        };
        store
            .record_runtime_started("placement-1", runtime.clone())
            .expect("container runtime");
        assert_eq!(
            store.inspect("placement-1"),
            Ok(LocalPlacementState::Spawned { runtime })
        );
    }

    #[test]
    fn invalid_container_runtime_identity_is_rejected() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        assert_eq!(
            store.record_runtime_started(
                "placement-1",
                RuntimeIdentity::Container {
                    id: "../not-a-container".into(),
                },
            ),
            Err(PlacementStoreError::CorruptState)
        );
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

        store
            .record_spawned("placement-1", process_identity(4242))
            .expect("spawned");
        assert_eq!(
            store.inspect("placement-1"),
            Ok(LocalPlacementState::Spawned {
                runtime: RuntimeIdentity::NativeProcess {
                    process: process_identity(4242),
                },
            })
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
        store
            .record_spawned("placement-1", process_identity(4242))
            .expect("spawned");
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
        store
            .record_spawned("placement-1", process_identity(4242))
            .expect("spawned");
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
    fn gc_prunes_reported_terminal_state_from_current_generation() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        store
            .record_terminal("placement-1", TerminalOutcome::Finished)
            .expect("terminal");
        store
            .mark_terminal_reported("placement-1")
            .expect("reported");

        assert_eq!(
            store.prune_reported_through_generation(3),
            Ok(vec!["placement-1".into()])
        );
        assert!(!directory.0.join("placement-1").exists());
        assert!(store.gc_root().is_dir());
        assert_eq!(fs::read_dir(store.gc_root()).expect("gc root").count(), 0);
    }

    #[test]
    fn acknowledged_placements_do_not_accumulate_past_scan_limit_in_one_generation() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");

        for index in 0..=MAX_PLACEMENTS {
            let placement_id = format!("placement-{index}");
            let command_id = format!("command-{index}");
            let mut command = command("jit-config-abc123==");
            command.command_id = command_id;
            if let ControllerCommand::StartPlacement {
                placement_id: id, ..
            } = &mut command.payload
            {
                *id = placement_id.clone();
            }
            store.begin(&command).expect("begin");
            store
                .record_terminal(&placement_id, TerminalOutcome::Finished)
                .expect("terminal");
            store
                .mark_terminal_reported(&placement_id)
                .expect("reported");
            store.prune_reported(&placement_id).expect("pruned");
        }

        assert_eq!(store.placement_ids(), Ok(Vec::new()));
    }

    #[test]
    fn gc_retains_unreported_terminal_state_across_generation_change() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        store
            .record_terminal("placement-1", TerminalOutcome::Cancelled)
            .expect("terminal");

        assert_eq!(store.prune_reported_through_generation(4), Ok(Vec::new()));
        assert!(directory.0.join("placement-1").is_dir());
        assert_eq!(store.pending_terminal_reports().expect("pending").len(), 1);
    }

    #[test]
    fn gc_retains_nonterminal_old_generation_for_restart_adoption() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        store
            .record_spawned("placement-1", process_identity(4242))
            .expect("spawned");

        assert_eq!(store.prune_reported_through_generation(4), Ok(Vec::new()));
        assert!(directory.0.join("placement-1").is_dir());
        assert_eq!(
            store.active_placements(),
            Ok(BTreeSet::from(["placement-1".into()]))
        );
    }

    #[test]
    fn gc_recovers_crash_after_atomic_move_before_marker() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        store
            .record_terminal("placement-1", TerminalOutcome::Finished)
            .expect("terminal");
        store
            .mark_terminal_reported("placement-1")
            .expect("reported");
        store.ensure_gc_root().expect("gc root");
        let source = directory.0.join("placement-1");
        let quarantine = store.gc_root().join("placement-1");
        fs::rename(source, &quarantine).expect("simulate atomic move");

        assert_eq!(store.prune_reported_through_generation(4), Ok(Vec::new()));
        assert!(!quarantine.exists());
    }

    #[test]
    fn gc_resumes_partial_delete_when_durable_marker_exists() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.begin(&command("jit-config-abc123==")).expect("begin");
        store
            .record_spawned("placement-1", process_identity(4242))
            .expect("spawned");
        store
            .record_terminal("placement-1", TerminalOutcome::Finished)
            .expect("terminal");
        store
            .mark_terminal_reported("placement-1")
            .expect("reported");
        store.ensure_gc_root().expect("gc root");
        let source = directory.0.join("placement-1");
        let quarantine = store.gc_root().join("placement-1");
        fs::rename(source, &quarantine).expect("simulate atomic move");
        prepare_gc_directory(&quarantine, "placement-1", 4).expect("durable gc marker");
        fs::remove_file(quarantine.join("reported.json")).expect("simulate partial delete");
        fs::remove_file(quarantine.join("terminal.json")).expect("simulate partial delete");

        assert_eq!(store.prune_reported_through_generation(4), Ok(Vec::new()));
        assert!(!quarantine.exists());
    }

    #[test]
    fn gc_refuses_unrecognized_quarantine_contents() {
        let directory = TestDirectory::new();
        let store = PlacementStore::new(&directory.0).expect("store");
        store.ensure_gc_root().expect("gc root");
        let quarantine = store.gc_root().join("placement-1");
        fs::create_dir(&quarantine).expect("quarantine directory");
        fs::write(quarantine.join("unexpected.txt"), b"do not delete").expect("unexpected file");

        assert_eq!(
            store.prune_reported_through_generation(4),
            Err(PlacementStoreError::CorruptState)
        );
        assert!(quarantine.join("unexpected.txt").exists());
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
