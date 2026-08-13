//! Windows-only secure storage primitives shared by account and history stores.
//!
//! Path-taking helpers intentionally permit ancestor reparse points. Their caller
//! must anchor every path beneath the trusted per-user `dirs::data_dir` parent;
//! this module validates only the final component. Path identity guarantees are
//! point-in-time: callers must keep using the returned handle and revalidate
//! before any later pathname operation.

use std::ffi::c_void;
use std::fs::File;
use std::io;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::{Path, PathBuf};
use std::ptr::{self, null, null_mut};
use std::slice;

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_ALREADY_EXISTS, ERROR_INSUFFICIENT_BUFFER,
    ERROR_SUCCESS, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE, NTSTATUS,
};
#[cfg(test)]
use windows_sys::Win32::Security::Authorization::SetSecurityInfo;
use windows_sys::Win32::Security::Authorization::{GetSecurityInfo, SE_FILE_OBJECT};
use windows_sys::Win32::Security::Cryptography::{
    BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
};
#[cfg(test)]
use windows_sys::Win32::Security::PROTECTED_DACL_SECURITY_INFORMATION;
use windows_sys::Win32::Security::{
    AclSizeInformation, AddAccessAllowedAceEx, CopySid, CreateWellKnownSid, GetAce,
    GetAclInformation, GetLengthSid, GetSecurityDescriptorControl, GetSecurityDescriptorDacl,
    GetSecurityDescriptorLength, GetTokenInformation, InitializeAcl, InitializeSecurityDescriptor,
    IsValidAcl, IsValidSecurityDescriptor, IsValidSid, SetSecurityDescriptorControl,
    SetSecurityDescriptorDacl, SetSecurityDescriptorOwner, TokenUser, WinLocalSystemSid,
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, ACL_REVISION, ACL_SIZE_INFORMATION,
    DACL_SECURITY_INFORMATION, NO_INHERITANCE, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
    PSID, SECURITY_ATTRIBUTES, SECURITY_DESCRIPTOR, SE_DACL_PROTECTED, TOKEN_QUERY, TOKEN_USER,
    WELL_KNOWN_SID_TYPE,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateDirectoryW, CreateFileW, FileAttributeTagInfo, FileIdInfo, FlushFileBuffers,
    GetFileInformationByHandleEx, GetFileType, CREATE_NEW, FILE_ALL_ACCESS, FILE_ATTRIBUTE_DEVICE,
    FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_REPARSE_POINT,
    FILE_ATTRIBUTE_TAG_INFO, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_ID_INFO, FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, FILE_TYPE_DISK, OPEN_ALWAYS, OPEN_EXISTING, READ_CONTROL,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

const ACCESS_ALLOWED_ACE_TYPE_VALUE: u8 = 0;
const SID_HEADER_LEN: usize = 8;
const ACE_SID_OFFSET: usize = size_of::<ACE_HEADER>() + size_of::<u32>();
const SECURITY_DESCRIPTOR_REVISION_VALUE: u32 = 1;
const STORAGE_SHARE_MODE: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
const VALIDATION_SHARE_MODE: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE;
const STORAGE_SECURITY_ACCESS: u32 = READ_CONTROL;
const SECURE_STORAGE_FALLBACK_SUFFIX: &str = ".secure";

#[derive(Clone, Copy, Eq, PartialEq)]
struct StorageIdentity {
    volume_serial_number: u64,
    file_id: [u8; 16],
}

#[derive(Clone, Copy)]
enum StorageObjectKind {
    Directory,
    RegularFile,
}

impl StorageObjectKind {
    fn is_directory(self) -> bool {
        matches!(self, Self::Directory)
    }

    fn open_flags(self) -> u32 {
        let type_flag = if self.is_directory() {
            FILE_FLAG_BACKUP_SEMANTICS
        } else {
            FILE_ATTRIBUTE_NORMAL
        };
        type_flag | FILE_FLAG_OPEN_REPARSE_POINT
    }
}

/// Resolve the sticky exact-secure root for new account and v3 history artifacts.
/// An existing fallback wins even if the preferred root later disappears or becomes
/// secure. A colliding fallback must itself pass the exact directory contract;
/// otherwise resolution fails closed before consulting or creating the preferred root.
///
/// The caller must place `preferred` beneath the trusted per-user `dirs::data_dir`
/// parent. The fallback is a sibling formed by appending `.secure` to its filename.
pub(crate) fn resolve_secure_storage_directory(preferred: &Path) -> io::Result<PathBuf> {
    let preferred_name = preferred.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "secure storage root has no filename",
        )
    })?;
    let mut fallback_name = preferred_name.to_os_string();
    fallback_name.push(SECURE_STORAGE_FALLBACK_SUFFIX);
    let fallback = preferred.with_file_name(fallback_name);

    match open_existing_secure_storage_directory(&fallback) {
        Ok(_) => return Ok(fallback),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    // Only a confirmed contract rejection activates fallback. Operational
    // failures stay unavailable rather than permanently splitting an exact root.
    match ensure_secure_storage_directory(preferred) {
        Ok(directory) => drop(directory),
        Err(error) if is_security_verification_failure(&error) => {
            drop(ensure_secure_storage_directory(&fallback)?);
            return Ok(fallback);
        }
        Err(error) => return Err(error),
    }

    // Recheck after preferred creation/verification so a concurrently installed
    // fallback is never ignored. Exact fallback remains the sticky authority.
    match open_existing_secure_storage_directory(&fallback) {
        Ok(_) => Ok(fallback),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(preferred.to_path_buf()),
        Err(error) => Err(error),
    }
}

fn open_existing_secure_storage_directory(path: &Path) -> io::Result<File> {
    open_secure_storage_object(
        path,
        GENERIC_WRITE | FILE_READ_ATTRIBUTES | STORAGE_SECURITY_ACCESS,
        OPEN_EXISTING,
        StorageObjectKind::Directory,
    )
}

/// Create only the final directory component securely when absent, then open and
/// verify that exact directory without following a final-component reparse point.
///
/// The caller must place `path` beneath the trusted per-user `dirs::data_dir`
/// parent. Ancestor reparse points are allowed and are not ACL-validated here.
#[allow(dead_code)] // Stage 2A2 primitive; production callers are wired later.
pub(crate) fn ensure_secure_storage_directory(path: &Path) -> io::Result<File> {
    ensure_secure_storage_directory_with(path, |_| Ok(()))
}

fn ensure_secure_storage_directory_with(
    path: &Path,
    before_verify: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<File> {
    let wide = wide_path(path)?;
    let mut security = CreationSecurity::new()?;
    let attributes = security.attributes();
    if unsafe { CreateDirectoryW(wide.as_ptr(), &attributes) } == 0 {
        let status = unsafe { GetLastError() };
        if status != ERROR_ALREADY_EXISTS {
            return Err(win32_status_error(status));
        }
    }

    open_secure_storage_object_with(
        path,
        GENERIC_WRITE | FILE_READ_ATTRIBUTES | STORAGE_SECURITY_ACCESS,
        OPEN_EXISTING,
        StorageObjectKind::Directory,
        before_verify,
    )
}

/// Create a new secure regular file opened for reading and writing.
/// The caller must anchor `path` beneath the trusted per-user data parent.
#[allow(dead_code)] // Stage 2A2 primitive; production callers are wired later.
pub(crate) fn create_new_secure_file(path: &Path) -> io::Result<File> {
    open_secure_storage_object(
        path,
        GENERIC_READ | GENERIC_WRITE | STORAGE_SECURITY_ACCESS,
        CREATE_NEW,
        StorageObjectKind::RegularFile,
    )
}

/// Open an existing regular file only when it already satisfies the exact
/// owner/DACL contract. This helper never tightens an existing object in place:
/// changing its DACL cannot revoke access already granted to retained handles.
/// The caller must anchor `path` beneath the trusted per-user data parent.
#[allow(dead_code)] // Stage 2A2 primitive; production callers are wired later.
pub(crate) fn open_existing_secure_file(path: &Path, writable: bool) -> io::Result<File> {
    let data_access = if writable {
        GENERIC_READ | GENERIC_WRITE
    } else {
        GENERIC_READ
    };
    open_secure_storage_object(
        path,
        data_access | STORAGE_SECURITY_ACCESS,
        OPEN_EXISTING,
        StorageObjectKind::RegularFile,
    )
}

/// Create a secure regular file when absent, or open it only when the existing
/// object already satisfies the exact owner/DACL contract. Never repairs in place.
/// The caller must anchor `path` beneath the trusted per-user data parent.
#[allow(dead_code)] // Stage 2A2 primitive; production callers are wired later.
pub(crate) fn open_or_create_secure_file(path: &Path) -> io::Result<File> {
    open_secure_storage_object(
        path,
        GENERIC_READ | GENERIC_WRITE | STORAGE_SECURITY_ACCESS,
        OPEN_ALWAYS,
        StorageObjectKind::RegularFile,
    )
}

/// Open or atomically create an exact secure lock file, acquire an exclusive
/// `fs2` lock, then revalidate its owner, DACL, type, and pathname identity.
///
/// The returned `File` keeps both the exclusive lock and a Windows handle that
/// does not share delete access. Callers may explicitly use
/// `fs2::FileExt::unlock` or drop it. The caller must anchor `path` beneath the
/// trusted per-user data parent.
#[allow(dead_code)] // Stage 2A3a primitive; production callers are wired later.
pub(crate) fn open_secure_lock_file(path: &Path) -> io::Result<File> {
    let file = open_windows_path_with_share(
        path,
        GENERIC_READ | GENERIC_WRITE | STORAGE_SECURITY_ACCESS,
        OPEN_ALWAYS,
        StorageObjectKind::RegularFile.open_flags(),
        VALIDATION_SHARE_MODE,
    )?;
    fs2::FileExt::lock_exclusive(&file)?;

    let verification = (|| {
        let handle = file.as_raw_handle() as HANDLE;
        let identity = storage_identity(handle, StorageObjectKind::RegularFile)?;
        verify_storage_handle(handle)?;
        verify_path_identity(path, StorageObjectKind::RegularFile, identity)
    })();
    if let Err(error) = verification {
        let _ = fs2::FileExt::unlock(&file);
        return Err(error);
    }
    Ok(file)
}

/// Atomically replace `destination_path` with `staged_path` after exact secure
/// validation. Both paths must be distinct direct children of `directory_path`,
/// and `directory` must name that exact secure directory.
///
/// The caller must hold the exclusive lock returned by `open_secure_lock_file`
/// for the whole operation. The staged file is flushed before commit. On a
/// replace error this helper leaves staged-file cleanup to the caller. Post-commit
/// verification or directory flush errors are reported honestly; the completed
/// replace cannot be rolled back here.
#[allow(dead_code)] // Stage 2A3a primitive; production callers are wired later.
pub(crate) fn replace_secure_file(
    directory: &File,
    directory_path: &Path,
    staged_path: &Path,
    destination_path: &Path,
) -> io::Result<()> {
    replace_secure_file_with(
        directory,
        directory_path,
        staged_path,
        destination_path,
        |staged, destination| tokscale_core::fs_atomic::replace_file(staged, destination),
    )
}

fn replace_secure_file_with(
    directory: &File,
    directory_path: &Path,
    staged_path: &Path,
    destination_path: &Path,
    replace: impl FnOnce(&Path, &Path) -> io::Result<()>,
) -> io::Result<()> {
    validate_replace_paths(directory_path, staged_path, destination_path)?;

    let directory_handle = directory.as_raw_handle() as HANDLE;
    let directory_identity = storage_identity(directory_handle, StorageObjectKind::Directory)?;
    verify_storage_handle(directory_handle)?;
    verify_path_identity(
        directory_path,
        StorageObjectKind::Directory,
        directory_identity,
    )?;

    let staged_identity = {
        let staged = open_existing_secure_file(staged_path, true)?;
        staged.sync_all()?;
        let identity = storage_identity(
            staged.as_raw_handle() as HANDLE,
            StorageObjectKind::RegularFile,
        )?;
        if identity.volume_serial_number != directory_identity.volume_serial_number {
            return Err(security_verification_failed());
        }
        identity
    };

    let destination_identity = match open_existing_secure_file(destination_path, false) {
        Ok(destination) => {
            let identity = storage_identity(
                destination.as_raw_handle() as HANDLE,
                StorageObjectKind::RegularFile,
            )?;
            if identity.volume_serial_number != directory_identity.volume_serial_number {
                return Err(security_verification_failed());
            }
            Some(identity)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };
    if destination_identity == Some(staged_identity) {
        return Err(security_verification_failed());
    }

    // Every staged/destination validation handle has left scope before the
    // pathname-based vendor helper runs, so it cannot block MoveFileExW.
    replace(staged_path, destination_path)?;

    let installed_identity = {
        let installed = open_existing_secure_file(destination_path, false)?;
        storage_identity(
            installed.as_raw_handle() as HANDLE,
            StorageObjectKind::RegularFile,
        )?
    };
    if installed_identity != staged_identity {
        return Err(security_verification_failed());
    }
    match std::fs::symlink_metadata(staged_path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Ok(_) => return Err(security_verification_failed()),
        Err(error) => return Err(error),
    }

    verify_path_identity(
        directory_path,
        StorageObjectKind::Directory,
        directory_identity,
    )?;
    flush_secure_storage_directory(directory)
}

/// Move one exact secure regular file to one explicit quarantine candidate by
/// creating a hard link and then unlinking the source pathname.
///
/// `source_path` and `candidate_path` must be distinct direct children of
/// `directory_path`. This helper tries exactly one candidate and never chooses a
/// collision suffix. The caller must hold the exclusive lock returned by
/// `open_secure_lock_file` for this entire call and must anchor every path beneath
/// the trusted per-user data parent. These pathname operations coordinate trusted
/// callers; they do not defend against a malicious process running as the same SID.
#[allow(dead_code)] // Stage 2A3b primitive; production callers are wired later.
pub(crate) fn quarantine_secure_file_candidate(
    directory: &File,
    directory_path: &Path,
    source_path: &Path,
    candidate_path: &Path,
) -> io::Result<()> {
    quarantine_secure_file_candidate_with(
        directory,
        directory_path,
        source_path,
        candidate_path,
        |source, candidate| std::fs::hard_link(source, candidate),
        |path| std::fs::remove_file(path),
        |directory| flush_secure_storage_directory(directory),
    )
}

fn quarantine_secure_file_candidate_with(
    directory: &File,
    directory_path: &Path,
    source_path: &Path,
    candidate_path: &Path,
    link: impl FnOnce(&Path, &Path) -> io::Result<()>,
    mut unlink: impl FnMut(&Path) -> io::Result<()>,
    flush: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<()> {
    validate_replace_paths(directory_path, source_path, candidate_path)?;

    let directory_handle = directory.as_raw_handle() as HANDLE;
    let directory_identity = storage_identity(directory_handle, StorageObjectKind::Directory)?;
    verify_storage_handle(directory_handle)?;
    verify_path_identity(
        directory_path,
        StorageObjectKind::Directory,
        directory_identity,
    )?;

    // Keep this handle alive through the complete hard-link/unlink transaction.
    // It shares delete access so the pathname unlink can proceed, while retaining
    // the original file identity for every comparison and rollback decision.
    let source = open_existing_secure_file(source_path, false)?;
    let source_identity = storage_identity(
        source.as_raw_handle() as HANDLE,
        StorageObjectKind::RegularFile,
    )?;
    if source_identity.volume_serial_number != directory_identity.volume_serial_number {
        return Err(security_verification_failed());
    }

    // CreateHardLinkW, reached through std, provides create-new collision
    // semantics. Never pre-delete or overwrite an existing candidate.
    link(source_path, candidate_path)?;

    if let Err(error) = verify_secure_file_path(&source, source_path) {
        rollback_quarantine_candidate(
            &source,
            source_path,
            candidate_path,
            source_identity,
            &mut unlink,
        )?;
        return Err(error);
    }
    let candidate = match open_secure_file_with_identity(candidate_path, source_identity) {
        Ok(candidate) => candidate,
        Err(error) => {
            rollback_quarantine_candidate(
                &source,
                source_path,
                candidate_path,
                source_identity,
                &mut unlink,
            )?;
            return Err(error);
        }
    };
    drop(candidate);

    if let Err(error) = unlink(source_path) {
        rollback_quarantine_candidate(
            &source,
            source_path,
            candidate_path,
            source_identity,
            &mut unlink,
        )?;
        return Err(error);
    }

    // The source unlink has committed. Verification or flush failures from here
    // are reported honestly; removing the surviving candidate would lose data.
    verify_path_absent(source_path)?;
    drop(open_secure_file_with_identity(
        candidate_path,
        source_identity,
    )?);
    verify_path_identity(
        directory_path,
        StorageObjectKind::Directory,
        directory_identity,
    )?;
    flush(directory)
}

fn open_secure_file_with_identity(path: &Path, expected: StorageIdentity) -> io::Result<File> {
    let file = open_existing_secure_file(path, false)?;
    let actual = storage_identity(
        file.as_raw_handle() as HANDLE,
        StorageObjectKind::RegularFile,
    )?;
    if actual == expected {
        Ok(file)
    } else {
        Err(security_verification_failed())
    }
}

fn rollback_quarantine_candidate(
    source: &File,
    source_path: &Path,
    candidate_path: &Path,
    expected: StorageIdentity,
    unlink: &mut impl FnMut(&Path) -> io::Result<()>,
) -> io::Result<()> {
    // Never delete by pathname until the candidate is securely opened and its
    // full volume + 128-bit file identity matches the retained source handle.
    let candidate = open_secure_file_with_identity(candidate_path, expected)?;
    verify_secure_file_path(source, source_path)?;
    drop(candidate);

    unlink(candidate_path)?;
    verify_secure_file_path(source, source_path)?;
    verify_path_absent(candidate_path)
}

fn verify_path_absent(path: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Ok(_) => Err(security_verification_failed()),
        Err(error) => Err(error),
    }
}

fn validate_replace_paths(
    directory_path: &Path,
    staged_path: &Path,
    destination_path: &Path,
) -> io::Result<()> {
    let invalid = || {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid Windows storage replace path",
        )
    };
    if staged_path == destination_path
        || staged_path.file_name().is_none()
        || destination_path.file_name().is_none()
        || staged_path.parent() != Some(directory_path)
        || destination_path.parent() != Some(directory_path)
    {
        return Err(invalid());
    }
    Ok(())
}

/// Verify that a currently open secure regular file names the same non-reparse
/// object at `path` during this call. This function never mutates either object.
/// The guarantee is point-in-time only: keep using `file`, and call this again
/// immediately before any later operation that must act on the pathname.
#[allow(dead_code)] // Stage 2A2 primitive; production callers are wired later.
pub(crate) fn verify_secure_file_path(file: &File, path: &Path) -> io::Result<()> {
    let handle = file.as_raw_handle() as HANDLE;
    let identity = storage_identity(handle, StorageObjectKind::RegularFile)?;
    verify_storage_handle(handle)?;
    verify_path_identity(path, StorageObjectKind::RegularFile, identity)
}

/// Durably flush a verified secure storage directory handle.
#[allow(dead_code)] // Stage 2A2 primitive; production callers are wired later.
pub(crate) fn flush_secure_storage_directory(directory: &File) -> io::Result<()> {
    flush_storage_directory_handle(directory.as_raw_handle() as HANDLE)
}

fn open_secure_storage_object(
    path: &Path,
    access: u32,
    disposition: u32,
    kind: StorageObjectKind,
) -> io::Result<File> {
    open_secure_storage_object_with(path, access, disposition, kind, |_| Ok(()))
}

fn open_secure_storage_object_with(
    path: &Path,
    access: u32,
    disposition: u32,
    kind: StorageObjectKind,
    before_verify: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<File> {
    let file = open_windows_path(path, access, disposition, kind.open_flags())?;
    let identity = storage_identity(file.as_raw_handle() as HANDLE, kind)?;
    before_verify(&file)?;

    // Existing objects are accepted only when they already satisfy the exact
    // contract. Never repair a permissive DACL in place: an access check that
    // granted another process a handle remains effective after the DACL changes.
    verify_storage_handle(file.as_raw_handle() as HANDLE)?;
    verify_path_identity(path, kind, identity)?;
    Ok(file)
}

fn verify_path_identity(
    path: &Path,
    kind: StorageObjectKind,
    expected: StorageIdentity,
) -> io::Result<()> {
    verify_path_identity_with(path, kind, expected, |_| Ok(()))
}

fn verify_path_identity_with(
    path: &Path,
    kind: StorageObjectKind,
    expected: StorageIdentity,
    while_validation_open: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<()> {
    // FILE_READ_DATA (FILE_LIST_DIRECTORY for directories) makes this a counted
    // read open, so omitting FILE_SHARE_DELETE blocks competing DELETE-access
    // opens for the validation lifetime. The primary data handle still shares
    // delete for later, separately revalidated replacement.
    let validation = open_windows_path_with_share(
        path,
        FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL,
        OPEN_EXISTING,
        kind.open_flags(),
        VALIDATION_SHARE_MODE,
    )?;
    let actual = storage_identity(validation.as_raw_handle() as HANDLE, kind)?;
    verify_storage_handle(validation.as_raw_handle() as HANDLE)?;
    while_validation_open(&validation)?;
    if actual == expected {
        Ok(())
    } else {
        Err(security_verification_failed())
    }
}

fn open_windows_path(path: &Path, access: u32, disposition: u32, flags: u32) -> io::Result<File> {
    open_windows_path_with_share(path, access, disposition, flags, STORAGE_SHARE_MODE)
}

fn open_windows_path_with_share(
    path: &Path,
    access: u32,
    disposition: u32,
    flags: u32,
    share_mode: u32,
) -> io::Result<File> {
    let wide = wide_path(path)?;
    let handle = match disposition {
        OPEN_EXISTING => unsafe {
            CreateFileW(
                wide.as_ptr(),
                access,
                share_mode,
                null(),
                disposition,
                flags,
                null_mut(),
            )
        },
        CREATE_NEW | OPEN_ALWAYS => {
            let mut security = CreationSecurity::new()?;
            let attributes = security.attributes();
            unsafe {
                CreateFileW(
                    wide.as_ptr(),
                    access,
                    share_mode,
                    &attributes,
                    disposition,
                    flags,
                    null_mut(),
                )
            }
        }
        _ => return Err(security_operation_failed()),
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(last_win32_error());
    }
    if handle.is_null() {
        return Err(security_operation_failed());
    }

    Ok(unsafe { File::from_raw_handle(handle as _) })
}

fn wide_path(path: &Path) -> io::Result<Vec<u16>> {
    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    if wide.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid Windows storage path",
        ));
    }
    wide.push(0);
    Ok(wide)
}

