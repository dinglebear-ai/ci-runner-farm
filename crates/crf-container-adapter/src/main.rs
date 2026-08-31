use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        io::{AsRawFd, FromRawFd},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use base64::Engine;
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::os::unix::process::CommandExt;

const MAX_FRAME: usize = 131_072;
const MAX_JIT: usize = 65_536;
const LABEL: &str = "io.dinglebear.ci-runner-farm";
const OTP_28_CAPABILITY: &str = "otp-28-compatible";

#[derive(Debug)]
struct Config {
    state_root: PathBuf,
    image: String,
    enable_dind: bool,
    docker: DockerExecutable,
}

#[derive(Debug)]
struct DockerExecutable {
    path: PathBuf,
    device: u64,
    inode: u64,
    test_trust_root: Option<PathBuf>,
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
    ownership_nonce: String,
    work_volume_name: String,
    bootstrap_volume_name: String,
    image: String,
    container_id: String,
    cpu_millis: u64,
    memory_bytes: u64,
    handoff_phase: String,
    terminal: Option<String>,
    #[serde(default)]
    cleanup: Cleanup,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Cleanup {
    requested: bool,
    container_removed: bool,
    bootstrap_removed: bool,
    work_removed: bool,
}

struct Lock {
    _file: fs::File,
}

struct StateStore {
    root: fs::File,
    locks: fs::File,
}

struct StatePath<'a> {
    store: &'a StateStore,
    name: String,
}

fn main() {
    if env::args().nth(1).as_deref() == Some("--image-capabilities") {
        match Config::from_env().and_then(|config| image_capabilities(&config)) {
            Ok(value) => println!("{value}"),
            Err(code) => {
                eprintln!("crf-container-adapter image preflight failed: {code}");
                std::process::exit(1);
            }
        }
        return;
    }
    if env::args().nth(1).as_deref() == Some("docker-supervise") {
        docker_supervise();
        return;
    }
    if env::args().nth(1).as_deref() == Some("runner-entrypoint") {
        if let Err(code) = run_runner_entrypoint() {
            eprintln!("crf-container-adapter runner entrypoint failed: {code}");
            std::process::exit(1);
        }
        return;
    }
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
    let store = StateStore::open(&config.state_root)?;
    let key = format!("{:x}", Sha256::digest(placement.as_bytes()));
    let _lock = acquire_lock(&store, &format!("{key}.lock")).ok_or("placement_busy")?;
    let state_path = StatePath {
        store: &store,
        name: format!("{key}.json"),
    };
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

fn image_capabilities(config: &Config) -> Result<Value, &'static str> {
    let repo_digests: Vec<String> = serde_json::from_str(&docker_output(
        config,
        &[
            "image",
            "inspect",
            "--format",
            "{{json .RepoDigests}}",
            &config.image,
        ],
    )?)
    .map_err(|_| "image_contract_unavailable")?;
    let contract_args = image_contract_run_args(&config.image);
    let contract = docker_output(config, &contract_args)?;
    let architecture = docker_output(
        config,
        &[
            "image",
            "inspect",
            "--format",
            "{{.Architecture}}",
            &config.image,
        ],
    )?;
    let capabilities =
        validated_image_capabilities(&config.image, &repo_digests, &architecture, &contract)?;
    Ok(json!(capabilities))
}

fn image_contract_run_args(image: &str) -> Vec<&str> {
    vec![
        "run",
        "--rm",
        "--pull=never",
        "--network=none",
        "--read-only",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--pids-limit=32",
        "--cpus=0.25",
        // The image contract probes bundled tooling such as buildx. 64 MiB
        // is below its observed peak on otherwise healthy nodes and lets the
        // kernel kill the probe, falsely quarantining the image.
        "--memory=128m",
        "--memory-swap=128m",
        "--user=65534:65534",
        "--entrypoint",
        "/usr/local/bin/crf-runner-image-contract",
        image,
    ]
}

fn validated_image_capabilities(
    configured_image: &str,
    repo_digests: &[String],
    inspected_architecture: &str,
    contract_json: &str,
) -> Result<Vec<&'static str>, &'static str> {
    if !immutable_image(configured_image)
        || !repo_digests.iter().any(|digest| digest == configured_image)
    {
        return Err("image_contract_unavailable");
    }
    let contract: Value =
        serde_json::from_str(contract_json).map_err(|_| "image_contract_unavailable")?;
    let compatible = contract.get("compatible").and_then(Value::as_bool) == Some(true);
    let schema = contract.get("schema_version").and_then(Value::as_u64) == Some(1);
    let os = contract.pointer("/os/id").and_then(Value::as_str);
    let version = contract.pointer("/os/version_id").and_then(Value::as_str);
    let image_os = contract.get("image_os").and_then(Value::as_str);
    let os_consistent = matches!(
        (os, version, image_os),
        (Some("ubuntu"), Some("24.04"), Some("ubuntu24"))
            | (Some("ubuntu"), Some("26.04"), Some("ubuntu26"))
    );
    let arch = contract.get("arch").and_then(Value::as_str);
    let arch_consistent = matches!(
        (inspected_architecture, arch),
        ("amd64", Some("x64")) | ("arm64", Some("arm64"))
    );
    let glibc_compatible = contract
        .get("glibc")
        .and_then(Value::as_str)
        .and_then(|value| value.split_once('.'))
        .and_then(|(major, minor)| Some((major.parse::<u32>().ok()?, minor.parse::<u32>().ok()?)))
        .is_some_and(|(major, minor)| major > 2 || (major == 2 && minor >= 34));
    let has_capability = contract
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|values| {
            values.iter().all(Value::is_string)
                && values
                    .iter()
                    .any(|value| value.as_str() == Some(OTP_28_CAPABILITY))
        });
    Ok(
        if compatible
            && schema
            && os_consistent
            && arch_consistent
            && glibc_compatible
            && has_capability
        {
            vec![OTP_28_CAPABILITY]
        } else {
            return Err("image_contract_unavailable");
        },
    )
}

impl Config {
    fn from_env() -> Result<Self, &'static str> {
        let state_root = absolute_root(
            "CRF_CONTAINER_STATE_DIR",
            "/var/lib/ci-runner-farm/container-adapter",
        )?;
        let image = env::var("CRF_RUNNER_IMAGE").map_err(|_| "immutable_image_required")?;
        if !immutable_image(&image) {
            return Err("immutable_image_required");
        }
        let enable_dind = env_flag("CRF_ENABLE_DIND")?;
        let docker = DockerExecutable::load()?;
        Ok(Self {
            state_root,
            image,
            enable_dind,
            docker,
        })
    }
}

