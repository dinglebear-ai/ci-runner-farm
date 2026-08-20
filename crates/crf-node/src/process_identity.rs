use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub start_token: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessIdentityError {
    InvalidPid,
    Unavailable,
}

impl ProcessIdentity {
    pub fn capture(pid: u32) -> Result<Self, ProcessIdentityError> {
        if pid == 0 {
            return Err(ProcessIdentityError::InvalidPid);
        }
        capture_platform(pid)
    }
}

#[cfg(target_os = "linux")]
fn capture_platform(pid: u32) -> Result<ProcessIdentity, ProcessIdentityError> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .map_err(|_| ProcessIdentityError::Unavailable)?;
    let close = stat.rfind(')').ok_or(ProcessIdentityError::Unavailable)?;
    let remainder = stat
        .get(close + 2..)
        .ok_or(ProcessIdentityError::Unavailable)?;
    let start_token = remainder
        .split_whitespace()
        .nth(19)
        .ok_or(ProcessIdentityError::Unavailable)?
        .parse::<u64>()
        .map_err(|_| ProcessIdentityError::Unavailable)?;
    if start_token == 0 {
        return Err(ProcessIdentityError::Unavailable);
    }
    Ok(ProcessIdentity { pid, start_token })
}

#[cfg(windows)]
fn capture_platform(pid: u32) -> Result<ProcessIdentity, ProcessIdentityError> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, FILETIME},
        System::Threading::{GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION},
    };

    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return Err(ProcessIdentityError::Unavailable);
        }
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        let ok = GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user);
        CloseHandle(process);
        if ok == 0 {
            return Err(ProcessIdentityError::Unavailable);
        }
        let start_token = ((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64;
        if start_token == 0 {
            return Err(ProcessIdentityError::Unavailable);
        }
        Ok(ProcessIdentity { pid, start_token })
    }
}

#[cfg(all(unix, not(target_os = "linux")))]
fn capture_platform(pid: u32) -> Result<ProcessIdentity, ProcessIdentityError> {
    use sysinfo::{Pid, ProcessesToUpdate, System};

    let mut system = System::new();
    let sys_pid = Pid::from_u32(pid);
    system.refresh_processes(ProcessesToUpdate::Some(&[sys_pid]), true);
    let process = system
        .process(sys_pid)
        .ok_or(ProcessIdentityError::Unavailable)?;
    let start_token = process.start_time();
    if start_token == 0 {
        return Err(ProcessIdentityError::Unavailable);
    }
    Ok(ProcessIdentity { pid, start_token })
}

#[cfg(not(any(unix, windows)))]
fn capture_platform(_pid: u32) -> Result<ProcessIdentity, ProcessIdentityError> {
    Err(ProcessIdentityError::Unavailable)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_process_identity_is_stable_and_nonzero() {
        let pid = std::process::id();
        let first = ProcessIdentity::capture(pid).expect("current process identity");
        let second = ProcessIdentity::capture(pid).expect("repeat process identity");
        assert_eq!(first, second);
        assert_eq!(first.pid, pid);
        assert_ne!(first.start_token, 0);
    }

    #[test]
    fn zero_pid_is_rejected() {
        assert_eq!(
            ProcessIdentity::capture(0),
            Err(ProcessIdentityError::InvalidPid)
        );
    }
}
