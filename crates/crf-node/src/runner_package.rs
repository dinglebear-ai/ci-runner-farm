use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Component, Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use crf_protocol::{Architecture, OperatingSystem};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    runner_archive::{RunnerArchiveError, extract_archive, freeze_tree, validate_template_tree},
    runner_manifest::{
        ArchiveFormat, ManifestError, RunnerArtifact, RunnerManifest, normalize_digest,
    },
};

const MARKER_FILE: &str = "package.json";
const TEMPLATE_DIR: &str = "template";
const CACHE_LOCK_FILE: &str = ".runner-cache.lock";
const MAX_CACHED_ENTRIES: usize = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RunnerPackageError {
    InvalidConfiguration,
    Manifest,
    UnsupportedPlatform,
    CacheIo,
    DownloadFailed,
    DownloadSizeMismatch,
    DigestMismatch,
    UnsafeArchive,
    ExtractionFailed,
    InvalidTemplate,
    CacheConflict,
}

impl From<ManifestError> for RunnerPackageError {
    fn from(value: ManifestError) -> Self {
        match value {
            ManifestError::UnsupportedPlatform => Self::UnsupportedPlatform,
            ManifestError::Read | ManifestError::Invalid => Self::Manifest,
        }
    }
}

impl From<RunnerArchiveError> for RunnerPackageError {
    fn from(value: RunnerArchiveError) -> Self {
        match value {
            RunnerArchiveError::Io => Self::ExtractionFailed,
            RunnerArchiveError::UnsafeArchive => Self::UnsafeArchive,
            RunnerArchiveError::InvalidTemplate => Self::InvalidTemplate,
        }
    }
}

