use std::{
    collections::BTreeSet,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use crf_protocol::NodeSnapshot;

use crate::{
    agent::{AgentCore, AgentSession, AgentSessionError, PlacementRuntime},
    command_ledger::CommandLedger,
    command_processor::CommandProcessor,
    config::{ConfigError, NodeConfig, NodeExecutionConfig, RunnerSourceConfig},
    container_adapter::ProcessContainerAdapter,
    container_executor::ContainerRunnerExecutor,
    generation::reserve_next_generation,
    native_executor::NativeRunnerExecutor,
    native_materializer::RunnerMaterializer,
    node_executor::NodeExecutor,
    node_status::{self, NodeStatusDetail, NodeStatusProjection},
    placement_state::PlacementStore,
    probe_local_platform,
    runner_package::RunnerPackageManager,
    system_probe::SystemProbe,
    transport::{TlsClient, TlsClientSettings},
};

const INITIAL_RECONNECT_BACKOFF: Duration = Duration::from_secs(1);
const MAX_RECONNECT_BACKOFF: Duration = Duration::from_secs(30);
const SLEEP_SLICE: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DaemonError {
    Config(ConfigError),
    HostProbe,
    ResourceBudgetExceedsHost,
    GenerationState,
    PlacementState,
    RunnerPackage,
    Materializer,
    NativeExecutor,
    ContainerAdapter,
    TlsClient,
    CommandLedger,
    AgentCore,
    SignalHandler,
    Clock,
    FatalSession,
}

pub fn run_from_env() -> Result<(), DaemonError> {
    let config = NodeConfig::from_env().map_err(DaemonError::Config)?;
    run(config)
}

pub fn run(config: NodeConfig) -> Result<(), DaemonError> {
    let running = Arc::new(AtomicBool::new(true));
    let signal_running = running.clone();
    ctrlc::set_handler(move || signal_running.store(false, Ordering::SeqCst))
        .map_err(|_| DaemonError::SignalHandler)?;
    run_until_stopped(config, running)
}

pub fn run_until_stopped(config: NodeConfig, running: Arc<AtomicBool>) -> Result<(), DaemonError> {
    let operator_projection_path = config.operator_projection_path.clone();
    let node_status_path = config.node_status_path.clone();
    let platform = probe_local_platform();
    let mut host = SystemProbe::new().map_err(|_| DaemonError::HostProbe)?;
    let host_memory = host
        .total_memory_bytes()
        .map_err(|_| DaemonError::HostProbe)?;
    let resources = config
        .resource_budget
        .resolve(crf_protocol::Resources::new(
            platform.logical_cpu_millis,
            host_memory,
        ))
        .map_err(|_| DaemonError::ResourceBudgetExceedsHost)?;

    let generation =
        reserve_next_generation(&config.state_root.join("generations"), &platform.node_id)
            .map_err(|_| DaemonError::GenerationState)?;
    let launch_token = config
        .node_launch_token
        .as_ref()
        .map(|token| token.as_str())
        .unwrap_or("");
    let mut status = NodeStatusReporter::new(
        node_status_path.as_deref(),
        &platform.node_id,
        generation,
        launch_token,
    );
    status.connecting(NodeStatusDetail::Starting, now_unix_ms()?);

    let placement_store = PlacementStore::new(config.state_root.join("placements"))
        .map_err(|_| DaemonError::PlacementState)?;
    let pruned_placements = placement_store
        .prune_reported_through_generation(generation)
        .map_err(|_| DaemonError::PlacementState)?;
    let executor = match &config.execution {
        NodeExecutionConfig::Native {
            runner_source,
            runtime_root,
            log_root,
        } => {
            let runner_template = match runner_source {
                RunnerSourceConfig::Template(path) => path.clone(),
                RunnerSourceConfig::Managed {
                    manifest_path,
                    cache_root,
                } => RunnerPackageManager::new(manifest_path, cache_root)
                    .and_then(|manager| manager.resolve(&platform.os, &platform.arch))
                    .map_err(|_| DaemonError::RunnerPackage)?,
            };
            let materializer = RunnerMaterializer::new(
                platform.os.clone(),
                &runner_template,
                runtime_root,
                log_root,
            )
            .map_err(|_| DaemonError::Materializer)?;
            for placement_id in &pruned_placements {
                materializer
                    .cleanup(placement_id)
                    .map_err(|_| DaemonError::Materializer)?;
            }
            NodeExecutor::Native(Box::new(
                NativeRunnerExecutor::new(platform.os.clone(), materializer, placement_store)
                    .map_err(|_| DaemonError::NativeExecutor)?,
            ))
        }
        NodeExecutionConfig::Container {
            adapter_program,
            adapter_timeout,
        } => {
            let adapter = ProcessContainerAdapter::new(adapter_program, *adapter_timeout)
                .map_err(|_| DaemonError::ContainerAdapter)?;
            NodeExecutor::Container(ContainerRunnerExecutor::new(adapter, placement_store))
        }
    };
    let execution_backend = executor.execution_backend();
    let mut capabilities = executor.capabilities();
    if config.operator_projection_path.is_some() {
        capabilities.insert("operator-projection-v1".into());
    }

    let mut available = resources;
    let reserved = executor
        .reserved_resources()
        .map_err(|_| DaemonError::PlacementState)?;
    if !available.subtract(reserved) {
        return Err(DaemonError::ResourceBudgetExceedsHost);
    }

    let node = NodeSnapshot {
        node_id: platform.node_id.clone(),
        generation,
        os: platform.os,
        arch: platform.arch,
        execution_backends: BTreeSet::from([execution_backend]),
        capabilities,
        total: resources,
        available,
        draining: false,
    };

    let diagnostic_node_id = platform.node_id.clone();
    let diagnostic_controller = config.controller_addr.to_string();
    let ledger = CommandLedger::new(platform.node_id, generation, config.command_ledger_capacity)
        .map_err(|_| DaemonError::CommandLedger)?;
    let processor = CommandProcessor::new(ledger, executor);
    let mut core = AgentCore::new(node, env!("CARGO_PKG_VERSION"), processor)
        .map_err(|_| DaemonError::AgentCore)?;

    let tls_client = TlsClient::new(TlsClientSettings {
        controller_addr: config.controller_addr,
        server_name: config.controller_server_name,
        ca_cert_path: config.ca_cert_path,
        client_cert_path: config.client_cert_path,
        client_key_path: config.client_key_path,
        connect_timeout: config.connect_timeout,
        io_timeout: config.io_timeout,
    })
    .map_err(|_| DaemonError::TlsClient)?;

    let mut backoff = INITIAL_RECONNECT_BACKOFF;
    let mut reconnect_log = ReconnectLog::default();
    let mut projection_log = ProjectionLog::default();
    while running.load(Ordering::SeqCst) {
        let transport = match tls_client.connect() {
            Ok(transport) => transport,
            Err(error) => {
                status.connecting(NodeStatusDetail::ControllerUnavailable, now_unix_ms()?);
                reconnect_log.failure(
                    &diagnostic_node_id,
                    &diagnostic_controller,
                    "tls_connect",
                    &format!("{error:?}"),
                    backoff,
                );
                sleep_interruptible(backoff, &running);
                backoff = next_backoff(backoff);
                continue;
            }
        };

        let mut session = AgentSession::new(transport, core);
        let registration_time = now_unix_ms()?;
        match session.register(registration_time) {
            Ok(outcome) => {
                projection_log.record(persist_operator_projection(
                    operator_projection_path.as_deref(),
                    outcome.operator_projection.as_ref(),
                ));
                reconnect_log.recovered(&diagnostic_node_id, &diagnostic_controller);
                status.ready(registration_time);
                backoff = INITIAL_RECONNECT_BACKOFF;
            }
            Err(error) => {
                let reconnect = matches!(error, AgentSessionError::Transport(_));
                core = session.into_core();
                if !reconnect {
                    status.failed(NodeStatusDetail::ControllerRejected, registration_time);
                    eprintln!(
                        "crf-node: fatal registration failure node_id={} controller={} error={error:?}",
                        diagnostic_node_id, diagnostic_controller
                    );
                    return Err(DaemonError::FatalSession);
                }
                status.connecting(NodeStatusDetail::RegistrationPending, registration_time);
                reconnect_log.failure(
                    &diagnostic_node_id,
                    &diagnostic_controller,
                    "registration_transport",
                    &format!("{error:?}"),
                    backoff,
                );
                sleep_interruptible(backoff, &running);
                backoff = next_backoff(backoff);
                continue;
            }
        }

        let mut poll_degraded = false;
        loop {
            if !running.load(Ordering::SeqCst) {
                return Ok(());
            }
            let heartbeat_time = now_unix_ms()?;
            match session.runtime_heartbeat(heartbeat_time) {
                Ok(outcome) => {
                    if outcome.terminal_sync.runtime_poll_degraded != poll_degraded {
                        poll_degraded = outcome.terminal_sync.runtime_poll_degraded;
                        if poll_degraded {
                            eprintln!(
                                "crf-node: runtime poll degraded node_id={} controller={} detail=execution_backend_unavailable",
                                diagnostic_node_id, diagnostic_controller
                            );
                        } else {
                            eprintln!(
                                "crf-node: runtime poll recovered node_id={} controller={}",
                                diagnostic_node_id, diagnostic_controller
                            );
                        }
                    }
                    projection_log.record(persist_operator_projection(
                        operator_projection_path.as_deref(),
                        outcome.heartbeat.operator_projection.as_ref(),
                    ));
                    status.ready(heartbeat_time);
                    sleep_interruptible(config.heartbeat_interval, &running);
                }
                Err(error) => {
                    let reconnect = heartbeat_error_reconnectable(&error);
                    core = session.into_core();
                    if !reconnect {
                        status.failed(NodeStatusDetail::ControllerRejected, heartbeat_time);
                        eprintln!(
                            "crf-node: fatal heartbeat failure node_id={} controller={} error={error:?}",
                            diagnostic_node_id, diagnostic_controller
                        );
                        return Err(DaemonError::FatalSession);
                    }
                    status.connecting(NodeStatusDetail::ControllerUnavailable, heartbeat_time);
                    reconnect_log.failure(
                        &diagnostic_node_id,
                        &diagnostic_controller,
                        "heartbeat_transport",
                        &format!("{error:?}"),
                        backoff,
                    );
                    sleep_interruptible(backoff, &running);
                    backoff = next_backoff(backoff);
                    break;
                }
            }
        }
    }
    Ok(())
}

fn heartbeat_error_reconnectable<T>(error: &AgentSessionError<T>) -> bool {
    matches!(error, AgentSessionError::Transport(_))
        || matches!(
            error,
            AgentSessionError::Agent(crate::agent::AgentError::ControllerRejected { code })
                if code == "unknown_node" || code == "node_not_registered"
        )
}

fn persist_operator_projection(
    path: Option<&std::path::Path>,
    projection: Option<&serde_json::Value>,
) -> Result<(), std::io::Error> {
    if let (Some(path), Some(projection)) = (path, projection) {
        crate::operator_projection::write_atomic(path, projection)?;
    }
    Ok(())
}

fn persist_node_status(
    path: Option<&std::path::Path>,
    status: &NodeStatusProjection,
) -> Result<(), std::io::Error> {
    if let Some(path) = path {
        node_status::write_atomic(path, status).map_err(|error| {
            std::io::Error::new(error.kind(), format!("{}: {error}", path.display()))
        })?;
    }
    Ok(())
}

struct NodeStatusReporter {
    path: Option<std::path::PathBuf>,
    node_id: String,
    generation: u64,
    launch_token: String,
    log: NodeStatusLog,
}

impl NodeStatusReporter {
    fn new(
        path: Option<&std::path::Path>,
        node_id: &str,
        generation: u64,
        launch_token: &str,
    ) -> Self {
        Self {
            path: path.map(std::path::Path::to_path_buf),
            node_id: node_id.to_owned(),
            generation,
            launch_token: launch_token.to_owned(),
            log: NodeStatusLog::default(),
        }
    }

    fn connecting(&mut self, detail: NodeStatusDetail, observed_at_unix_ms: u64) {
        self.record(NodeStatusProjection::connecting(
            &self.node_id,
            self.generation,
            &self.launch_token,
            detail,
            observed_at_unix_ms,
        ));
    }

    fn ready(&mut self, observed_at_unix_ms: u64) {
        self.record(NodeStatusProjection::ready(
            &self.node_id,
            self.generation,
            &self.launch_token,
            observed_at_unix_ms,
        ));
    }

    fn failed(&mut self, detail: NodeStatusDetail, observed_at_unix_ms: u64) {
        self.record(NodeStatusProjection::failed(
            &self.node_id,
            self.generation,
            &self.launch_token,
            detail,
            observed_at_unix_ms,
        ));
    }

    fn record(&mut self, projection: NodeStatusProjection) {
        self.log
            .record(persist_node_status(self.path.as_deref(), &projection));
    }
}

#[derive(Default)]
struct NodeStatusLog {
    failures: u64,
}

impl NodeStatusLog {
    fn record(&mut self, result: Result<(), std::io::Error>) {
        match result {
            Ok(()) => self.failures = 0,
            Err(error) => {
                self.failures = self.failures.saturating_add(1);
                if self.failures == 1 || self.failures.is_power_of_two() {
                    eprintln!(
                        "crf-node: private status write failed repeated_count={} error={error}",
                        self.failures,
                    );
                }
            }
        }
    }
}

#[derive(Default)]
struct ProjectionLog {
    failures: u64,
}

impl ProjectionLog {
    fn record(&mut self, result: Result<(), std::io::Error>) {
        match result {
            Ok(()) => self.failures = 0,
            Err(error) => {
                self.failures = self.failures.saturating_add(1);
                if self.failures == 1 || self.failures.is_power_of_two() {
                    eprintln!(
                        "crf-node: optional operator projection write failed repeated_count={} error={error}",
                        self.failures
                    );
                }
            }
        }
    }
}

#[derive(Default)]
struct ReconnectLog {
    last_failure: Option<String>,
    suppressed: u64,
}

impl ReconnectLog {
    fn failure(
        &mut self,
        node_id: &str,
        controller: &str,
        stage: &str,
        cause: &str,
        retry_delay: Duration,
    ) {
        let fingerprint = format!("{stage}:{cause}");
        if self.last_failure.as_deref() == Some(&fingerprint) {
            self.suppressed = self.suppressed.saturating_add(1);
            if self.suppressed.is_power_of_two() {
                eprintln!(
                    "crf-node: repeated reconnect failure node_id={node_id} controller={controller} stage={stage} repeated_count={} next_retry_delay_ms={}",
                    self.suppressed,
                    retry_delay.as_millis()
                );
            }
            return;
        }
        if self.suppressed > 0 {
            eprintln!(
                "crf-node: suppressed {} repeated reconnect failures node_id={node_id} controller={controller}",
                self.suppressed
            );
        }
        eprintln!(
            "crf-node: connection failure node_id={node_id} controller={controller} stage={stage} error={cause} retry_delay_ms={}",
            retry_delay.as_millis()
        );
        self.last_failure = Some(fingerprint);
        self.suppressed = 0;
    }

    fn recovered(&mut self, node_id: &str, controller: &str) {
        if self.last_failure.take().is_some() {
            eprintln!(
                "crf-node: controller registration recovered node_id={node_id} controller={controller} suppressed_failures={}",
                self.suppressed
            );
        }
        self.suppressed = 0;
    }
}

fn now_unix_ms() -> Result<u64, DaemonError> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| DaemonError::Clock)?
        .as_millis();
    u64::try_from(millis).map_err(|_| DaemonError::Clock)
}

