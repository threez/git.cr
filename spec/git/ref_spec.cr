require "../spec_helper"

describe Git::Repository::Ref do
  sha = "da39a3ee5e6b4b0d3255bfef95601890afd80709"

  describe ".parse_advertisement_line" do
    it "parses a plain ref line" do
      ref, caps_raw = Git::Repository::Ref.parse_advertisement_line("#{sha} refs/heads/main\n")
      ref.name.should eq("refs/heads/main")
      ref.oid.to_hex.should eq(sha)
      caps_raw.should be_nil
    end

    it "parses the first ref line with capabilities" do
      line = "#{sha} HEAD\x00side-band-64k ofs-delta agent=git/2.39.0\n"
      ref, caps_raw = Git::Repository::Ref.parse_advertisement_line(line)
      ref.name.should eq("HEAD")
      ref.oid.to_hex.should eq(sha)
      caps_raw.should eq("side-band-64k ofs-delta agent=git/2.39.0")
    end

    it "raises on malformed line" do
      expect_raises(Git::ProtocolError) do
        Git::Repository::Ref.parse_advertisement_line("not-a-ref-line\n")
      end
    end
  end

  describe "#branch?" do
    it "returns true for refs/heads/* refs" do
      ref, _ = Git::Repository::Ref.parse_advertisement_line("#{sha} refs/heads/main\n")
      ref.branch?.should be_true
    end

    it "returns false for HEAD" do
      ref, _ = Git::Repository::Ref.parse_advertisement_line("#{sha} HEAD\n")
      ref.branch?.should be_false
    end
  end

  describe "#branch_name" do
    it "strips the refs/heads/ prefix" do
      ref, _ = Git::Repository::Ref.parse_advertisement_line("#{sha} refs/heads/feature-x\n")
      ref.branch_name.should eq("feature-x")
    end

    it "returns nil for non-branch refs" do
      ref, _ = Git::Repository::Ref.parse_advertisement_line("#{sha} refs/tags/v1.0\n")
      ref.branch_name.should be_nil
    end
  end
end