impl DockerExecutable {
    fn load() -> Result<Self, &'static str> {
        let configured = env::var("CRF_DOCKER_PATH").unwrap_or_else(|_| "/usr/bin/docker".into());
        let configured = PathBuf::from(configured);
        if !configured.is_absolute() {
            return Err("missing_runtime_dependency");
        }
        let path = fs::canonicalize(&configured).map_err(|_| "missing_runtime_dependency")?;
        let test_trust_root = match env::var("CRF_TEST_DOCKER_TRUST_ROOT") {
            Ok(root) => Some(fs::canonicalize(root).map_err(|_| "missing_runtime_dependency")?),
            Err(_) => None,
        };
        validate_executable_path(&path, test_trust_root.as_deref())?;
        let metadata = fs::symlink_metadata(&path).map_err(|_| "missing_runtime_dependency")?;
        Ok(Self {
            path,
            device: metadata.dev(),
            inode: metadata.ino(),
            test_trust_root,
        })
    }

    fn command(&self) -> Result<Command, &'static str> {
        validate_executable_path(&self.path, self.test_trust_root.as_deref())?;
        let metadata =
            fs::symlink_metadata(&self.path).map_err(|_| "missing_runtime_dependency")?;
        if metadata.dev() != self.device || metadata.ino() != self.inode {
            return Err("missing_runtime_dependency");
        }
        Ok(Command::new(&self.path))
    }
}

fn validate_executable_path(path: &Path, test_root: Option<&Path>) -> Result<(), &'static str> {
    let metadata = fs::symlink_metadata(path).map_err(|_| "missing_runtime_dependency")?;
    let (mut current, required_uid) = if let Some(root) = test_root {
        if !path.starts_with(root) {
            return Err("missing_runtime_dependency");
        }
        (root.to_path_buf(), unsafe { libc::geteuid() } as u32)
    } else {
        (PathBuf::from("/"), 0)
    };
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.mode() & 0o111 == 0
        || metadata.uid() != required_uid
        || metadata.mode() & 0o022 != 0
    {
        return Err("missing_runtime_dependency");
    }
    let root_metadata = fs::symlink_metadata(&current).map_err(|_| "missing_runtime_dependency")?;
    if !root_metadata.is_dir()
        || root_metadata.file_type().is_symlink()
        || root_metadata.uid() != required_uid
        || root_metadata.mode() & 0o022 != 0
    {
        return Err("missing_runtime_dependency");
    }
    let relative = path
        .parent()
        .ok_or("missing_runtime_dependency")?
        .strip_prefix(&current)
        .map_err(|_| "missing_runtime_dependency")?;
    for component in relative.components() {
        current.push(component);
        let ancestor = fs::symlink_metadata(&current).map_err(|_| "missing_runtime_dependency")?;
        if !ancestor.is_dir()
            || ancestor.file_type().is_symlink()
            || ancestor.uid() != required_uid
            || ancestor.mode() & 0o022 != 0
        {
            return Err("missing_runtime_dependency");
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn start(
    config: &Config,
    path: &StatePath<'_>,
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
            || state.image != config.image
            || state.cpu_millis != resources.cpu_millis
            || state.memory_bytes != resources.memory_bytes
        {
            return Err("placement_conflict");
        }
        let mut observed = find_container(config, &placement, name, Some(&state))?;
        if observed.is_none() && state.handoff_phase == "pending_container_setup" {
            ensure_container(config, &state)?;
            observed = find_container(config, &placement, name, Some(&state))?;
        }
        let observed = observed.ok_or("container_start_uncertain")?;
        if state.container_id.is_empty() {
            state.container_id = observed.id.clone();
            write_state(path, &state)?;
        }
        if let Some(terminal_state) = &state.terminal {
            return Ok(terminal(terminal_state));
        }
        if matches!(
            state.handoff_phase.as_str(),
            "pending_container_setup" | "pending_start"
        ) {
            setup_container(config, path, &mut state, &observed.id)?;
        }
        return resume_handoff(config, path, state, jit, &observed.id);
    }
    if find_container(config, &placement, name, None)?.is_some() {
        return Ok(deferred("state_missing"));
    }
    let ownership_nonce = random_nonce()?;
    let work_volume_name = format!("crf-dist-work-{ownership_nonce}");
    let bootstrap_volume_name = format!("crf-dist-bootstrap-{ownership_nonce}");
    let mut state = State {
        schema_version: 1,
        placement_id: placement.clone(),
        command_id: command.clone(),
        pool_id: pool.clone(),
        runner_name: runner.clone(),
        container_name: name.into(),
        ownership_nonce: ownership_nonce.clone(),
        work_volume_name: work_volume_name.clone(),
        bootstrap_volume_name: bootstrap_volume_name.clone(),
        image: config.image.clone(),
        container_id: String::new(),
        cpu_millis: resources.cpu_millis,
        memory_bytes: resources.memory_bytes,
        handoff_phase: "pending_container_setup".into(),
        terminal: None,
        cleanup: Cleanup::default(),
    };
    write_state(path, &state)?;
    ensure_container(config, &state)?;
    let observed = find_container(config, &placement, name, Some(&state))?
        .ok_or("container_start_uncertain")?;
    state.container_id = observed.id.clone();
    if write_state(path, &state).is_err() {
        return Ok(deferred("state_write_failed"));
    }
    setup_container(config, path, &mut state, &observed.id)?;
    resume_handoff(config, path, state, jit, &observed.id)
}

fn setup_container(
    config: &Config,
    path: &StatePath<'_>,
    state: &mut State,
    id: &str,
) -> Result<(), &'static str> {
    let status = inspect_field(config, "{{.State.Status}}", id)?;
    if state.handoff_phase == "pending_container_setup" {
        if status != "created" {
            return Err("container_start_uncertain");
        }
        state.handoff_phase = "pending_start".into();
        write_state(path, state)?;
    }
    let status = inspect_field(config, "{{.State.Status}}", id)?;
    match status.as_str() {
        "created" if !docker_status(config, &["start".into(), id.into()], None) => {
            return Err("container_start_uncertain");
        }
        "created" | "running" => {}
        _ => return Err("container_start_uncertain"),
    }
    state.handoff_phase = "pending_ready".into();
    write_state(path, state)
}

