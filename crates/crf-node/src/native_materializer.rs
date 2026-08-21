use std::{
    fs::{self, File, OpenOptions},
    path::{Component, Path, PathBuf},
};

use crf_protocol::OperatingSystem;

const MAX_TEMPLATE_ENTRIES: usize = 30_000;
const MAX_TEMPLATE_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const MAX_COPY_DEPTH: usize = 64;

#[derive(Clone, Debug)]
pub struct RunnerMaterializer {
    os: OperatingSystem,
    template_root: PathBuf,
    runtime_root: PathBuf,
    log_root: PathBuf,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MaterializerError {
    InvalidConfiguration,
    InvalidTemplate,
    CreateRuntimeRoot,
    CreateLogRoot,
    MaterializationConflict,
    MaterializationFailed,
    LogOpenFailed,
}

impl RunnerMaterializer {
    pub fn new(
        os: OperatingSystem,
        template_root: impl Into<PathBuf>,
        runtime_root: impl Into<PathBuf>,
        log_root: impl Into<PathBuf>,
    ) -> Result<Self, MaterializerError> {
        let materializer = Self {
            os,
            template_root: template_root.into(),
            runtime_root: runtime_root.into(),
            log_root: log_root.into(),
        };
        materializer.validate()?;
        Ok(materializer)
    }

    pub fn prepare(&self, placement_id: &str) -> Result<PathBuf, MaterializerError> {
        ensure_private_directory(&self.runtime_root)
            .map_err(|_| MaterializerError::CreateRuntimeRoot)?;
        let final_root = self.runtime_root.join(placement_id);
        if final_root.exists() {
            return Err(MaterializerError::MaterializationConflict);
        }
        let temporary_root = self
            .runtime_root
            .join(format!("{placement_id}.materializing"));
        if temporary_root.exists() {
            return Err(MaterializerError::MaterializationConflict);
        }
        create_private_directory(&temporary_root)
            .map_err(|_| MaterializerError::MaterializationFailed)?;

        let mut budget = CopyBudget::default();
        if copy_tree(
            &self.template_root,
            &self.template_root,
            &temporary_root,
            0,
            &mut budget,
        )
        .is_err()
        {
            let _ = fs::remove_dir_all(&temporary_root);
            return Err(MaterializerError::MaterializationFailed);
        }
        if !expected_runner_entrypoint(&temporary_root, &self.os).is_file() {
            let _ = fs::remove_dir_all(&temporary_root);
            return Err(MaterializerError::InvalidTemplate);
        }
        fs::rename(&temporary_root, &final_root)
            .map_err(|_| MaterializerError::MaterializationConflict)?;
        sync_directory(&self.runtime_root).map_err(|_| MaterializerError::MaterializationFailed)?;
        Ok(final_root)
    }

    pub fn open_logs(&self, placement_id: &str) -> Result<(File, File), MaterializerError> {
        ensure_private_directory(&self.log_root).map_err(|_| MaterializerError::CreateLogRoot)?;
        let directory = self.log_root.join(placement_id);
        if !directory.exists() {
            create_private_directory(&directory).map_err(|_| MaterializerError::CreateLogRoot)?;
        }
        Ok((
            secure_log_file(&directory.join("runner.stdout.log"))?,
            secure_log_file(&directory.join("runner.stderr.log"))?,
        ))
    }

    pub fn os(&self) -> &OperatingSystem {
        &self.os
    }

    pub fn runtime_root(&self) -> &Path {
        &self.runtime_root
    }

    fn validate(&self) -> Result<(), MaterializerError> {
        if matches!(self.os, OperatingSystem::Other)
            || self.template_root.as_os_str().is_empty()
            || self.runtime_root.as_os_str().is_empty()
            || self.log_root.as_os_str().is_empty()
        {
            return Err(MaterializerError::InvalidConfiguration);
        }
        let metadata = fs::symlink_metadata(&self.template_root)
            .map_err(|_| MaterializerError::InvalidTemplate)?;
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            return Err(MaterializerError::InvalidTemplate);
        }
        for forbidden in [".runner", ".credentials", ".credentials_rsaparams"] {
            if self.template_root.join(forbidden).exists() {
                return Err(MaterializerError::InvalidTemplate);
            }
        }
        if !expected_runner_entrypoint(&self.template_root, &self.os).is_file() {
            return Err(MaterializerError::InvalidTemplate);
        }
        Ok(())
    }
}

#[derive(Default)]
struct CopyBudget {
    entries: usize,
    bytes: u64,
}

