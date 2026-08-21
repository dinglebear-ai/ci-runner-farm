use std::{process::Command, thread, time::Duration};

#[cfg(unix)]
use std::{fs, path::Path};

use crf_node::{process_tree::ManagedProcess, system_probe::SystemProbe};

#[cfg(unix)]
fn wait_for_pid(path: &Path) -> u32 {
    for _ in 0..200 {
        if let Ok(value) = fs::read_to_string(path)
            && let Ok(pid) = value.trim().parse::<u32>()
            && pid > 0
        {
            return pid;
        }
        thread::sleep(Duration::from_millis(20));
    }
    panic!("child pid was not published");
}

fn wait_for_exit(pid: u32) {
    let mut probe = SystemProbe::new().expect("system probe");
    for _ in 0..200 {
        if !probe.process_exists(pid) {
            return;
        }
        thread::sleep(Duration::from_millis(20));
    }
    panic!("descendant process {pid} survived tree termination");
}

#[cfg(unix)]
fn temp_path(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("crf-process-tree-{name}-{}", std::process::id()))
}

#[cfg(windows)]
fn wait_for_windows_child(parent_pid: u32) -> u32 {
    use std::mem::size_of;
    use windows_sys::Win32::{
        Foundation::{CloseHandle, INVALID_HANDLE_VALUE},
        System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, PROCESSENTRY32, Process32First, Process32Next,
            TH32CS_SNAPPROCESS,
        },
    };

    for _ in 0..200 {
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snapshot != INVALID_HANDLE_VALUE {
                let mut entry = PROCESSENTRY32 {
                    dwSize: size_of::<PROCESSENTRY32>() as u32,
                    ..Default::default()
                };
                let mut found = 0;
                if Process32First(snapshot, &mut entry) != 0 {
                    loop {
                        if entry.th32ParentProcessID == parent_pid && entry.th32ProcessID != 0 {
                            found = entry.th32ProcessID;
                            break;
                        }
                        if Process32Next(snapshot, &mut entry) == 0 {
                            break;
                        }
                    }
                }
                CloseHandle(snapshot);
                if found != 0 {
                    return found;
                }
            }
        }
        thread::sleep(Duration::from_millis(20));
    }
    panic!("child process was not observed under managed Windows parent {parent_pid}");
}

#[cfg(unix)]
#[test]
fn unix_tree_termination_kills_stubborn_descendant_process_group() {
    let pid_path = temp_path("unix-child.pid");
    let _ = fs::remove_file(&pid_path);
    let script = r#"trap '' TERM
(
  trap '' TERM
  while :; do sleep 1; done
) &
printf '%s' "$!" > "$1"
while :; do sleep 1; done
"#;
    let mut command = Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(script)
        .arg("crf-process-tree")
        .arg(&pid_path);

    let mut process = ManagedProcess::spawn(&mut command).expect("spawn managed process group");
    let descendant_pid = wait_for_pid(&pid_path);
    let mut probe = SystemProbe::new().expect("system probe");
    assert!(probe.process_exists(descendant_pid));

    let _status = process.terminate_tree().expect("terminate process group");
    wait_for_exit(descendant_pid);
    let _ = fs::remove_file(pid_path);
}

#[cfg(windows)]
#[test]
fn windows_job_termination_kills_descendant_process_tree() {
    let mut command = Command::new("cmd.exe");
    command
        .arg("/D")
        .arg("/S")
        .arg("/C")
        .arg("ping.exe -t 127.0.0.1 >NUL");

    let mut process = ManagedProcess::spawn(&mut command).expect("spawn managed Windows job");
    let descendant_pid = wait_for_windows_child(process.id());
    let mut probe = SystemProbe::new().expect("system probe");
    assert!(probe.process_exists(descendant_pid));

    let _status = process.terminate_tree().expect("terminate Windows job");
    wait_for_exit(descendant_pid);
}