fn ensure_container(config: &Config, state: &State) -> Result<(), &'static str> {
    for (volume_name, purpose) in [
        (&state.work_volume_name, "work"),
        (&state.bootstrap_volume_name, "bootstrap"),
    ] {
        let mut args = vec!["volume".into(), "create".into()];
        for label in volume_labels(state, purpose) {
            args.extend(["--label".into(), label]);
        }
        args.push(volume_name.clone());
        if !docker_status(config, &args, None)
            || !owned_volume(config, state, volume_name, purpose)?
        {
            return Err("container_start_uncertain");
        }
    }
    populate_bootstrap(config, state)?;
    let cpu = format!("{}.{:03}", state.cpu_millis / 1000, state.cpu_millis % 1000);
    let mut args = vec![
        "create".into(),
        "--restart=no".into(),
        "--name".into(),
        state.container_name.clone(),
        "--hostname".into(),
        state.runner_name.clone(),
        "--cpus".into(),
        cpu,
        "--memory".into(),
        state.memory_bytes.to_string(),
        "--memory-swap".into(),
        state.memory_bytes.to_string(),
        "--pids-limit".into(),
        "4096".into(),
        "--tmpfs".into(),
        "/run/crf:rw,noexec,nosuid,nodev,size=1m".into(),
        "--mount".into(),
        format!(
            "type=volume,src={},dst=/actions-runner/_work,volume-nocopy",
            state.work_volume_name
        ),
        "--mount".into(),
        format!(
            "type=volume,src={},dst=/opt/crf-bootstrap,readonly,volume-nocopy",
            state.bootstrap_volume_name
        ),
        "--entrypoint".into(),
        "/opt/crf-bootstrap/crf-container-adapter".into(),
    ];
    if config.enable_dind {
        args.push("--privileged".into());
        args.extend(["-e".into(), "START_DOCKER_SERVICE=true".into()]);
    }
    for label in container_labels(state) {
        args.extend(["--label".into(), label]);
    }
    for value in [
        "CRF_CREDENTIAL_KIND=jit",
        "EPHEMERAL=true",
        "RUN_AS_ROOT=false",
        "RUNNER_WORKDIR=/actions-runner/_work",
        "DISABLE_AUTO_UPDATE=true",
        "DISABLE_AUTOMATIC_DEREGISTRATION=true",
    ] {
        args.extend(["-e".into(), value.into()]);
    }
    args.extend([state.image.clone(), "runner-entrypoint".into()]);
    if docker_status(config, &args, None) {
        Ok(())
    } else {
        Err("container_start_uncertain")
    }
}

fn container_labels(state: &State) -> Vec<String> {
    vec![
        format!("{LABEL}.managed=true"),
        format!("{LABEL}.backend=distributed"),
        format!("{LABEL}.placement-id={}", state.placement_id),
        format!("{LABEL}.command-id={}", state.command_id),
        format!("{LABEL}.pool={}", state.pool_id),
        format!("{LABEL}.runner-name={}", state.runner_name),
        format!("{LABEL}.cpu-millis={}", state.cpu_millis),
        format!("{LABEL}.memory-bytes={}", state.memory_bytes),
        format!("{LABEL}.ownership-nonce={}", state.ownership_nonce),
        format!("{LABEL}.work-volume-name={}", state.work_volume_name),
        format!(
            "{LABEL}.bootstrap-volume-name={}",
            state.bootstrap_volume_name
        ),
    ]
}

fn populate_bootstrap(config: &Config, state: &State) -> Result<(), &'static str> {
    let init_name = format!("{}-bootstrap", state.container_name);
    let ids = docker_output(
        config,
        &[
            "ps",
            "-aq",
            "--filter",
            &format!("label={LABEL}.ownership-nonce={}", state.ownership_nonce),
            "--filter",
            &format!("label={LABEL}.purpose=bootstrap-init"),
        ],
    )?;
    let ids: Vec<_> = ids.lines().filter(|id| !id.is_empty()).collect();
    if ids.len() > 1 {
        return Err("container_identity_ambiguous");
    }
    let id = if let Some(id) = ids.first() {
        inspect_field(config, "{{.Id}}", id)?
    } else {
        let mut args = vec!["create".into(), "--name".into(), init_name.clone()];
        for label in volume_labels(state, "bootstrap-init") {
            args.extend(["--label".into(), label]);
        }
        args.extend([
            "--mount".into(),
            format!(
                "type=volume,src={},dst=/opt/crf-bootstrap,volume-nocopy",
                state.bootstrap_volume_name
            ),
            "--entrypoint".into(),
            "/bin/true".into(),
            state.image.clone(),
            "bootstrap-init".into(),
        ]);
        docker_output_owned(config, &args)?
    };
    if !container_id(&id) || !bootstrap_init_contract(config, &id, &init_name, state)? {
        return Err("container_identity_ambiguous");
    }
    let mut archive = adapter_archive()?;
    let copied = docker_status(
        config,
        &["cp".into(), "-".into(), format!("{id}:/opt/crf-bootstrap")],
        Some(&archive),
    );
    archive.fill(0);
    if !copied || !docker_status(config, &["rm".into(), "-f".into(), id], None) {
        return Err("container_start_uncertain");
    }
    Ok(())
}

fn bootstrap_init_contract(
    config: &Config,
    id: &str,
    name: &str,
    state: &State,
) -> Result<bool, &'static str> {
    if inspect_field(config, "{{.Name}}", id)?.trim_start_matches('/') != name
        || inspect_field(config, "{{.Config.Image}}", id)? != state.image
        || inspect_field(config, "{{json .Config.Entrypoint}}", id)? != "[\"/bin/true\"]"
        || inspect_field(config, "{{json .Config.Cmd}}", id)? != "[\"bootstrap-init\"]"
        || inspect_field(config, "{{.State.Status}}", id)? != "created"
    {
        return Ok(false);
    }
    for label in volume_labels(state, "bootstrap-init") {
        let (key, expected) = label
            .rsplit_once('=')
            .ok_or("container_identity_ambiguous")?;
        let key = key
            .rsplit_once('.')
            .map(|(_, key)| key)
            .ok_or("container_identity_ambiguous")?;
        if inspect_field(
            config,
            &format!("{{{{ index .Config.Labels \"{LABEL}.{key}\" }}}}"),
            id,
        )? != expected
        {
            return Ok(false);
        }
    }
    let mounts: Vec<Value> = serde_json::from_str(&inspect_field(config, "{{json .Mounts}}", id)?)
        .map_err(|_| "container_identity_ambiguous")?;
    Ok(mounts.len() == 1
        && mounts[0].get("Type").and_then(Value::as_str) == Some("volume")
        && mounts[0].get("Name").and_then(Value::as_str)
            == Some(state.bootstrap_volume_name.as_str())
        && mounts[0].get("Destination").and_then(Value::as_str) == Some("/opt/crf-bootstrap")
        && mounts[0].get("RW").and_then(Value::as_bool) == Some(true))
}

fn adapter_archive() -> Result<Vec<u8>, &'static str> {
    const MAX_ADAPTER_SIZE: u64 = 32 * 1024 * 1024;
    let mut executable =
        fs::File::open("/proc/self/exe").map_err(|_| "container_start_uncertain")?;
    let metadata = executable
        .metadata()
        .map_err(|_| "container_start_uncertain")?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_ADAPTER_SIZE {
        return Err("container_start_uncertain");
    }
    let mut archive = Vec::with_capacity(metadata.len() as usize + 2048);
    {
        let mut builder = tar::Builder::new(&mut archive);
        let mut header = tar::Header::new_gnu();
        header.set_size(metadata.len());
        header.set_mode(0o755);
        header.set_uid(0);
        header.set_gid(0);
        header.set_mtime(0);
        header.set_cksum();
        builder
            .append_data(&mut header, "crf-container-adapter", &mut executable)
            .and_then(|_| builder.finish())
            .map_err(|_| "container_start_uncertain")?;
    }
    Ok(archive)
}

