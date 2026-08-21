use std::{collections::BTreeSet, fs, path::Path};

use crf_protocol::{Architecture, OperatingSystem};
use serde::{Deserialize, Serialize};

const SCHEMA_VERSION: u32 = 1;
const MAX_MANIFEST_BYTES: u64 = 256 * 1024;
pub const MAX_ARCHIVE_BYTES: u64 = 1024 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RunnerManifest {
    pub schema_version: u32,
    pub version: String,
    pub artifacts: Vec<RunnerArtifact>,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RunnerArtifact {
    pub os: OperatingSystem,
    pub arch: Architecture,
    pub url: String,
    pub sha256: String,
    pub size_bytes: u64,
    pub format: ArchiveFormat,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ArchiveFormat {
    TarGz,
    Zip,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ManifestError {
    Read,
    Invalid,
    UnsupportedPlatform,
}

impl RunnerManifest {
    pub fn load(path: &Path) -> Result<Self, ManifestError> {
        let metadata = fs::symlink_metadata(path).map_err(|_| ManifestError::Read)?;
        if !metadata.file_type().is_file()
            || metadata.file_type().is_symlink()
            || metadata.len() == 0
            || metadata.len() > MAX_MANIFEST_BYTES
        {
            return Err(ManifestError::Read);
        }
        let bytes = fs::read(path).map_err(|_| ManifestError::Read)?;
        let manifest: Self = serde_json::from_slice(&bytes).map_err(|_| ManifestError::Invalid)?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn validate(&self) -> Result<(), ManifestError> {
        if self.schema_version != SCHEMA_VERSION
            || !valid_version(&self.version)
            || self.artifacts.is_empty()
            || self.artifacts.len() > 16
        {
            return Err(ManifestError::Invalid);
        }

        let mut platforms = BTreeSet::new();
        for artifact in &self.artifacts {
            if matches!(artifact.os, OperatingSystem::Other)
                || matches!(artifact.arch, Architecture::Other)
                || !valid_https_url(&artifact.url)
                || normalize_digest(&artifact.sha256).is_none()
                || artifact.size_bytes == 0
                || artifact.size_bytes > MAX_ARCHIVE_BYTES
                || !platforms.insert((artifact.os.clone(), artifact.arch.clone()))
            {
                return Err(ManifestError::Invalid);
            }
        }
        Ok(())
    }

    pub fn artifact_for(
        &self,
        os: &OperatingSystem,
        arch: &Architecture,
    ) -> Result<&RunnerArtifact, ManifestError> {
        self.artifacts
            .iter()
            .find(|artifact| &artifact.os == os && &artifact.arch == arch)
            .ok_or(ManifestError::UnsupportedPlatform)
    }
}

pub fn normalize_digest(value: &str) -> Option<String> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    Some(value.to_ascii_lowercase())
}

fn valid_https_url(value: &str) -> bool {
    value.starts_with("https://") && value.len() <= 2_048 && !value.chars().any(char::is_whitespace)
}

fn valid_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn artifact(os: OperatingSystem, arch: Architecture) -> RunnerArtifact {
        RunnerArtifact {
            os,
            arch,
            url: "https://github.com/actions/runner/releases/download/v2.336.0/runner.tar.gz"
                .into(),
            sha256: "a".repeat(64),
            size_bytes: 100,
            format: ArchiveFormat::TarGz,
        }
    }

    #[test]
    fn strict_manifest_selects_exact_platform() {
        let manifest = RunnerManifest {
            schema_version: 1,
            version: "2.336.0".into(),
            artifacts: vec![artifact(OperatingSystem::Linux, Architecture::X86_64)],
        };
        assert_eq!(manifest.validate(), Ok(()));
        assert!(
            manifest
                .artifact_for(&OperatingSystem::Linux, &Architecture::X86_64)
                .is_ok()
        );
        assert_eq!(
            manifest.artifact_for(&OperatingSystem::Windows, &Architecture::X86_64),
            Err(ManifestError::UnsupportedPlatform)
        );
    }

    #[test]
    fn duplicate_platform_http_url_and_bad_digest_fail_closed() {
        let duplicate = RunnerManifest {
            schema_version: 1,
            version: "2.336.0".into(),
            artifacts: vec![
                artifact(OperatingSystem::Linux, Architecture::X86_64),
                artifact(OperatingSystem::Linux, Architecture::X86_64),
            ],
        };
        assert_eq!(duplicate.validate(), Err(ManifestError::Invalid));

        let mut insecure = artifact(OperatingSystem::Linux, Architecture::X86_64);
        insecure.url = "http://example.invalid/runner.tgz".into();
        insecure.sha256 = "xyz".into();
        let invalid = RunnerManifest {
            schema_version: 1,
            version: "2.336.0".into(),
            artifacts: vec![insecure],
        };
        assert_eq!(invalid.validate(), Err(ManifestError::Invalid));
    }
}
