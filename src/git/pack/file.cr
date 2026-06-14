require "digest/sha1"

module Git
  module Pack
    module File
      MAGIC   = "PACK"
      VERSION = 2_u32

      # Reads a packfile from io, validates the header, streams it to output_path,
      # and returns the object count. Raises Pack::FileError on bad magic, version,
      # or trailing SHA-1 checksum mismatch.
      def self.receive(io : IO, output_path : String, fs : FileSystem = FileSystem::Local.new) : Int32
        magic, version, count = read_pack_header(io)

        # Write to a temp file while computing SHA-1 over all bytes written.
        # The last 20 bytes of the stream are the expected checksum — we write them
        # to disk but compare them against the digest of all preceding bytes.
        digest = Digest::SHA1.new
        version_buf = Bytes.new(4)
        count_buf = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(version, version_buf)
        IO::ByteFormat::BigEndian.encode(count, count_buf)
        digest.update(magic)
        digest.update(version_buf)
        digest.update(count_buf)

        fs.open(output_path, "wb") do |file|
          file.write(magic)
          file.write_bytes(version, IO::ByteFormat::BigEndian)
          file.write_bytes(count, IO::ByteFormat::BigEndian)

          # Stream body while keeping a 20-byte lookahead buffer for the trailing SHA-1.
          # We cannot know where the SHA-1 starts until the stream ends.
          lookahead = Bytes.new(20)
          lookahead_len = 0

          buf = Bytes.new(65536)
          loop do
            n = io.read(buf)
            break if n == 0
            chunk = buf[0, n]

            # Append chunk to lookahead, flushing overflow to disk+digest.
            combined_size = lookahead_len + n
            if combined_size > 20
              flush_len = combined_size - 20
              # Bytes to flush come from lookahead first, then chunk.
              flush_from_lookahead = Math.min(flush_len, lookahead_len)
              if flush_from_lookahead > 0
                to_flush = lookahead[0, flush_from_lookahead]
                file.write(to_flush)
                digest.update(to_flush)
              end
              flush_from_chunk = flush_len - flush_from_lookahead
              if flush_from_chunk > 0
                to_flush = chunk[0, flush_from_chunk]
                file.write(to_flush)
                digest.update(to_flush)
              end
              # Rebuild lookahead from remainder.
              remaining_lookahead = lookahead_len - flush_from_lookahead
              if remaining_lookahead > 0
                lookahead.copy_from(lookahead[flush_from_lookahead, remaining_lookahead])
              end
              new_from_chunk = n - flush_from_chunk
              if new_from_chunk > 0
                lookahead[remaining_lookahead, new_from_chunk].copy_from(chunk[flush_from_chunk, new_from_chunk])
              end
              lookahead_len = remaining_lookahead + new_from_chunk
            else
              # All fits in lookahead.
              chunk.copy_to(lookahead + lookahead_len)
              lookahead_len = combined_size
            end
          end

          # lookahead now holds the final 20 bytes (the SHA-1).
          if lookahead_len != 20
            raise Pack::FileError.new("Packfile too short: expected 20-byte trailing checksum, got #{lookahead_len} bytes")
          end

          expected = digest.final
          unless expected == lookahead[0, 20]
            raise Pack::FileError.new("Packfile checksum mismatch: expected #{expected.hexstring}, got #{lookahead[0, 20].hexstring}")
          end

          # Write the checksum itself to disk so the idx writer can read it.
          file.write(lookahead[0, 20])
        end

        count.to_i32
      end

      private def self.read_pack_header(io : IO) : {Bytes, UInt32, UInt32}
        magic = Bytes.new(4)
        begin
          io.read_fully(magic)
        rescue IO::EOFError
          raise Pack::FileError.new("Unexpected EOF reading packfile magic")
        end
        unless String.new(magic) == MAGIC
          raise Pack::FileError.new("Invalid packfile magic: #{magic.hexstring} (expected 'PACK')")
        end
        begin
          version = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        rescue IO::EOFError
          raise Pack::FileError.new("Unexpected EOF reading packfile version")
        end
        unless version == VERSION
          raise Pack::FileError.new("Unsupported packfile version: #{version} (only version 2 is supported)")
        end
        begin
          count = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        rescue IO::EOFError
          raise Pack::FileError.new("Unexpected EOF reading packfile object count")
        end
        {magic, version, count}
      end
    end
  end
end
