use std::io::{self, BufReader, BufWriter};

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args == ["--version"] {
        println!("crf-scheduler {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if !args.is_empty() {
        eprintln!("usage: crf-scheduler [--version]");
        std::process::exit(2);
    }

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = BufWriter::new(stdout.lock());
    if let Err(error) = crf_scheduler::service::run_framed(&mut reader, &mut writer) {
        eprintln!("crf-scheduler terminated: {error:?}");
        std::process::exit(1);
    }
}
