require "../../spec_helper"

describe Git::Transport::RemoteURL do
  describe ".parse" do
    it "parses an HTTPS URL" do
      url = Git.remote("https://github.com/user/repo.git")
      url.scheme.should eq(Git::Transport::RemoteURL::Scheme::HTTPS)
      url.host.should eq("github.com")
      url.path.should eq("/user/repo.git")
      url.user.should be_nil
      url.port.should be_nil
    end

    it "parses an HTTP URL" do
      url = Git.remote("http://localhost/repo.git")
      url.scheme.should eq(Git::Transport::RemoteURL::Scheme::HTTP)
      url.http?.should be_true
    end

    it "parses an SSH URL with user" do
      url = Git.remote("ssh://git@github.com/user/repo.git")
      url.scheme.should eq(Git::Transport::RemoteURL::Scheme::SSH)
      url.user.should eq("git")
      url.host.should eq("github.com")
      url.path.should eq("/user/repo.git")
      url.ssh?.should be_true
    end

    it "parses an SSH URL with custom port" do
      url = Git.remote("ssh://git@host.example.com:2222/path/repo.git")
      url.port.should eq(2222)
    end

    it "parses SCP-style git@host:path" do
      url = Git.remote("git@github.com:user/repo.git")
      url.scheme.should eq(Git::Transport::RemoteURL::Scheme::SSH)
      url.user.should eq("git")
      url.host.should eq("github.com")
      url.path.should eq("/user/repo.git")
    end

    it "parses SCP-style with absolute path" do
      url = Git.remote("git@host:/absolute/path.git")
      url.path.should eq("/absolute/path.git")
    end

    it "preserves the original URL string" do
      raw = "https://github.com/user/repo.git"
      Git.remote(raw).original.should eq(raw)
    end

    it "raises on unsupported scheme" do
      expect_raises(Git::Error) { Git.remote("ftp://host/repo") }
    end
  end

  describe "#to_ssh_command" do
    it "builds basic SSH argv" do
      url = Git.remote("git@github.com:user/repo.git")
      argv = url.to_ssh_command
      argv[0].should eq("ssh")
      argv[-2].should eq("git-upload-pack")
      argv[-1].should eq("'/user/repo.git'")
    end

    it "includes port when specified" do
      url = Git.remote("ssh://git@host:2222/repo.git")
      argv = url.to_ssh_command
      argv.should contain("-p")
      argv.should contain("2222")
    end

    it "quotes paths with single quotes" do
      url = Git.remote("git@host:some/path.git")
      argv = url.to_ssh_command
      argv.last.should start_with("'")
      argv.last.should end_with("'")
    end
  end
end
