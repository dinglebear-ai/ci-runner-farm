use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const MAX_FRAME: usize = 131_072;
const MAX_JIT: usize = 65_536;
const LABEL: &str = "io.dinglebear.ci-runner-farm";

#[derive(Debug)]
struct Config {
    state_root: PathBuf,
    work_root: PathBuf,
    entrypoint: PathBuf,
    image: String,
    docker: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    schema_version: u8,
    payload: Request,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Start {
        placement_id: String,
        command_id: String,
        pool_id: String,
        runner_name: String,
        resources: Resources,
        jit_config: String,
    },
    Inspect {
        placement_id: String,
        expected_id: Option<String>,
    },
    Cancel {
        placement_id: String,
        expected_id: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Resources {
    cpu_millis: u64,
    memory_bytes: u64,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct State {
    schema_version: u8,
    placement_id: String,
    command_id: String,
    pool_id: String,
    runner_name: String,
    container_name: String,
    container_id: String,
    cpu_millis: u64,
    memory_bytes: u64,
    handoff_phase: String,
    terminal: Option<String>,
}

struct Lock {
    _file: fs::File,
}

fn main() {
    if env::args().nth(1).as_deref() == Some("--version") {
        println!("crf-container-adapter {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    let response = match run() {
        Ok(value) => value,
        Err(code) => error_response(code),
    };
    println!("{}", response);
}

fn run() -> Result<Value, &'static str> {
    let config = Config::from_env()?;
    let mut bytes = Vec::new();
    io::stdin()
        .take((MAX_FRAME + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "invalid_request")?;
    if bytes.len() > MAX_FRAME {
        return Err("request_too_large");
    }
    let envelope: Envelope = serde_json::from_slice(&bytes).map_err(|_| "invalid_request")?;
    if envelope.schema_version != 1 {
        return Err("invalid_request");
    }
    let placement = match &envelope.payload {
        Request::Start { placement_id, .. }
        | Request::Inspect { placement_id, .. }
        | Request::Cancel { placement_id, .. } => placement_id,
    };
    if !identifier(placement) {
        return Err("invalid_request");
    }
    fs::create_dir_all(config.state_root.join("locks")).map_err(|_| "state_unavailable")?;
    fs::create_dir_all(&config.work_root).map_err(|_| "state_unavailable")?;
    private_dir(&config.state_root)?;
    private_dir(&config.state_root.join("locks"))?;
    private_dir(&config.work_root)?;
    let key = format!("{:x}", Sha256::digest(placement.as_bytes()));
    let lock_path = config.state_root.join("locks").join(format!("{key}.lock"));
    let _lock = acquire_lock(&lock_path).ok_or("placement_busy")?;
    let state_path = config.state_root.join(format!("{key}.json"));
    let name = format!("crf-dist-{}", &key[..20]);
    match envelope.payload {
        Request::Start {
            placement_id,
            command_id,
            pool_id,
            runner_name,
            resources,
            jit_config,
        } => start(
            &config,
            &state_path,
            &name,
            placement_id,
            command_id,
            pool_id,
            runner_name,
            resources,
            jit_config,
        ),
        Request::Inspect {
            placement_id,
            expected_id,
        } => inspect(
            &config,
            &state_path,
            &name,
            &placement_id,
            expected_id.as_deref(),
        ),
        Request::Cancel {
            placement_id,
            expected_id,
        } => cancel(
            &config,
            &state_path,
            &name,
            &placement_id,
            expected_id.as_deref(),
        ),
    }
}

impl Config {
    fn from_env() -> Result<Self, &'static str> {
        let state_root = absolute_root(
            "CRF_CONTAINER_STATE_DIR",
            "/var/lib/ci-runner-farm/container-adapter",
        )?;
        let work_root = absolute_root("CRF_CONTAINER_WORK_ROOT", "/var/lib/ci-runner-farm/work")?;
        let entrypoint = absolute_file(
            "CRF_RUNNER_ENTRYPOINT",
            "/opt/ci-runner-farm/current/libexec/runner-entrypoint.sh",
        )?;
        let image = env::var("CRF_RUNNER_IMAGE").map_err(|_| "immutable_image_required")?;
        if !immutable_image(&image) {
            return Err("immutable_image_required");
        }
        let docker = find_program("docker").ok_or("missing_runtime_dependency")?;
        Ok(Self {
            state_root,
            work_root,
            entrypoint,
            image,
            docker,
        })
    }
}

#[allow(clippy::too_many_arguments)]
fn start(
    config: &Config,
    path: &Path,
    name: &str,
    placement: String,
    command: String,
    pool: String,
    runner: String,
    resources: Resources,
    jit: String,
) -> Result<Value, &'static str> {
    if !identifier(&command)
        || !identifier(&pool)
        || !identifier(&runner)
        || resources.cpu_millis == 0
        || resources.cpu_millis > 256_000
        || resources.memory_bytes == 0
        || resources.memory_bytes > 1_099_511_627_776
        || jit.is_empty()
        || jit.len() > MAX_JIT
    {
        return Err("invalid_request");
    }
    if let Some(mut state) = read_state(path, &placement, name)? {
        if state.command_id != command
            || state.pool_id != pool
            || state.runner_name != runner
            || state.cpu_millis != resources.cpu_millis
            || state.memory_bytes != resources.memory_bytes
        {
            return Err("placement_conflict");
        }
        let observed = find_container(config, &placement, name, Some(&state))?
            .ok_or("container_start_uncertain")?;
        if state.container_id.is_empty() {
            state.container_id = observed.id.clone();
            write_state(path, &state)?;
        }
        if let Some(terminal_state) = &state.terminal {
            return Ok(terminal(terminal_state));
        }
        return resume_handoff(config, path, state, jit, &observed.id);
    }
    if find_container(config, &placement, name, None)?.is_some() {
        return Ok(deferred("state_missing"));
    }
    let work = config.work_root.join(hash(&placement));
    if work
        .symlink_metadata()
        .is_ok_and(|m| m.file_type().is_symlink())
    {
        return Err("invalid_work_root");
    }
    fs::create_dir_all(&work).map_err(|_| "work_root_unavailable")?;
    private_dir(&work)?;
    let mut state = State {
        schema_version: 1,
        placement_id: placement.clone(),
        command_id: command.clone(),
        pool_id: pool.clone(),
        runner_name: runner.clone(),
        container_name: name.into(),
        container_id: String::new(),
        cpu_millis: resources.cpu_millis,
        memory_bytes: resources.memory_bytes,
        handoff_phase: "pending_ready".into(),
        terminal: None,
    };
    write_state(path, &state)?;
    let cpu = format!(
        "{}.{:03}",
        resources.cpu_millis / 1000,
        resources.cpu_millis % 1000
    );
    let labels = [
        format!("{LABEL}.managed=true"),
        format!("{LABEL}.backend=distributed"),
        format!("{LABEL}.placement-id={placement}"),
        format!("{LABEL}.command-id={command}"),
        format!("{LABEL}.pool={pool}"),
        format!("{LABEL}.runner-name={runner}"),
        format!("{LABEL}.cpu-millis={}", resources.cpu_millis),
        format!("{LABEL}.memory-bytes={}", resources.memory_bytes),
    ];
    let mut args = vec![
        "run".into(),
        "-d".into(),
        "--restart=no".into(),
        "--name".into(),
        name.into(),
        "--hostname".into(),
        runner.clone(),
        "--cpus".into(),
        cpu,
        "--memory".into(),
        resources.memory_bytes.to_string(),
        "--memory-swap".into(),
        resources.memory_bytes.to_string(),
        "--pids-limit".into(),
        "4096".into(),
        "--tmpfs".into(),
        "/run/crf:rw,noexec,nosuid,nodev,size=1m".into(),
        "--mount".into(),
        format!(
            "type=bind,src={},dst=/usr/local/bin/crf-runner-entrypoint,readonly",
            config.entrypoint.display()
        ),
        "--mount".into(),
        format!("type=bind,src={},dst=/_work", work.display()),
        "--entrypoint".into(),
        "/usr/local/bin/crf-runner-entrypoint".into(),
    ];
    for label in labels {
        args.extend(["--label".into(), label]);
    }
    for env_pair in [
        "CRF_CREDENTIAL_KIND=jit",
        "EPHEMERAL=true",
        "RUN_AS_ROOT=false",
        "RUNNER_WORKDIR=/_work",
        "DISABLE_AUTO_UPDATE=true",
        "DISABLE_AUTOMATIC_DEREGISTRATION=true",
    ] {
        args.extend(["-e".into(), env_pair.into()]);
    }
    args.push(config.image.clone());
    if !docker_status(config, &args, None) {
        return Ok(deferred("container_start_uncertain"));
    }
    let observed = find_container(config, &placement, name, Some(&state))?
        .ok_or("container_start_uncertain")?;
    state.container_id = observed.id.clone();
    if write_state(path, &state).is_err() {
        let _ = docker_status(config, &["rm".into(), "-f".into(), observed.id], None);
        return Ok(deferred("state_write_failed"));
    }
    resume_handoff(config, path, state, jit, &observed.id)
}

fn resume_handoff(
    config: &Config,
    path: &Path,
    mut state: State,
    jit: String,
    id: &str,
) -> Result<Value, &'static str> {
    if state.handoff_phase == "pending_ready" {
        if !wait_file(config, id, "/run/crf/ready", 60) {
            return Ok(deferred("container_secret_pending"));
        }
        state.handoff_phase = "pending_secret".into();
        write_state(path, &state)?;
    }
    if state.handoff_phase == "pending_secret" {
        let mut secret = jit.into_bytes();
        secret.push(b'\n');
        let delivered = docker_status(
            config,
            &[
                "exec".into(),
                "-i".into(),
                id.into(),
                "tee".into(),
                "/run/crf/secret.in".into(),
            ],
            Some(&secret),
        );
        secret.fill(0);
        if !delivered {
            return Ok(deferred("container_secret_pending"));
        }
        state.handoff_phase = "pending_consumed".into();
        write_state(path, &state)?;
    }
    if state.handoff_phase == "pending_consumed" {
        if !wait_file(config, id, "/run/crf/consumed", 30) {
            return Ok(deferred("container_secret_pending"));
        }
        state.handoff_phase = "complete".into();
        write_state(path, &state)?;
    }
    Ok(reply_id("started", id))
}

struct Observed {
    id: String,
    status: String,
    exit: i32,
}
fn inspect(
    config: &Config,
    path: &Path,
    name: &str,
    placement: &str,
    expected: Option<&str>,
) -> Result<Value, &'static str> {
    if expected.is_some_and(|v| !container_id(v)) {
        return Err("invalid_request");
    }
    let mut state = read_state(path, placement, name)?;
    if let Some(state) = &state
        && state.handoff_phase != "complete"
    {
        return Ok(deferred(if state.handoff_phase == "cancelling" {
            "cancellation_pending"
        } else {
            "container_secret_pending"
        }));
    }
    if let Some(s) = &state
        && let Some(t) = &s.terminal
    {
        return Ok(terminal(t));
    }
    match find_container(config, placement, name, state.as_ref())? {
        Some(observed) => {
            if state
                .as_ref()
                .is_some_and(|s| !s.container_id.is_empty() && s.container_id != observed.id)
            {
                return Ok(deferred("runtime_identity_mismatch"));
            }
            if expected.is_some_and(|id| id != observed.id) {
                return Ok(reply_id("running", &observed.id));
            }
            match observed.status.as_str() {
                "running" | "paused" => Ok(reply_id("running", &observed.id)),
                "exited" => {
                    if let Some(ref mut s) = state {
                        s.terminal = Some(
                            if observed.exit == 0 {
                                "finished"
                            } else {
                                "failed"
                            }
                            .into(),
                        );
                        write_state(path, s)?;
                        Ok(terminal(s.terminal.as_deref().unwrap()))
                    } else {
                        Ok(deferred("state_missing"))
                    }
                }
                "dead" => Ok(deferred("container_runtime_dead")),
                _ => Ok(deferred("container_state_transitional")),
            }
        }
        None => Ok(if state.is_some() {
            failed("container_lost")
        } else {
            simple("absent")
        }),
    }
}