fn expected_runner_entrypoint(root: &Path, os: &OperatingSystem) -> PathBuf {
    match os {
        OperatingSystem::Windows => root.join("run.cmd"),
        OperatingSystem::Linux | OperatingSystem::Macos => root.join("run.sh"),
        OperatingSystem::Other => root.join("unsupported"),
    }
}

fn copy_tree(
    template_root: &Path,
    source: &Path,
    destination: &Path,
    depth: usize,
    budget: &mut CopyBudget,
) -> Result<(), MaterializerError> {
    if depth > MAX_COPY_DEPTH {
        return Err(MaterializerError::MaterializationFailed);
    }
    for entry in fs::read_dir(source).map_err(|_| MaterializerError::MaterializationFailed)? {
        let entry = entry.map_err(|_| MaterializerError::MaterializationFailed)?;
        budget.entries = budget.entries.saturating_add(1);
        if budget.entries > MAX_TEMPLATE_ENTRIES {
            return Err(MaterializerError::MaterializationFailed);
        }
        let metadata = entry
            .metadata()
            .map_err(|_| MaterializerError::MaterializationFailed)?;
        let file_type = entry
            .file_type()
            .map_err(|_| MaterializerError::MaterializationFailed)?;
        let target = destination.join(entry.file_name());
        if file_type.is_symlink() {
            let link_target = fs::read_link(entry.path())
                .map_err(|_| MaterializerError::MaterializationFailed)?;
            let link_path = entry
                .path()
                .strip_prefix(template_root)
                .map_err(|_| MaterializerError::MaterializationFailed)?
                .to_path_buf();
            validate_symlink_target(&link_path, &link_target)?;
            create_symlink(&link_target, &target)?;
        } else if file_type.is_dir() {
            fs::create_dir(&target).map_err(|_| MaterializerError::MaterializationFailed)?;
            copy_tree(template_root, &entry.path(), &target, depth + 1, budget)?;
            // Cached runner templates are deliberately read-only. Applying the
            // source mode before populating the destination makes directories
            // such as 0555 runner folders impossible to copy as the service
            // user. Populate first, then restore the template's final mode.
            fs::set_permissions(&target, metadata.permissions())
                .map_err(|_| MaterializerError::MaterializationFailed)?;
        } else if file_type.is_file() {
            budget.bytes = budget.bytes.saturating_add(metadata.len());
            if budget.bytes > MAX_TEMPLATE_BYTES {
                return Err(MaterializerError::MaterializationFailed);
            }
            fs::copy(entry.path(), &target)
                .map_err(|_| MaterializerError::MaterializationFailed)?;
        } else {
            return Err(MaterializerError::MaterializationFailed);
        }
    }
    Ok(())
}

fn validate_symlink_target(link_path: &Path, link_target: &Path) -> Result<(), MaterializerError> {
    if link_target.as_os_str().is_empty() || link_target.is_absolute() {
        return Err(MaterializerError::MaterializationFailed);
    }
    let mut depth = link_path
        .parent()
        .map(|parent| {
            parent
                .components()
                .filter(|component| matches!(component, Component::Normal(_)))
                .count()
        })
        .unwrap_or(0);
    for component in link_target.components() {
        match component {
            Component::Normal(_) => depth = depth.saturating_add(1),
            Component::CurDir => {}
            Component::ParentDir if depth > 0 => depth -= 1,
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(MaterializerError::MaterializationFailed);
            }
        }
        if depth > MAX_COPY_DEPTH {
            return Err(MaterializerError::MaterializationFailed);
        }
    }
    if depth == 0 {
        return Err(MaterializerError::MaterializationFailed);
    }
    Ok(())
}

#[cfg(unix)]
fn create_symlink(link_target: &Path, target: &Path) -> Result<(), MaterializerError> {
    std::os::unix::fs::symlink(link_target, target)
        .map_err(|_| MaterializerError::MaterializationFailed)
}

#[cfg(not(unix))]
fn create_symlink(_link_target: &Path, _target: &Path) -> Result<(), MaterializerError> {
    Err(MaterializerError::MaterializationFailed)
}

fn ensure_private_directory(path: &Path) -> Result<(), std::io::Error> {
    if !path.exists() {
        create_private_directory(path)?;
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(std::io::Error::other("unsafe directory"));
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> Result<(), std::io::Error> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn secure_log_file(path: &Path) -> Result<File, MaterializerError> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .map_err(|_| MaterializerError::LogOpenFailed)
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), std::io::Error> {
    File::open(path)?.sync_all()
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<(), std::io::Error> {
    Ok(())
}
