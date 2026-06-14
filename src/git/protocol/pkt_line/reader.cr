module Git
  module Protocol::PktLine
    # Decodes pkt-line packets from an IO stream.
    struct Reader
      def initialize(@io : IO)
      end

      # Reads the next packet. Returns `{Type, Bytes?}` — data is `nil` for Flush/Delim.
      # Raises `ProtocolError` on truncated input or invalid hex in the length header.
      def read_packet : {Type, Bytes?}
        header = Bytes.new(4)
        begin
          @io.read_fully(header)
        rescue IO::EOFError
          raise ProtocolError.new("Unexpected EOF reading packet header")
        end

        len_str = String.new(header)
        len = len_str.to_i?(16)
        raise ProtocolError.new("Invalid packet length: #{len_str.inspect}") unless len

        case len
        when 0
          {Type::Flush, nil}
        when 1
          {Type::Delim, nil}
        when 2
          {Type::ResponseEnd, nil}
        else
          data_len = len - 4
          raise ProtocolError.new("Invalid packet length #{len}") if data_len < 0
          data = Bytes.new(data_len)
          begin
            @io.read_fully(data) if data_len > 0
          rescue IO::EOFError
            raise ProtocolError.new("Unexpected EOF reading #{data_len} bytes of packet data")
          end
          {Type::Data, data}
        end
      end

      # Yields the payload bytes of each `Data` packet until a `Flush` is received.
      def each_data_packet(& : Bytes ->) : Nil
        loop do
          type, data = read_packet
          case type
          when Type::Flush
            break
          when Type::Data
            yield data.not_nil! # ameba:disable Lint/NotNil
          end
        end
      end

      # Reads data packets until a flush, returning each payload as a string with trailing newlines stripped.
      def read_lines_until_flush : Array(String)
        lines = [] of String
        each_data_packet do |data|
          lines << String.new(data).chomp
        end
        lines
      end
    end
  end
end
