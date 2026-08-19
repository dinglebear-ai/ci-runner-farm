use std::{
    ffi::OsString,
    io,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
};

use crf_protocol::OperatingSystem;

pub const JIT_CONFIG_ENV: &str = "ACTIONS_RUNNER_INPUT_JITCONFIG";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeRunnerInvocation {
    pub program: OsString,
    pub args: Vec<OsString>,
    pub working_directory: PathBuf,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeRunnerError {
    UnsupportedOperatingSystem,
}

impl NativeRunnerInvocation {
    pub fn for_platform(
        runner_root: impl AsRef<Path>,
        os: &OperatingSystem,
    ) -> Result<Self, NativeRunnerError> {
        let runner_root = runner_root.as_ref().to_path_buf();

        match os {
            OperatingSystem::Windows => Ok(Self {
                program: OsString::from("cmd.exe"),
                args: ["/D", "/S", "/C", "run.cmd"]
                    .into_iter()
                    .map(OsString::from)
                    .collect(),
                working_directory: runner_root,
            }),
            OperatingSystem::Linux | OperatingSystem::Macos => Ok(Self {
                program: runner_root.join("run.sh").into_os_string(),
                args: Vec::new(),
                working_directory: runner_root,
            }),
            OperatingSystem::Other => Err(NativeRunnerError::UnsupportedOperatingSystem),
        }
    }

    pub fn spawn(&self, jit_config: &str) -> io::Result<Child> {
        self.command(jit_config)
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .spawn()
    }

    pub fn spawn_with_logs(
        &self,
        jit_config: &str,
        stdout: std::fs::File,
        stderr: std::fs::File,
    ) -> io::Result<Child> {
        self.command(jit_config)
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .spawn()
    }

    fn command(&self, jit_config: &str) -> Command {
        let mut command = Command::new(&self.program);
        command
            .args(&self.args)
            .current_dir(&self.working_directory)
            .env(JIT_CONFIG_ENV, jit_config)
            .stdin(Stdio::null());
        command
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_native_runner_uses_environment_for_jit_secret() {
        let invocation =
            NativeRunnerInvocation::for_platform(r"C:\\crf\\runner", &OperatingSystem::Windows)
                .unwrap();

        assert_eq!(invocation.program, OsString::from("cmd.exe"));
        assert_eq!(
            invocation.args,
            vec![
                OsString::from("/D"),
                OsString::from("/S"),
                OsString::from("/C"),
                OsString::from("run.cmd")
            ]
        );
        assert!(
            invocation
                .args
                .iter()
                .all(|arg| !arg.to_string_lossy().contains("jitconfig"))
        );
        assert_eq!(JIT_CONFIG_ENV, "ACTIONS_RUNNER_INPUT_JITCONFIG");
    }

    #[test]
    fn unix_native_runner_invokes_run_script_without_jit_argument() {
        let invocation =
            NativeRunnerInvocation::for_platform("/opt/crf/runner", &OperatingSystem::Linux)
                .unwrap();

        assert!(invocation.program.to_string_lossy().ends_with("run.sh"));
        assert!(invocation.args.is_empty());
    }

    #[test]
    fn unknown_platform_is_fail_closed() {
        assert_eq!(
            NativeRunnerInvocation::for_platform("/tmp/runner", &OperatingSystem::Other),
            Err(NativeRunnerError::UnsupportedOperatingSystem)
        );
    }
}
