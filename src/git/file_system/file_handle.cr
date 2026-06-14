module Git
  class FileSystem
    # Minimal seekable-file abstraction yielded by `FileSystem#open`.
    #
    # Only the operations the pack layer actually uses are exposed, keeping
    # in-memory backends simple. `write_bytes` is implemented concretely here
    # in terms of `write` so subclasses only need the five primitives.
    abstract class FileHandle
      abstract def seek(offset : Int, whence : IO::Seek = IO::Seek::Set) : Nil
      abstract def pos : Int64
      abstract def read(slice : Bytes) : Int32
      abstract def read_fully(slice : Bytes) : Nil
      abstract def write(slice : Bytes) : Nil

      def print(string : String) : Nil
        write(string.to_slice)
      end

      def write_bytes(value : UInt32, format : IO::ByteFormat = IO::ByteFormat::SystemEndian) : Nil
        buf = IO::Memory.new(4)
        buf.write_bytes(value, format)
        write(buf.to_slice)
      end

      # Wraps a real `::File` handle.
      class Real < FileHandle
        def initialize(@file : ::File)
        end

        def seek(offset : Int, whence : IO::Seek = IO::Seek::Set) : Nil
          @file.seek(offset, whence)
        end

        def pos : Int64
          @file.pos
        end

        def read(slice : Bytes) : Int32
          @file.read(slice)
        end

        def read_fully(slice : Bytes) : Nil
          @file.read_fully(slice)
        end

        def write(slice : Bytes) : Nil
          @file.write(slice)
        end
      end

      # Wraps an `IO::Memory` buffer — used by `FileSystem::Memory#open`.
      class InMemory < FileHandle
        def initialize(@io : IO::Memory)
        end

        def seek(offset : Int, whence : IO::Seek = IO::Seek::Set) : Nil
          @io.seek(offset, whence)
        end

        def pos : Int64
          @io.pos.to_i64
        end

        def read(slice : Bytes) : Int32
          @io.read(slice)
        end

        def read_fully(slice : Bytes) : Nil
          @io.read_fully(slice)
        end

        def write(slice : Bytes) : Nil
          @io.write(slice)
        end
      end
    end
  end
end