fn cancel(
    config: &Config,
    path: &Path,
    name: &str,
    placement: &str,
    expected: Option<&str>,
) -> Result<Value, &'static str> {
    if expected.is_some_and(|v| !container_id(v)) {
        return Err("invalid_request");
    }
    let mut state = read_state(path, placement, name)?;
    let observed = find_container(config, placement, name, state.as_ref())?;
    if let Some(ref o) = observed {
        if expected.is_some_and(|id| id != o.id) {
            return Ok(deferred("runtime_identity_mismatch"));
        }
        if let Some(ref mut s) = state
            && s.terminal.is_none()
        {
            s.handoff_phase = "cancelling".into();
            write_state(path, s)?;
        }
        let _ = docker_status(
            config,
            &["stop".into(), "--time".into(), "15".into(), o.id.clone()],
            None,
        );
        if !docker_status(config, &["rm".into(), "-f".into(), o.id.clone()], None) {
            return Ok(deferred("container_remove_failed"));
        }
    }
    if let Some(ref mut s) = state {
        if let Some(t) = &s.terminal {
            return Ok(terminal(t));
        }
        s.terminal = Some("cancelled".into());
        s.handoff_phase = "complete".into();
        write_state(path, s)?;
    }
    Ok(simple("cancelled"))
}

