use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::Duration,
};

use crf_protocol::Resources;

use crate::controller_endpoint::ControllerEndpoint;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RunnerSourceConfig {
    Template(PathBuf),
    Managed {
        manifest_path: PathBuf,
        cache_root: PathBuf,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NodeExecutionConfig {
    Native {
        runner_source: RunnerSourceConfig,
        runtime_root: PathBuf,
        log_root: PathBuf,
    },
    Container {
        adapter_program: PathBuf,
        adapter_timeout: Duration,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NodeConfig {
    pub controller_addr: ControllerEndpoint,
    pub controller_server_name: String,
    pub ca_cert_path: PathBuf,
    pub client_cert_path: PathBuf,
    pub client_key_path: PathBuf,
    pub state_root: PathBuf,
    pub execution: NodeExecutionConfig,
    pub resources: Resources,
    pub heartbeat_interval: Duration,
    pub connect_timeout: Duration,
    pub io_timeout: Duration,
    pub command_ledger_capacity: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigError {
    MissingValue,
    InvalidControllerAddress,
    InvalidServerName,
    InvalidPath,
    InvalidRunnerSource,
    InvalidExecutionBackend,
    UnsafePathLayout,
    InvalidResources,
    InvalidDuration,
    InvalidLedgerCapacity,
}

impl NodeConfig {
    pub fn from_env() -> Result<Self, ConfigError> {
        let values = std::env::vars().collect::<BTreeMap<_, _>>();
        Self::from_values(&values)
    }

    pub fn from_values(values: &BTreeMap<String, String>) -> Result<Self, ConfigError> {
        let controller_addr = ControllerEndpoint::parse(required(values, "CRF_CONTROLLER_ADDR")?)
            .map_err(|_| ConfigError::InvalidControllerAddress)?;
        let controller_server_name = required(values, "CRF_CONTROLLER_SERVER_NAME")?.to_owned();
        if controller_server_name.is_empty() || controller_server_name.len() > 253 {
            return Err(ConfigError::InvalidServerName);
        }

        let ca_cert_path = absolute_path(required(values, "CRF_CA_CERT")?)?;
        let client_cert_path = absolute_path(required(values, "CRF_CLIENT_CERT")?)?;
        let client_key_path = absolute_path(required(values, "CRF_CLIENT_KEY")?)?;
        let state_root = absolute_path(required(values, "CRF_STATE_DIR")?)?;
        let execution = execution_config(values, &state_root)?;

        let cpu_millis = positive_u64(required(values, "CRF_NODE_CPU_MILLIS")?)
            .map_err(|_| ConfigError::InvalidResources)?;
        let memory_bytes = positive_u64(required(values, "CRF_NODE_MEMORY_BYTES")?)
            .map_err(|_| ConfigError::InvalidResources)?;
        let heartbeat_interval = duration_ms(values, "CRF_HEARTBEAT_MS", 5_000, 1_000, 60_000)?;
        let connect_timeout = duration_ms(values, "CRF_CONNECT_TIMEOUT_MS", 5_000, 100, 120_000)?;
        let io_timeout = duration_ms(values, "CRF_IO_TIMEOUT_MS", 15_000, 100, 120_000)?;
        let command_ledger_capacity = optional_u64(values, "CRF_COMMAND_LEDGER_CAPACITY", 4_096)
            .map_err(|_| ConfigError::InvalidLedgerCapacity)?;
        if command_ledger_capacity == 0 || command_ledger_capacity > 4_096 {
            return Err(ConfigError::InvalidLedgerCapacity);
        }

        Ok(Self {
            controller_addr,
            controller_server_name,
            ca_cert_path,
            client_cert_path,
            client_key_path,
            state_root,
            execution,
            resources: Resources::new(cpu_millis, memory_bytes),
            heartbeat_interval,
            connect_timeout,
            io_timeout,
            command_ledger_capacity: command_ledger_capacity as usize,
        })
    }
}

fn execution_config(
    values: &BTreeMap<String, String>,
    state_root: &Path,
) -> Result<NodeExecutionConfig, ConfigError> {
    match optional(values, "CRF_EXECUTION_BACKEND").unwrap_or("native_process") {
        "native_process" => {
            let runtime_root = absolute_path(required(values, "CRF_RUNTIME_DIR")?)?;
            let log_root = absolute_path(required(values, "CRF_LOG_DIR")?)?;
            let runner_source = runner_source(values)?;
            validate_path_layout(&runner_source, state_root, &runtime_root, &log_root)?;
            Ok(NodeExecutionConfig::Native {
                runner_source,
                runtime_root,
                log_root,
            })
        }
        "container" => {
            let adapter_program =
                absolute_path(required(values, "CRF_CONTAINER_ADAPTER_PROGRAM")?)?;
            if adapter_program.starts_with(state_root) || state_root.starts_with(&adapter_program) {
                return Err(ConfigError::UnsafePathLayout);
            }
            let adapter_timeout = duration_ms(
                values,
                "CRF_CONTAINER_ADAPTER_TIMEOUT_MS",
                15_000,
                100,
                120_000,
            )?;
            Ok(NodeExecutionConfig::Container {
                adapter_program,
                adapter_timeout,
            })
        }
        _ => Err(ConfigError::InvalidExecutionBackend),
    }
}

fn runner_source(values: &BTreeMap<String, String>) -> Result<RunnerSourceConfig, ConfigError> {
    let template = optional(values, "CRF_RUNNER_TEMPLATE");
    let manifest = optional(values, "CRF_RUNNER_MANIFEST");
    let cache = optional(values, "CRF_RUNNER_CACHE_DIR");

    match (template, manifest, cache) {
        (Some(template), None, None) => Ok(RunnerSourceConfig::Template(absolute_path(template)?)),
        (None, Some(manifest), Some(cache)) => Ok(RunnerSourceConfig::Managed {
            manifest_path: absolute_path(manifest)?,
            cache_root: absolute_path(cache)?,
        }),
        _ => Err(ConfigError::InvalidRunnerSource),
    }
}

fn required<'a>(values: &'a BTreeMap<String, String>, key: &str) -> Result<&'a str, ConfigError> {
    optional(values, key).ok_or(ConfigError::MissingValue)
}

fn optional<'a>(values: &'a BTreeMap<String, String>, key: &str) -> Option<&'a str> {
    values
        .get(key)
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
}

fn absolute_path(value: &str) -> Result<PathBuf, ConfigError> {
    let path = PathBuf::from(value);
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(ConfigError::InvalidPath);
    }
    Ok(path)
}

