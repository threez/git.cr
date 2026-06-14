require "../../spec_helper"

describe Git::Object::Tag do
  describe ".parse" do
    it "parses a well-formed annotated tag object" do
      raw = <<-TAG
        object 1234567890123456789012345678901234567890
        type commit
        tag v1.0
        tagger Test User <test@example.com> 1700000000 +0000

        Release 1.0

        Some details.
        TAG
      tag = Git::Object::Tag.parse(raw.lstrip.encode("UTF-8"))
      tag.object.should eq(Git.oid("1234567890123456789012345678901234567890"))
      tag.type.should eq("commit")
      tag.name.should eq("v1.0")
      tag.tagger.should eq("Test User <test@example.com> 1700000000 +0000")
      tag.message.should contain("Release 1.0")
    end

    it "sets message to empty string when no body follows the blank line" do
      raw = "object 1234567890123456789012345678901234567890\ntype commit\ntag v2.0\n\n"
      tag = Git::Object::Tag.parse(raw.encode("UTF-8"))
      tag.message.strip.should eq("")
    end

    it "raises ProtocolError when 'object' header is absent" do
      raw = "type commit\ntag v1.0\n\nno object header\n"
      expect_raises(Git::ProtocolError, /object/) do
        Git::Object::Tag.parse(raw.encode("UTF-8"))
      end
    end

    it "handles missing tagger gracefully (tagger is empty string)" do
      raw = "object abcdef1234567890abcdef1234567890abcdef12\ntype commit\ntag notagger\n\nmsg\n"
      tag = Git::Object::Tag.parse(raw.encode("UTF-8"))
      tag.tagger.should eq("")
      tag.name.should eq("notagger")
    end
  end
end
