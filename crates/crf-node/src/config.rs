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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResourceBudgetConfig {
    Explicit(Resources),
    Auto {
        cpu_reserve_millis: u64,
        memory_reserve_bytes: u64,
    },
}

impl ResourceBudgetConfig {
    pub fn resolve(self, host: Resources) -> Result<Resources, ConfigError> {
        match self {
            Self::Explicit(resources) if host.fits(resources) => Ok(resources),
            Self::Explicit(_) => Err(ConfigError::InvalidResources),
            Self::Auto {
                cpu_reserve_millis,
                memory_reserve_bytes,
            } => {
                let cpu_millis = host.cpu_millis.checked_sub(cpu_reserve_millis);
                let memory_bytes = host.memory_bytes.checked_sub(memory_reserve_bytes);
                match (cpu_millis, memory_bytes) {
                    (Some(cpu), Some(memory)) if cpu > 0 && memory > 0 => {
                        Ok(Resources::new(cpu, memory))
                    }
                    _ => Err(ConfigError::InvalidResources),
                }
            }
        }
    }
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
    pub resource_budget: ResourceBudgetConfig,
    pub heartbeat_interval: Duration,
    pub connect_timeout: Duration,
    pub io_timeout: Duration,
    pub command_ledger_capacity: usize,
    pub operator_projection_path: Option<PathBuf>,
    pub node_status_path: Option<PathBuf>,
    pub node_launch_token: Option<LaunchToken>,
}

#[derive(Clone, Eq, PartialEq)]
pub struct LaunchToken(String);

impl LaunchToken {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for LaunchToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("LaunchToken([REDACTED])")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigError {
    MissingValue,
    InvalidControllerAddress,
    InvalidServerName,
    InvalidPath,
    InvalidRunnerSource,
    InvalidExecutionBackend,
    UnsafeNativeExecution,
    UnsafePathLayout,
    InvalidResources,
    InvalidDuration,
    InvalidLedgerCapacity,
    InvalidLaunchToken,
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

        let resource_budget = resource_budget(values)?;
        let heartbeat_interval = duration_ms(values, "CRF_HEARTBEAT_MS", 5_000, 1_000, 60_000)?;
        let connect_timeout = duration_ms(values, "CRF_CONNECT_TIMEOUT_MS", 5_000, 100, 120_000)?;
        let io_timeout = duration_ms(values, "CRF_IO_TIMEOUT_MS", 15_000, 100, 120_000)?;
        let command_ledger_capacity = optional_u64(values, "CRF_COMMAND_LEDGER_CAPACITY", 4_096)
            .map_err(|_| ConfigError::InvalidLedgerCapacity)?;
        if command_ledger_capacity == 0 || command_ledger_capacity > 4_096 {
            return Err(ConfigError::InvalidLedgerCapacity);
        }
        let operator_projection_path = optional(values, "CRF_OPERATOR_PROJECTION_PATH")
            .filter(|value| !value.is_empty())
            .map(absolute_path)
            .transpose()?;
        let node_status_path = optional(values, "CRF_NODE_STATUS_PATH")
            .filter(|value| !value.is_empty())
            .map(absolute_path)
            .transpose()?;
        let node_launch_token = optional(values, "CRF_NODE_LAUNCH_TOKEN")
            .filter(|value| !value.is_empty())
            .map(launch_token)
            .transpose()?;
        if node_status_path.is_some() != node_launch_token.is_some() {
            return Err(ConfigError::InvalidLaunchToken);
        }

        Ok(Self {
            controller_addr,
            controller_server_name,
            ca_cert_path,
            client_cert_path,
            client_key_path,
            state_root,
            execution,
            resource_budget,
            heartbeat_interval,
            connect_timeout,
            io_timeout,
            command_ledger_capacity: command_ledger_capacity as usize,
            operator_projection_path,
            node_status_path,
            node_launch_token,
        })
    }
}

fn launch_token(value: &str) -> Result<LaunchToken, ConfigError> {
    if value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        Ok(LaunchToken(value.to_owned()))
    } else {
        Err(ConfigError::InvalidLaunchToken)
    }
}

fn resource_budget(values: &BTreeMap<String, String>) -> Result<ResourceBudgetConfig, ConfigError> {
    let cpu = required(values, "CRF_NODE_CPU_MILLIS")?;
    let memory = required(values, "CRF_NODE_MEMORY_BYTES")?;
    match (cpu, memory) {
        ("auto", "auto") => Ok(ResourceBudgetConfig::Auto {
            cpu_reserve_millis: optional_nonnegative_u64(
                values,
                "CRF_NODE_CPU_RESERVE_MILLIS",
                1_000,
            )?,
            memory_reserve_bytes: optional_nonnegative_u64(
                values,
                "CRF_NODE_MEMORY_RESERVE_BYTES",
                2 * 1024 * 1024 * 1024,
            )?,
        }),
        ("auto", _) | (_, "auto") => Err(ConfigError::InvalidResources),
        _ => {
            let cpu_millis = positive_u64(cpu).map_err(|_| ConfigError::InvalidResources)?;
            let memory_bytes = positive_u64(memory).map_err(|_| ConfigError::InvalidResources)?;
            Ok(ResourceBudgetConfig::Explicit(Resources::new(
                cpu_millis,
                memory_bytes,
            )))
        }
    }
}