pub trait RunnerFetcher {
    fn fetch(
        &self,
        url: &str,
        destination: &Path,
        expected_size: u64,
    ) -> Result<(), RunnerPackageError>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct HttpRunnerFetcher;

impl RunnerFetcher for HttpRunnerFetcher {
    fn fetch(
        &self,
        url: &str,
        destination: &Path,
        expected_size: u64,
    ) -> Result<(), RunnerPackageError> {
        let mut response = ureq::get(url)
            .call()
            .map_err(|_| RunnerPackageError::DownloadFailed)?;
        let mut reader = response.body_mut().as_reader();
        let mut output = secure_new_file(destination).map_err(|_| RunnerPackageError::CacheIo)?;
        let mut total = 0_u64;
        let mut buffer = [0_u8; 64 * 1024];

        loop {
            let read = reader
                .read(&mut buffer)
                .map_err(|_| RunnerPackageError::DownloadFailed)?;
            if read == 0 {
                break;
            }
            total = total
                .checked_add(read as u64)
                .ok_or(RunnerPackageError::DownloadSizeMismatch)?;
            if total > expected_size {
                return Err(RunnerPackageError::DownloadSizeMismatch);
            }
            output
                .write_all(&buffer[..read])
                .map_err(|_| RunnerPackageError::CacheIo)?;
        }
        output.sync_all().map_err(|_| RunnerPackageError::CacheIo)?;
        if total != expected_size {
            return Err(RunnerPackageError::DownloadSizeMismatch);
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct RunnerPackageManager {
    manifest_path: PathBuf,
    cache_root: PathBuf,
}

impl RunnerPackageManager {
    pub fn new(
        manifest_path: impl Into<PathBuf>,
        cache_root: impl Into<PathBuf>,
    ) -> Result<Self, RunnerPackageError> {
        let manager = Self {
            manifest_path: manifest_path.into(),
            cache_root: cache_root.into(),
        };
        if !safe_absolute(&manager.manifest_path) || !safe_absolute(&manager.cache_root) {
            return Err(RunnerPackageError::InvalidConfiguration);
        }
        Ok(manager)
    }

    pub fn resolve(
        &self,
        os: &OperatingSystem,
        arch: &Architecture,
    ) -> Result<PathBuf, RunnerPackageError> {
        self.resolve_with_fetcher(os, arch, &HttpRunnerFetcher)
    }

    pub fn resolve_with_fetcher(
        &self,
        os: &OperatingSystem,
        arch: &Architecture,
        fetcher: &dyn RunnerFetcher,
    ) -> Result<PathBuf, RunnerPackageError> {
        let manifest = RunnerManifest::load(&self.manifest_path)?;
        let artifact = manifest.artifact_for(os, arch)?;
        let digest = normalize_digest(&artifact.sha256).ok_or(RunnerPackageError::Manifest)?;

        ensure_private_directory(&self.cache_root).map_err(|_| RunnerPackageError::CacheIo)?;
        let _cache_lock = acquire_cache_lock(&self.cache_root)?;
        let templates_root = self.cache_root.join("templates");
        ensure_private_directory(&templates_root).map_err(|_| RunnerPackageError::CacheIo)?;
        let final_entry = templates_root.join(cache_key(&manifest.version, artifact, &digest));

        if final_entry.exists() {
            let template =
                validate_cached_entry(&final_entry, &manifest.version, artifact, &digest)?;
            prune_cache(&templates_root, &final_entry)?;
            return Ok(template);
        }

        let install_root = self
            .cache_root
            .join(format!(".install-{}", unique_suffix()));
        create_private_directory(&install_root).map_err(|_| RunnerPackageError::CacheIo)?;
        let archive_path = install_root.join("runner.archive");
        let staging_entry = install_root.join("entry");
        let staging_template = staging_entry.join(TEMPLATE_DIR);
        create_private_directory(&staging_template).map_err(|_| RunnerPackageError::CacheIo)?;

        let install_result = (|| {
            fetcher.fetch(&artifact.url, &archive_path, artifact.size_bytes)?;
            verify_archive(&archive_path, artifact.size_bytes, &digest)?;
            extract_archive(&archive_path, &staging_template, artifact.format)?;
            validate_template_tree(&staging_template, os)?;
            write_marker(
                &staging_entry,
                &CacheMarker {
                    schema_version: 1,
                    version: manifest.version.clone(),
                    os: artifact.os.clone(),
                    arch: artifact.arch.clone(),
                    sha256: digest.clone(),
                    size_bytes: artifact.size_bytes,
                    format: artifact.format,
                },
            )?;

            match fs::rename(&staging_entry, &final_entry) {
                Ok(()) => {
                    freeze_tree(&final_entry)?;
                    sync_directory(&templates_root).map_err(|_| RunnerPackageError::CacheIo)?;
                    Ok(final_entry.join(TEMPLATE_DIR))
                }
                Err(_) if final_entry.exists() => {
                    validate_cached_entry(&final_entry, &manifest.version, artifact, &digest)
                }
                Err(_) => Err(RunnerPackageError::CacheConflict),
            }
        })();

        let _ = fs::remove_dir_all(&install_root);
        let template = install_result?;
        prune_cache(&templates_root, &final_entry)?;
        Ok(template)
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct CacheMarker {
    schema_version: u32,
    version: String,
    os: OperatingSystem,
    arch: Architecture,
    sha256: String,
    size_bytes: u64,
    format: ArchiveFormat,
}

fn cache_key(version: &str, artifact: &RunnerArtifact, digest: &str) -> String {
    format!(
        "{}-{}-{}-{}",
        version,
        os_token(&artifact.os),
        arch_token(&artifact.arch),
        &digest[..16]
    )
}

fn validate_cached_entry(
    entry_root: &Path,
    version: &str,
    artifact: &RunnerArtifact,
    digest: &str,
) -> Result<PathBuf, RunnerPackageError> {
    let metadata =
        fs::symlink_metadata(entry_root).map_err(|_| RunnerPackageError::CacheConflict)?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(RunnerPackageError::CacheConflict);
    }
    let marker_path = entry_root.join(MARKER_FILE);
    let marker_metadata =
        fs::symlink_metadata(&marker_path).map_err(|_| RunnerPackageError::CacheConflict)?;
    if !marker_metadata.file_type().is_file()
        || marker_metadata.file_type().is_symlink()
        || marker_metadata.len() == 0
        || marker_metadata.len() > 8 * 1024
    {
        return Err(RunnerPackageError::CacheConflict);
    }
    let marker: CacheMarker = serde_json::from_slice(
        &fs::read(marker_path).map_err(|_| RunnerPackageError::CacheConflict)?,
    )
    .map_err(|_| RunnerPackageError::CacheConflict)?;
    if marker.schema_version != 1
        || marker.version != version
        || marker.os != artifact.os
        || marker.arch != artifact.arch
        || marker.sha256 != digest
        || marker.size_bytes != artifact.size_bytes
        || marker.format != artifact.format
    {
        return Err(RunnerPackageError::CacheConflict);
    }
    let template_root = entry_root.join(TEMPLATE_DIR);
    validate_template_tree(&template_root, &artifact.os)?;
    Ok(template_root)
}

fn verify_archive(
    path: &Path,
    expected_size: u64,
    expected_sha256: &str,
) -> Result<(), RunnerPackageError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| RunnerPackageError::CacheIo)?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(RunnerPackageError::CacheIo);
    }
    if metadata.len() != expected_size {
        return Err(RunnerPackageError::DownloadSizeMismatch);
    }
    let mut file = File::open(path).map_err(|_| RunnerPackageError::CacheIo)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| RunnerPackageError::CacheIo)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let actual = format!("{:x}", hasher.finalize());
    if actual != expected_sha256 {
        return Err(RunnerPackageError::DigestMismatch);
    }
    Ok(())
}

fn write_marker(root: &Path, marker: &CacheMarker) -> Result<(), RunnerPackageError> {
    let bytes = serde_json::to_vec(marker).map_err(|_| RunnerPackageError::CacheIo)?;
    let mut file =
        secure_new_file(&root.join(MARKER_FILE)).map_err(|_| RunnerPackageError::CacheIo)?;
    file.write_all(&bytes)
        .map_err(|_| RunnerPackageError::CacheIo)?;
    file.sync_all().map_err(|_| RunnerPackageError::CacheIo)
}

fn safe_absolute(path: &Path) -> bool {
    path.is_absolute()
        && !path
            .components()
            .any(|component| matches!(component, Component::ParentDir))
}

fn os_token(os: &OperatingSystem) -> &'static str {
    match os {
        OperatingSystem::Linux => "linux",
        OperatingSystem::Windows => "windows",
        OperatingSystem::Macos => "macos",
        OperatingSystem::Other => "other",
    }
}

