module Git
  module Protocol::PktLine
    # Packet type returned by `Reader#read_packet`.
    enum Type
      # Normal data payload.
      Data
      # `0000` — end of a logical packet stream.
      Flush
      # `0001` — separator used in protocol v2.
      Delim
      # `0002` — protocol v2 response end.
      ResponseEnd
    end
  end
end
