require "../../spec_helper"

# Writes a pkt-line data packet to *io*.
private def v2_write_pkt(io : IO, line : String) : Nil
  len = line.bytesize + 4
  io << "%04x" % len
  io << line
end

# Writes a flush packet to *io*.
private def v2_write_flush(io : IO) : Nil
  io << "0000"
end

# Writes a delim packet to *io*.
private def v2_write_delim(io : IO) : Nil
  io << "0001"
end

private def make_oid(hex_char : Char) : Git::Object::Id
  Git.oid(hex_char.to_s * 40)
end

describe Git::Protocol::V2 do
  describe ".build_ls_refs_body" do
    it "encodes command=ls-refs with delim and symrefs/peel args" do
      body = Git::Protocol::V2.build_ls_refs_body
      str = String.new(body)
      str.should contain("command=ls-refs")
      str.should contain("0001") # delim
      str.should contain("symrefs")
      str.should contain("peel")
      str.should contain("0000") # flush
    end
  end

  describe ".parse_ls_refs_response" do
    it "populates symref_target on HEAD when the symref-target attribute is present" do
      # Regression: previously the symref-target attribute was parsed but discarded.
      # When two branches share HEAD's OID, resolve_target must prefer the symref,
      # not guess by OID-matching (which is ambiguous).
      head_oid = make_oid('a')
      mem = IO::Memory.new
      v2_write_pkt(mem, "#{head_oid.to_hex} HEAD symref-target:refs/heads/main\n")
      v2_write_pkt(mem, "#{head_oid.to_hex} refs/heads/main\n")
      v2_write_pkt(mem, "#{head_oid.to_hex} refs/heads/other\n")
      v2_write_flush(mem)
      mem.rewind

      refs = Git::Protocol::V2.parse_ls_refs_response(mem)
      head = refs.find { |ref| ref.name == "HEAD" }
      head.should_not be_nil
      (head || raise "HEAD ref not found").symref_target.should eq("refs/heads/main")
    end

    it "parses ref lines into a list of refs" do
      oid1 = make_oid('c')
      oid2 = make_oid('d')
      mem = IO::Memory.new
      v2_write_pkt(mem, "#{oid1.to_hex} refs/heads/main\n")
      v2_write_pkt(mem, "#{oid2.to_hex} refs/heads/feature symref-target:refs/heads/main\n")
      v2_write_flush(mem)
      mem.rewind

      refs = Git::Protocol::V2.parse_ls_refs_response(mem)
      refs.size.should eq(2)
      refs[0].oid.should eq(oid1)
      refs[0].name.should eq("refs/heads/main")
      refs[1].oid.should eq(oid2)
      refs[1].name.should eq("refs/heads/feature")
    end
  end

  describe ".build_fetch_body" do
    it "encodes command=fetch with want and done" do
      oid = make_oid('e')
      body = Git::Protocol::V2.build_fetch_body([oid])
      str = String.new(body)
      str.should contain("command=fetch")
      str.should contain("0001") # delim
      str.should contain("want #{oid.to_hex}")
      str.should contain("done")
      str.should contain("0000") # flush
    end

    it "encodes have lines when provided" do
      want_oid = make_oid('f')
      have_oid = make_oid('1')
      body = Git::Protocol::V2.build_fetch_body([want_oid], [have_oid])
      str = String.new(body)
      str.should contain("have #{have_oid.to_hex}")
    end

    it "encodes deepen line when depth is provided" do
      oid = make_oid('2')
      body = Git::Protocol::V2.build_fetch_body([oid], depth: 5)
      str = String.new(body)
      str.should contain("deepen 5")
    end
  end

  describe ".parse_fetch_response" do
    it "returns a SidebandReader starting at the packfile section" do
      mem = IO::Memory.new
      # packfile section header
      v2_write_pkt(mem, "packfile\n")
      # one sideband pkt-line: channel 1 + "PACK"
      payload = Bytes.new(5)
      payload[0] = 1_u8 # channel 1 = pack data
      payload[1..4].copy_from("PACK".to_slice)
      len = payload.size + 4
      mem << "%04x" % len
      mem.write(payload)
      v2_write_flush(mem)
      mem.rewind

      pack_io, new_shallows, unshallowed = Git::Protocol::V2.parse_fetch_response(mem)
      new_shallows.should be_empty
      unshallowed.should be_empty
      buf = Bytes.new(4)
      pack_io.read_fully(buf)
      String.new(buf).should eq("PACK")
    end

    it "collects shallow OIDs from a shallow-info section before packfile" do
      shallow_oid = make_oid('a')
      mem = IO::Memory.new
      # shallow-info section
      v2_write_pkt(mem, "shallow-info\n")
      v2_write_pkt(mem, "shallow #{shallow_oid.to_hex}\n")
      v2_write_delim(mem) # delim ends shallow-info section
      # packfile section
      v2_write_pkt(mem, "packfile\n")
      # minimal sideband flush (channel 1, empty)
      v2_write_flush(mem)
      mem.rewind

      _, new_shallows, unshallowed = Git::Protocol::V2.parse_fetch_response(mem)
      new_shallows.should eq([shallow_oid])
      unshallowed.should be_empty
    end

    it "raises ProtocolError when response ends with flush before packfile" do
      mem = IO::Memory.new
      v2_write_flush(mem)
      mem.rewind

      expect_raises(Git::ProtocolError, /packfile/) do
        Git::Protocol::V2.parse_fetch_response(mem)
      end
    end
  end
end
