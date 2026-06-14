module Git
  class FileSystem
    # In-memory `FileSystem` implementation backed by hashes.
    #
    # All `chroot` descendants share the same underlying `Store`, so writes
    # made through a child are visible through the parent and vice-versa —
    # exactly like a real filesystem where chroot changes the root view but
    # not the underlying storage.
    #
    # Primarily useful for unit-testing code that accepts a `FileSystem`
    # parameter without touching disk.
    #
    # ```
    # fs = Git::FileSystem::Memory.new("/mock")
    # fs.write("hello.txt", "world")
    # fs.read("hello.txt") # => "world"
    # sub = fs.chroot("sub")
    # sub.write("a.txt", "x")
    # fs.exists?("sub/a.txt") # => true  (shared store)
    # ```
    class Memory < FileSystem
      private class Store
        property files = {} of String => Bytes
        property dirs = Set(String).new
        property symlinks = {} of String => String
        property modes = {} of String => Int32
      end

      getter root : String

      def initialize(root : String = "", @store : Store = Store.new)
        @root = root.empty? ? "" : ::File.expand_path(root)
      end

      def chroot(*parts : String) : FileSystem
        Memory.new(join(*parts), @store)
      end

      def read(path : String) : String
        abs = expand_path(path)
        data = @store.files[abs]? || raise ::File::NotFoundError.new(message: nil, file: abs)
        String.new(data)
      end

      def read_lines(path : String) : Array(String)
        read(path).lines(chomp: true)
      end

      def write(path : String, content : String | Bytes) : Nil
        abs = expand_path(path)
        data = content.is_a?(String) ? content.to_slice : content
        @store.files[abs] = data.dup
        ensure_parents(::File.dirname(abs))
      end

      def open(path : String, mode : String, & : FileHandle ->) : Nil
        abs = expand_path(path)
        io = case mode
             when "rb", "r"
               data = @store.files[abs]? || raise ::File::NotFoundError.new(message: nil, file: abs)
               mem = IO::Memory.new
               mem.write(data)
               mem.seek(0)
               mem
             when "wb", "w"
               IO::Memory.new
             when "r+b", "r+"
               mem = IO::Memory.new
               if data = @store.files[abs]?
                 mem.write(data)
                 mem.seek(0)
               end
               mem
             else
               raise ArgumentError.new("unsupported open mode: #{mode.inspect}")
             end
        yield FileHandle::InMemory.new(io)
        if mode.includes?("w") || mode.includes?("+")
          @store.files[abs] = io.to_slice.dup
          ensure_parents(::File.dirname(abs))
        end
      end

      def exists?(path : String) : Bool
        abs = expand_path(path)
        @store.files.has_key?(abs) || @store.dirs.includes?(abs) || @store.symlinks.has_key?(abs)
      end

      def directory?(path : String) : Bool
        @store.dirs.includes?(expand_path(path))
      end

      def file?(path : String) : Bool
        abs = expand_path(path)
        @store.files.has_key?(abs) && !@store.dirs.includes?(abs)
      end

      def symlink?(path : String) : Bool
        @store.symlinks.has_key?(expand_path(path))
      end

      def size(path : String) : Int64
        abs = expand_path(path)
        data = @store.files[abs]? || raise ::File::NotFoundError.new(message: nil, file: abs)
        data.size.to_i64
      end

      def delete(path : String) : Nil
        abs = expand_path(path)
        unless @store.files.delete(abs) || @store.symlinks.delete(abs)
          raise ::File::NotFoundError.new(message: nil, file: abs)
        end
      end

      def rename(from : String, to : String) : Nil
        abs_from = expand_path(from)
        abs_to = expand_path(to)
        data = @store.files.delete(abs_from) || raise ::File::NotFoundError.new(message: nil, file: abs_from)
        @store.files[abs_to] = data
        ensure_parents(::File.dirname(abs_to))
      end

      def chmod(path : String, mode : Int) : Nil
        @store.modes[expand_path(path)] = mode.to_i32
      end

      def symlink(target : String, path : String) : Nil
        @store.symlinks[expand_path(path)] = target
      end

      def mkdir_p(path : String) : Nil
        ensure_parents(expand_path(path))
      end

      def rm_rf(path : String) : Nil
        abs = expand_path(path)
        prefix = abs + "/"
        @store.files.reject! { |k, _| k == abs || k.starts_with?(prefix) }
        @store.dirs.reject! { |k| k == abs || k.starts_with?(prefix) }
        @store.symlinks.reject! { |k, _| k == abs || k.starts_with?(prefix) }
        @store.modes.reject! { |k, _| k == abs || k.starts_with?(prefix) }
      end

      def rmdir(path : String) : Nil
        abs = expand_path(path)
        raise ::File::Error.new(message: "Directory not empty", file: abs) unless dir_empty?(abs)
        @store.dirs.delete(abs)
      end

      def dir_empty?(path : String) : Bool
        abs = expand_path(path)
        prefix = abs + "/"
        !@store.files.any? { |k, _| k.starts_with?(prefix) } &&
          !@store.dirs.any?(&.starts_with?(prefix)) &&
          !@store.symlinks.any? { |k, _| k.starts_with?(prefix) }
      end

      def glob(pattern : String) : Array(String)
        all = (@store.files.keys +
               @store.dirs.to_a +
               @store.symlinks.keys).uniq
        all.select { |path| glob_match?(pattern, path) }.sort!
      end

      def expand_path(path : String) : String
        @root.empty? ? ::File.expand_path(path) : ::File.expand_path(path, @root)
      end

      private def ensure_parents(dir : String) : Nil
        return if @store.dirs.includes?(dir)
        parent = ::File.dirname(dir)
        ensure_parents(parent) unless parent == dir
        @store.dirs.add(dir)
      end

      private def glob_match?(pattern : String, path : String) : Bool
        pat = Regex.escape(pattern)
          .gsub("\\*\\*/", "(?:[^/]+/)*")
          .gsub("\\*\\*", ".*")
          .gsub("\\*", "[^/]*")
        Regex.new("\\A#{pat}\\z").matches?(path)
      end
    end
  end
end
