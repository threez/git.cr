module Git
  module Pack
    module CRC32
      POLY = 0xEDB88320_u32

      TABLE = Array.new(256) do |num|
        v = num.to_u32
        8.times { v = (v & 1_u32 == 0_u32) ? (v >> 1) : ((v >> 1) ^ POLY) }
        v
      end

      def self.update(crc : UInt32, data : Bytes) : UInt32
        data.reduce(crc) { |crc32, byte| TABLE[((crc32 ^ byte) & 0xff).to_i] ^ (crc32 >> 8) }
      end

      def self.digest(data : Bytes) : UInt32
        update(0xFFFFFFFF_u32, data) ^ 0xFFFFFFFF_u32
      end
    end
  end
end
