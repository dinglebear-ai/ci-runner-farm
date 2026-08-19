use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

use crf_protocol::valid_identifier;
use sha2::{Digest, Sha256};

const GENERATION_PREFIX: &str = "generation-";
const GENERATION_SUFFIX: &str = ".state";
const GENERATION_DIGITS: usize = 20;
const MAX_GENERATION_FILES: usize = 1_000_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GenerationError {
    InvalidNodeId,
    InvalidStateDirectory,
    CreateStateDirectory,
    OpenLockFile,
    LockFailed,
    ReadStateDirectory,
    CorruptGenerationFilename,
    TooManyGenerationFiles,
    GenerationExhausted,
    ReserveGeneration,
    WriteGeneration,
    SyncGeneration,
    UnlockFailed,
}

pub fn reserve_next_generation(
    state_directory: &Path,
    node_id: &str,
) -> Result<u64, GenerationError> {
    if !valid_identifier(node_id) {
        return Err(GenerationError::InvalidNodeId);
    }
    ensure_state_directory(state_directory)?;

    let lock_path = state_directory.join(".generation.lock");
    let lock_file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(lock_path)
        .map_err(|_| GenerationError::OpenLockFile)?;
    lock_file.lock().map_err(|_| GenerationError::LockFailed)?;

    let result = reserve_locked(state_directory, node_id);
    let unlock_result = lock_file.unlock();
    match (result, unlock_result) {
        (Ok(generation), Ok(())) => Ok(generation),
        (Err(error), _) => Err(error),
        (Ok(_), Err(_)) => Err(GenerationError::UnlockFailed),
    }
}

fn reserve_locked(state_directory: &Path, node_id: &str) -> Result<u64, GenerationError> {
    let mut max_generation = 0_u64;
    let mut generation_files = 0_usize;

    for entry in fs::read_dir(state_directory).map_err(|_| GenerationError::ReadStateDirectory)? {
        let entry = entry.map_err(|_| GenerationError::ReadStateDirectory)?;
        let file_type = entry
            .file_type()
            .map_err(|_| GenerationError::ReadStateDirectory)?;
        if !file_type.is_file() {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if !name.starts_with(GENERATION_PREFIX) {
            continue;
        }
        generation_files = generation_files.saturating_add(1);
        if generation_files > MAX_GENERATION_FILES {
            return Err(GenerationError::TooManyGenerationFiles);
        }
        let generation = parse_generation_filename(name)?;
        max_generation = max_generation.max(generation);
    }

    let next = max_generation
        .checked_add(1)
        .filter(|generation| *generation > 0)
        .ok_or(GenerationError::GenerationExhausted)?;
    let path = generation_path(state_directory, next);
    let mut reservation = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|_| GenerationError::ReserveGeneration)?;

    let checksum = generation_checksum(node_id, next);
    let record = format!(
        "schema_version=1
node_id={node_id}
generation={next}
checksum={checksum}
"
    );
    reservation
        .write_all(record.as_bytes())
        .map_err(|_| GenerationError::WriteGeneration)?;
    reservation
        .sync_all()
        .map_err(|_| GenerationError::SyncGeneration)?;
    Ok(next)
}

fn ensure_state_directory(path: &Path) -> Result<(), GenerationError> {
    if path.as_os_str().is_empty() {
        return Err(GenerationError::InvalidStateDirectory);
    }
    fs::create_dir_all(path).map_err(|_| GenerationError::CreateStateDirectory)?;
    let metadata =
        fs::symlink_metadata(path).map_err(|_| GenerationError::InvalidStateDirectory)?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(GenerationError::InvalidStateDirectory);
    }
    Ok(())
}

fn parse_generation_filename(name: &str) -> Result<u64, GenerationError> {
    if !name.ends_with(GENERATION_SUFFIX) {
        return Err(GenerationError::CorruptGenerationFilename);
    }
    let digits = &name[GENERATION_PREFIX.len()..name.len() - GENERATION_SUFFIX.len()];
    if digits.len() != GENERATION_DIGITS || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(GenerationError::CorruptGenerationFilename);
    }
    digits
        .parse::<u64>()
        .ok()
        .filter(|generation| *generation > 0)
        .ok_or(GenerationError::CorruptGenerationFilename)
}

fn generation_path(state_directory: &Path, generation: u64) -> PathBuf {
    state_directory.join(format!(
        "{GENERATION_PREFIX}{generation:0GENERATION_DIGITS$}{GENERATION_SUFFIX}"
    ))
}

fn generation_checksum(node_id: &str, generation: u64) -> String {
    let input = format!("crf-generation-v1|{node_id}|{generation}");
    let digest = Sha256::digest(input.as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use std::{
        fs::{File, OpenOptions},
        sync::atomic::{AtomicU64, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    use super::*;

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(1);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let counter = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "crf-generation-test-{}-{counter}-{nanos}",
                std::process::id()
            ));
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn generations_increase_monotonically() {
        let directory = TestDirectory::new();
        assert_eq!(reserve_next_generation(directory.path(), "dookie"), Ok(1));
        assert_eq!(reserve_next_generation(directory.path(), "dookie"), Ok(2));
        assert_eq!(reserve_next_generation(directory.path(), "dookie"), Ok(3));
    }

    #[test]
    fn partial_reserved_generation_is_burned_not_reused() {
        let directory = TestDirectory::new();
        fs::create_dir_all(directory.path()).expect("directory");
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(generation_path(directory.path(), 10))
            .expect("reserve partial generation");

        assert_eq!(reserve_next_generation(directory.path(), "steamy"), Ok(11));
    }

    #[test]
    fn malformed_generation_filename_fails_closed() {
        let directory = TestDirectory::new();
        fs::create_dir_all(directory.path()).expect("directory");
        File::create(directory.path().join("generation-not-a-number.state"))
            .expect("malformed state");

        assert_eq!(
            reserve_next_generation(directory.path(), "dookie"),
            Err(GenerationError::CorruptGenerationFilename)
        );
    }

    #[test]
    fn unrelated_files_do_not_change_generation() {
        let directory = TestDirectory::new();
        fs::create_dir_all(directory.path()).expect("directory");
        File::create(directory.path().join("notes.txt")).expect("unrelated file");
        assert_eq!(reserve_next_generation(directory.path(), "dookie"), Ok(1));
    }

    #[test]
    fn invalid_node_identity_fails_before_touching_state() {
        let directory = TestDirectory::new();
        assert_eq!(
            reserve_next_generation(directory.path(), "bad/node"),
            Err(GenerationError::InvalidNodeId)
        );
        assert!(!directory.path().exists());
    }
}
