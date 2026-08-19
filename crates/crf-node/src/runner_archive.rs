use std::{
    fs::{self, File, OpenOptions},
    io,
    path::{Component, Path, PathBuf},
};

use crf_protocol::OperatingSystem;
use flate2::read::GzDecoder;

use crate::runner_manifest::ArchiveFormat;

const MAX_TEMPLATE_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const MAX_TEMPLATE_ENTRIES: usize = 30_000;
const MAX_DEPTH: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RunnerArchiveError {
    Io,
    UnsafeArchive,
    InvalidTemplate,
}

pub fn extract_archive(
    archive_path: &Path,
    destination: &Path,
    format: ArchiveFormat,
) -> Result<(), RunnerArchiveError> {
    match format {
        ArchiveFormat::TarGz => extract_tar_gz(archive_path, destination),
        ArchiveFormat::Zip => extract_zip(archive_path, destination),
    }
}

pub fn validate_template_tree(root: &Path, os: &OperatingSystem) -> Result<(), RunnerArchiveError> {
    let metadata = fs::symlink_metadata(root).map_err(|_| RunnerArchiveError::InvalidTemplate)?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(RunnerArchiveError::InvalidTemplate);
    }
    for forbidden in [".runner", ".credentials", ".credentials_rsaparams"] {
        if root.join(forbidden).exists() {
            return Err(RunnerArchiveError::InvalidTemplate);
        }
    }
    let entrypoint = expected_entrypoint(root, os)?;
    let entrypoint_metadata =
        fs::symlink_metadata(entrypoint).map_err(|_| RunnerArchiveError::InvalidTemplate)?;
    if !entrypoint_metadata.file_type().is_file() || entrypoint_metadata.file_type().is_symlink() {
        return Err(RunnerArchiveError::InvalidTemplate);
    }
    scan_tree(root, 0, &mut Budget::default())
}

pub fn freeze_tree(path: &Path) -> Result<(), RunnerArchiveError> {
    freeze(path, 0)
}

fn extract_tar_gz(archive_path: &Path, destination: &Path) -> Result<(), RunnerArchiveError> {
    let file = File::open(archive_path).map_err(|_| RunnerArchiveError::Io)?;
    let mut archive = tar::Archive::new(GzDecoder::new(file));
    let entries = archive.entries().map_err(|_| RunnerArchiveError::Io)?;
    let mut budget = Budget::default();

    for entry in entries {
        let mut entry = entry.map_err(|_| RunnerArchiveError::Io)?;
        budget.entry()?;
        let entry_type = entry.header().entry_type();
        if !entry_type.is_file() && !entry_type.is_dir() {
            return Err(RunnerArchiveError::UnsafeArchive);
        }
        let relative = entry
            .path()
            .map_err(|_| RunnerArchiveError::UnsafeArchive)?
            .into_owned();
        validate_relative_path(&relative)?;
        let target = destination.join(relative);

        if entry_type.is_dir() {
            ensure_private_directory(&target).map_err(|_| RunnerArchiveError::Io)?;
            continue;
        }

        let size = entry.size();
        budget.bytes(size)?;
        if let Some(parent) = target.parent() {
            ensure_private_directory(parent).map_err(|_| RunnerArchiveError::Io)?;
        }
        let mut output = secure_new_file(&target).map_err(|_| RunnerArchiveError::UnsafeArchive)?;
        let copied = io::copy(&mut entry, &mut output).map_err(|_| RunnerArchiveError::Io)?;
        if copied != size {
            return Err(RunnerArchiveError::Io);
        }
        output.sync_all().map_err(|_| RunnerArchiveError::Io)?;
        set_archive_file_mode(&target, entry.header().mode().ok())?;
    }
    Ok(())
}

fn extract_zip(archive_path: &Path, destination: &Path) -> Result<(), RunnerArchiveError> {
    let file = File::open(archive_path).map_err(|_| RunnerArchiveError::Io)?;
    let mut archive = zip::ZipArchive::new(file).map_err(|_| RunnerArchiveError::Io)?;
    if archive.len() > MAX_TEMPLATE_ENTRIES {
        return Err(RunnerArchiveError::UnsafeArchive);
    }
    let mut budget = Budget::default();

    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|_| RunnerArchiveError::Io)?;
        budget.entry()?;
        if entry.is_symlink() || unsafe_zip_mode(entry.unix_mode(), entry.is_dir()) {
            return Err(RunnerArchiveError::UnsafeArchive);
        }
        let relative = entry
            .enclosed_name()
            .ok_or(RunnerArchiveError::UnsafeArchive)?;
        validate_relative_path(&relative)?;
        let target = destination.join(relative);

        if entry.is_dir() {
            ensure_private_directory(&target).map_err(|_| RunnerArchiveError::Io)?;
            continue;
        }
        if !entry.is_file() {
            return Err(RunnerArchiveError::UnsafeArchive);
        }
        let size = entry.size();
        budget.bytes(size)?;
        if let Some(parent) = target.parent() {
            ensure_private_directory(parent).map_err(|_| RunnerArchiveError::Io)?;
        }
        let mut output = secure_new_file(&target).map_err(|_| RunnerArchiveError::UnsafeArchive)?;
        let copied = io::copy(&mut entry, &mut output).map_err(|_| RunnerArchiveError::Io)?;
        if copied != size {
            return Err(RunnerArchiveError::Io);
        }
        output.sync_all().map_err(|_| RunnerArchiveError::Io)?;
        set_archive_file_mode(&target, entry.unix_mode())?;
    }
    Ok(())
}

