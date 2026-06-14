module Git
  module Pack
    module Index
      IDX_FANOUT_OFFSET = 8 + 255 * 4 # byte offset of fanout[255] = total count

      def self.read_count(idx_path : String, fs : FileSystem = FileSystem::Local.new) : Int32
        result = 0
        fs.open(idx_path, "rb") do |file|
          file.seek(IDX_FANOUT_OFFSET)
          buf = Bytes.new(4)
          file.read_fully(buf)
          result = IO::ByteFormat::BigEndian.decode(UInt32, buf).to_i32
        end
        result
      end
    end
  end
end