fn random_nonce() -> Result<String, &'static str> {
    let mut bytes = [0u8; 16];
    fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|_| "state_unavailable")?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn resume_handoff(
    config: &Config,
    path: &StatePath<'_>,
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
    path: &StatePath<'_>,
    name: &str,
    placement: &str,
    expected: Option<&str>,
) -> Result<Value, &'static str> {
    if expected.is_some_and(|v| !container_id(v)) {
        return Err("invalid_request");
    }
    let mut state = read_state(path, placement, name)?;
    if let Some(s) = &state
        && let Some(t) = &s.terminal
    {
        let outcome = t.clone();
        let s = state.as_mut().expect("state present");
        if !s.cleanup.requested {
            s.cleanup.requested = true;
            write_state(path, s)?;
        }
        return finish_cleanup(config, path, s, &outcome);
    }
    if let Some(state) = &state
        && state.handoff_phase != "complete"
    {
        if !owned_volume(config, state, &state.work_volume_name, "work")?
            || !owned_volume(config, state, &state.bootstrap_volume_name, "bootstrap")?
        {
            return Ok(deferred("container_identity_ambiguous"));
        }
        if !state.container_id.is_empty() {
            let observed = find_container(config, placement, name, Some(state))?;
            if observed.as_ref().map(|item| item.id.as_str()) != Some(state.container_id.as_str()) {
                return Ok(deferred("container_identity_ambiguous"));
            }
            if expected.is_some_and(|id| id != state.container_id) {
                return Ok(deferred("runtime_identity_mismatch"));
            }
        }
        return Ok(deferred(if state.handoff_phase == "cancelling" {
            "cancellation_pending"
        } else {
            "container_secret_pending"
        }));
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
                        s.cleanup.requested = true;
                        write_state(path, s)?;
                        let outcome = s.terminal.clone().expect("terminal set");
                        finish_cleanup(config, path, s, &outcome)
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
    path: &StatePath<'_>,
    name: &str,
    placement: &str,
    expected: Option<&str>,
) -> Result<Value, &'static str> {
    if expected.is_some_and(|v| !container_id(v)) {
        return Err("invalid_request");
    }
    let mut state = read_state(path, placement, name)?;
    let Some(ref mut s) = state else {
        return Ok(deferred("state_missing"));
    };
    if s.container_id.is_empty() || !container_id(&s.container_id) {
        return Ok(deferred("container_identity_ambiguous"));
    }
    if expected.is_some_and(|id| id != s.container_id) {
        return Ok(deferred("runtime_identity_mismatch"));
    }
    let observed = find_container(config, placement, name, Some(s))?;
    if let Some(ref o) = observed
        && o.id != s.container_id
    {
        return Ok(deferred("runtime_identity_mismatch"));
    }
    if s.terminal.is_none() {
        s.terminal = Some("cancelled".into());
    }
    s.handoff_phase = "cancelling".into();
    s.cleanup.requested = true;
    write_state(path, s)?;
    let outcome = s.terminal.clone().expect("terminal set");
    finish_cleanup(config, path, s, &outcome)
}

fn finish_cleanup(
    config: &Config,
    path: &StatePath<'_>,
    state: &mut State,
    outcome: &str,
) -> Result<Value, &'static str> {
    if !state.cleanup.requested
        || state.container_id.is_empty()
        || !container_id(&state.container_id)
    {
        return Ok(deferred("container_identity_ambiguous"));
    }
    if !state.cleanup.container_removed {
        if !container_present(config, &state.container_id)? {
            state.cleanup.container_removed = true;
            write_state(path, state)?;
        } else if !owned_container_id(config, state)? {
            return Ok(deferred("container_identity_ambiguous"));
        }
    }
    if !state.cleanup.container_removed {
        let _ = docker_status(
            config,
            &[
                "stop".into(),
                "--time".into(),
                "15".into(),
                state.container_id.clone(),
            ],
            None,
        );
        if !container_present(config, &state.container_id)? {
            state.cleanup.container_removed = true;
            write_state(path, state)?;
        } else {
            if !owned_container_id(config, state)? {
                return Ok(deferred("container_identity_ambiguous"));
            }
            let _ = docker_status(
                config,
                &["rm".into(), "-f".into(), state.container_id.clone()],
                None,
            );
            if !container_present(config, &state.container_id)? {
                state.cleanup.container_removed = true;
                write_state(path, state)?;
            }
        }
    }
    if state.cleanup.container_removed {
        let bootstrap_result = attempt_volume_cleanup(config, path, state, true);
        let work_result = attempt_volume_cleanup(config, path, state, false);
        bootstrap_result?;
        work_result?;
    }
    if state.cleanup.container_removed
        && state.cleanup.bootstrap_removed
        && state.cleanup.work_removed
    {
        state.handoff_phase = "complete".into();
        write_state(path, state)?;
        Ok(terminal(outcome))
    } else {
        Ok(deferred("container_remove_failed"))
    }
}

fn owned_container_id(config: &Config, state: &State) -> Result<bool, &'static str> {
    let id = &state.container_id;
    if inspect_field(config, "{{.Id}}", id)? != *id
        || inspect_field(config, "{{.Name}}", id)?.trim_start_matches('/') != state.container_name
        || !owned_volume(config, state, &state.work_volume_name, "work")?
        || !owned_volume(config, state, &state.bootstrap_volume_name, "bootstrap")?
        || !container_contract(config, id, state)?
    {
        return Ok(false);
    }
    for (key, expected) in [
        ("managed", "true".to_string()),
        ("backend", "distributed".to_string()),
        ("placement-id", state.placement_id.clone()),
        ("command-id", state.command_id.clone()),
        ("pool", state.pool_id.clone()),
        ("runner-name", state.runner_name.clone()),
        ("cpu-millis", state.cpu_millis.to_string()),
        ("memory-bytes", state.memory_bytes.to_string()),
        ("ownership-nonce", state.ownership_nonce.clone()),
        ("work-volume-name", state.work_volume_name.clone()),
        ("bootstrap-volume-name", state.bootstrap_volume_name.clone()),
    ] {
        if inspect_field(
            config,
            &format!("{{{{ index .Config.Labels \"{LABEL}.{key}\" }}}}"),
            id,
        )? != expected
        {
            return Ok(false);
        }
    }
    Ok(true)
}

fn volume_labels(state: &State, purpose: &str) -> Vec<String> {
    vec![
        format!("{LABEL}.managed=true"),
        format!("{LABEL}.backend=distributed"),
        format!("{LABEL}.placement-id={}", state.placement_id),
        format!("{LABEL}.command-id={}", state.command_id),
        format!("{LABEL}.pool={}", state.pool_id),
        format!("{LABEL}.runner-name={}", state.runner_name),
        format!("{LABEL}.container-name={}", state.container_name),
        format!("{LABEL}.ownership-nonce={}", state.ownership_nonce),
        format!("{LABEL}.image={}", state.image),
        format!("{LABEL}.cpu-millis={}", state.cpu_millis),
        format!("{LABEL}.memory-bytes={}", state.memory_bytes),
        format!("{LABEL}.purpose={purpose}"),
    ]
}

