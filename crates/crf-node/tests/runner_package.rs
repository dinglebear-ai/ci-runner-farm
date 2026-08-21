use std::{
    fs,
    io::{Cursor, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use crf_node::{
    runner_manifest::{ArchiveFormat, RunnerArtifact, RunnerManifest},
    runner_package::{RunnerFetcher, RunnerPackageError, RunnerPackageManager},
};
use crf_protocol::{Architecture, OperatingSystem};
use flate2::{Compression, write::GzEncoder};
use sha2::{Digest, Sha256};
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

struct TestRoot(PathBuf);

impl TestRoot {
    fn new(name: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "crf-runner-package-{name}-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("test root");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestRoot {
    fn drop(&mut self) {
        make_writable(&self.0);
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct BytesFetcher {
    bytes: Vec<u8>,
    calls: AtomicUsize,
}

impl BytesFetcher {
    fn new(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            calls: AtomicUsize::new(0),
        }
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl RunnerFetcher for BytesFetcher {
    fn fetch(
        &self,
        _url: &str,
        destination: &Path,
        _expected_size: u64,
    ) -> Result<(), RunnerPackageError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        fs::write(destination, &self.bytes).map_err(|_| RunnerPackageError::CacheIo)
    }
}

#[test]
fn valid_linux_tar_is_installed_once_and_reused_from_cache() {
    let root = TestRoot::new("linux-cache");
    let archive = tar_gz_file(
        "run.sh",
        b"#!/bin/sh
exit 0
",
        0o755,
    );
    let manager = package_manager(
        root.path(),
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        None,
    );
    let fetcher = BytesFetcher::new(archive);

    let first = manager
        .resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher)
        .expect("first install");
    assert!(first.join("run.sh").is_file());
    assert!(!first.join("package.json").exists());
    assert_eq!(fetcher.calls(), 1);

    let second = manager
        .resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher)
        .expect("cache hit");
    assert_eq!(first, second);
    assert_eq!(fetcher.calls(), 1);
}

#[test]
fn valid_windows_zip_installs_run_cmd() {
    let root = TestRoot::new("windows-zip");
    let archive = zip_file(
        "run.cmd",
        b"@echo off
exit /b 0
",
        false,
    );
    let manager = package_manager(
        root.path(),
        OperatingSystem::Windows,
        Architecture::X86_64,
        ArchiveFormat::Zip,
        &archive,
        None,
        None,
    );
    let fetcher = BytesFetcher::new(archive);

    let template = manager
        .resolve_with_fetcher(&OperatingSystem::Windows, &Architecture::X86_64, &fetcher)
        .expect("windows install");
    assert!(template.join("run.cmd").is_file());
}

#[test]
fn digest_and_size_mismatch_fail_before_extraction() {
    let digest_root = TestRoot::new("digest");
    let archive = tar_gz_file(
        "run.sh",
        b"#!/bin/sh
",
        0o755,
    );
    let manager = package_manager(
        digest_root.path(),
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        Some("b".repeat(64)),
        None,
    );
    assert_eq!(
        manager.resolve_with_fetcher(
            &OperatingSystem::Linux,
            &Architecture::X86_64,
            &BytesFetcher::new(archive.clone()),
        ),
        Err(RunnerPackageError::DigestMismatch)
    );
    assert!(!digest_root.path().join("escape").exists());

    let size_root = TestRoot::new("size");
    let manager = package_manager(
        size_root.path(),
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        Some(archive.len() as u64 + 1),
    );
    assert_eq!(
        manager.resolve_with_fetcher(
            &OperatingSystem::Linux,
            &Architecture::X86_64,
            &BytesFetcher::new(archive),
        ),
        Err(RunnerPackageError::DownloadSizeMismatch)
    );
}

#[test]
fn tar_parent_traversal_and_escaping_symlink_are_rejected() {
    let traversal_root = TestRoot::new("tar-traversal");
    let archive = malicious_parent_tar_gz();
    let manager = package_manager(
        traversal_root.path(),
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        None,
    );
    assert_eq!(
        manager.resolve_with_fetcher(
            &OperatingSystem::Linux,
            &Architecture::X86_64,
            &BytesFetcher::new(archive),
        ),
        Err(RunnerPackageError::UnsafeArchive)
    );
    assert!(!traversal_root.path().join("escape").exists());

    let link_root = TestRoot::new("tar-link");
    let archive = tar_gz_symlink();
    let manager = package_manager(
        link_root.path(),
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        None,
    );
    assert_eq!(
        manager.resolve_with_fetcher(
            &OperatingSystem::Linux,
            &Architecture::X86_64,
            &BytesFetcher::new(archive),
        ),
        Err(RunnerPackageError::UnsafeArchive)
    );
}

#[test]
fn zip_parent_traversal_and_symlink_are_rejected() {
    let traversal_root = TestRoot::new("zip-traversal");
    let archive = zip_file("../escape", b"nope", false);
    let manager = package_manager(
        traversal_root.path(),
        OperatingSystem::Windows,
        Architecture::X86_64,
        ArchiveFormat::Zip,
        &archive,
        None,
        None,
    );
    assert_eq!(
        manager.resolve_with_fetcher(
            &OperatingSystem::Windows,
            &Architecture::X86_64,
            &BytesFetcher::new(archive),
        ),
        Err(RunnerPackageError::UnsafeArchive)
    );
    assert!(!traversal_root.path().join("escape").exists());

    let link_root = TestRoot::new("zip-link");
    let archive = zip_file("linked", b"run.cmd", true);
    let manager = package_manager(
        link_root.path(),
        OperatingSystem::Windows,
        Architecture::X86_64,
        ArchiveFormat::Zip,
        &archive,
        None,
        None,
    );
    assert_eq!(
        manager.resolve_with_fetcher(
            &OperatingSystem::Windows,
            &Architecture::X86_64,
            &BytesFetcher::new(archive),
        ),
        Err(RunnerPackageError::UnsafeArchive)
    );
}

#[test]
fn corrupted_cached_marker_and_template_fail_closed_without_refetch() {
    let marker_root = TestRoot::new("cache-marker-corrupt");
    let archive = tar_gz_file(
        "run.sh",
        b"#!/bin/sh
exit 0
",
        0o755,
    );
    let manager = package_manager(
        marker_root.path(),
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        None,
    );
    let fetcher = BytesFetcher::new(archive.clone());
    let template = manager
        .resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher)
        .expect("install");
    let entry = template.parent().expect("entry");
    make_writable(entry);
    fs::write(entry.join("package.json"), br#"{"schema_version":999}"#).expect("corrupt marker");

    assert_eq!(
        manager.resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher),
        Err(RunnerPackageError::CacheConflict)
    );
    assert_eq!(fetcher.calls(), 1);

    let template_root = TestRoot::new("cache-template-corrupt");
    let manager = package_manager(
        template_root.path(),
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        None,
    );
    let fetcher = BytesFetcher::new(archive);
    let template = manager
        .resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher)
        .expect("install");
    make_writable(template.parent().expect("entry"));
    fs::remove_file(template.join("run.sh")).expect("remove entrypoint");

    assert_eq!(
        manager.resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher),
        Err(RunnerPackageError::InvalidTemplate)
    );
    assert_eq!(fetcher.calls(), 1);
}