fn find_container(
    config: &Config,
    placement: &str,
    name: &str,
    state: Option<&State>,
) -> Result<Option<Observed>, &'static str> {
    let ids = docker_output(
        config,
        &[
            "ps",
            "-aq",
            "--filter",
            &format!("label={LABEL}.placement-id={placement}"),
        ],
    )?;
    let ids: Vec<_> = ids.lines().filter(|v| !v.is_empty()).collect();
    if ids.len() > 1 {
        return Err("container_identity_ambiguous");
    }
    let Some(id) = ids.first() else {
        return Ok(None);
    };
    let observed_id = inspect_field(config, "{{.Id}}", id)?;
    if !container_id(&observed_id)
        || inspect_field(
            config,
            &format!("{{{{ index .Config.Labels \"{LABEL}.managed\" }}}}"),
            &observed_id,
        )? != "true"
        || inspect_field(
            config,
            &format!("{{{{ index .Config.Labels \"{LABEL}.placement-id\" }}}}"),
            &observed_id,
        )? != placement
        || inspect_field(config, "{{.Name}}", &observed_id)?.trim_start_matches('/') != name
    {
        return Err("container_identity_ambiguous");
    }
    if let Some(state) = state {
        for (key, expected) in [
            ("backend", "distributed".to_string()),
            ("command-id", state.command_id.clone()),
            ("pool", state.pool_id.clone()),
            ("runner-name", state.runner_name.clone()),
            ("cpu-millis", state.cpu_millis.to_string()),
            ("memory-bytes", state.memory_bytes.to_string()),
        ] {
            let format = format!("{{{{ index .Config.Labels \"{LABEL}.{key}\" }}}}");
            if inspect_field(config, &format, &observed_id)? != expected {
                return Err("container_identity_ambiguous");
            }
        }
    }
    let status = inspect_field(config, "{{.State.Status}}", &observed_id)?;
    let exit = inspect_field(config, "{{.State.ExitCode}}", &observed_id)?
        .parse()
        .map_err(|_| "container_identity_ambiguous")?;
    Ok(Some(Observed {
        id: observed_id,
        status,
        exit,
    }))
}

