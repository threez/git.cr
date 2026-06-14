module Git
  class FileSystem
    # Path-confining `FileSystem` implementation that rejects any access
    # outside a designated *root* directory.
    #
    # ### Security guarantees
    #
    # Before executing any operation, `Guarded` resolves the supplied path to
    # an absolute form via `File.expand_path` (relative to *root*) and enforces
    # two invariants:
    #
    # 1. **Root confinement** — The resolved path must be equal to *root* or
    #    start with `root/`. Paths containing `..` sequences or absolute paths
    #    that point outside the root are rejected with `Git::Error`.
    #
    # 2. **No symlink traversal** — Every directory component between *root*
    #    and the target path is checked with `File.symlink?`, and the final
    #    path component is also checked for operations that follow symlinks
    #    (read, write, chmod, …). This prevents a malicious repository from
    #    planting a symlink in an early tree entry and then writing through it
    #    to an arbitrary location outside the root in a later entry (a known
    #    attack vector in git clients). Operations that act *on* a symlink entry
    #    rather than through one (delete, symlink?, rename source, rm_rf) skip
    #    the leaf check via `safe!(path, follow: false)`.
    #
    # Both checks raise `Git::Error` on violation. Successful calls delegate
    # to an inner `FileSystem::Local` instance.
    #
    # ### Usage
    #
    # ```
    # fs = Git::FileSystem::Guarded.new("/srv/checkouts/myrepo")
    # fs.write("/srv/checkouts/myrepo/src/main.cr", data)           # OK
    # fs.write("/srv/checkouts/myrepo/../../etc/cron.d/evil", data) # raises Git::Error
    # ```
    class Guarded < FileSystem
      getter root : String

      def initialize(root : String)
        @root = File.expand_path(root)
        @root_prefix = @root.ends_with?(File::SEPARATOR_STRING) ? @root : @root + File::SEPARATOR_STRING
        @local = Local.new
      end

      def read(path : String) : String
        @local.read(safe!(path))
      end

      def read_lines(path : String) : Array(String)
        @local.read_lines(safe!(path))
      end

      def write(path : String, content : String | Bytes) : Nil
        @local.write(safe!(path), content)
      end

      def chroot(*parts : String) : FileSystem
        new_root = File.expand_path(join(*parts), @root)
        unless new_root == @root || new_root.starts_with?(@root_prefix)
          raise Error.new("cd escapes root #{@root.inspect}: #{File.join(*parts).inspect}")
        end
        check_parent_dirs!(new_root)
        if File.symlink?(new_root)
          raise Error.new("Symlink at #{new_root.inspect}; refusing to cd through it")
        end
        Guarded.new(new_root)
      end

      def open(path : String, mode : String, & : FileHandle ->) : Nil
        @local.open(safe!(path), mode) { |handle| yield handle }
      end

      def exists?(path : String) : Bool
        @local.exists?(safe!(path))
      end

      def directory?(path : String) : Bool
        @local.directory?(safe!(path))
      end

      def file?(path : String) : Bool
        @local.file?(safe!(path))
      end

      def symlink?(path : String) : Bool
        @local.symlink?(safe!(path, follow: false))
      end

      def size(path : String) : Int64
        @local.size(safe!(path))
      end

      def delete(path : String) : Nil
        @local.delete(safe!(path, follow: false))
      end

      def rename(from : String, to : String) : Nil
        @local.rename(safe!(from, follow: false), safe!(to))
      end

      def chmod(path : String, mode : Int) : Nil
        @local.chmod(safe!(path), mode)
      end

      def symlink(target : String, path : String) : Nil
        @local.symlink(target, safe!(path))
      end

      def mkdir_p(path : String) : Nil
        @local.mkdir_p(safe!(path))
      end

      def rm_rf(path : String) : Nil
        @local.rm_rf(safe!(path, follow: false))
      end

      def rmdir(path : String) : Nil
        @local.rmdir(safe!(path, follow: false))
      end

      def dir_empty?(path : String) : Bool
        @local.dir_empty?(safe!(path))
      end

      def glob(pattern : String) : Array(String)
        @local.glob(safe!(pattern))
      end

      def expand_path(path : String) : String
        safe!(path)
      end

      private def check_parent_dirs!(expanded : String) : Nil
        check = File.dirname(expanded)
        while check != @root && check.starts_with?(@root_prefix)
          if File.symlink?(check)
            raise Error.new("Symlink in path (#{check.inspect}); refusing to access through it")
          end
          check = File.dirname(check)
        end
      end

      private def safe!(path : String, follow : Bool = true) : String
        expanded = File.expand_path(path, @root)
        unless expanded == @root || expanded.starts_with?(@root_prefix)
          raise Error.new("Path escapes root #{@root.inspect}: #{path.inspect}")
        end
        check_parent_dirs!(expanded)
        if follow && File.symlink?(expanded)
          raise Error.new("Symlink at #{expanded.inspect}; refusing to access through it")
        end
        expanded
      end
    end
  end
end