fn unsafe_zip_mode(mode: Option<u32>, directory: bool) -> bool {
    let Some(mode) = mode else { return false };
    let kind = mode & 0o170000;
    if directory {
        kind != 0 && kind != 0o040000
    } else {
        kind != 0 && kind != 0o100000
    }
}

#[derive(Default)]
struct Budget {
    entries: usize,
    bytes: u64,
}

impl Budget {
    fn entry(&mut self) -> Result<(), RunnerArchiveError> {
        self.entries = self.entries.saturating_add(1);
        if self.entries > MAX_TEMPLATE_ENTRIES {
            return Err(RunnerArchiveError::UnsafeArchive);
        }
        Ok(())
    }

    fn bytes(&mut self, value: u64) -> Result<(), RunnerArchiveError> {
        self.bytes = self
            .bytes
            .checked_add(value)
            .ok_or(RunnerArchiveError::UnsafeArchive)?;
        if self.bytes > MAX_TEMPLATE_BYTES {
            return Err(RunnerArchiveError::UnsafeArchive);
        }
        Ok(())
    }
}

fn validate_relative_path(path: &Path) -> Result<(), RunnerArchiveError> {
    if path.as_os_str().is_empty() || path.is_absolute() {
        return Err(RunnerArchiveError::UnsafeArchive);
    }
    let mut depth = 0_usize;
    for component in path.components() {
        match component {
            Component::Normal(_) => depth = depth.saturating_add(1),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(RunnerArchiveError::UnsafeArchive);
            }
        }
        if depth > MAX_DEPTH {
            return Err(RunnerArchiveError::UnsafeArchive);
        }
    }
    if depth == 0 {
        return Err(RunnerArchiveError::UnsafeArchive);
    }
    Ok(())
}

fn scan_tree(root: &Path, depth: usize, budget: &mut Budget) -> Result<(), RunnerArchiveError> {
    if depth > MAX_DEPTH {
        return Err(RunnerArchiveError::InvalidTemplate);
    }
    for entry in fs::read_dir(root).map_err(|_| RunnerArchiveError::InvalidTemplate)? {
        let entry = entry.map_err(|_| RunnerArchiveError::InvalidTemplate)?;
        budget
            .entry()
            .map_err(|_| RunnerArchiveError::InvalidTemplate)?;
        let metadata =
            fs::symlink_metadata(entry.path()).map_err(|_| RunnerArchiveError::InvalidTemplate)?;
        let kind = metadata.file_type();
        if kind.is_symlink() {
            return Err(RunnerArchiveError::InvalidTemplate);
        }
        if kind.is_dir() {
            scan_tree(&entry.path(), depth + 1, budget)?;
        } else if kind.is_file() {
            budget
                .bytes(metadata.len())
                .map_err(|_| RunnerArchiveError::InvalidTemplate)?;
        } else {
            return Err(RunnerArchiveError::InvalidTemplate);
        }
    }
    Ok(())
}

fn expected_entrypoint(root: &Path, os: &OperatingSystem) -> Result<PathBuf, RunnerArchiveError> {
    match os {
        OperatingSystem::Windows => Ok(root.join("run.cmd")),
        OperatingSystem::Linux | OperatingSystem::Macos => Ok(root.join("run.sh")),
        OperatingSystem::Other => Err(RunnerArchiveError::InvalidTemplate),
    }
}

fn freeze(path: &Path, depth: usize) -> Result<(), RunnerArchiveError> {
    if depth > MAX_DEPTH {
        return Err(RunnerArchiveError::InvalidTemplate);
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| RunnerArchiveError::Io)?;
    if metadata.file_type().is_symlink() {
        return Err(RunnerArchiveError::InvalidTemplate);
    }
    if metadata.file_type().is_dir() {
        for entry in fs::read_dir(path).map_err(|_| RunnerArchiveError::Io)? {
            let entry = entry.map_err(|_| RunnerArchiveError::Io)?;
            freeze(&entry.path(), depth + 1)?;
        }
        set_readonly_directory(path).map_err(|_| RunnerArchiveError::Io)?;
    } else if metadata.file_type().is_file() {
        set_readonly_file(path, &metadata).map_err(|_| RunnerArchiveError::Io)?;
    } else {
        return Err(RunnerArchiveError::InvalidTemplate);
    }
    Ok(())
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
fn set_archive_file_mode(path: &Path, mode: Option<u32>) -> Result<(), RunnerArchiveError> {
    use std::os::unix::fs::PermissionsExt;
    let safe_mode = mode.unwrap_or(0o644) & 0o777;
    fs::set_permissions(path, fs::Permissions::from_mode(safe_mode))
        .map_err(|_| RunnerArchiveError::Io)
}

#[cfg(not(unix))]
fn set_archive_file_mode(_path: &Path, _mode: Option<u32>) -> Result<(), RunnerArchiveError> {
    Ok(())
}

#[cfg(unix)]
fn set_readonly_directory(path: &Path) -> Result<(), io::Error> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o555))
}

#[cfg(not(unix))]
fn set_readonly_directory(_path: &Path) -> Result<(), io::Error> {
    Ok(())
}

#[cfg(unix)]
fn set_readonly_file(path: &Path, metadata: &fs::Metadata) -> Result<(), io::Error> {
    use std::os::unix::fs::PermissionsExt;
    let executable = metadata.permissions().mode() & 0o111 != 0;
    fs::set_permissions(
        path,
        fs::Permissions::from_mode(if executable { 0o555 } else { 0o444 }),
    )
}

#[cfg(not(unix))]
fn set_readonly_file(path: &Path, metadata: &fs::Metadata) -> Result<(), io::Error> {
    let mut permissions = metadata.permissions();
    permissions.set_readonly(true);
    fs::set_permissions(path, permissions)
}