fn storage_identity(handle: HANDLE, kind: StorageObjectKind) -> io::Result<StorageIdentity> {
    validate_handle(handle)?;
    if unsafe { GetFileType(handle) } != FILE_TYPE_DISK {
        return Err(security_verification_failed());
    }

    let mut attributes = FILE_ATTRIBUTE_TAG_INFO::default();
    if unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileAttributeTagInfo,
            (&mut attributes as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
            size_of::<FILE_ATTRIBUTE_TAG_INFO>() as u32,
        )
    } == 0
    {
        return Err(last_win32_error());
    }
    let is_directory = attributes.FileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
    if attributes.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DEVICE) != 0
        || is_directory != kind.is_directory()
    {
        return Err(security_verification_failed());
    }

    let mut identity = FILE_ID_INFO::default();
    if unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileIdInfo,
            (&mut identity as *mut FILE_ID_INFO).cast(),
            size_of::<FILE_ID_INFO>() as u32,
        )
    } == 0
    {
        return Err(last_win32_error());
    }

    Ok(StorageIdentity {
        volume_serial_number: identity.VolumeSerialNumber,
        file_id: identity.FileId.Identifier,
    })
}

fn flush_storage_directory_handle(handle: HANDLE) -> io::Result<()> {
    storage_identity(handle, StorageObjectKind::Directory)?;
    verify_storage_handle(handle)?;
    if unsafe { FlushFileBuffers(handle) } == 0 {
        Err(last_win32_error())
    } else {
        Ok(())
    }
}

/// Fill a newly allocated buffer with the Windows system-preferred CNG RNG.
/// No fallback is permitted: an NTSTATUS failure returns no bytes.
#[allow(dead_code)] // Stage 2A1 primitive; production callers are wired later.
pub(crate) fn cng_random_bytes(len: usize) -> io::Result<Vec<u8>> {
    random_bytes_with(len, |buffer, buffer_len| unsafe {
        BCryptGenRandom(
            null_mut(),
            buffer,
            buffer_len,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    })
}

fn random_bytes_with(
    len: usize,
    fill: impl FnOnce(*mut u8, u32) -> NTSTATUS,
) -> io::Result<Vec<u8>> {
    let len_u32 = u32::try_from(len).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "requested random buffer is too large",
        )
    })?;
    let mut bytes = vec![0u8; len];
    if bytes.is_empty() {
        return Ok(bytes);
    }

    // BCrypt's BCRYPT_SUCCESS macro is the standard NT_SUCCESS(status >= 0)
    // predicate. On failure, clear the local buffer before returning only Err.
    if fill(bytes.as_mut_ptr(), len_u32) < 0 {
        bytes.fill(0);
        return Err(io::Error::other("secure random generation failed"));
    }
    Ok(bytes)
}

/// Verify without modifying a file or directory handle's owner or DACL.
#[allow(dead_code)] // Stage 2A1 primitive; production callers are wired later.
pub(crate) fn verify_storage_handle(handle: HANDLE) -> io::Result<()> {
    validate_handle(handle)?;
    let current_user = current_process_user_sid()?;
    let local_system = well_known_sid(WinLocalSystemSid)?;
    verify_storage_handle_with(handle, &current_user, &local_system)
}

fn verify_storage_handle_with(
    handle: HANDLE,
    current_user: &Sid,
    local_system: &Sid,
) -> io::Result<()> {
    let snapshot = read_security_snapshot(handle)?;
    inspect_owner(&snapshot.owner, current_user.as_bytes())?;
    inspect_acl(
        &snapshot.acl,
        current_user.as_bytes(),
        local_system.as_bytes(),
    )
}

fn inspect_owner(owner: &[u8], current_user: &[u8]) -> io::Result<()> {
    if !owner.is_empty() && owner == current_user {
        Ok(())
    } else {
        Err(security_verification_failed())
    }
}

fn validate_handle(handle: HANDLE) -> io::Result<()> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid Windows storage handle",
        ))
    } else {
        Ok(())
    }
}

fn expected_principals<'a>(current_user: &'a Sid, local_system: &'a Sid) -> Vec<&'a Sid> {
    if current_user.as_bytes() == local_system.as_bytes() {
        vec![current_user]
    } else {
        vec![current_user, local_system]
    }
}

struct AlignedBuffer {
    words: Vec<usize>,
    byte_len: usize,
}

impl AlignedBuffer {
    fn zeroed(byte_len: usize) -> io::Result<Self> {
        if byte_len == 0 {
            return Err(security_operation_failed());
        }
        let word_size = size_of::<usize>();
        let word_count = byte_len
            .checked_add(word_size - 1)
            .ok_or_else(security_operation_failed)?
            / word_size;
        Ok(Self {
            words: vec![0usize; word_count],
            byte_len,
        })
    }

    fn as_ptr(&self) -> *const u8 {
        self.words.as_ptr().cast()
    }

    fn as_mut_ptr(&mut self) -> *mut u8 {
        self.words.as_mut_ptr().cast()
    }

    fn len(&self) -> usize {
        self.byte_len
    }
}

struct Sid {
    buffer: AlignedBuffer,
    byte_len: usize,
}

impl Sid {
    fn zeroed(byte_len: usize) -> io::Result<Self> {
        Ok(Self {
            buffer: AlignedBuffer::zeroed(byte_len)?,
            byte_len,
        })
    }

    fn as_psid(&self) -> PSID {
        self.buffer.as_ptr() as PSID
    }

    fn as_mut_psid(&mut self) -> PSID {
        self.buffer.as_mut_ptr().cast()
    }

    fn as_bytes(&self) -> &[u8] {
        unsafe { slice::from_raw_parts(self.buffer.as_ptr(), self.byte_len) }
    }
}

struct OwnedHandle(HANDLE);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

struct LocalAllocation(*mut c_void);

impl Drop for LocalAllocation {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = LocalFree(self.0);
            }
        }
    }
}

fn current_process_user_sid() -> io::Result<Sid> {
    let mut token = null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(last_win32_error());
    }
    if token.is_null() || token == INVALID_HANDLE_VALUE {
        return Err(security_operation_failed());
    }
    let token = OwnedHandle(token);

    let mut required = 0u32;
    let first = unsafe { GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut required) };
    let first_error = unsafe { GetLastError() };
    if first != 0
        || first_error != ERROR_INSUFFICIENT_BUFFER
        || required < size_of::<TOKEN_USER>() as u32
    {
        return Err(security_operation_failed());
    }

    let mut token_buffer = AlignedBuffer::zeroed(required as usize)?;
    let mut returned = 0u32;
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            token_buffer.as_mut_ptr().cast(),
            required,
            &mut returned,
        )
    } == 0
    {
        return Err(last_win32_error());
    }
    if returned < size_of::<TOKEN_USER>() as u32 || returned > required {
        return Err(security_operation_failed());
    }

    let token_user = unsafe { ptr::read_unaligned(token_buffer.as_ptr().cast::<TOKEN_USER>()) };
    copy_sid_from_bounded(
        token_user.User.Sid,
        token_buffer.as_ptr(),
        returned as usize,
    )
}

