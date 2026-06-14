module Git
  # SSH transport that spawns `ssh [user@]host git-upload-pack '<path>'`.
  class Transport::SSH < Transport::Pipe
    def initialize(@url : Transport::RemoteURL)
    end

    def open : Nil
      argv = @url.to_ssh_command
      # Insert -o "SetEnv GIT_PROTOCOL=version=2" before the host to request v2.
      # argv layout: ["ssh", ("-p", port,)? host, "git-upload-pack", path]
      insert_at = @url.port ? 3 : 1
      argv.insert(insert_at, "SetEnv GIT_PROTOCOL=#{Protocol::VERSION_2}")
      argv.insert(insert_at, "-o")
      spawn_process(argv[0], argv[1..])
    end

    private def command_name : String
      "ssh"
    end
  end
end
