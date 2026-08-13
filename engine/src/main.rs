//! houmao 无头引擎二进制入口。
//!
//! 起一个 Unix socket，接受连接，每连接一个线程处理。
//! Socket 路径：第一个命令行参数，或默认 `$TMPDIR/houmao-engine.sock`。

use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::thread;

use houmao_engine::server::{handle_connection, EngineState};

fn main() -> std::io::Result<()> {
    let path = socket_path();
    // 清理上次残留的 socket 文件，否则 bind 会 AddrInUse。
    let _ = std::fs::remove_file(&path);

    let listener = UnixListener::bind(&path)?;
    // 仅当前用户可访问（Unix socket 靠文件权限鉴权）。
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    eprintln!("[engine] listening on {}", path.display());

    let state = EngineState::new();
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = state.clone();
                thread::spawn(move || handle_connection(state, stream));
            }
            Err(e) => eprintln!("[engine] accept error: {e}"),
        }
    }
    Ok(())
}

fn socket_path() -> PathBuf {
    if let Some(arg) = std::env::args().nth(1) {
        return PathBuf::from(arg);
    }
    let dir = std::env::var_os("TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    dir.join("houmao-engine.sock")
}