fn inspect_field(config: &Config, format: &str, id: &str) -> Result<String, &'static str> {
    docker_output(config, &["inspect", "--format", format, id])
}
fn docker_output(config: &Config, args: &[&str]) -> Result<String, &'static str> {
    let out = Command::new(&config.docker)
        .args(args)
        .env_clear()
        .env("PATH", env::var("PATH").unwrap_or_default())
        .envs(env::vars().filter(|(k, _)| k.starts_with("CRF_TEST_")))
        .output()
        .map_err(|_| "container_identity_ambiguous")?;
    if !out.status.success() {
        return Err("container_identity_ambiguous");
    }
    String::from_utf8(out.stdout)
        .map(|v| v.trim().into())
        .map_err(|_| "container_identity_ambiguous")
}
fn docker_status(config: &Config, args: &[String], input: Option<&[u8]>) -> bool {
    let mut child = match Command::new(&config.docker)
        .args(args)
        .env_clear()
        .env("PATH", env::var("PATH").unwrap_or_default())
        .envs(env::vars().filter(|(k, _)| k.starts_with("CRF_TEST_")))
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(v) => v,
        Err(_) => return false,
    };
    if let Some(bytes) = input {
        return write_input_and_wait(&mut child, bytes);
    }
    child.wait().is_ok_and(|s| s.success())
}
fn write_input_and_wait(child: &mut std::process::Child, bytes: &[u8]) -> bool {
    let write_ok = child
        .stdin
        .take()
        .is_some_and(|mut stdin| stdin.write_all(bytes).is_ok());
    if !write_ok {
        let _ = child.kill();
    }
    child
        .wait()
        .is_ok_and(|status| write_ok && status.success())
}
fn wait_file(config: &Config, id: &str, path: &str, attempts: usize) -> bool {
    (0..attempts).any(|_| {
        let ok = docker_status(
            config,
            &[
                "exec".into(),
                id.into(),
                "test".into(),
                "-f".into(),
                path.into(),
            ],
            None,
        );
        if !ok {
            thread::sleep(Duration::from_millis(500));
        }
        ok
    })
}