fn owned_volume(
    config: &Config,
    state: &State,
    name: &str,
    purpose: &str,
) -> Result<bool, &'static str> {
    for label in volume_labels(state, purpose) {
        let (key, expected) = label
            .rsplit_once('=')
            .ok_or("container_identity_ambiguous")?;
        let key = key
            .rsplit_once('.')
            .map(|(_, key)| key)
            .ok_or("container_identity_ambiguous")?;
        if inspect_volume_label(config, name, key)? != expected {
            return Ok(false);
        }
    }
    let options = inspect_volume_field(config, name, "{{json .Options}}")?;
    Ok(
        inspect_volume_field(config, name, "{{.Driver}}")? == "local"
            && matches!(options.as_str(), "null" | "{}"),
    )
}

fn inspect_volume_label(config: &Config, name: &str, key: &str) -> Result<String, &'static str> {
    inspect_volume_field(
        config,
        name,
        &format!("{{{{ index .Labels \"{LABEL}.{key}\" }}}}"),
    )
}

fn inspect_volume_field(config: &Config, name: &str, format: &str) -> Result<String, &'static str> {
    docker_output(config, &["volume", "inspect", "--format", format, name])
}

fn container_present(config: &Config, id: &str) -> Result<bool, &'static str> {
    let output = docker_output(
        config,
        &["ps", "-aq", "--no-trunc", "--filter", &format!("id={id}")],
    )?;
    if output.is_empty() {
        Ok(false)
    } else if output.lines().all(|found| found == id) {
        Ok(true)
    } else {
        Err("container_identity_ambiguous")
    }
}

fn volume_present(config: &Config, name: &str) -> Result<bool, &'static str> {
    let output = docker_output(
        config,
        &["volume", "ls", "-q", "--filter", &format!("name=^{name}$")],
    )?;
    if output.is_empty() {
        Ok(false)
    } else if output.lines().all(|found| found == name) {
        Ok(true)
    } else {
        Err("container_identity_ambiguous")
    }
}

fn attempt_volume_cleanup(
    config: &Config,
    path: &StatePath<'_>,
    state: &mut State,
    bootstrap: bool,
) -> Result<(), &'static str> {
    let (name, purpose, removed) = if bootstrap {
        (
            &state.bootstrap_volume_name,
            "bootstrap",
            state.cleanup.bootstrap_removed,
        )
    } else {
        (&state.work_volume_name, "work", state.cleanup.work_removed)
    };
    if removed {
        return Ok(());
    }
    if volume_present(config, name)? {
        if !owned_volume(config, state, name, purpose)? {
            return Ok(());
        }
        let _ = docker_status(config, &["volume".into(), "rm".into(), name.clone()], None);
    }
    if !volume_present(config, name)? {
        if bootstrap {
            state.cleanup.bootstrap_removed = true;
        } else {
            state.cleanup.work_removed = true;
        }
        write_state(path, state)?;
    }
    Ok(())
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
        if !owned_volume(config, state, &state.work_volume_name, "work")?
            || !owned_volume(config, state, &state.bootstrap_volume_name, "bootstrap")?
            || !container_contract(config, &observed_id, state)?
        {
            return Err("container_identity_ambiguous");
        }
        for (key, expected) in [
            ("backend", "distributed".to_string()),
            ("command-id", state.command_id.clone()),
            ("pool", state.pool_id.clone()),
            ("runner-name", state.runner_name.clone()),
            ("cpu-millis", state.cpu_millis.to_string()),
            ("memory-bytes", state.memory_bytes.to_string()),
            ("ownership-nonce", state.ownership_nonce.clone()),
            ("work-volume-name", state.work_volume_name.clone()),
            ("bootstrap-volume-name", state.bootstrap_volume_name.clone()),
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

fn container_contract(config: &Config, id: &str, state: &State) -> Result<bool, &'static str> {
    if inspect_field(config, "{{.Config.Image}}", id)? != state.image
        || inspect_field(config, "{{json .Config.Entrypoint}}", id)?
            != "[\"/opt/crf-bootstrap/crf-container-adapter\"]"
        || inspect_field(config, "{{json .Config.Cmd}}", id)? != "[\"runner-entrypoint\"]"
    {
        return Ok(false);
    }
    let mounts: Vec<Value> = serde_json::from_str(&inspect_field(config, "{{json .Mounts}}", id)?)
        .map_err(|_| "container_identity_ambiguous")?;
    if mounts.len() != 2 {
        return Ok(false);
    }
    Ok([
        (&state.work_volume_name, "/actions-runner/_work", true),
        (&state.bootstrap_volume_name, "/opt/crf-bootstrap", false),
    ]
    .into_iter()
    .all(|(name, destination, rw)| {
        mounts.iter().any(|mount| {
            mount.get("Type").and_then(Value::as_str) == Some("volume")
                && mount.get("Name").and_then(Value::as_str) == Some(name)
                && mount.get("Destination").and_then(Value::as_str) == Some(destination)
                && mount.get("RW").and_then(Value::as_bool) == Some(rw)
        })
    }))
}

