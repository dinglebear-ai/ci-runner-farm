use std::{
    ffi::OsString,
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

define_windows_service!(ffi_service_main, service_main);

pub fn dispatch() -> windows_service::Result<()> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)
}

fn service_main(_arguments: Vec<OsString>) {
    let _ = run_service();
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
        Err(_) => 1,
    };

    status.set_service_status(service_status(ServiceState::Stopped, false, exit_code))
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
