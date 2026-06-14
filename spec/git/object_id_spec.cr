require "../spec_helper"

describe Git::Object::Id do
  sha = "da39a3ee5e6b4b0d3255bfef95601890afd80709"

  describe ".from_hex" do
    it "parses a valid 40-char hex string" do
      oid = Git.oid(sha)
      oid.to_hex.should eq(sha)
    end

    it "raises on wrong length" do
      expect_raises(Git::Error) { Git.oid("abc") }
    end

    it "raises on invalid hex" do
      expect_raises(Git::Error, /non-hex/) { Git.oid("z" * 40) }
    end

    it "raises on whitespace-padded hex (would have been silently accepted before)" do
      expect_raises(Git::Error) { Git.oid("+f" * 20) }
    end
  end

  describe ".from_bytes" do
    it "round-trips through bytes" do
      oid = Git.oid(sha)
      oid2 = Git::Object::Id.from_bytes(oid.to_bytes)
      oid2.should eq(oid)
    end

    it "raises on wrong size" do
      expect_raises(Git::Error) { Git::Object::Id.from_bytes(Bytes.new(10)) }
    end
  end

  describe "#zero?" do
    it "returns true for the zero OID" do
      Git::Object::Id::ZERO.zero?.should be_true
    end

    it "returns false for a real OID" do
      Git.oid(sha).zero?.should be_false
    end
  end

  describe "#==" do
    it "equals itself" do
      oid = Git.oid(sha)
      oid.should eq(oid)
    end

    it "does not equal a different OID" do
      oid1 = Git.oid(sha)
      oid2 = Git::Object::Id::ZERO
      oid1.should_not eq(oid2)
    end
  end

  describe "#to_s" do
    it "produces the hex string" do
      Git.oid(sha).to_s.should eq(sha)
    end
  end
end
