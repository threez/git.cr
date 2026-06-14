require "digest/sha1"

module Git
  module Pack
    module IndexWriter
      IDX_MAGIC   = 0xFF744F63_u32
      IDX_VERSION =          2_u32

      LARGE_OFFSET_FLAG = 0x80000000_u32

      # Writes a v2 pack index (.idx) alongside the .pack file.
      # Offsets >= 2^31 are stored in the large-offset (OFS64) table per the v2 spec.
      # Returns the path of the written index file.
      def self.write_for_pack(objects : Array(ResolvedObject), pack_path : String, fs : FileSystem = FileSystem::Local.new) : String
        idx_path = pack_path.sub(/\.pack$/, Pack::IDX_EXT)

        sorted = objects.sort_by!(&.sha1.to_hex)

        fanout = build_fanout(sorted)
        pack_sha1 = read_pack_trailing_sha1(pack_path, fs)

        # Partition objects into those fitting in 31 bits and those needing OFS64.
        large_offsets = [] of Int64
        large_offset_index = Hash(Int64, UInt32).new

        sorted.each do |obj|
          if obj.pack_offset >= 0x80000000_i64
            unless large_offset_index.has_key?(obj.pack_offset)
              large_offset_index[obj.pack_offset] = large_offsets.size.to_u32
              large_offsets << obj.pack_offset
            end
          end
        end

        sha1_digest = Digest::SHA1.new
        buf = IO::Memory.new

        write_u32(buf, sha1_digest, IDX_MAGIC)
        write_u32(buf, sha1_digest, IDX_VERSION)
        fanout.each { |v| write_u32(buf, sha1_digest, v) }
        sorted.each { |obj| write_bytes(buf, sha1_digest, obj.sha1.to_bytes) }
        sorted.each { |obj| write_u32(buf, sha1_digest, obj.crc32) }
        sorted.each do |obj|
          if obj.pack_offset >= 0x80000000_i64
            # MSB set: value is an index into the OFS64 table.
            idx = large_offset_index[obj.pack_offset]
            write_u32(buf, sha1_digest, LARGE_OFFSET_FLAG | idx)
          else
            write_u32(buf, sha1_digest, obj.pack_offset.to_u32)
          end
        end
        # OFS64 table (only present when there are large offsets).
        large_offsets.each do |offset|
          high = ((offset >> 32) & 0xFFFFFFFF_i64).to_u32
          low = (offset & 0xFFFFFFFF_i64).to_u32
          write_u32(buf, sha1_digest, high)
          write_u32(buf, sha1_digest, low)
        end
        write_bytes(buf, sha1_digest, pack_sha1)
        buf.write(sha1_digest.final) # index trailing SHA1 (not hashed into itself)

        fs.write(idx_path, buf.to_slice)
        idx_path
      end

      private def self.build_fanout(sorted : Array(ResolvedObject)) : Array(UInt32)
        counts = Array(UInt32).new(256, 0_u32)
        sorted.each { |obj| counts[obj.sha1.to_bytes[0].to_i] += 1 }
        cumulative = 0_u32
        Array(UInt32).new(256) { |i| cumulative += counts[i]; cumulative }
      end

      private def self.read_pack_trailing_sha1(pack_path : String, fs : FileSystem = FileSystem::Local.new) : Bytes
        sha = Bytes.new(20)
        fs.open(pack_path, "rb") do |file|
          file.seek(-20, IO::Seek::End)
          file.read_fully(sha)
        end
        sha
      end

      private def self.write_u32(io : IO, digest : Digest::SHA1, value : UInt32) : Nil
        buf = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(value, buf)
        io.write(buf)
        digest.update(buf)
      end

      private def self.write_bytes(io : IO, digest : Digest::SHA1, data : Bytes) : Nil
        io.write(data)
        digest.update(data)
      end
    end
  end
end