fn inspect_field(config: &Config, format: &str, id: &str) -> Result<String, &'static str> {
    docker_output(config, &["inspect", "--format", format, id])
}
fn docker_output(config: &Config, args: &[&str]) -> Result<String, &'static str> {
    let out = config
        .docker
        .command()?
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
fn docker_output_owned(config: &Config, args: &[String]) -> Result<String, &'static str> {
    let refs: Vec<_> = args.iter().map(String::as_str).collect();
    docker_output(config, &refs)
}
fn docker_status(config: &Config, args: &[String], input: Option<&[u8]>) -> bool {
    let mut command = match config.docker.command() {
        Ok(command) => command,
        Err(_) => return false,
    };
    let mut child = match command
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

fn read_state(
    path: &StatePath<'_>,
    placement: &str,
    name: &str,
) -> Result<Option<State>, &'static str> {
    let file = match openat_file(
        &path.store.root,
        &path.name,
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        0,
    ) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("state_corrupt"),
    };
    let meta = file.metadata().map_err(|_| "state_corrupt")?;
    if !meta.is_file()
        || meta.file_type().is_symlink()
        || meta.permissions().mode() & 0o777 != 0o600
    {
        return Err("state_corrupt");
    }
    let mut bytes = Vec::new();
    file.take((MAX_FRAME + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "state_corrupt")?;
    if bytes.len() > MAX_FRAME {
        return Err("state_corrupt");
    }
    let state: State = serde_json::from_slice(&bytes).map_err(|_| "state_corrupt")?;
    if state.schema_version != 1
        || state.placement_id != placement
        || state.container_name != name
        || state.ownership_nonce.len() != 32
        || !state
            .ownership_nonce
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || state.work_volume_name != format!("crf-dist-work-{}", state.ownership_nonce)
        || state.bootstrap_volume_name != format!("crf-dist-bootstrap-{}", state.ownership_nonce)
        || !immutable_image(&state.image)
        || !identifier(&state.command_id)
        || !identifier(&state.pool_id)
        || !identifier(&state.runner_name)
        || (!state.container_id.is_empty() && !container_id(&state.container_id))
        || !matches!(
            state.handoff_phase.as_str(),
            "pending_container_setup"
                | "pending_start"
                | "pending_ready"
                | "pending_secret"
                | "pending_consumed"
                | "complete"
                | "cancelling"
        )
        || state
            .terminal
            .as_deref()
            .is_some_and(|value| !matches!(value, "finished" | "cancelled" | "failed"))
        || (!state.cleanup.requested
            && (state.cleanup.container_removed
                || state.cleanup.bootstrap_removed
                || state.cleanup.work_removed))
        || ((state.cleanup.bootstrap_removed || state.cleanup.work_removed)
            && !state.cleanup.container_removed)
    {
        return Err("state_corrupt");
    }
    Ok(Some(state))
}
fn write_state(path: &StatePath<'_>, state: &State) -> Result<(), &'static str> {
    let tmp = format!("{}.tmp-{}", path.name, std::process::id());
    let mut file = openat_file(
        &path.store.root,
        &tmp,
        libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        0o600,
    )
    .map_err(|_| "state_write_failed")?;
    serde_json::to_writer(&mut file, state).map_err(|_| "state_write_failed")?;
    file.sync_all().map_err(|_| "state_write_failed")?;
    if renameat_file(&path.store.root, &tmp, &path.name).is_err() {
        let _ = unlinkat_file(&path.store.root, &tmp);
        return Err("state_write_failed");
    }
    path.store
        .root
        .sync_all()
        .map_err(|_| "state_write_failed")?;
    Ok(())
}
fn acquire_lock(store: &StateStore, name: &str) -> Option<Lock> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let file = openat_file(
        &store.locks,
        name,
        libc::O_RDWR | libc::O_CREAT | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        0o600,
    )
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

impl StateStore {
    fn open(path: &Path) -> Result<Self, &'static str> {
        if !path.is_absolute() {
            return Err("invalid_storage_root");
        }
        let mut root = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open("/")
            .map_err(|_| "state_unavailable")?;
        let mut component_count = 0usize;
        for component in path.components() {
            match component {
                std::path::Component::RootDir => {}
                std::path::Component::Normal(name) => {
                    root = open_or_create_directory(&root, name)?;
                    component_count += 1;
                }
                _ => return Err("invalid_storage_root"),
            }
        }
        if component_count == 0 {
            return Err("invalid_storage_root");
        }
        if !root.metadata().is_ok_and(|metadata| metadata.is_dir()) {
            return Err("invalid_storage_root");
        }
        root.set_permissions(fs::Permissions::from_mode(0o700))
            .map_err(|_| "state_unavailable")?;
        let locks_name = std::ffi::CString::new("locks").expect("static name");
        if unsafe { libc::mkdirat(root.as_raw_fd(), locks_name.as_ptr(), 0o700) } != 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::EEXIST) {
                return Err("state_unavailable");
            }
        }
        let locks = openat_file(
            &root,
            "locks",
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0,
        )
        .map_err(|_| "state_unavailable")?;
        locks
            .set_permissions(fs::Permissions::from_mode(0o700))
            .map_err(|_| "state_unavailable")?;
        root.sync_all().map_err(|_| "state_unavailable")?;
        Ok(Self { root, locks })
    }
}

fn open_or_create_directory(
    parent: &fs::File,
    name: &std::ffi::OsStr,
) -> Result<fs::File, &'static str> {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.contains(&b'/') {
        return Err("invalid_storage_root");
    }
    let name = std::ffi::CString::new(bytes).map_err(|_| "invalid_storage_root")?;
    let open = || {
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(unsafe { fs::File::from_raw_fd(fd) })
        }
    };
    match open() {
        Ok(directory) => Ok(directory),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
                let mkdir_error = io::Error::last_os_error();
                if mkdir_error.raw_os_error() != Some(libc::EEXIST) {
                    return Err("state_unavailable");
                }
            }
            open().map_err(|_| "state_unavailable")
        }
        Err(_) => Err("invalid_storage_root"),
    }
}

fn relative_name(name: &str) -> io::Result<std::ffi::CString> {
    if name.is_empty() || name == "." || name == ".." || name.as_bytes().contains(&b'/') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid relative name",
        ));
    }
    std::ffi::CString::new(name)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid relative name"))
}

fn openat_file(dir: &fs::File, name: &str, flags: i32, mode: libc::mode_t) -> io::Result<fs::File> {
    let name = relative_name(name)?;
    let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags, mode as libc::c_uint) };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { fs::File::from_raw_fd(fd) })
    }
}

fn renameat_file(dir: &fs::File, from: &str, to: &str) -> io::Result<()> {
    let from = relative_name(from)?;
    let to = relative_name(to)?;
    if unsafe { libc::renameat(dir.as_raw_fd(), from.as_ptr(), dir.as_raw_fd(), to.as_ptr()) } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn unlinkat_file(dir: &fs::File, name: &str) -> io::Result<()> {
    let name = relative_name(name)?;
    if unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
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
fn run_runner_entrypoint() -> Result<(), &'static str> {
    let run_as_root = match env::var("RUN_AS_ROOT").as_deref() {
        Ok("true") => true,
        Ok("false") | Err(_) => false,
        _ => return Err("run_as_root"),
    };
    ensure_docker_ready()?;
    let secret_dir = safe_existing_or_created_dir("CRF_SECRET_DIR", "/run/crf")?;
    fs::create_dir_all(&secret_dir).map_err(|_| "secret_dir")?;
    fs::set_permissions(&secret_dir, fs::Permissions::from_mode(0o700))
        .map_err(|_| "secret_dir")?;
    let secret = secret_dir.join("secret.in");
    let ready = secret_dir.join("ready");
    let consumed = secret_dir.join("consumed");
    for path in [&secret, &ready, &consumed] {
        let _ = fs::remove_file(path);
    }
    let c_path =
        std::ffi::CString::new(secret.as_os_str().as_bytes()).map_err(|_| "secret_fifo")?;
    if unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) } != 0 {
        return Err("secret_fifo");
    }
    write_marker(&ready)?;
    let mut encoded = Vec::new();
    let read_result = fs::File::open(&secret)
        .map_err(|_| "secret_fifo")?
        .take((MAX_JIT + 2) as u64)
        .read_to_end(&mut encoded);
    let remove_result = fs::remove_file(&secret);
    read_result.map_err(|_| "secret_fifo")?;
    remove_result.map_err(|_| "secret_fifo")?;
    while encoded
        .last()
        .is_some_and(|byte| matches!(byte, b'\n' | b'\r'))
    {
        encoded.pop();
    }
    if encoded.is_empty() || encoded.len() > MAX_JIT {
        encoded.fill(0);
        return Err("jit_size");
    }
    let decoded = decode_jit_files(&encoded);
    encoded.fill(0);
    let mut files = decoded?;
    let config_dir = safe_existing_dir(
        "CRF_JIT_CONFIG_DIR",
        &env::current_dir().map_err(|_| "jit_dir")?,
    )?;
    if !run_as_root
        && (!command_succeeds("id", &["-u", "runner"]) || find_program("gosu").is_none())
    {
        return Err("runner_account");
    }
    materialize_jit_files(&config_dir, &mut files, run_as_root)?;
    if !run_as_root {
        let work = PathBuf::from(env::var("RUNNER_WORKDIR").unwrap_or_else(|_| "/_work".into()));
        if !safe_directory(&work)
            || !command_succeeds("chown", &["runner:runner", work.to_str().ok_or("workdir")?])
        {
            rollback_jit_files(&config_dir);
            return Err("workdir");
        }
    }
    if publish_marker(&consumed, &secret_dir).is_err() {
        rollback_jit_files(&config_dir);
        let _ = sync_directory(&config_dir);
        return Err("private_write");
    }
    let runner = env::var("CRF_JIT_RUNNER").unwrap_or_else(|_| "./run.sh".into());
    if run_as_root {
        let error = Command::new(&runner)
            .current_dir(&config_dir)
            .env("RUNNER_ALLOW_RUNASROOT", "1")
            .exec();
        return Err(if error.kind() == io::ErrorKind::NotFound {
            "runner_missing"
        } else {
            "runner_exec"
        });
    }
    let error = Command::new("gosu")
        .current_dir(&config_dir)
        .args([
            "runner",
            "env",
            "HOME=/home/runner",
            "USER=runner",
            "LOGNAME=runner",
            &runner,
        ])
        .exec();
    Err(if error.kind() == io::ErrorKind::NotFound {
        "gosu"
    } else {
        "runner_exec"
    })
}