fn next_backoff(current: Duration) -> Duration {
    current.saturating_mul(2).min(MAX_RECONNECT_BACKOFF)
}

fn sleep_interruptible(duration: Duration, running: &AtomicBool) {
    let started = Instant::now();
    while running.load(Ordering::SeqCst) {
        let elapsed = started.elapsed();
        if elapsed >= duration {
            break;
        }
        thread::sleep(SLEEP_SLICE.min(duration - elapsed));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconnect_backoff_is_bounded() {
        let mut backoff = INITIAL_RECONNECT_BACKOFF;
        for _ in 0..10 {
            backoff = next_backoff(backoff);
        }
        assert_eq!(backoff, MAX_RECONNECT_BACKOFF);
    }

    #[test]
    fn interruptible_sleep_returns_when_shutdown_is_requested() {
        let running = AtomicBool::new(false);
        let started = Instant::now();
        sleep_interruptible(Duration::from_secs(5), &running);
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn missing_controller_registration_reconnects_but_other_rejections_are_fatal() {
        for code in ["unknown_node", "node_not_registered"] {
            let error =
                AgentSessionError::<()>::Agent(crate::agent::AgentError::ControllerRejected {
                    code: code.into(),
                });
            assert!(heartbeat_error_reconnectable(&error));
        }
        let unauthorized =
            AgentSessionError::<()>::Agent(crate::agent::AgentError::ControllerRejected {
                code: "unauthorized".into(),
            });
        assert!(!heartbeat_error_reconnectable(&unauthorized));
        assert!(heartbeat_error_reconnectable(
            &AgentSessionError::<()>::Transport(())
        ));
    }

    #[test]
    fn reconnect_diagnostics_suppress_duplicates_and_reset_after_recovery() {
        let mut log = ReconnectLog::default();
        log.failure(
            "node-1",
            "controller:9443",
            "tls_connect",
            "refused",
            Duration::from_secs(1),
        );
        log.failure(
            "node-1",
            "controller:9443",
            "tls_connect",
            "refused",
            Duration::from_secs(2),
        );
        assert_eq!(log.suppressed, 1);
        log.recovered("node-1", "controller:9443");
        assert_eq!(log.last_failure, None);
        assert_eq!(log.suppressed, 0);
    }

    #[test]
    fn repeated_optional_projection_failures_are_nonfatal_and_recover() {
        let mut log = ProjectionLog::default();
        for _ in 0..5 {
            log.record(Err(std::io::Error::other("read-only status storage")));
        }
        assert_eq!(log.failures, 5);
        log.record(Ok(()));
        assert_eq!(log.failures, 0);
    }

    #[test]
    fn scripted_session_status_transitions_preserve_launch_identity_and_ignore_write_failures() {
        let root = tempfile::tempdir().expect("status root");
        let path = root.path().join("node-status.json");
        let token = "abcdefghijklmnopqrstuvwxyzABCDEFGH012345678";
        let mut reporter = NodeStatusReporter::new(Some(&path), "node-1", 17, token);

        let script = [
            (
                NodeStatusDetail::ControllerUnavailable,
                "connecting",
                "controller_unavailable",
                10,
            ),
            (
                NodeStatusDetail::RegistrationPending,
                "connecting",
                "registration_pending",
                20,
            ),
        ];
        for (detail, state, detail_code, observed_at) in script {
            reporter.connecting(detail, observed_at);
            assert_status(&path, state, Some(detail_code), observed_at, token, 17);
        }

        // Successful registration and the subsequent heartbeat both refresh
        // readiness without changing the launch identity.
        reporter.ready(30);
        assert_status(&path, "ready", None, 30, token, 17);
        reporter.ready(40);
        assert_status(&path, "ready", None, 40, token, 17);

        reporter.failed(NodeStatusDetail::ControllerRejected, 50);
        assert_status(&path, "failed", Some("controller_rejected"), 50, token, 17);

        // A projection failure is diagnostic-only: recording returns normally,
        // later transitions continue, and a successful write clears suppression.
        let unwritable_path = root.path().join("directory-instead-of-file");
        std::fs::create_dir(&unwritable_path).expect("failure fixture");
        reporter.path = Some(unwritable_path);
        reporter.connecting(NodeStatusDetail::ControllerUnavailable, 60);
        assert_eq!(reporter.log.failures, 1);
        reporter.path = Some(path.clone());
        reporter.ready(70);
        assert_eq!(reporter.log.failures, 0);
        assert_status(&path, "ready", None, 70, token, 17);
    }

    fn assert_status(
        path: &std::path::Path,
        state: &str,
        detail_code: Option<&str>,
        observed_at_unix_ms: u64,
        launch_token: &str,
        generation: u64,
    ) {
        let status: serde_json::Value = serde_json::from_slice(
            &std::fs::read(path).expect("status projection remains readable"),
        )
        .expect("valid status projection");
        assert_eq!(status["node_id"], "node-1");
        assert_eq!(status["generation"], generation);
        assert_eq!(status["launch_token"], launch_token);
        assert_eq!(status["state"], state);
        assert_eq!(status["detail_code"].as_str(), detail_code);
        assert_eq!(status["observed_at_unix_ms"], observed_at_unix_ms);
    }
}
