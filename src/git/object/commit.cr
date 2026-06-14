module Git
  module Object
    # Yields each "key value" header pair parsed from a git object's raw bytes,
    # then returns the message body (everything after the first blank line).
    def self.each_header(data : Bytes, & : String, String ->) : String
      text = String.new(data)
      lines = text.split('\n')
      msg_start = lines.size
      lines.each_with_index do |line, i|
        if line.empty?
          msg_start = i + 1
          break
        elsif space = line.index(' ')
          yield line[0, space], line[space + 1..]
        end
      end
      lines[msg_start..].join("\n")
    end

    # A parsed git commit object. Holds the tree SHA-1, parent list, author/committer
    # identity lines, and the commit message.
    struct Commit
      # SHA-1 of the root tree object for this commit.
      getter tree : Id

      # SHA-1s of parent commits (empty for root commits, two entries for merges).
      getter parents : Array(Id)

      # Raw `author` header value, e.g. `"Alice <alice@example.com> 1700000000 +0000"`.
      getter author : String

      # Raw `committer` header value, same format as `author`.
      getter committer : String

      # Commit message body (everything after the first blank line in the object).
      getter message : String

      def initialize(@tree, @parents, @author, @committer, @message)
      end

      # Parses raw commit object bytes. Raises `ProtocolError` if the `tree` header line is absent.
      def self.parse(data : Bytes) : Commit
        tree = nil.as(Id?)
        parents = [] of Id
        author = ""
        committer = ""
        message = Object.each_header(data) do |key, value|
          case key
          when "tree"      then tree = Id.from_hex(value[0, 40])
          when "parent"    then parents << Id.from_hex(value[0, 40])
          when "author"    then author = value
          when "committer" then committer = value
          end
        end
        raise ProtocolError.new("Commit missing 'tree' line") unless tree
        new(tree, parents, author, committer, message)
      end
    end
  end
end