fn safe_existing_or_created_dir(key: &str, default: &str) -> Result<PathBuf, &'static str> {
    let path = PathBuf::from(env::var(key).unwrap_or_else(|_| default.into()));
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
        || !no_symlink_components(&path)
    {
        return Err("secret_dir");
    }
    fs::create_dir_all(&path).map_err(|_| "secret_dir")?;
    safe_directory(&path).then_some(path).ok_or("secret_dir")
}

fn safe_existing_dir(key: &str, default: &Path) -> Result<PathBuf, &'static str> {
    let path = env::var_os(key)
        .map(PathBuf::from)
        .unwrap_or_else(|| default.to_path_buf());
    if safe_directory(&path) && no_symlink_components(&path) {
        Ok(path)
    } else {
        Err("jit_dir")
    }
}

fn safe_directory(path: &Path) -> bool {
    path.is_absolute()
        && path
            .symlink_metadata()
            .is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
}

fn materialize_jit_files(
    dir: &Path,
    files: &mut [(&'static str, Vec<u8>)],
    run_as_root: bool,
) -> Result<(), &'static str> {
    rollback_jit_files(dir);
    let mut temps = Vec::new();
    for (index, (_, contents)) in files.iter_mut().enumerate() {
        let temp = dir.join(format!(".crf-jit-{}-{index}", std::process::id()));
        if write_private(&temp, contents).is_err() {
            temps.iter().for_each(|p: &PathBuf| {
                let _ = fs::remove_file(p);
            });
            contents.fill(0);
            return Err("private_write");
        }
        contents.fill(0);
        if !run_as_root
            && !command_succeeds("chown", &["runner:runner", temp.to_str().ok_or("jit_dir")?])
        {
            temps.push(temp);
            temps.iter().for_each(|p| {
                let _ = fs::remove_file(p);
            });
            return Err("chown");
        }
        temps.push(temp);
    }
    for ((name, _), temp) in files.iter().zip(&temps) {
        if fs::rename(temp, dir.join(name)).is_err() {
            temps.iter().for_each(|p| {
                let _ = fs::remove_file(p);
            });
            rollback_jit_files(dir);
            return Err("private_write");
        }
        let final_path = dir.join(name);
        if OpenOptions::new()
            .read(true)
            .open(&final_path)
            .and_then(|file| file.sync_all())
            .is_err()
            || env::var("CRF_TEST_JIT_FAIL_AFTER_RENAME").as_deref() == Ok(*name)
        {
            temps.iter().for_each(|path| {
                let _ = fs::remove_file(path);
            });
            rollback_jit_files(dir);
            let _ = sync_directory(dir);
            return Err("private_write");
        }
    }
    if sync_directory(dir).is_err() {
        rollback_jit_files(dir);
        let _ = sync_directory(dir);
        return Err("private_write");
    }
    Ok(())
}

fn rollback_jit_files(dir: &Path) {
    for name in [".runner", ".credentials", ".credentials_rsaparams"] {
        let _ = fs::remove_file(dir.join(name));
    }
}

fn sync_directory(path: &Path) -> Result<(), &'static str> {
    OpenOptions::new()
        .read(true)
        .open(path)
        .and_then(|dir| dir.sync_all())
        .map_err(|_| "private_write")
}

fn command_succeeds(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .status()
        .is_ok_and(|s| s.success())
}

fn docker_is_ready() -> bool {
    Command::new("docker")
        .arg("info")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn ensure_docker_ready() -> Result<(), &'static str> {
    if env::var("START_DOCKER_SERVICE").as_deref() != Ok("true") {
        return Ok(());
    }
    if !docker_is_ready() {
        docker_service_start();
    }
    for _ in 0..90 {
        if docker_is_ready() {
            if env::var("CRF_DOCKER_SUPERVISE").as_deref() != Ok("false") {
                Command::new(env::current_exe().map_err(|_| "docker_supervise")?)
                    .arg("docker-supervise")
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .map_err(|_| "docker_supervise")?;
            }
            return Ok(());
        }
        thread::sleep(Duration::from_secs(1));
    }
    Err("docker_ready")
}

fn docker_service_start() {
    let pid = env::var("CRF_DOCKER_PID_FILE").unwrap_or_else(|_| "/var/run/docker.pid".into());
    let _ = fs::remove_file(pid);
    let log = env::var("CRF_DOCKER_LOG").unwrap_or_else(|_| "/var/log/dockerd.log".into());
    if let Ok(stdout) = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(log)
        && let Ok(stderr) = stdout.try_clone()
    {
        let _ = Command::new("service")
            .args(["docker", "start"])
            .stdout(stdout)
            .stderr(stderr)
            .status();
    }
}

fn docker_supervise() {
    loop {
        thread::sleep(Duration::from_secs(3));
        if !docker_is_ready() {
            docker_service_start();
        }
    }
}

fn decode_jit_files(encoded: &[u8]) -> Result<Vec<(&'static str, Vec<u8>)>, &'static str> {
    let mut decoded = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| "jit_base64")?;
    let result = decode_jit_manifest(&decoded);
    decoded.fill(0);
    result
}

