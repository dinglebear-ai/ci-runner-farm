use crf_protocol::{NodeSnapshot, Resources, WorkRequirement};
use serde::{Deserialize, Serialize};

pub mod service;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Placement {
    pub work_id: String,
    pub pool_id: String,
    pub node_id: String,
    pub node_generation: u64,
    pub reserved: Resources,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UnplacedReason {
    InvalidRequest,
    NoEligibleNode,
    InsufficientResources,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnplacedWork {
    pub work_id: String,
    pub reason: UnplacedReason,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScheduleResult {
    pub placements: Vec<Placement>,
    pub unplaced: Vec<UnplacedWork>,
}

pub fn schedule(requests: &[WorkRequirement], nodes: &[NodeSnapshot]) -> ScheduleResult {
    let mut state: Vec<NodeSnapshot> = nodes
        .iter()
        .filter(|node| node.validate().is_ok())
        .cloned()
        .collect();
    state.sort_by(|left, right| left.node_id.cmp(&right.node_id));

    let mut result = ScheduleResult::default();

    for request in requests {
        if request.validate().is_err() {
            result.unplaced.push(UnplacedWork {
                work_id: request.work_id.clone(),
                reason: UnplacedReason::InvalidRequest,
            });
            continue;
        }

        let eligible: Vec<usize> = state
            .iter()
            .enumerate()
            .filter_map(|(index, node)| node.matches_constraints(request).then_some(index))
            .collect();

        if eligible.is_empty() {
            result.unplaced.push(UnplacedWork {
                work_id: request.work_id.clone(),
                reason: UnplacedReason::NoEligibleNode,
            });
            continue;
        }

        let selected = eligible
            .into_iter()
            .filter(|index| state[*index].available.fits(request.resources))
            .min_by_key(|index| {
                let node = &state[*index];
                let preferred = request
                    .preferred_cpu_millis
                    .unwrap_or(request.resources.cpu_millis);
                let granted = node.available.cpu_millis.min(preferred);
                (
                    preferred - granted,
                    node.available.memory_bytes - request.resources.memory_bytes,
                    node.available.cpu_millis - granted,
                    node.node_id.clone(),
                )
            });

        let Some(index) = selected else {
            result.unplaced.push(UnplacedWork {
                work_id: request.work_id.clone(),
                reason: UnplacedReason::InsufficientResources,
            });
            continue;
        };

        let node = &mut state[index];
        let reserved = Resources::new(
            node.available.cpu_millis.min(
                request
                    .preferred_cpu_millis
                    .unwrap_or(request.resources.cpu_millis),
            ),
            request.resources.memory_bytes,
        );
        let did_reserve = node.available.subtract(reserved);
        debug_assert!(did_reserve, "selected node must have enough resources");
        result.placements.push(Placement {
            work_id: request.work_id.clone(),
            pool_id: request.pool_id.clone(),
            node_id: node.node_id.clone(),
            node_generation: node.generation,
            reserved,
        });
    }

    result
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use crf_protocol::{Architecture, ExecutionBackend, OperatingSystem};

    use super::*;

    const GIB: u64 = 1024 * 1024 * 1024;

    fn node(
        id: &str,
        os: OperatingSystem,
        backend: ExecutionBackend,
        cpu_millis: u64,
        memory_bytes: u64,
    ) -> NodeSnapshot {
        NodeSnapshot {
            node_id: id.into(),
            generation: 1,
            os,
            arch: Architecture::X86_64,
            execution_backends: BTreeSet::from([backend]),
            capabilities: BTreeSet::new(),
            total: Resources::new(cpu_millis, memory_bytes),
            available: Resources::new(cpu_millis, memory_bytes),
            draining: false,
        }
    }

    fn work(
        id: &str,
        os: OperatingSystem,
        backend: ExecutionBackend,
        cpu_millis: u64,
        memory_bytes: u64,
    ) -> WorkRequirement {
        WorkRequirement {
            work_id: id.into(),
            pool_id: "build".into(),
            resources: Resources::new(cpu_millis, memory_bytes),
            preferred_cpu_millis: None,
            required_os: Some(os),
            required_arch: Some(Architecture::X86_64),
            required_backend: Some(backend),
            required_capabilities: BTreeSet::new(),
        }
    }

    #[test]
    fn preferred_cpu_is_acceleration_not_an_admission_minimum() {
        let nodes = vec![node(
            "small-node",
            OperatingSystem::Linux,
            ExecutionBackend::Container,
            2_000,
            8 * GIB,
        )];
        let mut request = work(
            "job-1",
            OperatingSystem::Linux,
            ExecutionBackend::Container,
            1_000,
            6 * GIB,
        );
        request.preferred_cpu_millis = Some(8_000);

        let result = schedule(&[request], &nodes);

        assert!(result.unplaced.is_empty());
        assert_eq!(result.placements.len(), 1);
        assert_eq!(result.placements[0].node_id, "small-node");
        assert_eq!(
            result.placements[0].reserved,
            Resources::new(2_000, 6 * GIB)
        );
    }

    #[test]
    fn windows_native_work_never_lands_on_linux_container_node() {
        let nodes = vec![
            node(
                "dookie",
                OperatingSystem::Linux,
                ExecutionBackend::Container,
                20_000,
                48 * GIB,
            ),
            node(
                "steamy",
                OperatingSystem::Windows,
                ExecutionBackend::NativeProcess,
                12_000,
                32 * GIB,
            ),
        ];
        let requests = vec![work(
            "job-1",
            OperatingSystem::Windows,
            ExecutionBackend::NativeProcess,
            4_000,
            8 * GIB,
        )];

        let result = schedule(&requests, &nodes);
        assert_eq!(result.placements.len(), 1);
        assert_eq!(result.placements[0].node_id, "steamy");
        assert!(result.unplaced.is_empty());
    }

    #[test]
    fn reservations_prevent_cross_job_oversubscription() {
        let nodes = vec![node(
            "squirts",
            OperatingSystem::Linux,
            ExecutionBackend::Container,
            4_000,
            16 * GIB,
        )];
        let requests = vec![
            work(
                "job-1",
                OperatingSystem::Linux,
                ExecutionBackend::Container,
                3_000,
                8 * GIB,
            ),
            work(
                "job-2",
                OperatingSystem::Linux,
                ExecutionBackend::Container,
                3_000,
                8 * GIB,
            ),
        ];

        let result = schedule(&requests, &nodes);
        assert_eq!(result.placements.len(), 1);
        assert_eq!(result.unplaced.len(), 1);
        assert_eq!(
            result.unplaced[0].reason,
            UnplacedReason::InsufficientResources
        );
    }

    #[test]
    fn equal_fit_is_deterministic_by_node_id() {
        let nodes = vec![
            node(
                "node-b",
                OperatingSystem::Linux,
                ExecutionBackend::Container,
                8_000,
                16 * GIB,
            ),
            node(
                "node-a",
                OperatingSystem::Linux,
                ExecutionBackend::Container,
                8_000,
                16 * GIB,
            ),
        ];
        let requests = vec![work(
            "job-1",
            OperatingSystem::Linux,
            ExecutionBackend::Container,
            2_000,
            4 * GIB,
        )];

        let result = schedule(&requests, &nodes);
        assert_eq!(result.placements[0].node_id, "node-a");
    }

    #[test]
    fn draining_nodes_are_ineligible() {
        let mut draining = node(
            "node-a",
            OperatingSystem::Linux,
            ExecutionBackend::Container,
            8_000,
            16 * GIB,
        );
        draining.draining = true;
        let requests = vec![work(
            "job-1",
            OperatingSystem::Linux,
            ExecutionBackend::Container,
            2_000,
            4 * GIB,
        )];

        let result = schedule(&requests, &[draining]);
        assert!(result.placements.is_empty());
        assert_eq!(result.unplaced[0].reason, UnplacedReason::NoEligibleNode);
    }
}