fn arch_token(arch: &Architecture) -> &'static str {
    match arch {
        Architecture::X86_64 => "x86_64",
        Architecture::Arm64 => "arm64",
        Architecture::Other => "other",
    }
}

fn acquire_cache_lock(cache_root: &Path) -> Result<File, RunnerPackageError> {
    let path = cache_root.join(CACHE_LOCK_FILE);
    if path.exists() {
        let metadata = fs::symlink_metadata(&path).map_err(|_| RunnerPackageError::CacheIo)?;
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            return Err(RunnerPackageError::CacheConflict);
        }
    }

    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(&path)
        .map_err(|_| RunnerPackageError::CacheIo)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .map_err(|_| RunnerPackageError::CacheIo)?;
    }
    file.lock().map_err(|_| RunnerPackageError::CacheIo)?;
    Ok(file)
}

fn prune_cache(templates_root: &Path, current: &Path) -> Result<(), RunnerPackageError> {
    let mut candidates = Vec::new();
    for entry in fs::read_dir(templates_root).map_err(|_| RunnerPackageError::CacheIo)? {
        let entry = entry.map_err(|_| RunnerPackageError::CacheIo)?;
        let path = entry.path();
        if path == current {
            continue;
        }
        let metadata = fs::symlink_metadata(&path).map_err(|_| RunnerPackageError::CacheIo)?;
        if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
            return Err(RunnerPackageError::CacheConflict);
        }
        candidates.push((
            metadata.modified().unwrap_or(UNIX_EPOCH),
            entry.file_name(),
            path,
        ));
    }

    candidates.sort_by(|left, right| right.0.cmp(&left.0).then_with(|| right.1.cmp(&left.1)));
    let keep_previous = MAX_CACHED_ENTRIES.saturating_sub(1);
    let mut removed = false;
    for (_, _, path) in candidates.into_iter().skip(keep_previous) {
        thaw_tree(&path, 0)?;
        fs::remove_dir_all(path).map_err(|_| RunnerPackageError::CacheIo)?;
        removed = true;
    }
    if removed {
        sync_directory(templates_root).map_err(|_| RunnerPackageError::CacheIo)?;
    }
    Ok(())
}

fn thaw_tree(path: &Path, depth: usize) -> Result<(), RunnerPackageError> {
    if depth > 64 {
        return Err(RunnerPackageError::CacheConflict);
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| RunnerPackageError::CacheIo)?;
    if metadata.file_type().is_symlink() {
        return Err(RunnerPackageError::CacheConflict);
    }
    if metadata.file_type().is_dir() {
        set_writable_directory(path).map_err(|_| RunnerPackageError::CacheIo)?;
        for entry in fs::read_dir(path).map_err(|_| RunnerPackageError::CacheIo)? {
            let entry = entry.map_err(|_| RunnerPackageError::CacheIo)?;
            thaw_tree(&entry.path(), depth + 1)?;
        }
    } else if metadata.file_type().is_file() {
        set_writable_file(path, &metadata).map_err(|_| RunnerPackageError::CacheIo)?;
    } else {
        return Err(RunnerPackageError::CacheConflict);
    }
    Ok(())
}

#[cfg(unix)]
fn set_writable_directory(path: &Path) -> Result<(), io::Error> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

#[cfg(not(unix))]
fn set_writable_directory(_path: &Path) -> Result<(), io::Error> {
    Ok(())
}

#[cfg(unix)]
fn set_writable_file(path: &Path, _metadata: &fs::Metadata) -> Result<(), io::Error> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}

#[cfg(windows)]
#[allow(clippy::permissions_set_readonly_false)]
fn set_writable_file(path: &Path, metadata: &fs::Metadata) -> Result<(), io::Error> {
    // On Windows this toggles FILE_ATTRIBUTE_READONLY; it does not make the
    // file world-writable as the same portable API can on Unix.
    let mut permissions = metadata.permissions();
    permissions.set_readonly(false);
    fs::set_permissions(path, permissions)
}

#[cfg(all(not(unix), not(windows)))]
fn set_writable_file(_path: &Path, _metadata: &fs::Metadata) -> Result<(), io::Error> {
    Ok(())
}

fn unique_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("{}-{nanos}", std::process::id())
}

fn secure_new_file(path: &Path) -> Result<File, io::Error> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn ensure_private_directory(path: &Path) -> Result<(), io::Error> {
    if !path.exists() {
        create_private_directory(path)?;
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(io::Error::other("unsafe directory"));
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> Result<(), io::Error> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), io::Error> {
    File::open(path)?.sync_all()
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<(), io::Error> {
    Ok(())
}
