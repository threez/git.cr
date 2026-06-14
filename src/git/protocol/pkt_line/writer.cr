module Git
  module Protocol::PktLine
    MAX_DATA_SIZE = 65516 # 65520 - 4 (header bytes)

    # Encodes pkt-line packets and writes them to an IO stream.
    struct Writer
      def initialize(@io : IO)
      end

      # Writes *data* as a length-prefixed data packet.
      # Raises `ProtocolError` if *data* exceeds `MAX_DATA_SIZE`.
      def write_data(data : String) : Nil
        write_data(data.to_slice)
      end

      # :ditto:
      def write_data(data : Bytes) : Nil
        if data.size > MAX_DATA_SIZE
          raise ProtocolError.new("Packet too large: #{data.size} bytes (max #{MAX_DATA_SIZE})")
        end
        len = data.size + 4
        @io << len.to_s(16).rjust(4, '0')
        @io.write(data)
      end

      # Writes a `0000` flush packet.
      def write_flush : Nil
        @io << "0000"
      end

      # Writes a `0001` delim packet.
      def write_delim : Nil
        @io << "0001"
      end
    end
  end
end
