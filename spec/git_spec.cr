require "./spec_helper"

# Top-level integration tests — require a local git installation.
# Run with: crystal spec spec/git_spec.cr

describe Git do
  describe "VERSION" do
    it "is defined" do
      Git::VERSION.should eq("0.1.0")
    end
  end
end
