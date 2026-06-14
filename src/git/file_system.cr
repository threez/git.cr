module Git
  # Abstract interface for all filesystem interactions in the library.
  #
  # All file and directory operations must go through a `FileSystem` instance
  # rather than calling Crystal's `File`/`Dir` APIs directly. This makes it
  # possible to swap in a `FileSystem::Guarded` that enforces path confinement
  # (protecting against protocol-based path-traversal and symlink-redirect
  # attacks) or a `FileSystem::Local` passthrough for paths that are already
  # trusted.
  #
  # ### Choosing an implementation
  #
  # | Situation | Implementation |
  # |-----------|---------------|
  # | Writing untrusted tree content to a working directory | `FileSystem::Guarded.new(work_dir)` |
  # | Reading/writing inside a known `.git/` directory | `FileSystem::Local.new` |
  #
  # ### Implementing a custom backend
  #
  # Subclass `FileSystem` and provide concrete implementations for every
  # `abstract def`. The `join` helper is non-abstract and delegates to
  # `File.join`; override it only when path joining semantics must differ.
  abstract class FileSystem
    # Returns the absolute root directory this filesystem instance is anchored to.
    abstract def root : String

    # Returns the full contents of *path* as a `String`.
    abstract def read(path : String) : String

    # Returns the lines of *path* as an `Array(String)` (newlines stripped).
    abstract def read_lines(path : String) : Array(String)

    # Writes *content* to *path*, creating or truncating the file.
    abstract def write(path : String, content : String | Bytes) : Nil

    # Opens *path* with *mode* and yields a `FileHandle`. The handle is closed
    # when the block returns. Common modes: `"r"` (read), `"w"` (write/truncate),
    # `"rb"` (read binary), `"wb"` (write binary), `"r+b"` (read-write binary).
    abstract def open(path : String, mode : String, & : FileHandle ->) : Nil

    # Returns `true` if *path* exists (file, directory, or symlink).
    abstract def exists?(path : String) : Bool

    # Returns true if *path* is an existing directory.
    abstract def directory?(path : String) : Bool

    # Returns `true` if *path* is a regular file (not a directory or symlink).
    abstract def file?(path : String) : Bool

    # Returns `true` if *path* is a symbolic link.
    abstract def symlink?(path : String) : Bool

    # Returns the byte size of the file at *path*.
    abstract def size(path : String) : Int64

    # Deletes the file at *path*. Raises if the path does not exist or is a
    # directory.
    abstract def delete(path : String) : Nil

    # Atomically renames *from* to *to*.
    abstract def rename(from : String, to : String) : Nil

    # Sets the permission bits of *path* to *mode* (e.g. `0o755`).
    abstract def chmod(path : String, mode : Int) : Nil

    # Creates a symbolic link at *path* whose target is *target*.
    abstract def symlink(target : String, path : String) : Nil

    # Creates *path* and all missing parent directories (equivalent to
    # `mkdir -p`).
    abstract def mkdir_p(path : String) : Nil

    # Recursively removes *path* and everything inside it (equivalent to
    # `rm -rf`). Silently succeeds when *path* does not exist.
    abstract def rm_rf(path : String) : Nil

    # Removes the empty directory at *path*. Raises if the directory is not
    # empty.
    abstract def rmdir(path : String) : Nil

    # Returns `true` if *path* is a directory that contains no entries other
    # than `.` and `..`.
    abstract def dir_empty?(path : String) : Bool

    # Returns all paths matching the glob *pattern*.
    abstract def glob(pattern : String) : Array(String)

    # Resolves *path* to an absolute path, expanding `.` and `..` components.
    abstract def expand_path(path : String) : String

    # Returns a new filesystem of the same concrete type rooted at `join(*parts)`.
    abstract def chroot(*parts : String) : FileSystem

    # Joins *parts* under this filesystem's root when root is set, otherwise
    # delegates to `File.join` for unrooted (legacy) filesystem instances.
    def join(*parts : String) : String
      r = root
      r.empty? ? File.join(*parts) : File.join(r, *parts)
    end
  end
end
