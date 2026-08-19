use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

pub mod wire;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperatingSystem {
    Linux,
    Windows,
    Macos,
    Other,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Architecture {
    X86_64,
    Arm64,
    Other,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionBackend {
    Container,
    NativeProcess,
    VirtualMachine,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Resources {
    pub cpu_millis: u64,
    pub memory_bytes: u64,
}

impl Resources {
    pub const fn new(cpu_millis: u64, memory_bytes: u64) -> Self {
        Self {
            cpu_millis,
            memory_bytes,
        }
    }

    pub const fn fits(self, requested: Self) -> bool {
        self.cpu_millis >= requested.cpu_millis && self.memory_bytes >= requested.memory_bytes
    }

    pub fn subtract(&mut self, requested: Self) -> bool {
        if !self.fits(requested) {
            return false;
        }
        self.cpu_millis -= requested.cpu_millis;
        self.memory_bytes -= requested.memory_bytes;
        true
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NodeSnapshot {
    pub node_id: String,
    pub generation: u64,
    pub os: OperatingSystem,
    pub arch: Architecture,
    pub execution_backends: BTreeSet<ExecutionBackend>,
    pub capabilities: BTreeSet<String>,
    pub total: Resources,
    pub available: Resources,
    pub draining: bool,
}

impl NodeSnapshot {
    pub fn validate(&self) -> Result<(), ValidationError> {
        if !valid_identifier(&self.node_id) {
            return Err(ValidationError::InvalidNodeId);
        }
        if self.generation == 0 {
            return Err(ValidationError::InvalidGeneration);
        }
        if self.total.cpu_millis == 0 || self.total.memory_bytes == 0 {
            return Err(ValidationError::InvalidResources);
        }
        if self.execution_backends.is_empty() {
            return Err(ValidationError::InvalidExecutionBackends);
        }
        if self.available.cpu_millis > self.total.cpu_millis
            || self.available.memory_bytes > self.total.memory_bytes
        {
            return Err(ValidationError::AvailableExceedsTotal);
        }
        if self
            .capabilities
            .iter()
            .any(|capability| !valid_identifier(capability))
        {
            return Err(ValidationError::InvalidCapability);
        }
        Ok(())
    }

    pub fn matches_constraints(&self, work: &WorkRequirement) -> bool {
        if self.draining {
            return false;
        }
        if let Some(os) = &work.required_os
            && &self.os != os
        {
            return false;
        }
        if let Some(arch) = &work.required_arch
            && &self.arch != arch
        {
            return false;
        }
        if let Some(backend) = &work.required_backend
            && !self.execution_backends.contains(backend)
        {
            return false;
        }
        work.required_capabilities
            .iter()
            .all(|capability| self.capabilities.contains(capability))
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkRequirement {
    pub work_id: String,
    pub pool_id: String,
    pub resources: Resources,
    pub required_os: Option<OperatingSystem>,
    pub required_arch: Option<Architecture>,
    pub required_backend: Option<ExecutionBackend>,
    pub required_capabilities: BTreeSet<String>,
}

impl WorkRequirement {
    pub fn validate(&self) -> Result<(), ValidationError> {
        if !valid_identifier(&self.work_id) {
            return Err(ValidationError::InvalidWorkId);
        }
        if !valid_identifier(&self.pool_id) {
            return Err(ValidationError::InvalidPoolId);
        }
        if self.resources.cpu_millis == 0 || self.resources.memory_bytes == 0 {
            return Err(ValidationError::InvalidResources);
        }
        if self
            .required_capabilities
            .iter()
            .any(|capability| !valid_identifier(capability))
        {
            return Err(ValidationError::InvalidCapability);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ValidationError {
    InvalidNodeId,
    InvalidWorkId,
    InvalidPoolId,
    InvalidGeneration,
    InvalidResources,
    AvailableExceedsTotal,
    InvalidExecutionBackends,
    InvalidCapability,
}

pub fn valid_identifier(value: &str) -> bool {
    if value.is_empty() || value.len() > 128 {
        return false;
    }
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_alphanumeric() {
        return false;
    }
    chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | ':' | '-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_are_bounded_and_transport_safe() {
        assert!(valid_identifier("dookie-01"));
        assert!(valid_identifier("pool:rust_x64"));
        assert!(!valid_identifier("-bad"));
        assert!(!valid_identifier("bad/name"));
        assert!(!valid_identifier(""));
    }

    #[test]
    fn resources_never_underflow() {
        let mut available = Resources::new(4_000, 8 * 1024 * 1024 * 1024);
        assert!(!available.subtract(Resources::new(5_000, 1)));
        assert_eq!(available.cpu_millis, 4_000);
        assert!(available.subtract(Resources::new(1_000, 1024)));
        assert_eq!(available.cpu_millis, 3_000);
    }

    #[test]
    fn nodes_without_an_execution_backend_are_rejected() {
        let node = NodeSnapshot {
            node_id: "node-1".into(),
            generation: 1,
            os: OperatingSystem::Linux,
            arch: Architecture::X86_64,
            execution_backends: BTreeSet::new(),
            capabilities: BTreeSet::new(),
            total: Resources::new(4_000, 8 * 1024 * 1024 * 1024),
            available: Resources::new(4_000, 8 * 1024 * 1024 * 1024),
            draining: false,
        };

        assert_eq!(
            node.validate(),
            Err(ValidationError::InvalidExecutionBackends)
        );
    }
}
