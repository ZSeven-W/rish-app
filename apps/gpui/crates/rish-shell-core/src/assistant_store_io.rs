//! Native supplies a trusted canonical app-private root, never a model-chosen
//! path. Descriptor-relative I/O then prevents child symlinks from redirecting
//! assistant data. All writers cooperate through one stable OS lock file.
use super::{AssistantAvatar, AssistantSnapshot, AssistantStoreError as Error, StoreResult};
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Component, Path};
use std::sync::Mutex;

pub(super) const STATE_FILE: &str = "assistant-v1.json";
const LOCK_FILE: &str = ".assistant-v1.lock";
const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;
static PROCESS_LOCK: Mutex<()> = Mutex::new(());

pub(super) struct Storage {
    directory: File,
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::ffi::{CString, OsStr};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
    };

    fn cstring(name: &OsStr) -> StoreResult<CString> {
        CString::new(name.as_bytes()).map_err(|_| Error::UnsafePath)
    }
    fn open_at(directory: &File, name: &OsStr, flags: i32) -> StoreResult<File> {
        let name = cstring(name)?;
        // SAFETY: The C string is terminated; the directory descriptor remains
        // alive for this syscall; a successful descriptor is owned exactly once.
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            return Err(
                if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) {
                    Error::UnsafePath
                } else {
                    error.into()
                },
            );
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    fn regular(file: &File) -> StoreResult<()> {
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.nlink() != 1 {
            return Err(Error::UnsafePath);
        }
        Ok(())
    }

    impl Storage {
        pub(in crate::assistant_store) fn duplicate(&self) -> StoreResult<Self> {
            Ok(Self {
                directory: self.directory.try_clone()?,
            })
        }
        pub(in crate::assistant_store) fn open(path: &Path) -> StoreResult<Self> {
            if !path.is_absolute()
                || path.components().any(|component| {
                    !matches!(component, Component::RootDir | Component::Normal(_))
                })
                || path.canonicalize().map_err(|_| Error::UnsafePath)? != path
            {
                return Err(Error::UnsafePath);
            }
            // Do not open /private, /var, or other ancestor directories: iOS
            // grants the app access to its container, not directory listings
            // of its ancestors. Native already resolves the trusted root.
            let directory = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_DIRECTORY)
                .open(path)
                .map_err(|error| {
                    if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) {
                        Error::UnsafePath
                    } else {
                        error.into()
                    }
                })?;
            Ok(Self { directory })
        }

        pub(in crate::assistant_store) fn locked<T>(
            &self,
            action: impl FnOnce() -> StoreResult<T>,
        ) -> StoreResult<T> {
            let _process_guard = PROCESS_LOCK
                .lock()
                .map_err(|_| Error::Io("Assistant process lock is poisoned".into()))?;
            let file = open_at(
                &self.directory,
                OsStr::new(LOCK_FILE),
                libc::O_RDWR | libc::O_CREAT,
            )?;
            regular(&file)?;
            loop {
                // SAFETY: flock only operates on the owned, live file descriptor.
                if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                    break;
                }
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    return Err(error.into());
                }
            }
            // The lock descriptor closes (and unlocks) on every return path.
            // Reject a lock replaced while waiting instead of using two locks.
            let current = open_at(&self.directory, OsStr::new(LOCK_FILE), libc::O_RDONLY)?;
            let a = current.metadata()?;
            let b = file.metadata()?;
            if a.dev() != b.dev() || a.ino() != b.ino() {
                return Err(Error::UnsafePath);
            }
            action()
        }

        pub(in crate::assistant_store) fn read(&self) -> StoreResult<AssistantSnapshot> {
            let file = match open_at(
                &self.directory,
                OsStr::new(STATE_FILE),
                libc::O_RDONLY | libc::O_NONBLOCK,
            ) {
                Ok(file) => file,
                Err(Error::Io(_)) => {
                    // Preserve the original error unless the pathname is truly
                    // absent. Dangling symlinks are rejected by open_at above.
                    let name = cstring(OsStr::new(STATE_FILE))?;
                    let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
                    let code = unsafe {
                        libc::fstatat(
                            self.directory.as_raw_fd(),
                            name.as_ptr(),
                            status.as_mut_ptr(),
                            libc::AT_SYMLINK_NOFOLLOW,
                        )
                    };
                    if code < 0
                        && std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound
                    {
                        return Ok(AssistantSnapshot::default());
                    }
                    return Err(Error::Io("Cannot read assistant state".into()));
                }
                Err(error) => return Err(error),
            };
            regular(&file)?;
            if file.metadata()?.len() > MAX_FILE_BYTES {
                return Err(Error::Corrupt);
            }
            let mut bytes = Vec::new();
            file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
            if bytes.len() as u64 > MAX_FILE_BYTES {
                return Err(Error::Corrupt);
            }
            let snapshot: AssistantSnapshot =
                serde_json::from_slice(&bytes).map_err(|_| Error::Corrupt)?;
            super::super::validate_snapshot(&snapshot).map_err(|_| Error::Corrupt)?;
            Ok(snapshot)
        }

        pub(in crate::assistant_store) fn read_avatar(
            &self,
            avatar: &AssistantAvatar,
        ) -> StoreResult<Vec<u8>> {
            avatar.validate()?;
            let directory = open_at(
                &self.directory,
                OsStr::new("avatars"),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NONBLOCK,
            )?;
            let name = format!("{}.png", avatar.id);
            let file = open_at(
                &directory,
                OsStr::new(&name),
                libc::O_RDONLY | libc::O_NONBLOCK,
            )?;
            regular(&file)?;
            if file.metadata()?.len() != avatar.byte_length {
                return Err(Error::Corrupt);
            }
            let mut bytes = Vec::new();
            file.take(avatar.byte_length + 1).read_to_end(&mut bytes)?;
            if bytes.len() as u64 != avatar.byte_length
                || rish_agent_core::canonical::sha256_hex(&bytes) != avatar.sha256
                || !png_dimensions_match(&bytes, avatar)
            {
                return Err(Error::Corrupt);
            }
            Ok(bytes)
        }

        pub(in crate::assistant_store) fn write(
            &self,
            snapshot: &AssistantSnapshot,
        ) -> StoreResult<()> {
            let bytes = serde_json::to_vec(snapshot).map_err(|_| Error::Corrupt)?;
            if bytes.len() as u64 > MAX_FILE_BYTES {
                return Err(Error::Invalid("state exceeds size limit"));
            }
            let temporary = format!(".assistant-v1-{}.tmp", uuid::Uuid::new_v4());
            let mut file = open_at(
                &self.directory,
                OsStr::new(&temporary),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            )?;
            let temporary = cstring(OsStr::new(&temporary))?;
            let destination = cstring(OsStr::new(STATE_FILE))?;
            let result = (|| {
                file.write_all(&bytes)?;
                file.sync_all()?;
                // SAFETY: Both names are C strings anchored to the same live
                // directory. Rename is atomic and does not follow destination.
                if unsafe {
                    libc::renameat(
                        self.directory.as_raw_fd(),
                        temporary.as_ptr(),
                        self.directory.as_raw_fd(),
                        destination.as_ptr(),
                    )
                } != 0
                {
                    return Err(std::io::Error::last_os_error().into());
                }
                self.directory.sync_all()?;
                Ok(())
            })();
            if result.is_err() {
                unsafe {
                    libc::unlinkat(self.directory.as_raw_fd(), temporary.as_ptr(), 0);
                }
            }
            result
        }
    }
}