fn well_known_sid(kind: WELL_KNOWN_SID_TYPE) -> io::Result<Sid> {
    let mut required = 0u32;
    let first = unsafe { CreateWellKnownSid(kind, null_mut(), null_mut(), &mut required) };
    let first_error = unsafe { GetLastError() };
    if first != 0 || first_error != ERROR_INSUFFICIENT_BUFFER || required == 0 {
        return Err(security_operation_failed());
    }

    let mut sid = Sid::zeroed(required as usize)?;
    let mut returned = required;
    if unsafe { CreateWellKnownSid(kind, null_mut(), sid.as_mut_psid(), &mut returned) } == 0 {
        return Err(last_win32_error());
    }
    if returned == 0 || returned > required {
        return Err(security_operation_failed());
    }

    let validated = validate_sid_within(sid.as_psid(), sid.buffer.as_ptr(), returned as usize)?;
    if validated != returned as usize {
        return Err(security_operation_failed());
    }
    sid.byte_len = validated;
    Ok(sid)
}

fn copy_sid_from_bounded(source: PSID, base: *const u8, available: usize) -> io::Result<Sid> {
    let byte_len = validate_sid_within(source, base, available)?;
    let mut copy = Sid::zeroed(byte_len)?;
    if unsafe { CopySid(byte_len as u32, copy.as_mut_psid(), source) } == 0 {
        return Err(last_win32_error());
    }
    if validate_sid_within(copy.as_psid(), copy.buffer.as_ptr(), copy.buffer.len())? != byte_len {
        return Err(security_operation_failed());
    }
    Ok(copy)
}

fn validate_sid_within(source: PSID, base: *const u8, available: usize) -> io::Result<usize> {
    if source.is_null() || base.is_null() {
        return Err(security_operation_failed());
    }

    let base_address = base as usize;
    let end_address = base_address
        .checked_add(available)
        .ok_or_else(security_operation_failed)?;
    let sid_address = source as usize;
    let header_end = sid_address
        .checked_add(SID_HEADER_LEN)
        .ok_or_else(security_operation_failed)?;
    if sid_address < base_address || header_end > end_address {
        return Err(security_operation_failed());
    }

    let sub_authority_count = unsafe { *(source.cast::<u8>().add(1)) } as usize;
    let byte_len = SID_HEADER_LEN
        .checked_add(
            sub_authority_count
                .checked_mul(size_of::<u32>())
                .ok_or_else(security_operation_failed)?,
        )
        .ok_or_else(security_operation_failed)?;
    let sid_end = sid_address
        .checked_add(byte_len)
        .ok_or_else(security_operation_failed)?;
    if sid_end > end_address || unsafe { IsValidSid(source) } == 0 {
        return Err(security_operation_failed());
    }
    if unsafe { GetLengthSid(source) } as usize != byte_len {
        return Err(security_operation_failed());
    }
    Ok(byte_len)
}

struct AclBuffer(AlignedBuffer);

impl AclBuffer {
    fn as_ptr(&self) -> *const ACL {
        self.0.as_ptr().cast()
    }
}

fn build_full_control_acl(principals: &[&Sid]) -> io::Result<AclBuffer> {
    if principals.is_empty() {
        return Err(security_operation_failed());
    }

    let ace_prefix_len = size_of::<ACCESS_ALLOWED_ACE>() - size_of::<u32>();
    let mut acl_len = size_of::<ACL>();
    for principal in principals {
        acl_len = acl_len
            .checked_add(
                ace_prefix_len
                    .checked_add(principal.byte_len)
                    .ok_or_else(security_operation_failed)?,
            )
            .ok_or_else(security_operation_failed)?;
    }
    if acl_len > u16::MAX as usize {
        return Err(security_operation_failed());
    }

    let mut buffer = AlignedBuffer::zeroed(acl_len)?;
    let acl = buffer.as_mut_ptr().cast::<ACL>();
    if unsafe { InitializeAcl(acl, acl_len as u32, ACL_REVISION) } == 0 {
        return Err(last_win32_error());
    }
    for principal in principals {
        if unsafe {
            AddAccessAllowedAceEx(
                acl,
                ACL_REVISION,
                NO_INHERITANCE,
                FILE_ALL_ACCESS,
                principal.as_psid(),
            )
        } == 0
        {
            return Err(last_win32_error());
        }
    }
    if unsafe { IsValidAcl(acl) } == 0 {
        return Err(security_operation_failed());
    }
    Ok(AclBuffer(buffer))
}

struct CreationSecurity {
    // These allocations back pointers stored in the absolute descriptor.
    _owner: Sid,
    _acl: AclBuffer,
    descriptor: SECURITY_DESCRIPTOR,
}

impl CreationSecurity {
    fn new() -> io::Result<Self> {
        let owner = current_process_user_sid()?;
        let local_system = well_known_sid(WinLocalSystemSid)?;
        let principals = expected_principals(&owner, &local_system);
        let acl = build_full_control_acl(&principals)?;
        let mut descriptor = SECURITY_DESCRIPTOR::default();
        let descriptor_pointer: PSECURITY_DESCRIPTOR =
            (&mut descriptor as *mut SECURITY_DESCRIPTOR).cast();

        if unsafe {
            InitializeSecurityDescriptor(descriptor_pointer, SECURITY_DESCRIPTOR_REVISION_VALUE)
        } == 0
        {
            return Err(last_win32_error());
        }
        if unsafe { SetSecurityDescriptorOwner(descriptor_pointer, owner.as_psid(), 0) } == 0 {
            return Err(last_win32_error());
        }
        if unsafe { SetSecurityDescriptorDacl(descriptor_pointer, 1, acl.as_ptr(), 0) } == 0 {
            return Err(last_win32_error());
        }
        if unsafe {
            SetSecurityDescriptorControl(descriptor_pointer, SE_DACL_PROTECTED, SE_DACL_PROTECTED)
        } == 0
        {
            return Err(last_win32_error());
        }
        if unsafe { IsValidSecurityDescriptor(descriptor_pointer) } == 0 {
            return Err(security_operation_failed());
        }

        Ok(Self {
            _owner: owner,
            _acl: acl,
            descriptor,
        })
    }

    fn attributes(&mut self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: (&mut self.descriptor as *mut SECURITY_DESCRIPTOR).cast(),
            bInheritHandle: 0,
        }
    }
}

#[cfg(test)]
fn set_protected_handle_dacl(handle: HANDLE, acl: *const ACL) -> io::Result<()> {
    let status = unsafe {
        SetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            acl,
            null(),
        )
    };
    if status == ERROR_SUCCESS {
        Ok(())
    } else {
        Err(win32_status_error(status))
    }
}

#[derive(Clone, Eq, PartialEq)]
struct AclSnapshot {
    dacl_present: bool,
    dacl_null: bool,
    protected: bool,
    aces: Vec<AceSnapshot>,
}

#[derive(Clone, Eq, PartialEq)]
struct AceSnapshot {
    ace_type: u8,
    flags: u8,
    mask: u32,
    sid: Vec<u8>,
}

struct SecuritySnapshot {
    owner: Vec<u8>,
    acl: AclSnapshot,
}

fn read_acl_snapshot(handle: HANDLE) -> io::Result<AclSnapshot> {
    Ok(read_security_snapshot(handle)?.acl)
}

fn read_security_snapshot(handle: HANDLE) -> io::Result<SecuritySnapshot> {
    validate_handle(handle)?;

    let mut owner = null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    let status = unsafe {
        GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            null_mut(),
            null_mut(),
            &mut descriptor,
        )
    };
    let descriptor_allocation = LocalAllocation(descriptor);
    if status != ERROR_SUCCESS {
        return Err(win32_status_error(status));
    }
    if descriptor_allocation.0.is_null() {
        return Err(security_operation_failed());
    }

    let descriptor_len = unsafe { GetSecurityDescriptorLength(descriptor_allocation.0) } as usize;
    if descriptor_len == 0 {
        return Err(security_operation_failed());
    }
    let owner_len =
        validate_sid_within(owner, descriptor_allocation.0.cast::<u8>(), descriptor_len)?;
    let owner = unsafe { slice::from_raw_parts(owner.cast::<u8>(), owner_len) }.to_vec();

    let mut control = 0u16;
    let mut revision = 0u32;
    if unsafe { GetSecurityDescriptorControl(descriptor_allocation.0, &mut control, &mut revision) }
        == 0
    {
        return Err(last_win32_error());
    }

    let mut dacl_present = 0;
    let mut dacl = null_mut();
    let mut dacl_defaulted = 0;
    if unsafe {
        GetSecurityDescriptorDacl(
            descriptor_allocation.0,
            &mut dacl_present,
            &mut dacl,
            &mut dacl_defaulted,
        )
    } == 0
    {
        return Err(last_win32_error());
    }

    let mut snapshot = AclSnapshot {
        dacl_present: dacl_present != 0,
        dacl_null: dacl.is_null(),
        protected: control & SE_DACL_PROTECTED != 0,
        aces: Vec::new(),
    };
    if !snapshot.dacl_present || snapshot.dacl_null {
        return Ok(SecuritySnapshot {
            owner,
            acl: snapshot,
        });
    }
    let descriptor_start = descriptor_allocation.0 as usize;
    let descriptor_end = descriptor_start
        .checked_add(descriptor_len)
        .ok_or_else(security_verification_failed)?;
    let acl_start = dacl as usize;
    let acl_header_end = acl_start
        .checked_add(size_of::<ACL>())
        .ok_or_else(security_verification_failed)?;
    if acl_start < descriptor_start || acl_header_end > descriptor_end {
        return Err(security_verification_failed());
    }

    let acl_header = unsafe { ptr::read_unaligned(dacl) };
    let acl_size = acl_header.AclSize as usize;
    let allocated_acl_end = acl_start
        .checked_add(acl_size)
        .ok_or_else(security_verification_failed)?;
    if acl_size < size_of::<ACL>() || allocated_acl_end > descriptor_end {
        return Err(security_verification_failed());
    }
    if unsafe { IsValidAcl(dacl) } == 0 {
        return Err(security_verification_failed());
    }

    let mut info = ACL_SIZE_INFORMATION::default();
    if unsafe {
        GetAclInformation(
            dacl,
            (&mut info as *mut ACL_SIZE_INFORMATION).cast(),
            size_of::<ACL_SIZE_INFORMATION>() as u32,
            AclSizeInformation,
        )
    } == 0
    {
        return Err(last_win32_error());
    }

    let bytes_in_use = info.AclBytesInUse as usize;
    if bytes_in_use < size_of::<ACL>() || bytes_in_use > acl_size {
        return Err(security_verification_failed());
    }
    let acl_end = acl_start
        .checked_add(bytes_in_use)
        .ok_or_else(security_verification_failed)?;
    let first_ace = acl_header_end;

    snapshot.aces.reserve(info.AceCount as usize);
    for index in 0..info.AceCount {
        let mut ace = null_mut::<c_void>();
        if unsafe { GetAce(dacl, index, &mut ace) } == 0 {
            return Err(last_win32_error());
        }
        if ace.is_null() {
            return Err(security_verification_failed());
        }

        let ace_start = ace as usize;
        let header_end = ace_start
            .checked_add(size_of::<ACE_HEADER>())
            .ok_or_else(security_verification_failed)?;
        if ace_start < first_ace || header_end > acl_end {
            return Err(security_verification_failed());
        }
        let header = unsafe { ptr::read_unaligned(ace.cast::<ACE_HEADER>()) };
        let ace_size = header.AceSize as usize;
        let ace_end = ace_start
            .checked_add(ace_size)
            .ok_or_else(security_verification_failed)?;
        if ace_size < size_of::<ACE_HEADER>() || ace_end > acl_end {
            return Err(security_verification_failed());
        }

        if header.AceType != ACCESS_ALLOWED_ACE_TYPE_VALUE {
            snapshot.aces.push(AceSnapshot {
                ace_type: header.AceType,
                flags: header.AceFlags,
                mask: 0,
                sid: Vec::new(),
            });
            continue;
        }
        if ace_size < ACE_SID_OFFSET + SID_HEADER_LEN {
            return Err(security_verification_failed());
        }

        let ace_bytes = ace.cast::<u8>();
        let mask =
            unsafe { ptr::read_unaligned(ace_bytes.add(size_of::<ACE_HEADER>()).cast::<u32>()) };
        let sid = unsafe { ace_bytes.add(ACE_SID_OFFSET) } as PSID;
        let sid_len = validate_sid_within(sid, ace_bytes, ace_size)?;
        if ACE_SID_OFFSET + sid_len != ace_size {
            return Err(security_verification_failed());
        }
        let sid = unsafe { slice::from_raw_parts(sid.cast::<u8>(), sid_len) }.to_vec();
        snapshot.aces.push(AceSnapshot {
            ace_type: header.AceType,
            flags: header.AceFlags,
            mask,
            sid,
        });
    }

    Ok(SecuritySnapshot {
        owner,
        acl: snapshot,
    })
}

fn inspect_acl(snapshot: &AclSnapshot, current_user: &[u8], local_system: &[u8]) -> io::Result<()> {
    if current_user.is_empty()
        || local_system.is_empty()
        || !snapshot.dacl_present
        || snapshot.dacl_null
        || !snapshot.protected
    {
        return Err(security_verification_failed());
    }

    let same_principal = current_user == local_system;
    let expected_count = if same_principal { 1 } else { 2 };
    if snapshot.aces.len() != expected_count {
        return Err(security_verification_failed());
    }

    let mut current_seen = false;
    let mut system_seen = same_principal;
    for ace in &snapshot.aces {
        if ace.ace_type != ACCESS_ALLOWED_ACE_TYPE_VALUE
            || ace.flags != NO_INHERITANCE as u8
            || ace.mask != FILE_ALL_ACCESS
        {
            return Err(security_verification_failed());
        }

        if ace.sid == current_user {
            if current_seen {
                return Err(security_verification_failed());
            }
            current_seen = true;
        } else if !same_principal && ace.sid == local_system {
            if system_seen {
                return Err(security_verification_failed());
            }
            system_seen = true;
        } else {
            // This rejects every broad or foreign SID, including Users,
            // Authenticated Users, and Everyone, for both allow and deny ACEs.
            return Err(security_verification_failed());
        }
    }

    if current_seen && system_seen {
        Ok(())
    } else {
        Err(security_verification_failed())
    }
}

fn last_win32_error() -> io::Error {
    win32_status_error(unsafe { GetLastError() })
}

fn win32_status_error(status: u32) -> io::Error {
    io::Error::from_raw_os_error(status as i32)
}

fn security_operation_failed() -> io::Error {
    io::Error::other("Windows security operation failed")
}

fn security_verification_failed() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "Windows storage security verification failed",
    )
}

