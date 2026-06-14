require "../../spec_helper"

describe Git::Protocol::V1 do
  describe ".build_want_body" do
    it "encodes want lines and done" do
      oid = Git.oid("a" * 40)
      caps = Git::Protocol::CapabilitySet.parse("")
      body = Git::Protocol::V1.build_want_body([oid], caps)
      str = String.new(body)
      str.should contain("want #{oid.to_hex}")
      str.should contain("done")
    end

    it "encodes have lines when provided" do
      want_oid = Git.oid("a" * 40)
      have_oid = Git.oid("b" * 40)
      caps = Git::Protocol::CapabilitySet.parse("")
      body = Git::Protocol::V1.build_want_body([want_oid], caps, [have_oid])
      str = String.new(body)
      str.should contain("have #{have_oid.to_hex}")
    end
  end

  describe ".parse_stateless_fetch_response" do
    it "consumes the NAK pkt-line before handing off to the sideband reader" do
      # Simulate the raw HTTP response body for a non-shallow fetch without common objects:
      # a NAK pkt-line followed by one sideband channel-1 packet containing "PACK", then flush.
      mem = IO::Memory.new
      # NAK pkt-line: 4 bytes "NAK\n" → total length field 0008
      mem << "0008NAK\n"
      # Sideband pkt-line: channel byte 0x01 + 4 bytes "PACK" = 5-byte payload → total 0009
      mem << "0009"
      mem.write_byte(1_u8)
      mem.write("PACK".to_slice)
      # Flush: signals end of sideband stream
      mem << "0000"
      mem.rewind

      caps = Git::Protocol::CapabilitySet.parse("side-band-64k")
      pack_io, shallows, unshallowed = Git::Protocol::V1.parse_stateless_fetch_response(
        mem, caps, nil, [] of Git::Object::Id, nil
      )
      shallows.should be_empty
      unshallowed.should be_empty

      buf = Bytes.new(4)
      pack_io.read_fully(buf)
      String.new(buf).should eq("PACK")
    end
  end

  describe ".parse_ref_advertisement" do
    it "parses a synthetic ref advertisement into refs and capabilities" do
      oid = Git.oid("c" * 40)
      mem = IO::Memory.new
      w = Git::Protocol::PktLine::Writer.new(mem)
      # First line carries capabilities after NUL
      w.write_data("#{oid.to_hex} refs/heads/main\0side-band-64k\n")
      w.write_flush
      mem.rewind

      refs, caps = Git::Protocol::V1.parse_ref_advertisement(Git::Protocol::PktLine::Reader.new(mem))
      refs.size.should eq(1)
      refs[0].name.should eq("refs/heads/main")
      refs[0].oid.should eq(oid)
      caps.side_band_64k?.should be_true
    end
  end
end
