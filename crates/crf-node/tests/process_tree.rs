use std::{fs, path::Path, process::Command, thread, time::Duration};

use crf_node::{process_tree::ManagedProcess, system_probe::SystemProbe};

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

fn temp_path(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("crf-process-tree-{name}-{}", std::process::id()))
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
    let pid_path = temp_path("windows-child.pid");
    let _ = fs::remove_file(&pid_path);
    let escaped = pid_path.to_string_lossy().replace('\'', "''");
    let script = format!(
        "$child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-Command','while ($true) {{ Start-Sleep -Seconds 1 }}') -PassThru; Set-Content -NoNewline -Path '{escaped}' -Value $child.Id; Wait-Process -Id $child.Id"
    );
    let mut command = Command::new("powershell.exe");
    command.arg("-NoProfile").arg("-Command").arg(script);

    let mut process = ManagedProcess::spawn(&mut command).expect("spawn managed Windows job");
    let descendant_pid = wait_for_pid(&pid_path);
    let mut probe = SystemProbe::new().expect("system probe");
    assert!(probe.process_exists(descendant_pid));

    let _status = process.terminate_tree().expect("terminate Windows job");
    wait_for_exit(descendant_pid);
    let _ = fs::remove_file(pid_path);
}
