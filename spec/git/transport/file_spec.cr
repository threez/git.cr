require "../../spec_helper"

private def git_upload_pack_available? : Bool
  Process.find_executable("git-upload-pack") != nil
end

describe Git::Transport::File do
  it "close raises TransportError when the repo path does not exist" do
    pending "git-upload-pack not available" unless git_upload_pack_available?

    url = Git.remote("file:///nonexistent-path-that-does-not-exist-#{Random::Secure.hex(4)}")
    transport = Git::Transport::File.new(url)
    transport.open
    expect_raises(Git::TransportError) do
      transport.close
    end
  end
end