#[test]
fn cache_pruning_keeps_current_and_one_previous_version() {
    let root = TestRoot::new("cache-prune");
    let archive = tar_gz_file(
        "run.sh",
        b"#!/bin/sh
exit 0
",
        0o755,
    );
    let manager = package_manager(
        root.path(),
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        None,
    );
    let fetcher = BytesFetcher::new(archive.clone());

    let first = manager
        .resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher)
        .expect("v1");
    assert!(first.exists());

    write_manifest(
        root.path(),
        "2.337.0",
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        None,
    );
    let second = manager
        .resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher)
        .expect("v2");
    assert!(second.exists());

    write_manifest(
        root.path(),
        "2.338.0",
        OperatingSystem::Linux,
        Architecture::X86_64,
        ArchiveFormat::TarGz,
        &archive,
        None,
        None,
    );
    let current = manager
        .resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher)
        .expect("v3");
    assert!(current.exists());
    assert_eq!(fetcher.calls(), 3);

    let entries = fs::read_dir(root.path().join("cache/templates"))
        .expect("templates")
        .map(|entry| entry.expect("entry").path())
        .collect::<Vec<_>>();
    assert_eq!(entries.len(), 2);
    assert!(
        entries
            .iter()
            .any(|path| path == current.parent().expect("current entry"))
    );
    assert!(!first.exists());
}

#[test]
fn strict_manifest_rejects_unknown_fields_before_fetch() {
    let root = TestRoot::new("manifest-unknown");
    let manifest_path = root.path().join("manifest.json");
    fs::write(
        &manifest_path,
        r#"{"schema_version":1,"version":"2.336.0","artifacts":[],"surprise":true}"#,
    )
    .expect("manifest");
    let manager =
        RunnerPackageManager::new(&manifest_path, root.path().join("cache")).expect("manager");
    let fetcher = BytesFetcher::new(Vec::new());
    assert_eq!(
        manager.resolve_with_fetcher(&OperatingSystem::Linux, &Architecture::X86_64, &fetcher),
        Err(RunnerPackageError::Manifest)
    );
    assert_eq!(fetcher.calls(), 0);
}

