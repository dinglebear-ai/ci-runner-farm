use std::{
    io,
    process::{Child, Command, ExitStatus},
};

#[cfg(unix)]
use std::{
    thread,
    time::{Duration, Instant},
};

#[cfg(unix)]
const TERMINATE_GRACE: Duration = Duration::from_secs(5);
#[cfg(unix)]
const POLL_INTERVAL: Duration = Duration::from_millis(25);

pub struct ManagedProcess {
    child: Child,
    tree: ProcessTree,
}

impl ManagedProcess {
    pub fn spawn(command: &mut Command) -> io::Result<Self> {
        ProcessTree::configure(command);
        let mut child = command.spawn()?;
        match ProcessTree::attach_and_start(&mut child) {
            Ok(tree) => Ok(Self { child, tree }),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                Err(error)
            }
        }
    }

    pub fn id(&self) -> u32 {
        self.child.id()
    }

    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        self.child.try_wait()
    }

    pub fn terminate_tree(&mut self) -> io::Result<ExitStatus> {
        self.tree.terminate(&mut self.child)
    }
}

#[cfg(unix)]
struct ProcessTree {
    pgid: i32,
}

#[cfg(unix)]
impl ProcessTree {
    fn configure(command: &mut Command) {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }

    fn attach_and_start(child: &mut Child) -> io::Result<Self> {
        let pgid =
            i32::try_from(child.id()).map_err(|_| io::Error::other("runner pid overflow"))?;
        Ok(Self { pgid })
    }

    fn terminate(&self, child: &mut Child) -> io::Result<ExitStatus> {
        self.signal_group(libc::SIGTERM)?;
        let deadline = Instant::now() + TERMINATE_GRACE;
        while Instant::now() < deadline {
            if !self.group_alive()? {
                break;
            }
            thread::sleep(POLL_INTERVAL);
        }
        if self.group_alive()? {
            self.signal_group(libc::SIGKILL)?;
        }
        child.wait()
    }

    fn signal_group(&self, signal: i32) -> io::Result<()> {
        let result = unsafe { libc::kill(-self.pgid, signal) };
        if result == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(())
        } else {
            Err(error)
        }
    }

    fn group_alive(&self) -> io::Result<bool> {
        let result = unsafe { libc::kill(-self.pgid, 0) };
        if result == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::ESRCH) => Ok(false),
            Some(libc::EPERM) => Ok(true),
            _ => Err(error),
        }
    }
}

#[cfg(windows)]
struct ProcessTree {
    job: windows_sys::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
impl ProcessTree {
    fn configure(command: &mut Command) {
        use std::os::windows::process::CommandExt;
        use windows_sys::Win32::System::Threading::CREATE_SUSPENDED;
        command.creation_flags(CREATE_SUSPENDED);
    }

    fn attach_and_start(child: &mut Child) -> io::Result<Self> {
        use std::{os::windows::io::AsRawHandle, ptr};
        use windows_sys::Win32::{
            Foundation::CloseHandle,
            System::JobObjects::{AssignProcessToJobObject, CreateJobObjectW},
        };
        let job = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
        if job.is_null() {
            return Err(io::Error::last_os_error());
        }
        let assigned = unsafe { AssignProcessToJobObject(job, child.as_raw_handle().cast()) };
        if assigned == 0 {
            let error = io::Error::last_os_error();
            unsafe {
                CloseHandle(job);
            }
            return Err(error);
        }
        if let Err(error) = resume_initial_thread(child.id()) {
            unsafe {
                CloseHandle(job);
            }
            return Err(error);
        }
        Ok(Self { job })
    }

    fn terminate(&self, child: &mut Child) -> io::Result<ExitStatus> {
        use windows_sys::Win32::System::JobObjects::TerminateJobObject;
        if unsafe { TerminateJobObject(self.job, 1) } == 0 {
            if let Some(status) = child.try_wait()? {
                return Ok(status);
            }
            return Err(io::Error::last_os_error());
        }
        child.wait()
    }
}

#[cfg(windows)]
impl Drop for ProcessTree {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;
        if !self.job.is_null() {
            unsafe {
                CloseHandle(self.job);
            }
        }
    }
}

#[cfg(windows)]
fn resume_initial_thread(pid: u32) -> io::Result<()> {
    use std::mem::size_of;
    use windows_sys::Win32::{
        Foundation::{CloseHandle, INVALID_HANDLE_VALUE},
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First,
                Thread32Next,
            },
            Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME},
        },
    };
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    let result = (|| {
        let mut entry = THREADENTRY32 {
            dwSize: size_of::<THREADENTRY32>() as u32,
            ..Default::default()
        };
        let mut has_entry = unsafe { Thread32First(snapshot, &mut entry) } != 0;
        while has_entry {
            if entry.th32OwnerProcessID == pid {
                let thread_handle =
                    unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
                if thread_handle.is_null() {
                    return Err(io::Error::last_os_error());
                }
                let previous = unsafe { ResumeThread(thread_handle) };
                unsafe {
                    CloseHandle(thread_handle);
                }
                if previous == u32::MAX {
                    return Err(io::Error::last_os_error());
                }
                return Ok(());
            }
            has_entry = unsafe { Thread32Next(snapshot, &mut entry) } != 0;
        }
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            "suspended runner thread not found",
        ))
    })();
    unsafe {
        CloseHandle(snapshot);
    }
    result
}
