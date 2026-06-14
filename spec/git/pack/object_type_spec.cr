require "../../spec_helper"

describe Git::Pack::ObjectType do
  it "has the correct wire values" do
    Git::Pack::ObjectType::Commit.value.should eq(1_u8)
    Git::Pack::ObjectType::Tree.value.should eq(2_u8)
    Git::Pack::ObjectType::Blob.value.should eq(3_u8)
    Git::Pack::ObjectType::Tag.value.should eq(4_u8)
    Git::Pack::ObjectType::OfsDelta.value.should eq(6_u8)
    Git::Pack::ObjectType::RefDelta.value.should eq(7_u8)
  end

  describe "#delta?" do
    it "returns false for standalone object types" do
      Git::Pack::ObjectType::Commit.delta?.should be_false
      Git::Pack::ObjectType::Blob.delta?.should be_false
    end

    it "returns true for OfsDelta and RefDelta" do
      Git::Pack::ObjectType::OfsDelta.delta?.should be_true
      Git::Pack::ObjectType::RefDelta.delta?.should be_true
    end
  end

  describe "#to_git_type_string" do
    it "returns the correct lowercase string for each standalone type" do
      Git::Pack::ObjectType::Commit.to_git_type_string.should eq("commit")
      Git::Pack::ObjectType::Tree.to_git_type_string.should eq("tree")
      Git::Pack::ObjectType::Blob.to_git_type_string.should eq("blob")
      Git::Pack::ObjectType::Tag.to_git_type_string.should eq("tag")
    end

    it "raises Git::Error for delta types" do
      expect_raises(Git::Error) { Git::Pack::ObjectType::OfsDelta.to_git_type_string }
      expect_raises(Git::Error) { Git::Pack::ObjectType::RefDelta.to_git_type_string }
    end
  end
end