fn validate_path_layout(
    source: &RunnerSourceConfig,
    state: &Path,
    runtime: &Path,
    logs: &Path,
) -> Result<(), ConfigError> {
    let mut writable = vec![state, runtime, logs];
    match source {
        RunnerSourceConfig::Template(template) => {
            if writable
                .iter()
                .any(|path| path == &template.as_path() || path.starts_with(template))
            {
                return Err(ConfigError::UnsafePathLayout);
            }
        }
        RunnerSourceConfig::Managed {
            manifest_path,
            cache_root,
        } => {
            writable.push(cache_root.as_path());
            if writable
                .iter()
                .any(|path| manifest_path == *path || manifest_path.starts_with(path))
            {
                return Err(ConfigError::UnsafePathLayout);
            }
        }
    }

    for (index, left) in writable.iter().enumerate() {
        for right in writable.iter().skip(index + 1) {
            if left == right || left.starts_with(right) || right.starts_with(left) {
                return Err(ConfigError::UnsafePathLayout);
            }
        }
    }
    Ok(())
}

fn positive_u64(value: &str) -> Result<u64, ()> {
    value
        .parse::<u64>()
        .ok()
        .filter(|value| *value > 0)
        .ok_or(())
}

fn optional_u64(values: &BTreeMap<String, String>, key: &str, default: u64) -> Result<u64, ()> {
    match values.get(key) {
        None => Ok(default),
        Some(value) => positive_u64(value),
    }
}

