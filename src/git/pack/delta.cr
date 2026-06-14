require "digest/sha1"

module Git
  # Git delta encoding utilities: applies delta streams and computes git object SHA-1s.
  module Pack::Delta
    # Reads a variable-length integer from delta (7 bits per byte, MSB = more bytes follow).
    private def self.read_size_varint(delta : Bytes, pos : Int32) : {Int64, Int32}
      size = 0_i64
      shift = 0
      bytes_read = 0

      loop do
        if pos + bytes_read >= delta.size
          raise Pack::FileError.new("Delta varint extends beyond delta stream")
        end
        if shift >= 64
          raise Pack::FileError.new("Delta varint too large (shift=#{shift})")
        end
        byte = delta[pos + bytes_read].to_i64
        bytes_read += 1
        size |= ((byte & 0x7f) << shift)
        shift += 7
        break if byte & 0x80 == 0
      end

      {size, bytes_read}
    end

    # Applies a git delta stream to base_data and returns the reconstructed object data.
    # Delta format: [base_size_varint][result_size_varint][instructions...]
    # COPY instruction (bit 7 = 1): copy len bytes from base at offset
    # ADD instruction (bit 7 = 0): append len literal bytes from delta stream
    # ameba:disable Metrics/CyclomaticComplexity
    def self.apply(base : Bytes, delta : Bytes) : Bytes
      pos = 0

      base_size, n = read_size_varint(delta, pos)
      pos += n
      raise Pack::FileError.new("Delta base size mismatch: expected #{base_size}, got #{base.size}") if base_size != base.size

      result_size, n = read_size_varint(delta, pos)
      pos += n

      result = IO::Memory.new(result_size)

      while pos < delta.size
        cmd = delta[pos].to_u32
        pos += 1

        if cmd & 0x80 != 0
          # COPY instruction: copy from base
          offset = 0_u32
          len = 0_u32

          if cmd & 0x01 != 0
            offset |= delta[pos].to_u32; pos += 1
          end
          if cmd & 0x02 != 0
            offset |= (delta[pos].to_u32 << 8); pos += 1
          end
          if cmd & 0x04 != 0
            offset |= (delta[pos].to_u32 << 16); pos += 1
          end
          if cmd & 0x08 != 0
            offset |= (delta[pos].to_u32 << 24); pos += 1
          end

          if cmd & 0x10 != 0
            len |= delta[pos].to_u32; pos += 1
          end
          if cmd & 0x20 != 0
            len |= (delta[pos].to_u32 << 8); pos += 1
          end
          if cmd & 0x40 != 0
            len |= (delta[pos].to_u32 << 16); pos += 1
          end
          len = 0x10000_u32 if len == 0 # git encodes "copy entire base" as len=0 meaning 64KB

          raise Pack::FileError.new("Delta COPY out of bounds: offset=#{offset} len=#{len} base_size=#{base.size}") if offset + len > base.size

          result.write(base[offset.to_i32, len.to_i32])
        else
          # ADD instruction: append literal bytes from delta stream
          add_len = (cmd & 0x7f).to_i32
          raise Pack::FileError.new("Delta ADD with zero length") if add_len == 0
          raise Pack::FileError.new("Delta ADD out of bounds: pos=#{pos} add_len=#{add_len} delta_size=#{delta.size}") if pos + add_len > delta.size

          result.write(delta[pos, add_len])
          pos += add_len
        end
      end

      actual = result.pos.to_i64
      if actual != result_size
        raise Pack::FileError.new("Delta result size mismatch: expected #{result_size}, got #{actual}")
      end
      result.to_slice
    end

    # Computes the git object SHA1 for an uncompressed object.
    # Format: SHA1("<type> <size>\0<data>")
    def self.git_sha1(type : Pack::ObjectType, data : Bytes) : Object::Id
      type_str = type.to_git_type_string
      digest = Digest::SHA1.new
      digest.update("#{type_str} #{data.size}\0")
      digest.update(data)
      Object::Id.from_bytes(digest.final)
    end
  end
end
