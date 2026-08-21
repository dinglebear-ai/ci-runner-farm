use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::Path,
};

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

pub fn write_atomic(path: &Path, projection: &serde_json::Value) -> io::Result<()> {
    let parent = path
        .parent()
        .filter(|parent| parent.is_absolute())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "projection path"))?;
    fs::create_dir_all(parent)?;
    if fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "projection target is a symlink",
        ));
    }

    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "projection filename"))?;
    let temporary = parent.join(format!(".{file_name}.{}.tmp", std::process::id()));
    let _ = fs::remove_file(&temporary);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options.open(&temporary)?;
    let bytes = serde_json::to_vec(projection).map_err(io::Error::other)?;
    file.write_all(&bytes)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    drop(file);
    replace(&temporary, path).inspect_err(|_| {
        let _ = fs::remove_file(&temporary);
    })
}

#[cfg(not(windows))]
fn replace(source: &Path, target: &Path) -> io::Result<()> {
    fs::rename(source, target)
}

#[cfg(windows)]
fn replace(source: &Path, target: &Path) -> io::Result<()> {
    use std::{iter, os::windows::ffi::OsStrExt};
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect::<Vec<_>>();
    let target = target
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect::<Vec<_>>();
    // SAFETY: both pointers reference NUL-terminated UTF-16 buffers for this call.
    if unsafe {
        MoveFileExW(
            source.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_valid_projection_atomically() {
        let root = std::env::temp_dir().join(format!("crf-projection-{}", std::process::id()));
        let path = root.join("fleet.json");
        let value = serde_json::json!({"schema_version": 1, "nodes": []});
        write_atomic(&path, &value).expect("projection writes");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&fs::read(&path).expect("read"))
                .expect("json"),
            value
        );
        let _ = fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_target() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!("crf-projection-link-{}", std::process::id()));
        fs::create_dir_all(&root).expect("root");
        let actual = root.join("actual.json");
        fs::write(&actual, "unchanged").expect("actual");
        let link = root.join("fleet.json");
        symlink(&actual, &link).expect("link");
        assert!(write_atomic(&link, &serde_json::json!({"nodes": []})).is_err());
        assert_eq!(fs::read_to_string(actual).expect("actual"), "unchanged");
        let _ = fs::remove_dir_all(root);
    }
}