fn duration_ms(
    values: &BTreeMap<String, String>,
    key: &str,
    default: u64,
    min: u64,
    max: u64,
) -> Result<Duration, ConfigError> {
    let value = optional_u64(values, key, default).map_err(|_| ConfigError::InvalidDuration)?;
    if value < min || value > max {
        return Err(ConfigError::InvalidDuration);
    }
    Ok(Duration::from_millis(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_path(path: &str) -> String {
        #[cfg(windows)]
        {
            format!(
                r"C:\crf-test\{}",
                path.trim_start_matches('/').replace('/', "\\")
            )
        }
        #[cfg(not(windows))]
        {
            path.to_owned()
        }
    }

    fn values() -> BTreeMap<String, String> {
        BTreeMap::from([
            ("CRF_CONTROLLER_ADDR".into(), "127.0.0.1:9443".into()),
            (
                "CRF_CONTROLLER_SERVER_NAME".into(),
                "controller.internal".into(),
            ),
            ("CRF_CA_CERT".into(), test_path("/etc/crf/ca.pem")),
            ("CRF_CLIENT_CERT".into(), test_path("/etc/crf/node.pem")),
            ("CRF_CLIENT_KEY".into(), test_path("/etc/crf/node-key.pem")),
            ("CRF_STATE_DIR".into(), test_path("/var/lib/crf/state")),
            (
                "CRF_RUNNER_TEMPLATE".into(),
                test_path("/opt/crf/runner-template"),
            ),
            ("CRF_RUNTIME_DIR".into(), test_path("/var/lib/crf/runners")),
            ("CRF_LOG_DIR".into(), test_path("/var/log/crf")),
            ("CRF_NODE_CPU_MILLIS".into(), "8000".into()),
            ("CRF_NODE_MEMORY_BYTES".into(), "17179869184".into()),
        ])
    }

    #[test]
    fn valid_staged_config_uses_bounded_defaults() {
        let config = NodeConfig::from_values(&values()).expect("config");
        assert_eq!(
            config.execution,
            NodeExecutionConfig::Native {
                runner_source: RunnerSourceConfig::Template(PathBuf::from(test_path(
                    "/opt/crf/runner-template",
                ))),
                runtime_root: PathBuf::from(test_path("/var/lib/crf/runners")),
                log_root: PathBuf::from(test_path("/var/log/crf")),
            }
        );
        assert_eq!(
            config.resources,
            Resources::new(8_000, 16 * 1024 * 1024 * 1024)
        );
        assert_eq!(config.heartbeat_interval, Duration::from_secs(5));
        assert_eq!(config.command_ledger_capacity, 4_096);
    }

    #[test]
    fn controller_endpoint_accepts_magicdns_hostname_without_resolving_at_parse_time() {
        let mut values = values();
        values.insert(
            "CRF_CONTROLLER_ADDR".into(),
            "controller.tailnet-name.ts.net:9443".into(),
        );
        let config = NodeConfig::from_values(&values).expect("MagicDNS endpoint");
        assert_eq!(
            config.controller_addr.as_str(),
            "controller.tailnet-name.ts.net:9443"
        );
    }

    #[test]
    fn controller_endpoint_rejects_url_and_zero_port_shapes() {
        for endpoint in ["https://controller:9443", "controller:0", "bad_name:9443"] {
            let mut values = values();
            values.insert("CRF_CONTROLLER_ADDR".into(), endpoint.into());
            assert_eq!(
                NodeConfig::from_values(&values),
                Err(ConfigError::InvalidControllerAddress),
                "{endpoint}"
            );
        }
    }

    #[test]
    fn container_backend_requires_only_adapter_runtime_configuration() {
        let mut container = values();
        container.remove("CRF_RUNNER_TEMPLATE");
        container.remove("CRF_RUNTIME_DIR");
        container.remove("CRF_LOG_DIR");
        container.insert("CRF_EXECUTION_BACKEND".into(), "container".into());
        container.insert(
            "CRF_CONTAINER_ADAPTER_PROGRAM".into(),
            test_path("/usr/local/libexec/crf-container-adapter"),
        );

        assert_eq!(
            NodeConfig::from_values(&container)
                .expect("container config")
                .execution,
            NodeExecutionConfig::Container {
                adapter_program: PathBuf::from(test_path(
                    "/usr/local/libexec/crf-container-adapter",
                )),
                adapter_timeout: Duration::from_secs(15),
            }
        );
    }

    #[test]
    fn container_backend_rejects_unknown_backend_and_unsafe_adapter_path() {
        let mut invalid = values();
        invalid.insert("CRF_EXECUTION_BACKEND".into(), "docker".into());
        assert_eq!(
            NodeConfig::from_values(&invalid),
            Err(ConfigError::InvalidExecutionBackend)
        );

        let mut overlapping = values();
        overlapping.remove("CRF_RUNNER_TEMPLATE");
        overlapping.remove("CRF_RUNTIME_DIR");
        overlapping.remove("CRF_LOG_DIR");
        overlapping.insert("CRF_EXECUTION_BACKEND".into(), "container".into());
        overlapping.insert(
            "CRF_CONTAINER_ADAPTER_PROGRAM".into(),
            test_path("/var/lib/crf/state/bin/adapter"),
        );
        assert_eq!(
            NodeConfig::from_values(&overlapping),
            Err(ConfigError::UnsafePathLayout)
        );
    }

    #[test]
    fn container_adapter_timeout_is_bounded() {
        let mut container = values();
        container.remove("CRF_RUNNER_TEMPLATE");
        container.remove("CRF_RUNTIME_DIR");
        container.remove("CRF_LOG_DIR");
        container.insert("CRF_EXECUTION_BACKEND".into(), "container".into());
        container.insert(
            "CRF_CONTAINER_ADAPTER_PROGRAM".into(),
            test_path("/usr/local/libexec/crf-container-adapter"),
        );
        container.insert("CRF_CONTAINER_ADAPTER_TIMEOUT_MS".into(), "121000".into());
        assert_eq!(
            NodeConfig::from_values(&container),
            Err(ConfigError::InvalidDuration)
        );
    }

    #[test]
    fn managed_runner_source_requires_manifest_and_cache_only() {
        let mut managed = values();
        managed.remove("CRF_RUNNER_TEMPLATE");
        managed.insert(
            "CRF_RUNNER_MANIFEST".into(),
            test_path("/etc/crf/runner-manifest.json"),
        );
        managed.insert(
            "CRF_RUNNER_CACHE_DIR".into(),
            test_path("/var/cache/crf/runner"),
        );

        assert_eq!(
            NodeConfig::from_values(&managed)
                .expect("managed")
                .execution,
            NodeExecutionConfig::Native {
                runner_source: RunnerSourceConfig::Managed {
                    manifest_path: PathBuf::from(test_path("/etc/crf/runner-manifest.json")),
                    cache_root: PathBuf::from(test_path("/var/cache/crf/runner")),
                },
                runtime_root: PathBuf::from(test_path("/var/lib/crf/runners")),
                log_root: PathBuf::from(test_path("/var/log/crf")),
            }
        );

        managed.insert(
            "CRF_RUNNER_TEMPLATE".into(),
            test_path("/opt/crf/runner-template"),
        );
        assert_eq!(
            NodeConfig::from_values(&managed),
            Err(ConfigError::InvalidRunnerSource)
        );
    }

    #[test]
    fn writable_paths_cannot_live_inside_runner_template() {
        let mut values = values();
        values.insert(
            "CRF_RUNTIME_DIR".into(),
            test_path("/opt/crf/runner-template/runners"),
        );
        assert_eq!(
            NodeConfig::from_values(&values),
            Err(ConfigError::UnsafePathLayout)
        );
    }

    #[test]
    fn managed_cache_cannot_overlap_other_writable_roots() {
        let mut values = values();
        values.remove("CRF_RUNNER_TEMPLATE");
        values.insert(
            "CRF_RUNNER_MANIFEST".into(),
            test_path("/etc/crf/runner-manifest.json"),
        );
        values.insert(
            "CRF_RUNNER_CACHE_DIR".into(),
            test_path("/var/lib/crf/runners/cache"),
        );
        assert_eq!(
            NodeConfig::from_values(&values),
            Err(ConfigError::UnsafePathLayout)
        );
    }

    #[test]
    fn explicit_resource_budget_is_required() {
        let mut values = values();
        values.remove("CRF_NODE_MEMORY_BYTES");
        assert_eq!(
            NodeConfig::from_values(&values),
            Err(ConfigError::MissingValue)
        );
    }
}
