fn main() {
    if let Err(error) = crf_node::daemon::run_from_env() {
        eprintln!("crf-node terminated: {error:?}");
        std::process::exit(1);
    }
}
