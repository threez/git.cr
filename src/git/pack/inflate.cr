require "lib_z"

module Git
  module Pack
    module Inflate
      ZLIB_VERSION = "1.2.0"

      # Decompresses one zlib-wrapped object from pack[pos..].
      # Returns {decompressed_bytes, compressed_bytes_consumed}.
      #
      # expected_size must match the uncompressed object size from the pack header.
      # Using LibZ directly (rather than Compress::Zlib::Reader) lets us read
      # z_stream.total_in after inflation, which gives the exact number of
      # compressed bytes consumed so we can advance the cursor to the next object.
      def self.at(pack : Bytes, pos : Int32, expected_size : Int32) : {Bytes, Int32}
        output = Bytes.new(expected_size)
        stream = LibZ::ZStream.new

        ret = LibZ.inflateInit2(pointerof(stream), 15, ZLIB_VERSION, sizeof(LibZ::ZStream))
        raise Pack::FileError.new("inflateInit2 failed: #{ret}") unless ret == LibZ::Error::OK

        stream.next_in = pack.to_unsafe + pos
        stream.avail_in = (pack.size - pos).to_u32
        stream.next_out = output.to_unsafe
        stream.avail_out = expected_size.to_u32

        ret = LibZ.inflate(pointerof(stream), LibZ::Flush::FINISH)
        LibZ.inflateEnd(pointerof(stream))

        raise Pack::FileError.new("inflate failed: #{ret}") unless ret == LibZ::Error::STREAM_END

        actual_out = stream.total_out.to_i32
        if actual_out != expected_size
          raise Pack::FileError.new("inflate output size mismatch: expected #{expected_size}, got #{actual_out}")
        end

        consumed = stream.total_in.to_i32
        {output, consumed}
      end
    end
  end
end