fn read_state(path: &Path, placement: &str, name: &str) -> Result<Option<State>, &'static str> {
    if !path.exists() {
        return Ok(None);
    }
    let meta = fs::symlink_metadata(path).map_err(|_| "state_corrupt")?;
    if !meta.is_file()
        || meta.file_type().is_symlink()
        || meta.permissions().mode() & 0o777 != 0o600
    {
        return Err("state_corrupt");
    }
    let state: State = serde_json::from_slice(&fs::read(path).map_err(|_| "state_corrupt")?)
        .map_err(|_| "state_corrupt")?;
    if state.schema_version != 1
        || state.placement_id != placement
        || state.container_name != name
        || !identifier(&state.command_id)
        || !identifier(&state.pool_id)
        || !identifier(&state.runner_name)
        || (!state.container_id.is_empty() && !container_id(&state.container_id))
        || !matches!(
            state.handoff_phase.as_str(),
            "pending_ready" | "pending_secret" | "pending_consumed" | "complete" | "cancelling"
        )
        || state
            .terminal
            .as_deref()
            .is_some_and(|value| !matches!(value, "finished" | "cancelled" | "failed"))
    {
        return Err("state_corrupt");
    }
    Ok(Some(state))
}
fn write_state(path: &Path, state: &State) -> Result<(), &'static str> {
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|_| "state_write_failed")?;
    serde_json::to_writer(&mut file, state).map_err(|_| "state_write_failed")?;
    file.sync_all().map_err(|_| "state_write_failed")?;
    fs::rename(&tmp, path).map_err(|_| "state_write_failed")?;
    if let Some(parent) = path.parent() {
        OpenOptions::new()
            .read(true)
            .open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|_| "state_write_failed")?;
    }
    Ok(())
}
fn acquire_lock(path: &Path) -> Option<Lock> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)
        .ok()?;
    loop {
        match file.try_lock_exclusive() {
            Ok(()) => return Some(Lock { _file: file }),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(50))
            }
            Err(_) => return None,
        }
    }
}
fn private_dir(path: &Path) -> Result<(), &'static str> {
    let meta = fs::symlink_metadata(path).map_err(|_| "state_unavailable")?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err("invalid_storage_root");
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|_| "state_unavailable")
}
fn absolute_root(key: &str, default: &str) -> Result<PathBuf, &'static str> {
    let p = PathBuf::from(env::var(key).unwrap_or_else(|_| default.into()));
    if !p.is_absolute()
        || p.components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
        || !no_symlink_components(&p)
    {
        Err("invalid_storage_root")
    } else {
        Ok(p)
    }
}
fn no_symlink_components(path: &Path) -> bool {
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => return false,
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => return false,
        }
    }
    true
}
fn absolute_file(key: &str, default: &str) -> Result<PathBuf, &'static str> {
    let p = absolute_root(key, default).map_err(|_| "invalid_runner_entrypoint")?;
    let m = p
        .symlink_metadata()
        .map_err(|_| "invalid_runner_entrypoint")?;
    if !m.is_file()
        || m.file_type().is_symlink()
        || m.permissions().mode() & 0o111 == 0
        || !safe_mount_source(&p)
    {
        Err("invalid_runner_entrypoint")
    } else {
        Ok(p)
    }
}
fn safe_mount_source(path: &Path) -> bool {
    path.as_os_str()
        .as_bytes()
        .iter()
        .all(|byte| *byte != b',' && !byte.is_ascii_control())
}
fn find_program(name: &str) -> Option<PathBuf> {
    env::split_paths(&env::var_os("PATH")?)
        .map(|p| p.join(name))
        .filter_map(|candidate| fs::canonicalize(candidate).ok())
        .find(|path| {
            fs::symlink_metadata(path).is_ok_and(|metadata| {
                metadata.is_file()
                    && !metadata.file_type().is_symlink()
                    && metadata.permissions().mode() & 0o111 != 0
            })
        })
}
fn immutable_image(v: &str) -> bool {
    let Some((name, digest)) = v.rsplit_once("@sha256:") else {
        return false;
    };
    !name.is_empty()
        && !name.bytes().any(|b| b.is_ascii_whitespace() || b == b'@')
        && digest.len() == 64
        && digest
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn identifier(v: &str) -> bool {
    let mut b = v.bytes();
    matches!(b.next(),Some(c) if c.is_ascii_alphanumeric())
        && v.len() <= 128
        && b.all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
}
fn container_id(v: &str) -> bool {
    v.len() == 64
        && v.bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn hash(v: &str) -> String {
    format!("{:x}", Sha256::digest(v.as_bytes()))
}
fn payload(v: Value) -> Value {
    json!({"schema_version":1,"payload":v})
}
fn simple(result: &str) -> Value {
    payload(json!({"result":result}))
}
fn reply_id(result: &str, id: &str) -> Value {
    payload(json!({"result":result,"id":id}))
}
fn rejected(code: &str) -> Value {
    payload(json!({"result":"rejected","detail_code":code}))
}
fn error_response(code: &str) -> Value {
    match code {
        "placement_busy"
        | "state_corrupt"
        | "state_write_failed"
        | "container_identity_ambiguous"
        | "work_root_unavailable" => deferred(code),
        _ => rejected(code),
    }
}
fn deferred(code: &str) -> Value {
    payload(json!({"result":"deferred","detail_code":code}))
}
fn failed(code: &str) -> Value {
    payload(json!({"result":"terminal","outcome":{"failed":{"detail_code":code}}}))
}
fn terminal(v: &str) -> Value {
    match v {
        "finished" => payload(json!({"result":"terminal","outcome":"finished"})),
        "cancelled" => payload(json!({"result":"terminal","outcome":"cancelled"})),
        _ => failed("container_exit_nonzero"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;
    #[test]
    fn identifiers_are_anchored() {
        assert!(identifier("node-1"));
        assert!(!identifier("node one"));
        assert!(!identifier("node\n"));
        assert!(!identifier("_node"));
    }
    #[test]
    fn image_requires_lowercase_sha256_digest() {
        assert!(immutable_image(&format!(
            "registry/image@sha256:{}",
            "a".repeat(64)
        )));
        assert!(!immutable_image("registry/image:latest"));
        assert!(!immutable_image(&format!(
            "registry/image@sha256:{}",
            "A".repeat(64)
        )));
    }
    #[test]
    fn unknown_request_fields_are_rejected() {
        let input=br#"{"schema_version":1,"payload":{"action":"inspect","placement_id":"p","expected_id":null,"extra":true}}"#;
        assert!(serde_json::from_slice::<Envelope>(input).is_err());
    }

    #[test]
    fn docker_mount_source_rejects_grammar_and_control_bytes() {
        assert!(safe_mount_source(Path::new("/opt/crf/entrypoint")));
        assert!(!safe_mount_source(Path::new("/opt/crf/entry,point")));
        assert!(!safe_mount_source(Path::new(std::ffi::OsStr::from_bytes(
            b"/opt/crf/entry\npoint",
        ))));
    }

    #[test]
    fn failed_stdin_write_reaps_the_child() {
        let mut child = Command::new("sh")
            .args(["-c", "exec 0<&-; sleep 30"])
            .stdin(Stdio::piped())
            .spawn()
            .expect("spawn helper");
        let started = Instant::now();
        assert!(!write_input_and_wait(&mut child, &vec![b'x'; 1024 * 1024]));
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(child.try_wait().expect("child status").is_some());
    }
}
