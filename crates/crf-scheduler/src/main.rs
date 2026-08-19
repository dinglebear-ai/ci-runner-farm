use std::io::{self, BufReader, BufWriter};

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = BufWriter::new(stdout.lock());
    if let Err(error) = crf_scheduler::service::run_framed(&mut reader, &mut writer) {
        eprintln!("crf-scheduler terminated: {error:?}");
        std::process::exit(1);
    }
}