fn package_manager(
    root: &Path,
    os: OperatingSystem,
    arch: Architecture,
    format: ArchiveFormat,
    archive: &[u8],
    digest_override: Option<String>,
    size_override: Option<u64>,
) -> RunnerPackageManager {
    write_manifest(
        root,
        "2.336.0",
        os,
        arch,
        format,
        archive,
        digest_override,
        size_override,
    );
    RunnerPackageManager::new(root.join("manifest.json"), root.join("cache")).expect("manager")
}

#[allow(clippy::too_many_arguments)]
fn write_manifest(
    root: &Path,
    version: &str,
    os: OperatingSystem,
    arch: Architecture,
    format: ArchiveFormat,
    archive: &[u8],
    digest_override: Option<String>,
    size_override: Option<u64>,
) {
    let manifest = RunnerManifest {
        schema_version: 1,
        version: version.into(),
        artifacts: vec![RunnerArtifact {
            os,
            arch,
            url: "https://example.invalid/actions-runner".into(),
            sha256: digest_override.unwrap_or_else(|| sha256(archive)),
            size_bytes: size_override.unwrap_or(archive.len() as u64),
            format,
        }],
    };
    fs::write(
        root.join("manifest.json"),
        serde_json::to_vec(&manifest).expect("json"),
    )
    .expect("manifest");
}

fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn tar_gz_file(path: &str, data: &[u8], mode: u32) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    let mut header = tar::Header::new_gnu();
    header.set_path(path).expect("path");
    header.set_mode(mode);
    header.set_size(data.len() as u64);
    header.set_cksum();
    builder.append(&header, data).expect("append");
    gzip(builder.into_inner().expect("tar"))
}

fn tar_gz_symlink() -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    let mut header = tar::Header::new_gnu();
    header.set_path("linked").expect("path");
    header.set_entry_type(tar::EntryType::Symlink);
    header.set_link_name("../escape").expect("link");
    header.set_size(0);
    header.set_cksum();
    builder.append(&header, std::io::empty()).expect("append");
    gzip(builder.into_inner().expect("tar"))
}

fn malicious_parent_tar_gz() -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    let mut header = tar::Header::new_gnu();
    header.set_path("aaaaaaaaa").expect("safe source path");
    header.set_mode(0o644);
    header.set_size(4);
    header.set_cksum();
    builder.append(&header, &b"nope"[..]).expect("append");
    let mut raw = builder.into_inner().expect("tar");

    raw[..100].fill(0);
    raw[..9].copy_from_slice(b"../escape");
    raw[148..156].fill(b' ');
    let checksum: u32 = raw[..512].iter().map(|byte| u32::from(*byte)).sum();
    let encoded = format!("{checksum:06o}  ");
    raw[148..156].copy_from_slice(encoded.as_bytes());
    gzip(raw)
}

fn gzip(raw: Vec<u8>) -> Vec<u8> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(&raw).expect("gzip write");
    encoder.finish().expect("gzip")
}

fn zip_file(path: &str, data: &[u8], symlink: bool) -> Vec<u8> {
    let cursor = Cursor::new(Vec::new());
    let mut writer = ZipWriter::new(cursor);
    let options = SimpleFileOptions::default()
        .compression_method(CompressionMethod::Stored)
        .unix_permissions(0o755);
    if symlink {
        writer
            .add_symlink(path, String::from_utf8_lossy(data), options)
            .expect("symlink");
    } else {
        writer.start_file(path, options).expect("zip file");
        writer.write_all(data).expect("zip data");
    }
    writer.finish().expect("zip finish").into_inner()
}

#[cfg_attr(windows, allow(clippy::permissions_set_readonly_false))]
fn make_writable(path: &Path) {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return;
    };
    if metadata.file_type().is_symlink() {
        return;
    }
    if metadata.is_dir() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
        }
        if let Ok(entries) = fs::read_dir(path) {
            for entry in entries.flatten() {
                make_writable(&entry.path());
            }
        }
    } else if metadata.is_file() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
        }
        #[cfg(not(unix))]
        {
            let mut permissions = metadata.permissions();
            permissions.set_readonly(false);
            let _ = fs::set_permissions(path, permissions);
        }
    }
}
