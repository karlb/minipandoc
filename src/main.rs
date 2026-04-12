use std::process::ExitCode;

fn main() -> ExitCode {
    match minipandoc::cli::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("minipandoc: {e}");
            ExitCode::FAILURE
        }
    }
}