fn execution_config(
    values: &BTreeMap<String, String>,
    state_root: &Path,
) -> Result<NodeExecutionConfig, ConfigError> {
    match required(values, "CRF_EXECUTION_BACKEND")? {
        // Native workflow code would inherit the node agent's OS identity and
        // could read mTLS credentials/control state or inspect sibling jobs.
        // Keep the implementation unavailable to production configuration until
        // each placement has a real platform sandbox and distinct identity.
        "native_process" => Err(ConfigError::UnsafeNativeExecution),
        "container" => {
            let adapter_program =
                adapter_program(required(values, "CRF_CONTAINER_ADAPTER_PROGRAM")?)?;
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

fn adapter_program(value: &str) -> Result<PathBuf, ConfigError> {
    if value == "sibling" {
        let executable = std::env::current_exe().map_err(|_| ConfigError::InvalidPath)?;
        let directory = executable.parent().ok_or(ConfigError::InvalidPath)?;
        return Ok(directory.join(if cfg!(windows) {
            "crf-container-adapter.cmd"
        } else {
            "crf-container-adapter"
        }));
    }
    absolute_path(value)
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

fn optional_nonnegative_u64(
    values: &BTreeMap<String, String>,
    key: &str,
    default: u64,
) -> Result<u64, ConfigError> {
    values
        .get(key)
        .map_or(Ok(default), |value| value.parse::<u64>())
        .map_err(|_| ConfigError::InvalidResources)
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
            ("CRF_EXECUTION_BACKEND".into(), "container".into()),
            (
                "CRF_CONTAINER_ADAPTER_PROGRAM".into(),
                test_path("/usr/local/libexec/crf-container-adapter"),
            ),
            ("CRF_NODE_CPU_MILLIS".into(), "8000".into()),
            ("CRF_NODE_MEMORY_BYTES".into(), "17179869184".into()),
        ])
    }

    #[test]
    fn valid_staged_config_uses_bounded_defaults() {
        let config = NodeConfig::from_values(&values()).expect("config");
        assert_eq!(
            config.execution,
            NodeExecutionConfig::Container {
                adapter_program: PathBuf::from(test_path(
                    "/usr/local/libexec/crf-container-adapter",
                )),
                adapter_timeout: Duration::from_secs(15),
            }
        );
        assert_eq!(
            config.resource_budget,
            ResourceBudgetConfig::Explicit(Resources::new(8_000, 16 * 1024 * 1024 * 1024))
        );
        assert_eq!(config.heartbeat_interval, Duration::from_secs(5));
        assert_eq!(config.command_ledger_capacity, 4_096);
        assert_eq!(config.operator_projection_path, None);
        assert_eq!(config.node_status_path, None);
        assert_eq!(config.node_launch_token, None);
    }

    #[test]
    fn operator_projection_path_is_optional_and_absolute() {
        let mut configured = values();
        configured.insert(
            "CRF_OPERATOR_PROJECTION_PATH".into(),
            test_path("/var/lib/crf/status/controller.json"),
        );
        assert_eq!(
            NodeConfig::from_values(&configured)
                .expect("projection config")
                .operator_projection_path,
            Some(PathBuf::from(test_path(
                "/var/lib/crf/status/controller.json"
            )))
        );

        configured.insert(
            "CRF_OPERATOR_PROJECTION_PATH".into(),
            "relative.json".into(),
        );
        assert_eq!(
            NodeConfig::from_values(&configured),
            Err(ConfigError::InvalidPath)
        );
    }

    #[test]
    fn node_status_path_is_optional_and_absolute() {
        let mut configured = values();
        configured.insert(
            "CRF_NODE_STATUS_PATH".into(),
            test_path("/var/lib/crf/status/node.json"),
        );
        configured.insert(
            "CRF_NODE_LAUNCH_TOKEN".into(),
            "abcdefghijklmnopqrstuvwxyzABCDEFGH012345678".into(),
        );
        assert_eq!(
            NodeConfig::from_values(&configured)
                .expect("status config")
                .node_status_path,
            Some(PathBuf::from(test_path("/var/lib/crf/status/node.json")))
        );

        configured.insert("CRF_NODE_STATUS_PATH".into(), "relative.json".into());
        assert_eq!(
            NodeConfig::from_values(&configured),
            Err(ConfigError::InvalidPath)
        );
    }

    #[test]
    fn node_status_token_is_required_with_status_and_redacted_from_debug() {
        let mut configured = values();
        configured.insert(
            "CRF_NODE_STATUS_PATH".into(),
            test_path("/var/lib/crf/status/node.json"),
        );
        assert_eq!(
            NodeConfig::from_values(&configured),
            Err(ConfigError::InvalidLaunchToken)
        );

        configured.insert("CRF_NODE_LAUNCH_TOKEN".into(), "secret-token".into());
        assert_eq!(
            NodeConfig::from_values(&configured),
            Err(ConfigError::InvalidLaunchToken)
        );

        configured.insert(
            "CRF_NODE_LAUNCH_TOKEN".into(),
            "abcdefghijklmnopqrstuvwxyzABCDEFGH012345678".into(),
        );
        let config = NodeConfig::from_values(&configured).expect("status config");
        let debug = format!("{config:?}");
        assert!(debug.contains("[REDACTED]"));
        assert!(!debug.contains("abcdefghijklmnopqrstuvwxyzABCDEFGH012345678"));
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
        let container = values();
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
    fn container_backend_resolves_only_the_fixed_sibling_adapter_token() {
        let mut values = values();
        values.insert("CRF_EXECUTION_BACKEND".into(), "container".into());
        values.insert("CRF_CONTAINER_ADAPTER_PROGRAM".into(), "sibling".into());

        let config = NodeConfig::from_values(&values).expect("sibling adapter config");
        let NodeExecutionConfig::Container {
            adapter_program, ..
        } = config.execution
        else {
            panic!("container backend");
        };
        assert_eq!(
            adapter_program.file_name().unwrap(),
            if cfg!(windows) {
                "crf-container-adapter.cmd"
            } else {
                "crf-container-adapter"
            }
        );

        values.insert("CRF_CONTAINER_ADAPTER_PROGRAM".into(), "nearby".into());
        assert_eq!(
            NodeConfig::from_values(&values),
            Err(ConfigError::InvalidPath)
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
        container.insert("CRF_CONTAINER_ADAPTER_TIMEOUT_MS".into(), "121000".into());
        assert_eq!(
            NodeConfig::from_values(&container),
            Err(ConfigError::InvalidDuration)
        );
    }

    #[test]
    fn native_execution_is_rejected_before_runner_paths_are_opened() {
        let mut managed = values();
        managed.insert("CRF_EXECUTION_BACKEND".into(), "native_process".into());
        managed.remove("CRF_CONTAINER_ADAPTER_PROGRAM");
        managed.insert(
            "CRF_RUNNER_MANIFEST".into(),
            test_path("/etc/crf/runner-manifest.json"),
        );
        managed.insert(
            "CRF_RUNNER_CACHE_DIR".into(),
            test_path("/var/cache/crf/runner"),
        );

        assert_eq!(
            NodeConfig::from_values(&managed),
            Err(ConfigError::UnsafeNativeExecution)
        );
    }

    #[test]
    fn execution_backend_must_be_explicit() {
        let mut configured = values();
        configured.remove("CRF_EXECUTION_BACKEND");
        assert_eq!(
            NodeConfig::from_values(&configured),
            Err(ConfigError::MissingValue)
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

    #[test]
    fn automatic_resource_budget_subtracts_explicit_host_reserves() {
        let mut configured = values();
        configured.insert("CRF_NODE_CPU_MILLIS".into(), "auto".into());
        configured.insert("CRF_NODE_MEMORY_BYTES".into(), "auto".into());
        configured.insert("CRF_NODE_CPU_RESERVE_MILLIS".into(), "2500".into());
        configured.insert(
            "CRF_NODE_MEMORY_RESERVE_BYTES".into(),
            (3 * 1024 * 1024 * 1024_u64).to_string(),
        );
        let budget = NodeConfig::from_values(&configured)
            .expect("automatic budget")
            .resource_budget;
        assert_eq!(
            budget.resolve(Resources::new(12_000, 32 * 1024 * 1024 * 1024)),
            Ok(Resources::new(9_500, 29 * 1024 * 1024 * 1024))
        );
    }

    #[test]
    fn automatic_resource_budget_fails_closed_on_partial_auto_or_exhausted_host() {
        let mut configured = values();
        configured.insert("CRF_NODE_CPU_MILLIS".into(), "auto".into());
        assert_eq!(
            NodeConfig::from_values(&configured),
            Err(ConfigError::InvalidResources)
        );

        configured.insert("CRF_NODE_MEMORY_BYTES".into(), "auto".into());
        configured.insert("CRF_NODE_CPU_RESERVE_MILLIS".into(), "2000".into());
        let budget = NodeConfig::from_values(&configured)
            .expect("automatic budget")
            .resource_budget;
        assert_eq!(
            budget.resolve(Resources::new(2_000, 8 * 1024 * 1024 * 1024)),
            Err(ConfigError::InvalidResources)
        );
    }
}
