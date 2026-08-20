use std::env;

use crf_protocol::{Architecture, OperatingSystem};

pub mod agent;
pub mod command_ledger;
pub mod command_processor;
pub mod config;
pub mod daemon;
pub mod generation;
pub mod native_executor;
pub mod native_materializer;
pub mod placement_state;
pub mod process_identity;
pub mod process_tree;
pub mod runner_archive;
pub mod runner_manifest;
pub mod runner_package;
pub mod runtime;
pub mod system_probe;
pub mod transport;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalPlatform {
    pub node_id: String,
    pub os: OperatingSystem,
    pub arch: Architecture,
    pub logical_cpu_millis: u64,
}

pub fn probe_local_platform() -> LocalPlatform {
    LocalPlatform {
        node_id: suggested_node_id(),
        os: current_os(),
        arch: current_arch(),
        logical_cpu_millis: std::thread::available_parallelism()
            .map(|cpus| cpus.get() as u64 * 1_000)
            .unwrap_or(1_000),
    }
}

pub fn current_os() -> OperatingSystem {
    match env::consts::OS {
        "linux" => OperatingSystem::Linux,
        "windows" => OperatingSystem::Windows,
        "macos" => OperatingSystem::Macos,
        _ => OperatingSystem::Other,
    }
}

pub fn current_arch() -> Architecture {
    match env::consts::ARCH {
        "x86_64" => Architecture::X86_64,
        "aarch64" => Architecture::Arm64,
        _ => Architecture::Other,
    }
}

pub fn suggested_node_id() -> String {
    env::var("CRF_NODE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| env::var("COMPUTERNAME").ok())
        .or_else(|| env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "crf-node".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_probe_reports_some_cpu_capacity() {
        let platform = probe_local_platform();
        assert!(platform.logical_cpu_millis >= 1_000);
        assert!(!platform.node_id.is_empty());
    }
}
