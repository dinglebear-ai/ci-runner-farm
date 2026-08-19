use sysinfo::{MemoryRefreshKind, Pid, ProcessesToUpdate, System};

#[derive(Debug)]
pub struct SystemProbe {
    system: System,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SystemProbeError {
    UnsupportedSystem,
    MemoryUnavailable,
}

impl SystemProbe {
    pub fn new() -> Result<Self, SystemProbeError> {
        if !sysinfo::IS_SUPPORTED_SYSTEM {
            return Err(SystemProbeError::UnsupportedSystem);
        }
        Ok(Self {
            system: System::new(),
        })
    }

    pub fn total_memory_bytes(&mut self) -> Result<u64, SystemProbeError> {
        self.system
            .refresh_memory_specifics(MemoryRefreshKind::nothing().with_ram());
        let total = self.system.total_memory();
        if total == 0 {
            Err(SystemProbeError::MemoryUnavailable)
        } else {
            Ok(total)
        }
    }

    pub fn process_exists(&mut self, pid: u32) -> bool {
        if pid == 0 {
            return false;
        }
        let pid = Pid::from_u32(pid);
        self.system
            .refresh_processes(ProcessesToUpdate::Some(&[pid]), true);
        self.system.process(pid).is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_probe_reports_memory_and_current_process() {
        let mut probe = SystemProbe::new().expect("supported system");
        assert!(probe.total_memory_bytes().expect("memory") > 0);
        assert!(probe.process_exists(std::process::id()));
        assert!(!probe.process_exists(0));
    }
}
