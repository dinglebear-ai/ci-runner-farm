use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use windows_service::{
    define_windows_service,
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
};

use crate::config::NodeConfig;

const SERVICE_NAME: &str = "CiRunnerFarmNode";
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;
const ERROR_LOG_ENV: &str = "CRF_SERVICE_ERROR_LOG";
const MAX_ERROR_LOG_BYTES: u64 = 64 * 1024;

define_windows_service!(ffi_service_main, service_main);

pub fn dispatch() -> windows_service::Result<()> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)
}

fn service_main(_arguments: Vec<OsString>) {
    if let Err(error) = run_service() {
        record_failure("service-control", &format!("{error}"));
    }
}

fn run_service() -> windows_service::Result<()> {
    let running = Arc::new(AtomicBool::new(true));
    let handler_running = running.clone();
    let event_handler = move |control| match control {
        ServiceControl::Stop => {
            handler_running.store(false, Ordering::SeqCst);
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    };
    let status = service_control_handler::register(SERVICE_NAME, event_handler)?;
    status.set_service_status(service_status(ServiceState::Running, true, 0))?;

    let exit_code = match NodeConfig::from_env()
        .map_err(crate::daemon::DaemonError::Config)
        .and_then(|config| crate::daemon::run_until_stopped(config, running))
    {
        Ok(()) => 0,
        Err(error) => {
            record_failure("daemon", &format!("{error:?}"));
            1
        }
    };

    status.set_service_status(service_status(ServiceState::Stopped, false, exit_code))
}

fn record_failure(component: &str, detail: &str) {
    let Some(path) = std::env::var_os(ERROR_LOG_ENV).map(PathBuf::from) else {
        return;
    };
    if !path.is_absolute() {
        return;
    }
    let detail = detail
        .chars()
        .filter(|character| !character.is_control())
        .take(512)
        .collect::<String>();
    let _ = append_bounded(&path, &format!("crf-node {component} failure: {detail}\n"));
}

fn append_bounded(path: &Path, message: &str) -> std::io::Result<()> {
    if fs::metadata(path).is_ok_and(|metadata| metadata.len() >= MAX_ERROR_LOG_BYTES) {
        let rotated = path.with_extension("log.old");
        let _ = fs::remove_file(&rotated);
        fs::rename(path, rotated)?;
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?
        .write_all(message.as_bytes())
}

fn service_status(state: ServiceState, accepts_stop: bool, exit_code: u32) -> ServiceStatus {
    ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: state,
        controls_accepted: if accepts_stop {
            ServiceControlAccept::STOP
        } else {
            ServiceControlAccept::empty()
        },
        exit_code: ServiceExitCode::Win32(exit_code),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    }
}
