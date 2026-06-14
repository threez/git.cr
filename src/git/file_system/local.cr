require "file_utils"

module Git
  class FileSystem
    # Passthrough `FileSystem` implementation with no path restrictions.
    #
    # Every method delegates directly to the Crystal stdlib (`File`, `Dir`,
    # `FileUtils`) without any additional checks. Use this for paths that are
    # already trusted — for example, files inside a known `.git/` directory
    # whose location was set by the caller at repository-open time.
    #
    # For untrusted content (tree entries, filenames from a remote pack) use
    # `FileSystem::Guarded` instead.
    class Local < FileSystem
      getter root : String

      # *root* anchors this filesystem to a base directory. When omitted (legacy
      # usage in pack/object utilities that pass absolute paths directly), `root`
      # returns `""` and `join` delegates to `File.join` without prepending.
      def initialize(root : String = "")
        @root = root.empty? ? "" : File.expand_path(root)
      end

      def read(path : String) : String
        File.read(path)
      end

      def read_lines(path : String) : Array(String)
        File.read_lines(path)
      end

      def write(path : String, content : String | Bytes) : Nil
        File.write(path, content)
      end

      def chroot(*parts : String) : FileSystem
        Local.new(join(*parts))
      end

      def open(path : String, mode : String, & : FileHandle ->) : Nil
        ::File.open(path, mode) { |file| yield FileHandle::Real.new(file) }
      end

      def exists?(path : String) : Bool
        File.exists?(path)
      end

      def directory?(path : String) : Bool
        Dir.exists?(path)
      end

      def file?(path : String) : Bool
        File.file?(path)
      end

      def symlink?(path : String) : Bool
        File.symlink?(path)
      end

      def size(path : String) : Int64
        File.size(path)
      end

      def delete(path : String) : Nil
        File.delete(path)
      end

      def rename(from : String, to : String) : Nil
        File.rename(from, to)
      end

      def chmod(path : String, mode : Int) : Nil
        File.chmod(path, mode)
      end

      def symlink(target : String, path : String) : Nil
        File.symlink(target, path)
      end

      def mkdir_p(path : String) : Nil
        Dir.mkdir_p(path)
      end

      def rm_rf(path : String) : Nil
        FileUtils.rm_rf(path)
      end

      def rmdir(path : String) : Nil
        Dir.delete(path)
      end

      def dir_empty?(path : String) : Bool
        Dir.empty?(path)
      end

      def glob(pattern : String) : Array(String)
        Dir.glob(pattern)
      end

      def expand_path(path : String) : String
        File.expand_path(path)
      end
    end
  end
end
