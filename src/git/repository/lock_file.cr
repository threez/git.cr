require "c/fcntl"

module Git
  # Implements the git lockfile protocol for atomic file writes.
  # Callers yield to a writable IO; on normal block exit the write is committed
  # atomically via rename; on exception the lock file is cleaned up.
  module Repository::LockFile
    # Acquires *path*.lock using O_CREAT | O_EXCL, yields the lock file's IO to
    # the block, then renames *path*.lock → *path* (atomic on POSIX).
    # Raises `LockError` if the lock file already exists (another writer is active).
    # Deletes the lock file if the block raises, then re-raises the exception.
    # The parent directory of *path* must already exist.
    def self.write(path : String, fs : FileSystem = FileSystem::Local.new, & : IO ->) : Nil
      lock_path = path + ".lock"
      fd = LibC.open(lock_path.check_no_null_byte,
        LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL,
        0o666_u32)
      if fd < 0
        if Errno.value == Errno::EEXIST
          raise LockError.new("Unable to create '#{lock_path}': already locked")
        else
          raise ::File::Error.from_errno("Error acquiring lockfile", file: lock_path)
        end
      end

      committed = false
      begin
        io = IO::FileDescriptor.new(fd)
        fd = -1 # io owns the fd from here; avoid double-close in ensure
        yield io
        io.flush
        io.close
        fs.rename(lock_path, path)
        committed = true
      ensure
        LibC.close(fd) if fd >= 0
        fs.delete(lock_path) rescue nil unless committed
      end
    end
  end
end
