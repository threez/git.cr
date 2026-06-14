module Git
  # Local file transport that spawns `git-upload-pack <path>` directly.
  class Transport::File < Transport::Pipe
    def initialize(@url : Transport::RemoteURL)
    end

    def open : Nil
      spawn_process(Protocol::SERVICE, [@url.path], {"GIT_PROTOCOL" => Protocol::VERSION_2})
    end

    def needs_post_checkout_lfs? : Bool
      true
    end

    private def command_name : String
      Protocol::SERVICE
    end
  end
end