fn is_security_verification_failure(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::PermissionDenied && error.raw_os_error().is_none()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File, OpenOptions};
    use std::io::{Read, Seek, SeekFrom, Write};
    use std::os::windows::fs::{symlink_file, OpenOptionsExt};
    use std::os::windows::io::AsRawHandle;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    use windows_sys::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE};
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{WinAuthenticatedUserSid, WinWorldSid, INHERITED_ACE};
    use windows_sys::Win32::Storage::FileSystem::{DELETE, READ_CONTROL, WRITE_DAC};
    const ACCESS_DENIED_ACE_TYPE_VALUE: u8 = 1;
    macro_rules! check {
        ($condition:expr, $label:expr) => {
            ::std::assert!($condition, $label);
        };
    }
    static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(0);
    struct TempRoot {
        path: PathBuf,
    }
    impl TempRoot {
        fn create() -> io::Result<Self> {
            for _ in 0..32 {
                let timestamp = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos();
                let sequence = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
                let path = std::env::temp_dir().join(format!(
                    "tokenbar-storage-root-{}-{timestamp}-{sequence}",
                    std::process::id()
                ));
                match fs::create_dir(&path) {
                    Ok(()) => return Ok(Self { path }),
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                    Err(error) => return Err(error),
                }
            }
            Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "unable to create temporary storage root",
            ))
        }
    }
    impl Drop for TempRoot {
        fn drop(&mut self) {
            if !self.path.as_os_str().is_empty() {
                let _ = fs::remove_dir_all(&self.path);
            }
        }
    }
    struct SecureWorkspace {
        directory: File,
        path: PathBuf,
        root: TempRoot,
    }
    impl SecureWorkspace {
        fn create() -> io::Result<Self> {
            let root = TempRoot::create()?;
            let path = root.path.join("storage");
            let directory = ensure_secure_storage_directory(&path)?;
            Ok(Self {
                directory,
                path,
                root,
            })
        }
    }
    fn create_test_file(path: &Path, contents: &[u8]) -> io::Result<File> {
        let mut file = open_windows_path(
            path,
            GENERIC_READ | GENERIC_WRITE | READ_CONTROL | WRITE_DAC,
            CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL,
        )?;
        file.write_all(contents)?;
        file.sync_all()?;
        Ok(file)
    }
    fn create_permissive_test_file(path: &Path, contents: &[u8]) -> io::Result<File> {
        let file = create_test_file(path, contents)?;
        let everyone = well_known_sid(WinWorldSid)?;
        let acl = build_full_control_acl(&[&everyone])?;
        set_protected_handle_dacl(file.as_raw_handle() as HANDLE, acl.as_ptr())?;
        Ok(file)
    }
    fn create_permissive_test_directory(path: &Path) -> io::Result<File> {
        drop(ensure_secure_storage_directory(path)?);
        let directory = open_windows_path(
            path,
            GENERIC_WRITE | FILE_READ_ATTRIBUTES | READ_CONTROL | WRITE_DAC,
            OPEN_EXISTING,
            StorageObjectKind::Directory.open_flags(),
        )?;
        let everyone = well_known_sid(WinWorldSid)?;
        let acl = build_full_control_acl(&[&everyone])?;
        set_protected_handle_dacl(directory.as_raw_handle() as HANDLE, acl.as_ptr())?;
        Ok(directory)
    }
    fn create_junction(link: &Path, target: &Path) -> io::Result<()> {
        let output = Command::new("cmd")
            .args(["/D", "/C", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .output()?;
        if output.status.success() {
            Ok(())
        } else {
            Err(io::Error::other("unable to create test junction"))
        }
    }
    fn read_open_file(file: &mut File) -> io::Result<Vec<u8>> {
        file.seek(SeekFrom::Start(0))?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        Ok(bytes)
    }
    fn regular_file_identity(file: &File) -> io::Result<StorageIdentity> {
        storage_identity(
            file.as_raw_handle() as HANDLE,
            StorageObjectKind::RegularFile,
        )
    }
    fn create_secure_test_file(
        path: &Path,
        contents: &[u8],
    ) -> io::Result<(File, StorageIdentity)> {
        let mut file = create_new_secure_file(path)?;
        file.write_all(contents)?;
        file.sync_all()?;
        let identity = regular_file_identity(&file)?;
        Ok((file, identity))
    }
    #[derive(Clone)]
    struct FileSnapshot {
        bytes: Vec<u8>,
        identity: StorageIdentity,
        acl: AclSnapshot,
        kind: StorageObjectKind,
    }
    fn snapshot_object(file: &File, kind: StorageObjectKind) -> io::Result<FileSnapshot> {
        let identity = storage_identity(file.as_raw_handle() as HANDLE, kind)?;
        let acl = read_acl_snapshot(file.as_raw_handle() as HANDLE)?;
        let bytes = if kind.is_directory() {
            Vec::new()
        } else {
            let mut copy = file.try_clone()?;
            read_open_file(&mut copy)?
        };
        Ok(FileSnapshot {
            bytes,
            identity,
            acl,
            kind,
        })
    }
    fn snapshot_path(path: &Path, kind: StorageObjectKind) -> io::Result<FileSnapshot> {
        let access = if kind.is_directory() {
            FILE_READ_ATTRIBUTES | READ_CONTROL
        } else {
            GENERIC_READ | READ_CONTROL
        };
        let file = open_windows_path(path, access, OPEN_EXISTING, kind.open_flags())?;
        snapshot_object(&file, kind)
    }
    fn assert_snapshot(path: &Path, expected: &FileSnapshot, label: &str) {
        let actual = snapshot_path(path, expected.kind).expect("snapshot remains readable");
        check!(
            actual.bytes == expected.bytes
                && actual.identity == expected.identity
                && actual.acl == expected.acl,
            "{label}: bytes, identity, or DACL changed"
        );
    }
    fn assert_handle_snapshot(file: &File, expected: &FileSnapshot, label: &str) {
        let actual =
            snapshot_object(file, expected.kind).expect("retained handle remains readable");
        check!(
            actual.bytes == expected.bytes
                && actual.identity == expected.identity
                && actual.acl == expected.acl,
            "{label}: bytes, identity, or DACL changed"
        );
    }
    fn file_snapshot_fixture(
        path: &Path,
        contents: &[u8],
        permissive: bool,
    ) -> io::Result<(File, FileSnapshot)> {
        let file = if permissive {
            create_permissive_test_file(path, contents)?
        } else {
            create_secure_test_file(path, contents)?.0
        };
        let snapshot = snapshot_object(&file, StorageObjectKind::RegularFile)?;
        Ok((file, snapshot))
    }

    fn assert_absent(path: &Path, label: &str) {
        match fs::symlink_metadata(path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            _ => panic!("{label}: pathname remains installed"),
        }
    }

    fn sid_string(sid: &Sid) -> io::Result<String> {
        let mut wide = null_mut();
        if unsafe { ConvertSidToStringSidW(sid.as_psid(), &mut wide) } == 0 {
            return Err(last_win32_error());
        }
        let allocation = LocalAllocation(wide.cast());
        if allocation.0.is_null() {
            return Err(security_operation_failed());
        }
        let mut len = 0usize;
        while len < 256 && unsafe { *wide.add(len) } != 0 {
            len += 1;
        }
        if len == 256 {
            return Err(security_operation_failed());
        }
        String::from_utf16(unsafe { slice::from_raw_parts(wide, len) })
            .map_err(|_| security_operation_failed())
    }
    fn assert_generic_error(error: &io::Error, sensitive_values: &[&str]) {
        let message = error.to_string().to_lowercase();
        for value in sensitive_values {
            if !value.is_empty() {
                check!(
                    !message.contains(&value.to_lowercase()),
                    "security error discloses sensitive context"
                );
            }
        }
    }
    fn ace(sid: &[u8]) -> AceSnapshot {
        AceSnapshot {
            ace_type: ACCESS_ALLOWED_ACE_TYPE_VALUE,
            flags: NO_INHERITANCE as u8,
            mask: FILE_ALL_ACCESS,
            sid: sid.to_vec(),
        }
    }
    fn canonical_acl(current_user: &Sid, local_system: &Sid) -> AclSnapshot {
        let mut aces = vec![ace(current_user.as_bytes())];
        if current_user.as_bytes() != local_system.as_bytes() {
            aces.push(ace(local_system.as_bytes()));
        }
        AclSnapshot {
            dacl_present: true,
            dacl_null: false,
            protected: true,
            aces,
        }
    }
    fn reject_acl_mutations(current_user: &Sid, local_system: &Sid, foreign: &Sid) {
        let valid = canonical_acl(current_user, local_system);
        check!(
            inspect_acl(&valid, current_user.as_bytes(), local_system.as_bytes()).is_ok(),
            "ACL/BASE: canonical descriptor is accepted"
        );
        for case in [
            "missing-dacl",
            "null-dacl",
            "unprotected-dacl",
            "wrong-owner",
            "missing-user",
            "missing-system",
            "foreign-non-broad-allow",
            "broad-allow",
            "deny",
            "inherited",
            "wrong-flags",
            "wrong-mask",
            "duplicate-user",
            "duplicate-system",
            "incomplete-ace",
            "unsupported-ace",
        ] {
            let mut candidate = valid.clone();
            match case {
                "missing-dacl" => candidate.dacl_present = false,
                "null-dacl" => candidate.dacl_null = true,
                "unprotected-dacl" => candidate.protected = false,
                "wrong-owner" => {
                    check!(
                        inspect_owner(foreign.as_bytes(), current_user.as_bytes()).is_err(),
                        "ACL/{case}: foreign owner rejected"
                    );
                    continue;
                }
                "missing-user" => {
                    if current_user.as_bytes() == local_system.as_bytes() {
                        candidate.aces.clear();
                    } else {
                        candidate
                            .aces
                            .retain(|entry| entry.sid != current_user.as_bytes());
                    }
                }
                "missing-system" => {
                    candidate
                        .aces
                        .retain(|entry| entry.sid != local_system.as_bytes());
                }
                "foreign-non-broad-allow" => candidate.aces.push(AceSnapshot {
                    mask: FILE_READ_DATA,
                    ..ace(foreign.as_bytes())
                }),
                "broad-allow" => candidate.aces.push(ace(foreign.as_bytes())),
                "deny" => candidate.aces.push(AceSnapshot {
                    ace_type: ACCESS_DENIED_ACE_TYPE_VALUE,
                    ..ace(current_user.as_bytes())
                }),
                "inherited" => candidate.aces[0].flags = INHERITED_ACE as u8,
                "wrong-flags" => candidate.aces[0].flags = 1,
                "wrong-mask" => candidate.aces[0].mask &= !1,
                "duplicate-user" => candidate.aces.push(ace(current_user.as_bytes())),
                "duplicate-system" => candidate.aces.push(ace(local_system.as_bytes())),
                "incomplete-ace" => candidate.aces[0].sid.clear(),
                "unsupported-ace" => candidate.aces[0].ace_type = 0xff,
                _ => unreachable!(),
            }
            check!(
                inspect_acl(&candidate, current_user.as_bytes(), local_system.as_bytes()).is_err(),
                "ACL-MUTATION-MATRIX/{case}: mutation is rejected"
            );
        }
    }
    fn replace_success_case(destination_present: bool, label: &str) -> io::Result<()> {
        let workspace = SecureWorkspace::create()?;
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let staged_path = storage_path.join("staged.tmp");
        let destination_path = storage_path.join("history.json");
        let (staged, staged_identity) = create_secure_test_file(&staged_path, b"new bytes")?;
        let staged_snapshot = snapshot_object(&staged, StorageObjectKind::RegularFile)?;
        drop(staged);
        if destination_present {
            let (destination, _) = create_secure_test_file(&destination_path, b"old bytes")?;
            drop(destination);
        }
        replace_secure_file(&directory, &storage_path, &staged_path, &destination_path)?;
        let installed = snapshot_path(&destination_path, StorageObjectKind::RegularFile)?;
        check!(
            installed.bytes == b"new bytes"
                && installed.identity == staged_identity
                && installed.acl == staged_snapshot.acl,
            "{label}: staged bytes, identity, or DACL changed"
        );
        assert_absent(&staged_path, label);
        Ok(())
    }
    fn replace_precommit_failure_case() -> io::Result<()> {
        let root = TempRoot::create()?;
        let storage_path = root.path.join("storage");
        let directory = ensure_secure_storage_directory(&storage_path)?;
        let staged_path = storage_path.join("staged.tmp");
        let destination_path = storage_path.join("history.json");
        let (staged, _) = create_secure_test_file(&staged_path, b"staged bytes")?;
        let staged_snapshot = snapshot_object(&staged, StorageObjectKind::RegularFile)?;
        let (destination, _) = create_secure_test_file(&destination_path, b"last-good bytes")?;
        let destination_snapshot = snapshot_object(&destination, StorageObjectKind::RegularFile)?;
        drop(destination);
        drop(staged);
        let mut called = false;
        let error = replace_secure_file_with(
            &directory,
            &storage_path,
            &staged_path,
            &destination_path,
            |_, _| {
                called = true;
                Err(io::Error::other("injected replace failure"))
            },
        )
        .expect_err("REPLACE-PRECOMMIT: injected failure returns error");
        check!(called, "REPLACE-PRECOMMIT: seam reached");
        assert_path_snapshots([
            (&staged_path, &staged_snapshot, "REPLACE-PRECOMMIT/staged"),
            (
                &destination_path,
                &destination_snapshot,
                "REPLACE-PRECOMMIT/destination",
            ),
        ]);
        Ok(())
    }
    fn assert_path_snapshots<const N: usize>(cases: [(&Path, &FileSnapshot, &str); N]) {
        for (path, snapshot, label) in cases {
            assert_snapshot(path, snapshot, label);
        }
    }
    fn reject_replace_reparse(
        directory: &File,
        storage_path: &Path,
        target: &Path,
        target_snapshot: &FileSnapshot,
        link: &Path,
        regular: &Path,
        regular_snapshot: &FileSnapshot,
        staged: &Path,
        destination: &Path,
        label: &str,
    ) {
        symlink_file(target, link).expect("REPLACE-FINAL-REPARSE: link");
        replace_secure_file(directory, storage_path, staged, destination)
            .expect_err("REPLACE-FINAL-REPARSE: link accepted");
        check!(
            fs::symlink_metadata(link)
                .expect("REPLACE-FINAL-REPARSE: link remains")
                .file_type()
                .is_symlink(),
            "{label}"
        );
        assert_snapshot(target, target_snapshot, "REPLACE-FINAL-REPARSE/target");
        assert_snapshot(regular, regular_snapshot, "REPLACE-FINAL-REPARSE/regular");
        fs::remove_file(link).expect("REPLACE-FINAL-REPARSE: remove link");
    }
    #[test]
    fn cng_success_exact_length_and_injected_failure_return_no_partial() {
        let first = cng_random_bytes(32).expect("CNG success returns bytes");
        let second = cng_random_bytes(32).expect("CNG second success returns bytes");
        check!(first.len() == 32, "CNG-EXACT-LENGTH: first length");
        check!(second.len() == 32, "CNG-EXACT-LENGTH: second length");
        let result = random_bytes_with(32, |buffer, buffer_len| {
            unsafe { ptr::write_bytes(buffer, 0xA5, buffer_len as usize) };
            -1
        });
        check!(
            result.is_err(),
            "CNG-INJECTED-FAILURE: failure has no result"
        );
    }
    #[test]
    fn acl_descriptor_and_handle_mutations_fail_closed() {
        let current = current_process_user_sid().expect("ACL: current SID");
        let system = well_known_sid(WinLocalSystemSid).expect("ACL: system SID");
        let foreign = well_known_sid(WinWorldSid).expect("ACL: foreign SID");
        assert!(
            foreign.as_bytes() != current.as_bytes() && foreign.as_bytes() != system.as_bytes(),
            "ACL-FOREIGN-SID"
        );
        let root = TempRoot::create().expect("ACL-ROUNDTRIP: root");
        let path = root.path.join("artifact.tmp");
        let artifact = create_test_file(&path, b"").expect("ACL-ROUNDTRIP: create artifact");
        verify_storage_handle(artifact.as_raw_handle() as HANDLE)
            .expect("ACL-ROUNDTRIP: creation verifies");
        let snapshot = read_acl_snapshot(artifact.as_raw_handle() as HANDLE)
            .expect("ACL-ROUNDTRIP: read DACL");
        inspect_acl(&snapshot, current.as_bytes(), system.as_bytes())
            .expect("ACL-ROUNDTRIP: exact DACL");
        let expected_count = usize::from(current.as_bytes() != system.as_bytes()) + 1;
        check!(snapshot.dacl_present, "ACL-ROUNDTRIP: DACL present");
        check!(!snapshot.dacl_null, "ACL-ROUNDTRIP: DACL non-null");
        check!(snapshot.protected, "ACL-ROUNDTRIP: DACL protected");
        check!(
            snapshot.aces.len() == expected_count,
            "ACL-ROUNDTRIP: ACE count"
        );
        check!(
            snapshot
                .aces
                .iter()
                .all(|entry| entry.flags & INHERITED_ACE as u8 == 0),
            "ACL-ROUNDTRIP: no inherited ACE"
        );
        for kind in [WinWorldSid, WinAuthenticatedUserSid] {
            let broad = well_known_sid(kind).expect("ACL-BROAD-ALLOW: broad SID");
            let acl = build_full_control_acl(&[&broad]).expect("ACL-BROAD-ALLOW: build DACL");
            set_protected_handle_dacl(artifact.as_raw_handle() as HANDLE, acl.as_ptr())
                .expect("ACL-BROAD-ALLOW: apply DACL");
            let before = snapshot_object(&artifact, StorageObjectKind::RegularFile)
                .expect("ACL-BROAD-ALLOW: before snapshot");
            check!(
                verify_storage_handle(artifact.as_raw_handle() as HANDLE).is_err(),
                "ACL-BROAD-ALLOW: broad ACE rejected"
            );
            assert_handle_snapshot(&artifact, &before, "ACL-BROAD-ALLOW");
        }
        check!(
            inspect_owner(foreign.as_bytes(), current.as_bytes()).is_err(),
            "ACL-WRONG-OWNER: foreign owner rejected"
        );
        check!(
            inspect_owner(current.as_bytes(), current.as_bytes()).is_ok(),
            "ACL-WRONG-OWNER: current owner accepted"
        );
        reject_acl_mutations(&current, &system, &foreign);
    }
    #[test]
    fn secure_root_resolver_preserves_preferred_fallback_sticky_and_collision_cases() {
        let root = TempRoot::create().expect("RESOLVER: root");
        let preferred = root.path.join("com.nyanako.tokenbar");
        let fallback = root.path.join("com.nyanako.tokenbar.secure");
        fs::create_dir(&preferred).expect("RESOLVER-FALLBACK: preferred");
        let preferred_handle = open_windows_path(
            &preferred,
            FILE_READ_ATTRIBUTES | READ_CONTROL,
            OPEN_EXISTING,
            StorageObjectKind::Directory.open_flags(),
        )
        .expect("RESOLVER-FALLBACK: open preferred");
        let preferred_identity = storage_identity(
            preferred_handle.as_raw_handle() as HANDLE,
            StorageObjectKind::Directory,
        )
        .expect("RESOLVER-FALLBACK: preferred identity");
        let preferred_acl = read_acl_snapshot(preferred_handle.as_raw_handle() as HANDLE)
            .expect("RESOLVER-FALLBACK: preferred DACL");
        check!(
            verify_storage_handle(preferred_handle.as_raw_handle() as HANDLE).is_err(),
            "RESOLVER-FALLBACK: legacy preferred rejected"
        );
        let v1_path = preferred.join("codex-weekly-history.json");
        fs::write(&v1_path, b"legacy-v1-sentinel").expect("RESOLVER-FALLBACK: v1 bytes");
        let v1 = open_windows_path(
            &v1_path,
            GENERIC_READ | FILE_READ_ATTRIBUTES,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
        )
        .expect("RESOLVER-FALLBACK: open v1");
        let v1_snapshot = snapshot_object(&v1, StorageObjectKind::RegularFile)
            .expect("RESOLVER-FALLBACK: v1 snapshot");
        let v1_mtime = fs::metadata(&v1_path)
            .expect("RESOLVER-FALLBACK: v1 metadata")
            .modified()
            .expect("RESOLVER-FALLBACK: v1 mtime");
        check!(
            resolve_secure_storage_directory(&preferred).expect("RESOLVER-FALLBACK: resolve")
                == fallback,
            "RESOLVER-FALLBACK: fallback selected"
        );
        let fallback_handle =
            ensure_secure_storage_directory(&fallback).expect("RESOLVER-FALLBACK: exact fallback");
        verify_storage_handle(fallback_handle.as_raw_handle() as HANDLE)
            .expect("RESOLVER-FALLBACK: fallback DACL");
        let preferred_after = open_windows_path(
            &preferred,
            FILE_READ_ATTRIBUTES | READ_CONTROL,
            OPEN_EXISTING,
            StorageObjectKind::Directory.open_flags(),
        )
        .expect("RESOLVER-FALLBACK: reopen preferred");
        check!(
            storage_identity(
                preferred_after.as_raw_handle() as HANDLE,
                StorageObjectKind::Directory
            )
            .expect("RESOLVER-FALLBACK: preferred identity after")
                == preferred_identity,
            "RESOLVER-FALLBACK: preferred identity unchanged"
        );
        check!(
            read_acl_snapshot(preferred_after.as_raw_handle() as HANDLE)
                .expect("RESOLVER-FALLBACK: preferred DACL after")
                == preferred_acl,
            "RESOLVER-FALLBACK: preferred DACL unchanged"
        );
        assert_handle_snapshot(&v1, &v1_snapshot, "RESOLVER-FALLBACK/v1");
        check!(
            fs::metadata(&v1_path)
                .expect("RESOLVER-FALLBACK: v1 metadata after")
                .modified()
                .expect("RESOLVER-FALLBACK: v1 mtime after")
                == v1_mtime,
            "RESOLVER-FALLBACK: v1 mtime unchanged"
        );
        drop(v1);
        drop((preferred_after, preferred_handle));
        fs::remove_dir_all(&preferred).unwrap();
        drop(ensure_secure_storage_directory(&preferred).expect("RESOLVER-STICKY: preferred"));
        check!(
            resolve_secure_storage_directory(&preferred).expect("RESOLVER-STICKY: second")
                == fallback,
            "RESOLVER-STICKY: fallback remains authoritative"
        );
        let collision = root.path.join("collision-root");
        fs::create_dir(&collision).expect("RESOLVER-COLLISION: root");
        let collision_preferred = collision.join("com.nyanako.tokenbar");
        let collision_fallback = collision.join("com.nyanako.tokenbar.secure");
        let fallback_file = create_test_file(&collision_fallback, b"fallback-file")
            .expect("RESOLVER-COLLISION: file collision");
        let file_snapshot = snapshot_object(&fallback_file, StorageObjectKind::RegularFile)
            .expect("RESOLVER-COLLISION: file snapshot");
        check!(
            resolve_secure_storage_directory(&collision_preferred).is_err(),
            "RESOLVER-COLLISION: file collision rejected"
        );
        assert_absent(&collision_preferred, "RESOLVER-COLLISION/file preferred");
        assert_handle_snapshot(&fallback_file, &file_snapshot, "RESOLVER-COLLISION/file");
        drop(fallback_file);
        fs::remove_file(&collision_fallback).expect("RESOLVER-COLLISION: remove file collision");
        let target = collision.join("fallback-target");
        let target_file = create_test_file(&target, b"fallback-target")
            .expect("RESOLVER-COLLISION: reparse target");
        let target_snapshot = snapshot_object(&target_file, StorageObjectKind::RegularFile)
            .expect("RESOLVER-COLLISION: target snapshot");
        symlink_file(&target, &collision_fallback).expect("RESOLVER-COLLISION: fallback reparse");
        check!(
            resolve_secure_storage_directory(&collision_preferred).is_err(),
            "RESOLVER-COLLISION: reparse collision rejected"
        );
        assert_absent(&collision_preferred, "RESOLVER-COLLISION/reparse preferred");
        assert_handle_snapshot(
            &target_file,
            &target_snapshot,
            "RESOLVER-COLLISION/reparse target",
        );
        fs::remove_file(&collision_fallback).expect("RESOLVER-COLLISION: remove reparse");
        drop(target_file);
        let fallback_directory = create_permissive_test_directory(&collision_fallback)
            .expect("RESOLVER-COLLISION: permissive directory");
        let directory_snapshot = snapshot_object(&fallback_directory, StorageObjectKind::Directory)
            .expect("RESOLVER-COLLISION: directory snapshot");
        check!(
            resolve_secure_storage_directory(&collision_preferred).is_err(),
            "RESOLVER-COLLISION: permissive collision rejected"
        );
        assert_absent(
            &collision_preferred,
            "RESOLVER-COLLISION/directory preferred",
        );
        assert_handle_snapshot(
            &fallback_directory,
            &directory_snapshot,
            "RESOLVER-COLLISION/directory",
        );
        drop(fallback_directory);
        let preferred_only = root.path.join("preferred-only");
        let preferred_only_fallback = root.path.join("preferred-only.secure");
        drop(
            ensure_secure_storage_directory(&preferred_only)
                .expect("RESOLVER-PREFERRED: preferred"),
        );
        check!(
            resolve_secure_storage_directory(&preferred_only).expect("RESOLVER-PREFERRED: resolve")
                == preferred_only,
            "RESOLVER-PREFERRED: exact preferred selected"
        );
        assert_absent(&preferred_only_fallback, "RESOLVER-PREFERRED/fallback");
    }
    #[test]
    fn new_objects_are_secure_on_their_first_open_handle() {
        let root = TempRoot::create().expect("FIRST-OPEN: root");
        let storage_path = root.path.join("storage");
        let _directory = ensure_secure_storage_directory_with(&storage_path, |created| {
            verify_storage_handle(created.as_raw_handle() as HANDLE)
        })
        .expect("FIRST-OPEN: directory");
        for (name, disposition) in [
            ("create-new.json", CREATE_NEW),
            ("open-always.json", OPEN_ALWAYS),
        ] {
            let path = storage_path.join(name);
            let _file = open_secure_storage_object_with(
                &path,
                GENERIC_READ | GENERIC_WRITE | STORAGE_SECURITY_ACCESS,
                disposition,
                StorageObjectKind::RegularFile,
                |created| verify_storage_handle(created.as_raw_handle() as HANDLE),
            )
            .expect("FIRST-OPEN: file secure on initial handle");
        }
    }
    #[test]
    fn secure_directory_and_files_round_trip_type_dacl_identity_and_bytes() {
        let workspace = SecureWorkspace::create().expect("OBJECT-ROUNDTRIP: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        storage_identity(
            directory.as_raw_handle() as HANDLE,
            StorageObjectKind::Directory,
        )
        .expect("OBJECT-ROUNDTRIP: directory identity");
        verify_storage_handle(directory.as_raw_handle() as HANDLE).expect("OBJECT-ROUNDTRIP: DACL");
        flush_secure_storage_directory(&directory).expect("OBJECT-ROUNDTRIP: directory flush");
        let file_path = storage_path.join("history.json");
        let mut file = create_new_secure_file(&file_path).expect("OBJECT-ROUNDTRIP: file");
        file.write_all(b"secure history")
            .expect("OBJECT-ROUNDTRIP: write");
        file.sync_all().expect("OBJECT-ROUNDTRIP: sync");
        let identity = regular_file_identity(&file).expect("OBJECT-ROUNDTRIP: file identity");
        verify_storage_handle(file.as_raw_handle() as HANDLE).expect("OBJECT-ROUNDTRIP: file DACL");
        verify_secure_file_path(&file, &file_path).expect("OBJECT-ROUNDTRIP: file path");
        let mut reopened =
            open_existing_secure_file(&file_path, false).expect("OBJECT-ROUNDTRIP: reopen");
        check!(
            regular_file_identity(&reopened).expect("OBJECT-ROUNDTRIP: reopen identity")
                == identity,
            "OBJECT-ROUNDTRIP: identity stable"
        );
        check!(
            read_open_file(&mut reopened).expect("OBJECT-ROUNDTRIP: read") == b"secure history",
            "OBJECT-ROUNDTRIP: bytes stable"
        );
        let mut writable =
            open_existing_secure_file(&file_path, true).expect("OBJECT-ROUNDTRIP: writable reopen");
        writable
            .seek(SeekFrom::End(0))
            .expect("OBJECT-ROUNDTRIP: seek");
        writable.write_all(b"!").expect("OBJECT-ROUNDTRIP: append");
        writable.sync_all().expect("OBJECT-ROUNDTRIP: append sync");
        drop(writable);
        check!(
            read_open_file(&mut reopened).expect("OBJECT-ROUNDTRIP: reread") == b"secure history!",
            "OBJECT-ROUNDTRIP: append persists"
        );
        let lock_path = storage_path.join("history.lock");
        let lock = open_or_create_secure_file(&lock_path).expect("OBJECT-ROUNDTRIP: lock create");
        let lock_identity = regular_file_identity(&lock).expect("OBJECT-ROUNDTRIP: lock identity");
        drop(lock);
        let reopened_lock =
            open_or_create_secure_file(&lock_path).expect("OBJECT-ROUNDTRIP: lock reopen");
        check!(
            regular_file_identity(&reopened_lock).expect("OBJECT-ROUNDTRIP: lock identity after")
                == lock_identity,
            "OBJECT-ROUNDTRIP: lock identity stable"
        );
        drop(reopened_lock);
        drop(reopened);
    }
    #[test]
    fn secure_lock_preserves_one_identity_and_blocks_delete_until_handles_drop() {
        let workspace = SecureWorkspace::create().expect("LOCK-NO-DELETE: workspace");
        let storage_path = &workspace.path;
        let lock_path = storage_path.join("history.lock");
        let renamed_path = storage_path.join("history.lock.renamed");
        let first = open_secure_lock_file(&lock_path).expect("LOCK-NO-DELETE: first lock");
        let identity = regular_file_identity(&first).expect("LOCK-NO-DELETE: identity");
        let second = open_windows_path_with_share(
            &lock_path,
            GENERIC_READ | GENERIC_WRITE | STORAGE_SECURITY_ACCESS,
            OPEN_EXISTING,
            StorageObjectKind::RegularFile.open_flags(),
            VALIDATION_SHARE_MODE,
        )
        .expect("LOCK-NO-DELETE: second handle");
        check!(
            regular_file_identity(&second).expect("LOCK-NO-DELETE: second identity") == identity,
            "LOCK-NO-DELETE: identity stable"
        );
        fs2::FileExt::try_lock_exclusive(&second).expect_err("LOCK-NO-DELETE: second lock blocked");
        fs::rename(&lock_path, &renamed_path).expect_err("LOCK-NO-DELETE: rename blocked");
        fs::remove_file(&lock_path).expect_err("LOCK-NO-DELETE: delete blocked");
        fs2::FileExt::unlock(&first).expect("LOCK-NO-DELETE: unlock");
        drop(second);
        drop(first);
        fs::rename(&lock_path, &renamed_path).expect("LOCK-NO-DELETE: rename after drop");
        let renamed =
            open_existing_secure_file(&renamed_path, false).expect("LOCK-NO-DELETE: renamed open");
        check!(
            regular_file_identity(&renamed).expect("LOCK-NO-DELETE: renamed identity") == identity,
            "LOCK-NO-DELETE: renamed identity stable"
        );
        drop(renamed);
    }
    #[test]
    fn replace_success_and_precommit_failure_preserve_boundaries() {
        for (present, label) in [(true, "REPLACE-SUCCESS"), (false, "REPLACE-ABSENT")] {
            replace_success_case(present, label).expect("REPLACE-SUCCESS: replacement");
        }
        replace_precommit_failure_case().expect("REPLACE-PRECOMMIT: scenario");
    }
    #[test]
    fn replace_validation_type_reparse_and_path_boundaries_preserve_objects() {
        let workspace = SecureWorkspace::create().expect("REPLACE-VALIDATION: workspace");
        let (root, directory) = (&workspace.path, &workspace.directory);
        let reject = |staged: &Path, destination: &Path| {
            replace_secure_file(directory, root, staged, destination)
                .expect_err("REPLACE-VALIDATION: invalid object accepted");
        };
        for (case, staged_permissive, destination_permissive) in [
            ("permissive-destination", false, true),
            ("permissive-staged", true, false),
        ] {
            let staged_path = root.join(format!("{case}.tmp"));
            let destination_path = root.join(format!("{case}.json"));
            let (staged, staged_snapshot) =
                file_snapshot_fixture(&staged_path, b"staged", staged_permissive)
                    .expect("REPLACE-VALIDATION: staged fixture");
            let (destination, destination_snapshot) =
                file_snapshot_fixture(&destination_path, b"last-good", destination_permissive)
                    .expect("REPLACE-VALIDATION: destination fixture");
            reject(&staged_path, &destination_path);
            assert_path_snapshots([
                (
                    &staged_path,
                    &staged_snapshot,
                    "REPLACE-VALIDATION/staged path",
                ),
                (
                    &destination_path,
                    &destination_snapshot,
                    "REPLACE-VALIDATION/destination path",
                ),
            ]);
        }
        let fixture = |path: &Path, directory: bool, marker: &[u8]| {
            if directory {
                let file =
                    ensure_secure_storage_directory(path).expect("REPLACE-WRONG-TYPE: directory");
                let marker_path = path.join("marker.bin");
                fs::write(&marker_path, marker).expect("REPLACE-WRONG-TYPE: marker");
                (file, Some(marker_path))
            } else {
                (
                    create_new_secure_file(path).expect("REPLACE-WRONG-TYPE: file"),
                    None,
                )
            }
        };
        let check_object = |path: &Path, marker: &Option<PathBuf>, expected: &[u8], label: &str| {
            if let Some(marker) = marker {
                check!(fs::read(marker).expect(label) == expected, "{label}");
            } else {
                check!(path.exists(), "{label}");
            }
        };
        for (case, staged_directory, destination_directory) in [
            ("directory-staged", true, false),
            ("directory-destination", false, true),
        ] {
            let staged_path = root.join(format!("{case}.tmp"));
            let destination_path = root.join(format!("{case}.json"));
            let (staged, staged_marker) = fixture(&staged_path, staged_directory, b"staged marker");
            let (destination, destination_marker) = fixture(
                &destination_path,
                destination_directory,
                b"destination marker",
            );
            reject(&staged_path, &destination_path);
            check_object(
                &staged_path,
                &staged_marker,
                b"staged marker",
                "REPLACE-WRONG-TYPE/staged",
            );
            check_object(
                &destination_path,
                &destination_marker,
                b"destination marker",
                "REPLACE-WRONG-TYPE/destination",
            );
            drop(destination);
            drop(staged);
        }
        for (case, link_is_staged) in [("destination-link", false), ("staged-link", true)] {
            let target_path = root.join(format!("{case}-target.json"));
            let link_path = root.join(format!("{case}-link.json"));
            let regular_path = root.join(format!("{case}-regular.json"));
            let (target, target_snapshot) =
                file_snapshot_fixture(&target_path, b"reparse target", false)
                    .expect("REPLACE-FINAL-REPARSE: target");
            let (regular, regular_snapshot) =
                file_snapshot_fixture(&regular_path, b"last-good", false)
                    .expect("REPLACE-FINAL-REPARSE: regular");
            drop(target);
            drop(regular);
            let (staged_path, destination_path) = if link_is_staged {
                (&link_path, &regular_path)
            } else {
                (&regular_path, &link_path)
            };
            reject_replace_reparse(
                directory,
                root,
                &target_path,
                &target_snapshot,
                &link_path,
                &regular_path,
                &regular_snapshot,
                staged_path,
                destination_path,
                &format!("REPLACE-FINAL-REPARSE/{case}: link unchanged"),
            );
        }
        let other = workspace.root.path.join("other-storage");
        let _other_directory = ensure_secure_storage_directory(&other)
            .expect("REPLACE-PATH-BOUNDARY: other directory");
        let cross_staged = other.join("cross.tmp");
        let local_destination = root.join("cross-destination.json");
        let (cross_file, cross_snapshot) =
            file_snapshot_fixture(&cross_staged, b"cross staged", false)
                .expect("REPLACE-PATH-BOUNDARY: cross staged");
        let (destination_file, destination_snapshot) =
            file_snapshot_fixture(&local_destination, b"last-good", false)
                .expect("REPLACE-PATH-BOUNDARY: destination");
        let local_staged = root.join("local-staged.tmp");
        let cross_destination = other.join("cross-destination.json");
        let (local_file, local_snapshot) =
            file_snapshot_fixture(&local_staged, b"local staged", false)
                .expect("REPLACE-PATH-BOUNDARY: local staged");
        let (remote_file, remote_snapshot) =
            file_snapshot_fixture(&cross_destination, b"remote", false)
                .expect("REPLACE-PATH-BOUNDARY: remote destination");
        for (staged, staged_snapshot, destination, destination_snapshot, label) in [
            (
                &cross_staged,
                &cross_snapshot,
                &local_destination,
                &destination_snapshot,
                "REPLACE-PATH-BOUNDARY/cross-source",
            ),
            (
                &local_staged,
                &local_snapshot,
                &cross_destination,
                &remote_snapshot,
                "REPLACE-PATH-BOUNDARY/cross-destination",
            ),
        ] {
            reject(staged, destination);
            assert_snapshot(staged, staged_snapshot, label);
            assert_snapshot(destination, destination_snapshot, label);
        }
        replace_secure_file(directory, root, &local_staged, &local_staged)
            .expect_err("REPLACE-PATH-BOUNDARY: same path accepted");
        check!(
            validate_replace_paths(root, Path::new(""), &local_destination).is_err(),
            "REPLACE-PATH-BOUNDARY: missing filename rejected"
        );
        let same_identity = root.join("same-identity.json");
        fs::hard_link(&local_staged, &same_identity).expect("REPLACE-PATH-BOUNDARY: hard link");
        replace_secure_file(directory, root, &local_staged, &same_identity)
            .expect_err("REPLACE-PATH-BOUNDARY: same identity accepted");
        assert_snapshot(
            &local_staged,
            &local_snapshot,
            "REPLACE-PATH-BOUNDARY/same-identity staged",
        );
        assert_snapshot(
            &same_identity,
            &local_snapshot,
            "REPLACE-PATH-BOUNDARY/same-identity destination",
        );
    }
    #[test]
    fn injected_post_replace_identity_mismatch_is_detected() {
        let workspace = SecureWorkspace::create().expect("REPLACE-POSTCOMMIT: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let staged = storage_path.join("staged.tmp");
        let destination = storage_path.join("history.json");
        let alternate = storage_path.join("alternate.tmp");
        let displaced = storage_path.join("displaced.json");
        let (staged_file, staged_identity) =
            create_secure_test_file(&staged, b"expected").expect("REPLACE-POSTCOMMIT: staged");
        let staged_snapshot = snapshot_object(&staged_file, StorageObjectKind::RegularFile)
            .expect("REPLACE-POSTCOMMIT: staged snapshot");
        let (destination_file, _) =
            create_secure_test_file(&destination, b"old").expect("REPLACE-POSTCOMMIT: destination");
        let (alternate_file, alternate_identity) =
            create_secure_test_file(&alternate, b"unexpected")
                .expect("REPLACE-POSTCOMMIT: alternate");
        drop(staged_file);
        drop(destination_file);
        drop(alternate_file);
        replace_secure_file_with(
            &directory,
            &storage_path,
            &staged,
            &destination,
            |staged, destination| {
                tokscale_core::fs_atomic::replace_file(staged, &displaced)?;
                tokscale_core::fs_atomic::replace_file(&alternate, destination)
            },
        )
        .expect_err("REPLACE-POSTCOMMIT: identity mismatch returned");
        let installed = snapshot_path(&destination, StorageObjectKind::RegularFile)
            .expect("REPLACE-POSTCOMMIT: installed snapshot");
        check!(
            installed.bytes == b"unexpected",
            "REPLACE-POSTCOMMIT: alternate bytes installed"
        );
        check!(
            installed.identity == alternate_identity && installed.identity != staged_identity,
            "REPLACE-POSTCOMMIT: alternate identity detected"
        );
        assert_snapshot(&displaced, &staged_snapshot, "REPLACE-POSTCOMMIT/displaced");
        assert_absent(&staged, "REPLACE-POSTCOMMIT/staged pathname");
    }
    #[test]
    fn secure_quarantine_candidate_preserves_bytes_dacl_identity_and_flushes_directory() {
        let workspace = SecureWorkspace::create().expect("QUARANTINE-SUCCESS: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let source = storage_path.join("history.json");
        let candidate = storage_path.join("history.corrupt-1.json");
        let (source_file, source_snapshot) =
            file_snapshot_fixture(&source, b"corrupt bytes", false)
                .expect("QUARANTINE-SUCCESS: source");
        quarantine_secure_file_candidate(&directory, &storage_path, &source, &candidate)
            .expect("QUARANTINE-SUCCESS: commit and flush");
        assert_absent(&source, "QUARANTINE-SUCCESS/source");
        assert_snapshot(&candidate, &source_snapshot, "QUARANTINE-SUCCESS/candidate");
    }
    #[test]
    fn secure_quarantine_existing_candidate_collision_preserves_both_files() {
        let workspace = SecureWorkspace::create().expect("QUARANTINE-LINK-FAILURE: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let source = storage_path.join("account.json");
        let candidate = storage_path.join("account.corrupt-1.json");
        let (source_file, source_snapshot) = file_snapshot_fixture(&source, b"source", false)
            .expect("QUARANTINE-LINK-FAILURE: source");
        let (candidate_file, candidate_snapshot) =
            file_snapshot_fixture(&candidate, b"existing", false)
                .expect("QUARANTINE-LINK-FAILURE: candidate");
        drop(candidate_file);
        drop(source_file);
        let error =
            quarantine_secure_file_candidate(&directory, &storage_path, &source, &candidate)
                .expect_err("QUARANTINE-LINK-FAILURE: collision returned");
        check!(
            error.kind() == io::ErrorKind::AlreadyExists,
            "QUARANTINE-LINK-FAILURE: native collision kind"
        );
        assert_path_snapshots([
            (
                &source,
                &source_snapshot,
                "QUARANTINE-LINK-FAILURE/native/source",
            ),
            (
                &candidate,
                &candidate_snapshot,
                "QUARANTINE-LINK-FAILURE/native/candidate",
            ),
        ]);
        let source2 = storage_path.join("generic-source.json");
        let candidate2 = storage_path.join("generic-candidate.json");
        let (source2_file, source2_snapshot) =
            file_snapshot_fixture(&source2, b"source two", false)
                .expect("QUARANTINE-LINK-FAILURE: generic source");
        let (candidate2_file, candidate2_snapshot) =
            file_snapshot_fixture(&candidate2, b"candidate two", false)
                .expect("QUARANTINE-LINK-FAILURE: generic candidate");
        let mut unlink_called = false;
        let mut flush_called = false;
        quarantine_secure_file_candidate_with(
            &directory,
            &storage_path,
            &source2,
            &candidate2,
            |_, _| Err(io::Error::other("generic hard-link failure")),
            |_| {
                unlink_called = true;
                Err(io::Error::other("unexpected unlink"))
            },
            |_| {
                flush_called = true;
                Ok(())
            },
        )
        .expect_err("QUARANTINE-LINK-FAILURE: generic link error returned");
        check!(
            !unlink_called,
            "QUARANTINE-LINK-FAILURE: link error does not unlink"
        );
        check!(
            !flush_called,
            "QUARANTINE-LINK-FAILURE: link error does not flush"
        );
        assert_path_snapshots([
            (
                &source2,
                &source2_snapshot,
                "QUARANTINE-LINK-FAILURE/generic/source",
            ),
            (
                &candidate2,
                &candidate2_snapshot,
                "QUARANTINE-LINK-FAILURE/generic/candidate",
            ),
        ]);
    }
    #[test]
    fn secure_quarantine_reparse_and_directory_collisions_touch_no_targets() {
        let workspace =
            SecureWorkspace::create().expect("QUARANTINE-CANDIDATE-COLLISION: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let source = storage_path.join("source.json");
        let candidate = storage_path.join("candidate.json");
        let target = storage_path.join("target.json");
        let (source_file, source_snapshot) = file_snapshot_fixture(&source, b"source", false)
            .expect("QUARANTINE-CANDIDATE-COLLISION: source");
        let (target_file, target_snapshot) = file_snapshot_fixture(&target, b"target", false)
            .expect("QUARANTINE-CANDIDATE-COLLISION: target");
        symlink_file(&target, &candidate)
            .expect("QUARANTINE-CANDIDATE-COLLISION: symlink candidate");
        quarantine_secure_file_candidate(&directory, &storage_path, &source, &candidate)
            .expect_err("QUARANTINE-CANDIDATE-COLLISION: symlink rejected");
        check!(
            fs::symlink_metadata(&candidate)
                .expect("QUARANTINE-CANDIDATE-COLLISION: symlink remains")
                .file_type()
                .is_symlink(),
            "QUARANTINE-CANDIDATE-COLLISION: symlink unchanged"
        );
        assert_snapshot(
            &source,
            &source_snapshot,
            "QUARANTINE-CANDIDATE-COLLISION/symlink source",
        );
        assert_snapshot(
            &target,
            &target_snapshot,
            "QUARANTINE-CANDIDATE-COLLISION/symlink target",
        );
        fs::remove_file(&candidate).expect("QUARANTINE-CANDIDATE-COLLISION: remove symlink");
        let directory_source = storage_path.join("directory-source.json");
        let directory_candidate = storage_path.join("directory-candidate");
        let marker = directory_candidate.join("marker.bin");
        let (source_file, _) = create_secure_test_file(&directory_source, b"directory source")
            .expect("QUARANTINE-CANDIDATE-COLLISION: directory source");
        let source_snapshot = snapshot_object(&source_file, StorageObjectKind::RegularFile)
            .expect("QUARANTINE-CANDIDATE-COLLISION: directory source snapshot");
        let candidate_directory = ensure_secure_storage_directory(&directory_candidate)
            .expect("QUARANTINE-CANDIDATE-COLLISION: candidate directory");
        let candidate_identity = storage_identity(
            candidate_directory.as_raw_handle() as HANDLE,
            StorageObjectKind::Directory,
        )
        .expect("QUARANTINE-CANDIDATE-COLLISION: candidate identity");
        let candidate_acl = read_acl_snapshot(candidate_directory.as_raw_handle() as HANDLE)
            .expect("QUARANTINE-CANDIDATE-COLLISION: candidate DACL");
        fs::write(&marker, b"marker").expect("QUARANTINE-CANDIDATE-COLLISION: marker");
        drop(source_file);
        quarantine_secure_file_candidate(
            &directory,
            &storage_path,
            &directory_source,
            &directory_candidate,
        )
        .expect_err("QUARANTINE-CANDIDATE-COLLISION: directory rejected");
        assert_snapshot(
            &directory_source,
            &source_snapshot,
            "QUARANTINE-CANDIDATE-COLLISION/directory source",
        );
        verify_path_identity(
            &directory_candidate,
            StorageObjectKind::Directory,
            candidate_identity,
        )
        .expect("QUARANTINE-CANDIDATE-COLLISION: directory identity");
        check!(
            read_acl_snapshot(candidate_directory.as_raw_handle() as HANDLE)
                .expect("QUARANTINE-CANDIDATE-COLLISION: directory DACL after")
                == candidate_acl,
            "QUARANTINE-CANDIDATE-COLLISION: directory DACL unchanged"
        );
        check!(
            fs::read(&marker).expect("QUARANTINE-CANDIDATE-COLLISION: marker after") == b"marker",
            "QUARANTINE-CANDIDATE-COLLISION: marker unchanged"
        );
    }
    #[test]
    fn quarantine_fault_phases_preserve_commit_boundaries() {
        let workspace = SecureWorkspace::create().expect("QUARANTINE-FAULTS: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let source = storage_path.join("history.json");
        let candidate = storage_path.join("history.corrupt-2.json");
        let (source_file, source_snapshot) = create_secure_test_file(&source, b"source bytes")
            .map(|(file, _)| (file, ()))
            .expect("QUARANTINE-ROLLBACK: source");
        let source_snapshot = snapshot_object(&source_file, StorageObjectKind::RegularFile)
            .expect("QUARANTINE-ROLLBACK: snapshot");
        drop(source_file);
        let mut flush_called = false;
        quarantine_secure_file_candidate_with(
            directory,
            storage_path,
            &source,
            &candidate,
            |source, candidate| fs::hard_link(source, candidate),
            |path| {
                if path == source.as_path() {
                    Err(io::Error::other("injected source unlink failure"))
                } else {
                    fs::remove_file(path)
                }
            },
            |_| {
                flush_called = true;
                Ok(())
            },
        )
        .expect_err("QUARANTINE-ROLLBACK: unlink failure returned");
        check!(
            !flush_called,
            "QUARANTINE-ROLLBACK: rollback does not flush"
        );
        assert_absent(&candidate, "QUARANTINE-ROLLBACK/candidate");
        assert_snapshot(&source, &source_snapshot, "QUARANTINE-ROLLBACK/source");

        let source = storage_path.join("account.json");
        let candidate = storage_path.join("account.corrupt-2.json");
        let (source_file, _) =
            create_secure_test_file(&source, b"source evidence").expect("QUARANTINE-SWAP: source");
        let source_snapshot = snapshot_object(&source_file, StorageObjectKind::RegularFile)
            .expect("QUARANTINE-SWAP: source snapshot");
        drop(source_file);
        let mut replacement_snapshot = None;
        quarantine_secure_file_candidate_with(
            directory,
            storage_path,
            &source,
            &candidate,
            |source, candidate| fs::hard_link(source, candidate),
            |path| {
                if path == source.as_path() {
                    fs::remove_file(&candidate)?;
                    let (replacement, _) =
                        create_secure_test_file(&candidate, b"unrelated candidate")?;
                    replacement_snapshot = Some(snapshot_object(
                        &replacement,
                        StorageObjectKind::RegularFile,
                    )?);
                    drop(replacement);
                    Err(io::Error::other("injected source unlink failure"))
                } else {
                    panic!("QUARANTINE-SWAP: rollback targeted unrelated candidate")
                }
            },
            |_| panic!("QUARANTINE-SWAP: identity mismatch must not flush"),
        )
        .expect_err("QUARANTINE-SWAP: candidate identity mismatch returned");
        assert_snapshot(&source, &source_snapshot, "QUARANTINE-SWAP/source");
        assert_snapshot(
            &candidate,
            &replacement_snapshot.expect("QUARANTINE-SWAP: replacement snapshot"),
            "QUARANTINE-SWAP/candidate",
        );
    }
    #[test]
    fn quarantine_source_and_path_validation_rejects_without_touching_targets() {
        let workspace = SecureWorkspace::create().expect("QUARANTINE-VALIDATION: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let reject = |source: &Path, candidate: &Path, label: &str| {
            quarantine_secure_file_candidate_with(
                directory,
                storage_path,
                source,
                candidate,
                |_, _| panic!("{label}: link called"),
                |_| panic!("{label}: unlink called"),
                |_| panic!("{label}: flush called"),
            )
            .expect_err("QUARANTINE-VALIDATION: unsafe input accepted");
        };
        let permissive_path = storage_path.join("permissive.json");
        let candidate = storage_path.join("permissive.corrupt.json");
        let permissive = create_permissive_test_file(&permissive_path, b"permissive")
            .expect("QUARANTINE-SOURCE-VALIDATION: permissive source");
        let permissive_snapshot = snapshot_object(&permissive, StorageObjectKind::RegularFile)
            .expect("QUARANTINE-SOURCE-VALIDATION: permissive snapshot");
        reject(
            &permissive_path,
            &candidate,
            "QUARANTINE-SOURCE-VALIDATION/permissive",
        );
        assert_generic_error(
            &security_verification_failed(),
            &[&permissive_path.to_string_lossy()],
        );
        assert_handle_snapshot(
            &permissive,
            &permissive_snapshot,
            "QUARANTINE-SOURCE-VALIDATION/permissive",
        );
        assert_absent(
            &candidate,
            "QUARANTINE-SOURCE-VALIDATION/permissive candidate",
        );
        let target = storage_path.join("source-target.json");
        let source_link = storage_path.join("source-link.json");
        let link_candidate = storage_path.join("source-link.corrupt.json");
        let (target_file, _) = create_secure_test_file(&target, b"target")
            .expect("QUARANTINE-SOURCE-VALIDATION: target");
        let target_snapshot = snapshot_object(&target_file, StorageObjectKind::RegularFile)
            .expect("QUARANTINE-SOURCE-VALIDATION: target snapshot");
        drop(target_file);
        symlink_file(&target, &source_link).expect("QUARANTINE-SOURCE-VALIDATION: source symlink");
        reject(
            &source_link,
            &link_candidate,
            "QUARANTINE-SOURCE-VALIDATION/symlink",
        );
        check!(
            fs::symlink_metadata(&source_link)
                .expect("QUARANTINE-SOURCE-VALIDATION: source symlink remains")
                .file_type()
                .is_symlink(),
            "QUARANTINE-SOURCE-VALIDATION: source symlink unchanged"
        );
        assert_snapshot(
            &target,
            &target_snapshot,
            "QUARANTINE-SOURCE-VALIDATION/target",
        );
        assert_absent(
            &link_candidate,
            "QUARANTINE-SOURCE-VALIDATION/symlink candidate",
        );
        fs::remove_file(&source_link).expect("QUARANTINE-SOURCE-VALIDATION: remove source symlink");
        let source_directory_path = storage_path.join("source-directory");
        let directory_candidate = storage_path.join("source-directory.corrupt");
        let marker = source_directory_path.join("marker.bin");
        let source_directory = ensure_secure_storage_directory(&source_directory_path)
            .expect("QUARANTINE-SOURCE-VALIDATION: source directory");
        let directory_identity = storage_identity(
            source_directory.as_raw_handle() as HANDLE,
            StorageObjectKind::Directory,
        )
        .expect("QUARANTINE-SOURCE-VALIDATION: directory identity");
        let directory_acl = read_acl_snapshot(source_directory.as_raw_handle() as HANDLE)
            .expect("QUARANTINE-SOURCE-VALIDATION: directory DACL");
        fs::write(&marker, b"marker").expect("QUARANTINE-SOURCE-VALIDATION: directory marker");
        reject(
            &source_directory_path,
            &directory_candidate,
            "QUARANTINE-SOURCE-VALIDATION/directory",
        );
        verify_path_identity(
            &source_directory_path,
            StorageObjectKind::Directory,
            directory_identity,
        )
        .expect("QUARANTINE-SOURCE-VALIDATION: directory remains");
        check!(
            read_acl_snapshot(source_directory.as_raw_handle() as HANDLE)
                .expect("QUARANTINE-SOURCE-VALIDATION: directory DACL after")
                == directory_acl,
            "QUARANTINE-SOURCE-VALIDATION: directory DACL unchanged"
        );
        check!(
            fs::read(&marker).expect("QUARANTINE-SOURCE-VALIDATION: marker after") == b"marker",
            "QUARANTINE-SOURCE-VALIDATION: marker unchanged"
        );
        assert_absent(
            &directory_candidate,
            "QUARANTINE-SOURCE-VALIDATION/directory candidate",
        );
        let other = workspace.root.path.join("other-storage");
        let _other_directory = ensure_secure_storage_directory(&other)
            .expect("QUARANTINE-PATH-BOUNDARY: other directory");
        let local_source = storage_path.join("local.json");
        let cross_source = other.join("cross.json");
        let (local_file, _) = create_secure_test_file(&local_source, b"local")
            .expect("QUARANTINE-PATH-BOUNDARY: local source");
        let local_snapshot = snapshot_object(&local_file, StorageObjectKind::RegularFile)
            .expect("QUARANTINE-PATH-BOUNDARY: local snapshot");
        let (cross_file, _) = create_secure_test_file(&cross_source, b"cross")
            .expect("QUARANTINE-PATH-BOUNDARY: cross source");
        let cross_snapshot = snapshot_object(&cross_file, StorageObjectKind::RegularFile)
            .expect("QUARANTINE-PATH-BOUNDARY: cross snapshot");
        let local_candidate = storage_path.join("local.corrupt");
        let cross_candidate = other.join("local.corrupt");
        let mismatch_candidate = other.join("mismatch.corrupt");
        for (source, candidate, dir, label) in [
            (
                cross_source.as_path(),
                local_candidate.as_path(),
                storage_path.as_path(),
                "QUARANTINE-PATH-BOUNDARY/cross source",
            ),
            (
                local_source.as_path(),
                cross_candidate.as_path(),
                storage_path.as_path(),
                "QUARANTINE-PATH-BOUNDARY/cross candidate",
            ),
            (
                local_source.as_path(),
                local_source.as_path(),
                storage_path.as_path(),
                "QUARANTINE-PATH-BOUNDARY/same path",
            ),
            (
                Path::new(""),
                local_candidate.as_path(),
                storage_path.as_path(),
                "QUARANTINE-PATH-BOUNDARY/missing source",
            ),
            (
                cross_source.as_path(),
                mismatch_candidate.as_path(),
                other.as_path(),
                "QUARANTINE-PATH-BOUNDARY/directory mismatch",
            ),
        ] {
            reject(source, candidate, label);
        }
        assert_snapshot(
            &cross_source,
            &cross_snapshot,
            "QUARANTINE-PATH-BOUNDARY/cross source",
        );
        assert_snapshot(
            &local_source,
            &local_snapshot,
            "QUARANTINE-PATH-BOUNDARY/local source",
        );
        assert_absent(&local_candidate, "QUARANTINE-PATH-BOUNDARY/local candidate");
    }
    #[test]
    fn post_unlink_flush_failure_returns_error_without_false_rollback() {
        let workspace = SecureWorkspace::create().expect("QUARANTINE-POSTCOMMIT: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let source = storage_path.join("history.json");
        let candidate = storage_path.join("history.corrupt-3.json");
        let (source_file, _) = create_secure_test_file(&source, b"committed bytes")
            .expect("QUARANTINE-POSTCOMMIT: source");
        let source_snapshot = snapshot_object(&source_file, StorageObjectKind::RegularFile)
            .expect("QUARANTINE-POSTCOMMIT: source snapshot");
        drop(source_file);
        quarantine_secure_file_candidate_with(
            &directory,
            &storage_path,
            &source,
            &candidate,
            |source, candidate| fs::hard_link(source, candidate),
            |path| fs::remove_file(path),
            |_| Err(io::Error::other("injected directory flush failure")),
        )
        .expect_err("QUARANTINE-POSTCOMMIT: flush failure returned");
        assert_absent(&source, "QUARANTINE-POSTCOMMIT/source");
        assert_snapshot(
            &candidate,
            &source_snapshot,
            "QUARANTINE-POSTCOMMIT/candidate",
        );
    }
    #[test]
    fn existing_permissive_file_and_directory_are_rejected_without_repair() {
        let workspace = SecureWorkspace::create().expect("OPEN-NO-REPAIR: workspace");
        let file_path = workspace.path.join("legacy.json");
        let mut file =
            create_permissive_test_file(&file_path, b"legacy").expect("OPEN-NO-REPAIR: file");
        let file_before = snapshot_object(&file, StorageObjectKind::RegularFile)
            .expect("OPEN-NO-REPAIR: snapshot");
        open_existing_secure_file(&file_path, false)
            .expect_err("OPEN-NO-REPAIR: permissive rejected");
        assert_handle_snapshot(&file, &file_before, "OPEN-NO-REPAIR/rejected");
        file.seek(SeekFrom::End(0))
            .expect("OPEN-NO-REPAIR: retained seek");
        file.write_all(b"!")
            .expect("OPEN-NO-REPAIR: retained write");
        file.sync_all().expect("OPEN-NO-REPAIR: retained sync");
        check!(
            fs::read(&file_path).expect("OPEN-NO-REPAIR: read") == b"legacy!",
            "OPEN-NO-REPAIR: retained access remains"
        );
        let directory_path = workspace.root.path.join("legacy-storage");
        let directory = create_permissive_test_directory(&directory_path)
            .expect("OPEN-DIR-NO-REPAIR: directory");
        let directory_before = snapshot_object(&directory, StorageObjectKind::Directory)
            .expect("OPEN-DIR-NO-REPAIR: snapshot");
        ensure_secure_storage_directory(&directory_path)
            .expect_err("OPEN-DIR-NO-REPAIR: permissive rejected");
        assert_handle_snapshot(&directory, &directory_before, "OPEN-DIR-NO-REPAIR/rejected");
    }
    #[test]
    fn final_file_symlink_and_directory_junction_fail_without_touching_targets() {
        let workspace = SecureWorkspace::create().expect("FINAL-NO-REPARSE: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        let file_target_path = storage_path.join("file-target.json");
        let file_link = storage_path.join("file-link.json");
        let file_target = create_permissive_test_file(&file_target_path, b"target file")
            .expect("FINAL-NO-REPARSE: file target");
        let file_snapshot = snapshot_object(&file_target, StorageObjectKind::RegularFile)
            .expect("FINAL-NO-REPARSE: file snapshot");
        symlink_file(&file_target_path, &file_link).expect("FINAL-NO-REPARSE: file link");
        check!(
            open_existing_secure_file(&file_link, false).is_err(),
            "FINAL-NO-REPARSE: final file symlink rejected"
        );
        assert_handle_snapshot(&file_target, &file_snapshot, "FINAL-NO-REPARSE/file target");
        fs::remove_file(&file_link).expect("FINAL-NO-REPARSE: remove file link");
        let directory_target_path = storage_path.join("directory-target");
        let junction_path = storage_path.join("directory-junction");
        let directory_target = create_permissive_test_directory(&directory_target_path)
            .expect("FINAL-NO-REPARSE: directory target");
        let marker = directory_target_path.join("marker.bin");
        fs::write(&marker, b"target directory").expect("FINAL-NO-REPARSE: marker");
        let directory_snapshot = snapshot_object(&directory_target, StorageObjectKind::Directory)
            .expect("FINAL-NO-REPARSE: directory snapshot");
        create_junction(&junction_path, &directory_target_path)
            .expect("FINAL-NO-REPARSE: junction");
        check!(
            ensure_secure_storage_directory(&junction_path).is_err(),
            "FINAL-NO-REPARSE: final junction rejected"
        );
        assert_handle_snapshot(
            &directory_target,
            &directory_snapshot,
            "FINAL-NO-REPARSE/directory target",
        );
        check!(
            fs::read(&marker).expect("FINAL-NO-REPARSE: marker after") == b"target directory",
            "FINAL-NO-REPARSE: marker unchanged"
        );
        fs::remove_dir(&junction_path).expect("FINAL-NO-REPARSE: remove junction");
    }
    #[test]
    fn ancestor_junction_resolves_to_real_final_objects_with_matching_identity() {
        let root = TempRoot::create().expect("ANCESTOR-REPARSE-ALLOWED: root");
        let real_parent = root.path.join("real-parent");
        fs::create_dir(&real_parent).expect("ANCESTOR-REPARSE-ALLOWED: real parent");
        let junction_parent = root.path.join("junction-parent");
        create_junction(&junction_parent, &real_parent)
            .expect("ANCESTOR-REPARSE-ALLOWED: junction");
        let via = junction_parent.join("storage");
        let physical = real_parent.join("storage");
        let directory = ensure_secure_storage_directory(&via)
            .expect("ANCESTOR-REPARSE-ALLOWED: final directory");
        let physical_directory = open_windows_path(
            &physical,
            FILE_READ_ATTRIBUTES | READ_CONTROL,
            OPEN_EXISTING,
            StorageObjectKind::Directory.open_flags(),
        )
        .expect("ANCESTOR-REPARSE-ALLOWED: physical directory");
        check!(
            storage_identity(
                directory.as_raw_handle() as HANDLE,
                StorageObjectKind::Directory
            )
            .expect("ANCESTOR-REPARSE-ALLOWED: via identity")
                == storage_identity(
                    physical_directory.as_raw_handle() as HANDLE,
                    StorageObjectKind::Directory
                )
                .expect("ANCESTOR-REPARSE-ALLOWED: physical identity"),
            "ANCESTOR-REPARSE-ALLOWED: directory identity"
        );
        let via_file = via.join("history.json");
        let physical_file = physical.join("history.json");
        let mut file =
            create_new_secure_file(&via_file).expect("ANCESTOR-REPARSE-ALLOWED: via file");
        file.write_all(b"junction bytes")
            .expect("ANCESTOR-REPARSE-ALLOWED: write");
        file.sync_all().expect("ANCESTOR-REPARSE-ALLOWED: sync");
        let physical_file_handle = open_windows_path(
            &physical_file,
            GENERIC_READ | FILE_READ_ATTRIBUTES | READ_CONTROL,
            OPEN_EXISTING,
            StorageObjectKind::RegularFile.open_flags(),
        )
        .expect("ANCESTOR-REPARSE-ALLOWED: physical file");
        check!(
            regular_file_identity(&file).expect("ANCESTOR-REPARSE-ALLOWED: via file identity")
                == regular_file_identity(&physical_file_handle)
                    .expect("ANCESTOR-REPARSE-ALLOWED: physical file identity"),
            "ANCESTOR-REPARSE-ALLOWED: file identity"
        );
        let mut physical_file_handle = physical_file_handle;
        check!(
            read_open_file(&mut physical_file_handle)
                .expect("ANCESTOR-REPARSE-ALLOWED: physical bytes")
                == b"junction bytes",
            "ANCESTOR-REPARSE-ALLOWED: physical bytes"
        );
        drop(physical_file_handle);
        drop(file);
        drop(physical_directory);
        drop(directory);
        fs::remove_dir(&junction_parent).expect("ANCESTOR-REPARSE-ALLOWED: remove junction");
    }
    #[test]
    fn validation_handle_blocks_replacement_until_identity_check_finishes() {
        let workspace = SecureWorkspace::create().expect("VALIDATION-BARRIER: workspace");
        let storage_path = &workspace.path;
        let live = storage_path.join("history.json");
        let replacement = storage_path.join("replacement.json");
        let detached = storage_path.join("detached.json");
        let original = create_new_secure_file(&live).expect("VALIDATION-BARRIER: original");
        let identity = storage_identity(
            original.as_raw_handle() as HANDLE,
            StorageObjectKind::RegularFile,
        )
        .expect("VALIDATION-BARRIER: identity");
        drop(create_new_secure_file(&replacement).expect("VALIDATION-BARRIER: replacement"));
        verify_path_identity_with(&live, StorageObjectKind::RegularFile, identity, |_| {
            check!(
                OpenOptions::new()
                    .access_mode(DELETE)
                    .share_mode(STORAGE_SHARE_MODE)
                    .open(&live)
                    .is_err(),
                "VALIDATION-BARRIER: delete open blocked"
            );
            let output = Command::new("cmd")
                .args(["/D", "/C", "move", "/Y"])
                .arg(&live)
                .arg(&detached)
                .output()?;
            check!(
                !output.status.success(),
                "VALIDATION-BARRIER: detach blocked"
            );
            check!(live.exists(), "VALIDATION-BARRIER: live pathname remains");
            assert_absent(&detached, "VALIDATION-BARRIER/detached");
            Ok(())
        })
        .expect("VALIDATION-BARRIER: identity check");
        let output = Command::new("cmd")
            .args(["/D", "/C", "move", "/Y"])
            .arg(&live)
            .arg(&detached)
            .output()
            .expect("VALIDATION-BARRIER: detach after");
        check!(
            output.status.success(),
            "VALIDATION-BARRIER: detach after close"
        );
        fs::rename(&replacement, &live).expect("VALIDATION-BARRIER: install replacement");
    }
    #[test]
    fn path_replacement_is_detected_without_rewriting_either_file() {
        let workspace = SecureWorkspace::create().expect("PATH-REPLACEMENT: workspace");
        let storage_path = &workspace.path;
        let live = storage_path.join("history.json");
        let replacement = storage_path.join("replacement.json");
        let detached = storage_path.join("detached.json");
        let mut original = create_new_secure_file(&live).expect("PATH-REPLACEMENT: original");
        original
            .write_all(b"old bytes")
            .expect("PATH-REPLACEMENT: old bytes");
        original.sync_all().expect("PATH-REPLACEMENT: old sync");
        let original_identity =
            regular_file_identity(&original).expect("PATH-REPLACEMENT: original identity");
        let mut replacement_file =
            create_new_secure_file(&replacement).expect("PATH-REPLACEMENT: replacement");
        replacement_file
            .write_all(b"new bytes")
            .expect("PATH-REPLACEMENT: new bytes");
        replacement_file
            .sync_all()
            .expect("PATH-REPLACEMENT: new sync");
        let replacement_identity = regular_file_identity(&replacement_file)
            .expect("PATH-REPLACEMENT: replacement identity");
        check!(
            original_identity != replacement_identity,
            "PATH-REPLACEMENT: identities distinct"
        );
        drop(replacement_file);
        fs::rename(&live, &detached).expect("PATH-REPLACEMENT: detach");
        fs::rename(&replacement, &live).expect("PATH-REPLACEMENT: install");
        check!(
            verify_secure_file_path(&original, &live).is_err(),
            "PATH-REPLACEMENT: identity swap detected"
        );
        check!(
            read_open_file(&mut original).expect("PATH-REPLACEMENT: old handle") == b"old bytes",
            "PATH-REPLACEMENT: old bytes unchanged"
        );
        check!(
            fs::read(&live).expect("PATH-REPLACEMENT: new path") == b"new bytes",
            "PATH-REPLACEMENT: new bytes unchanged"
        );
        drop(original);
    }
    #[test]
    fn file_and_directory_helpers_reject_the_wrong_object_type() {
        let root = TempRoot::create().expect("TYPE-MATRIX: root");
        let directory_path = root.path.join("permissive-directory");
        let directory =
            create_permissive_test_directory(&directory_path).expect("TYPE-MATRIX: directory");
        let directory_snapshot = snapshot_object(&directory, StorageObjectKind::Directory)
            .expect("TYPE-MATRIX: directory snapshot");
        check!(
            open_existing_secure_file(&directory_path, false).is_err(),
            "TYPE-MATRIX: file helper rejects directory"
        );
        assert_handle_snapshot(&directory, &directory_snapshot, "TYPE-MATRIX/directory");
        let file_path = root.path.join("permissive-file");
        let file = create_permissive_test_file(&file_path, b"bytes").expect("TYPE-MATRIX: file");
        let file_snapshot = snapshot_object(&file, StorageObjectKind::RegularFile)
            .expect("TYPE-MATRIX: file snapshot");
        check!(
            ensure_secure_storage_directory(&file_path).is_err(),
            "TYPE-MATRIX: directory helper rejects file"
        );
        assert_handle_snapshot(&file, &file_snapshot, "TYPE-MATRIX/file");
    }
    #[test]
    fn device_kernel_object_is_rejected_as_regular_file() {
        let device = open_windows_path(
            Path::new(r"\\.\NUL"),
            GENERIC_READ,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
        )
        .expect("TYPE-MATRIX/DEVICE: open deterministic NUL device");
        check!(
            storage_identity(
                device.as_raw_handle() as HANDLE,
                StorageObjectKind::RegularFile
            )
            .is_err(),
            "TYPE-MATRIX/DEVICE: kernel device rejected as regular file"
        );
    }
    #[test]
    fn security_errors_do_not_disclose_path_sid_or_username() {
        let root = TempRoot::create().expect("ERROR-PRIVACY: root");
        let path = root.path.join("private-storage-object");
        let file = create_permissive_test_file(&path, b"private").expect("ERROR-PRIVACY: file");
        let path_text = path.to_string_lossy().into_owned();
        let current = current_process_user_sid().expect("ERROR-PRIVACY: current SID");
        let sid_text = sid_string(&current).expect("ERROR-PRIVACY: SID text");
        let username = std::env::var("USERNAME").expect("ERROR-PRIVACY: username");
        let secret = "raw-secret-sentinel";
        let path_error =
            ensure_secure_storage_directory(&path).expect_err("ERROR-PRIVACY: wrong type rejected");
        assert_generic_error(&path_error, &[&path_text, &sid_text, &username, secret]);
        let system = well_known_sid(WinLocalSystemSid).expect("ERROR-PRIVACY: system SID");
        let foreign = well_known_sid(WinWorldSid).expect("ERROR-PRIVACY: foreign SID");
        let foreign = if current.as_bytes() != system.as_bytes() {
            &system
        } else {
            &foreign
        };
        let owner_error = inspect_owner(foreign.as_bytes(), current.as_bytes())
            .expect_err("ERROR-PRIVACY: owner rejected");
        assert_generic_error(&owner_error, &[&path_text, &sid_text, &username, secret]);
        drop(file);
    }
    #[test]
    fn directory_flush_and_missing_inputs_fail_closed() {
        let workspace = SecureWorkspace::create().expect("FLUSH-MISSING: workspace");
        let storage_path = &workspace.path;
        let directory = &workspace.directory;
        flush_secure_storage_directory(&directory).expect("FLUSH-MISSING: valid flush");
        check!(
            flush_storage_directory_handle(INVALID_HANDLE_VALUE).is_err(),
            "FLUSH-MISSING: invalid handle rejected"
        );
        check!(
            open_existing_secure_file(&storage_path.join("missing.json"), false).is_err(),
            "FLUSH-MISSING: missing file rejected"
        );
        let missing_parent = workspace.root.path.join("missing-parent");
        check!(
            ensure_secure_storage_directory(&missing_parent.join("storage")).is_err(),
            "FLUSH-MISSING: missing parent rejected"
        );
        assert_absent(&missing_parent, "FLUSH-MISSING/parent");
    }
}
