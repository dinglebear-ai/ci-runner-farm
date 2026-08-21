fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args == ["--version"] {
        println!("crf-node {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    #[cfg(windows)]
    if args == ["--windows-service"] {
        if let Err(error) = crf_node::windows_service::dispatch() {
            eprintln!("crf-node Windows service terminated: {error}");
            std::process::exit(1);
        }
        return;
    }
    if !args.is_empty() {
        eprintln!("usage: crf-node [--version]");
        std::process::exit(2);
    }

    if let Err(error) = crf_node::daemon::run_from_env() {
        eprintln!("crf-node terminated: {error:?}");
        std::process::exit(1);
    }
}
