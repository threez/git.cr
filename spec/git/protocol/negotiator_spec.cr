require "../../spec_helper"

private def neg_write_pkt(io : IO, line : String) : Nil
  len = line.bytesize + 4
  io << "%04x" % len
  io << line
end

private def neg_write_flush(io : IO) : Nil
  io << "0000"
end

private def neg_make_oid(hex_char : Char) : Git::Object::Id
  Git.oid(hex_char.to_s * 40)
end

private class NegStubTransport < Git::Transport::Base
  def request(body : Bytes, & : IO ->) : Nil
    raise Git::TransportError.new("NegStubTransport: request not implemented")
  end

  def handshake_io : IO
    IO::Memory.new
  end

  def stateless? : Bool
    true
  end
end

describe Git::Protocol::Negotiator do
  stub = NegStubTransport.new

  describe ".detect_version_from_io (HTTP / stateless)" do
    it "returns a V2 session for a v2 info/refs response" do
      mem = IO::Memory.new
      neg_write_pkt(mem, "version 2\n")
      neg_write_pkt(mem, "fetch\n")
      neg_write_pkt(mem, "ls-refs\n")
      neg_write_flush(mem)
      mem.rewind

      session = Git::Protocol::Negotiator.detect_version_from_io(mem, stateless: true, transport: stub)
      session.should be_a(Git::Protocol::V2)
    end

    it "returns a V1 session with refs for a v1 info/refs response" do
      oid = neg_make_oid('b')
      mem = IO::Memory.new
      neg_write_pkt(mem, "# service=git-upload-pack\n")
      neg_write_flush(mem)
      neg_write_pkt(mem, "#{oid.to_hex} refs/heads/main\0side-band-64k\n")
      neg_write_flush(mem)
      mem.rewind

      session = Git::Protocol::Negotiator.detect_version_from_io(mem, stateless: true, transport: stub)
      session.should be_a(Git::Protocol::V1::HTTP)
      session.refs.size.should eq(1)
      session.refs[0].name.should eq("refs/heads/main")
      session.refs[0].oid.should eq(oid)
    end
  end

  describe ".detect_version_from_io (pipe / stateless: false)" do
    it "returns a V2 session for a v2 ssh response" do
      mem = IO::Memory.new
      neg_write_pkt(mem, "version 2\n")
      neg_write_pkt(mem, "ls-refs\n")
      neg_write_pkt(mem, "fetch\n")
      neg_write_flush(mem)
      mem.rewind

      session = Git::Protocol::Negotiator.detect_version_from_io(mem, stateless: false, transport: stub)
      session.should be_a(Git::Protocol::V2)
    end

    it "returns a V1 session with refs for a v1 ssh response, including the first ref" do
      oid = neg_make_oid('c')
      mem = IO::Memory.new
      neg_write_pkt(mem, "#{oid.to_hex} refs/heads/main\0side-band-64k\n")
      neg_write_flush(mem)
      mem.rewind

      session = Git::Protocol::Negotiator.detect_version_from_io(mem, stateless: false, transport: stub)
      session.should be_a(Git::Protocol::V1::Pipe)
      session.refs.size.should eq(1)
      session.refs[0].oid.should eq(oid)
      session.refs[0].name.should eq("refs/heads/main")
    end
  end
end
