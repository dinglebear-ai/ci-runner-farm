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
    let platform = probe_local_platform();
    let mut host = SystemProbe::new().map_err(|_| DaemonError::HostProbe)?;
    let host_memory = host
        .total_memory_bytes()
        .map_err(|_| DaemonError::HostProbe)?;
    if config.resources.cpu_millis > platform.logical_cpu_millis
        || config.resources.memory_bytes > host_memory
    {
        return Err(DaemonError::ResourceBudgetExceedsHost);
    }

    let generation =
        reserve_next_generation(&config.state_root.join("generations"), &platform.node_id)
            .map_err(|_| DaemonError::GenerationState)?;

    let placement_store = PlacementStore::new(config.state_root.join("placements"))
        .map_err(|_| DaemonError::PlacementState)?;
    placement_store
        .prune_reported_before_generation(generation)
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
    let capabilities = executor.capabilities();

    let mut available = config.resources;
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
        total: config.resources,
        available,
        draining: false,
    };

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

    let running = Arc::new(AtomicBool::new(true));
    let signal_running = running.clone();
    ctrlc::set_handler(move || signal_running.store(false, Ordering::SeqCst))
        .map_err(|_| DaemonError::SignalHandler)?;

    let mut backoff = INITIAL_RECONNECT_BACKOFF;
    while running.load(Ordering::SeqCst) {
        let transport = match tls_client.connect() {
            Ok(transport) => transport,
            Err(_) => {
                sleep_interruptible(backoff, &running);
                backoff = next_backoff(backoff);
                continue;
            }
        };

        let mut session = AgentSession::new(transport, core);
        match session.register(now_unix_ms()?) {
            Ok(_) => backoff = INITIAL_RECONNECT_BACKOFF,
            Err(error) => {
                let reconnect = matches!(error, AgentSessionError::Transport(_));
                core = session.into_core();
                if !reconnect {
                    return Err(DaemonError::FatalSession);
                }
                sleep_interruptible(backoff, &running);
                backoff = next_backoff(backoff);
                continue;
            }
        }

        loop {
            if !running.load(Ordering::SeqCst) {
                return Ok(());
            }
            match session.runtime_heartbeat(now_unix_ms()?) {
                Ok(_) => sleep_interruptible(config.heartbeat_interval, &running),
                Err(error) => {
                    let reconnect = matches!(error, AgentSessionError::Transport(_));
                    core = session.into_core();
                    if !reconnect {
                        return Err(DaemonError::FatalSession);
                    }
                    sleep_interruptible(backoff, &running);
                    backoff = next_backoff(backoff);
                    break;
                }
            }
        }
    }
    Ok(())
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
}
