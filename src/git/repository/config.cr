module Git
  # Minimal read-only parser for `.git/config` (INI format with `[section "subsection"]` headers).
  struct Repository::Config
    # Parsed INI sections keyed by `"section"` or `"section.subsection"`, each mapping key → value.
    getter sections : Hash(String, Hash(String, String))

    def initialize(@sections : Hash(String, Hash(String, String)))
    end

    # Reads and parses `.git/config` for *repo*.
    def self.read(repo : Repository) : Repository::Config
      path = repo.git_dir.join("config")
      parse(repo.git_dir.read(path))
    end

    # Parses raw INI text into a `Repository::Config`.
    def self.parse(text : String) : Repository::Config
      sections = Hash(String, Hash(String, String)).new
      current = nil.as(String?)

      text.each_line do |raw|
        line = raw.strip
        next if line.empty? || line.starts_with?('#') || line.starts_with?(';')

        if m = line.match(/^\[(\w+)(?:\s+"([^"]+)")?\]$/)
          base = m[1]
          sub = m[2]?
          current = sub ? "#{base}.#{sub}" : base
          sections[current] ||= Hash(String, String).new
        elsif (sep = line.index('=')) && current
          key = line[0, sep].strip
          val = line[sep + 1..].strip
          sections[current][key] = val
        end
      end

      new(sections)
    end

    # Returns the `url` value from `[remote "<name>"]`.
    # Raises `RepositoryError` if the section or the `url` key is absent.
    def remote_url(name : String = "origin") : String
      section = @sections["remote.#{name}"]?
      raise RepositoryError.new("No remote #{name.inspect} in config") unless section
      section["url"]? || raise RepositoryError.new("Remote #{name.inspect} has no url")
    end
  end
end