fn decode_jit_manifest(decoded: &[u8]) -> Result<Vec<(&'static str, Vec<u8>)>, &'static str> {
    let manifest: serde_json::Map<String, Value> =
        serde_json::from_slice(decoded).map_err(|_| "jit_manifest")?;
    const NAMES: [&str; 3] = [".runner", ".credentials", ".credentials_rsaparams"];
    if manifest.len() != NAMES.len() || !NAMES.iter().all(|key| manifest.contains_key(*key)) {
        return Err("jit_manifest");
    }
    NAMES
        .into_iter()
        .map(|name| {
            let value = manifest
                .get(name)
                .and_then(Value::as_str)
                .ok_or("jit_manifest")?;
            let contents = base64::engine::general_purpose::STANDARD
                .decode(value)
                .map_err(|_| "jit_file")?;
            if contents.is_empty() || contents.len() > MAX_JIT {
                return Err("jit_file");
            }
            Ok((name, contents))
        })
        .collect()
}

fn write_marker(path: &Path) -> Result<(), &'static str> {
    write_private(path, b"")
}
fn publish_marker(path: &Path, dir: &Path) -> Result<(), &'static str> {
    write_marker(path)?;
    if sync_directory(dir).is_err() {
        let _ = fs::remove_file(path);
        let _ = sync_directory(dir);
        return Err("private_write");
    }
    Ok(())
}
fn write_private(path: &Path, contents: &[u8]) -> Result<(), &'static str> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|_| "private_write")?;
    file.write_all(contents)
        .and_then(|_| file.sync_all())
        .map_err(|_| "private_write")
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

fn env_flag(name: &str) -> Result<bool, &'static str> {
    match env::var(name).as_deref() {
        Err(env::VarError::NotPresent) | Ok("false") => Ok(false),
        Ok("true") => Ok(true),
        _ => Err("invalid_runtime_configuration"),
    }
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
        | "container_start_uncertain"
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
    fn image_contract_probe_uses_exact_bounded_memory_contract() {
        let args = image_contract_run_args("registry/image@sha256:digest");

        assert!(
            args.windows(2)
                .any(|pair| pair == ["--memory=128m", "--memory-swap=128m"])
        );
        assert!(!args.iter().any(|arg| *arg == "--memory=64m"));
    }

    #[test]
    fn otp_capability_requires_exact_immutable_digest_and_true_contract_label() {
        let image = format!("registry/image@sha256:{}", "a".repeat(64));
        assert_eq!(
            validated_image_capabilities(
                &image,
                std::slice::from_ref(&image),
                "amd64",
                r#"{"schema_version":1,"compatible":true,"os":{"id":"ubuntu","version_id":"24.04"},"image_os":"ubuntu24","glibc":"2.39","arch":"x64","capabilities":["github-actions","container","otp-28-compatible"]}"#,
            ),
            Ok(vec![OTP_28_CAPABILITY])
        );
        assert_eq!(
            validated_image_capabilities(
                &image,
                &[],
                "amd64",
                r#"{"schema_version":1,"compatible":true,"os":{"id":"ubuntu","version_id":"24.04"},"image_os":"ubuntu24","glibc":"2.39","arch":"x64","capabilities":["otp-28-compatible"]}"#
            ),
            Err("image_contract_unavailable")
        );
        assert_eq!(
            validated_image_capabilities(
                &image,
                std::slice::from_ref(&image),
                "amd64",
                r#"{"schema_version":1,"compatible":false,"os":{"id":"ubuntu","version_id":"24.04"},"image_os":"ubuntu24","glibc":"2.39","arch":"x64","capabilities":["otp-28-compatible"]}"#
            ),
            Err("image_contract_unavailable")
        );
    }
    #[test]
    fn unknown_request_fields_are_rejected() {
        let input=br#"{"schema_version":1,"payload":{"action":"inspect","placement_id":"p","expected_id":null,"extra":true}}"#;
        assert!(serde_json::from_slice::<Envelope>(input).is_err());
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

    #[test]
    fn state_store_remains_anchored_after_root_replacement() {
        let base = env::temp_dir().join(format!(
            "crf-state-anchor-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let root = base.join("state");
        let anchored = base.join("anchored");
        fs::create_dir_all(&root).unwrap();
        let store = StateStore::open(&root).unwrap();

        fs::rename(&root, &anchored).unwrap();
        fs::create_dir(&root).unwrap();
        let mut file = openat_file(
            &store.root,
            "proof",
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW,
            0o600,
        )
        .unwrap();
        file.write_all(b"anchored").unwrap();
        file.sync_all().unwrap();
        store.root.sync_all().unwrap();

        assert_eq!(fs::read(anchored.join("proof")).unwrap(), b"anchored");
        assert!(!root.join("proof").exists());
        assert!(acquire_lock(&store, "proof.lock").is_some());
        assert!(anchored.join("locks/proof.lock").exists());
        assert!(!root.join("locks/proof.lock").exists());
        std::os::unix::fs::symlink(root.join("attacker"), anchored.join("trap")).unwrap();
        assert!(openat_file(&store.root, "trap", libc::O_RDONLY | libc::O_NOFOLLOW, 0).is_err());

        drop(store);
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn state_store_acquisition_rejects_symlinks_and_creates_beneath_open_parent() {
        let base = env::temp_dir().join(format!(
            "crf-state-acquire-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(base.join("attacker")).unwrap();
        std::os::unix::fs::symlink(base.join("attacker"), base.join("linked")).unwrap();
        assert!(StateStore::open(&base.join("linked/state")).is_err());
        assert!(!base.join("attacker/state").exists());

        let control = StateStore::open(&base.join("control/nested")).unwrap();
        assert!(base.join("control/nested/locks").is_dir());
        drop(control);

        fs::create_dir(base.join("parent")).unwrap();
        let base_fd = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(&base)
            .unwrap();
        let parent_fd = open_or_create_directory(&base_fd, std::ffi::OsStr::new("parent")).unwrap();
        fs::rename(base.join("parent"), base.join("anchored-parent")).unwrap();
        fs::create_dir(base.join("parent")).unwrap();
        let child = open_or_create_directory(&parent_fd, std::ffi::OsStr::new("state")).unwrap();
        drop(child);
        assert!(base.join("anchored-parent/state").is_dir());
        assert!(!base.join("parent/state").exists());

        drop(parent_fd);
        drop(base_fd);
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn jit_manifest_is_exact_and_bounded() {
        let encode = |value: Value| {
            base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&value).unwrap())
        };
        let file = |value: &[u8]| base64::engine::general_purpose::STANDARD.encode(value);
        let valid = encode(json!({
            ".runner": file(b"runner"),
            ".credentials": file(b"credentials"),
            ".credentials_rsaparams": file(b"rsa")
        }));
        let files = decode_jit_files(valid.as_bytes()).expect("valid manifest");
        assert_eq!(files[0], (".runner", b"runner".to_vec()));

        let extra = encode(json!({
            ".runner": file(b"runner"),
            ".credentials": file(b"credentials"),
            ".credentials_rsaparams": file(b"rsa"),
            "unexpected": file(b"secret")
        }));
        assert_eq!(decode_jit_files(extra.as_bytes()), Err("jit_manifest"));

        let oversized = encode(json!({
            ".runner": file(&vec![b'x'; MAX_JIT + 1]),
            ".credentials": file(b"credentials"),
            ".credentials_rsaparams": file(b"rsa")
        }));
        assert_eq!(decode_jit_files(oversized.as_bytes()), Err("jit_file"));
    }
}