/// This header check bounds decoded dimensions before the UI image decoder
/// sees the bytes. The decoder still validates the remaining PNG structure.
fn png_dimensions_match(bytes: &[u8], avatar: &AssistantAvatar) -> bool {
    bytes.len() >= 33
        && &bytes[..8] == b"\x89PNG\r\n\x1a\n"
        && bytes[8..12] == 13u32.to_be_bytes()
        && &bytes[12..16] == b"IHDR"
        && bytes[16..20] == avatar.width.to_be_bytes()
        && bytes[20..24] == avatar.height.to_be_bytes()
}

#[cfg(not(unix))]
impl Storage {
    pub(in crate::assistant_store) fn duplicate(&self) -> StoreResult<Self> {
        Err(Error::UnsafePath)
    }
    pub(in crate::assistant_store) fn open(_: &Path) -> StoreResult<Self> {
        Err(Error::Io(
            "Assistant storage is currently supported on Unix hosts".into(),
        ))
    }
    pub(in crate::assistant_store) fn locked<T>(
        &self,
        _: impl FnOnce() -> StoreResult<T>,
    ) -> StoreResult<T> {
        Err(Error::UnsafePath)
    }
    pub(in crate::assistant_store) fn read(&self) -> StoreResult<AssistantSnapshot> {
        Err(Error::UnsafePath)
    }
    pub(in crate::assistant_store) fn read_avatar(
        &self,
        _: &AssistantAvatar,
    ) -> StoreResult<Vec<u8>> {
        Err(Error::UnsafePath)
    }
    pub(in crate::assistant_store) fn write(&self, _: &AssistantSnapshot) -> StoreResult<()> {
        Err(Error::UnsafePath)
    }
}
