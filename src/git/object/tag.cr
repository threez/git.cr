module Git
  module Object
    # A parsed git tag object. Holds the tagged object SHA-1, type, tag name,
    # tagger identity line, and the tag message.
    struct Tag
      # SHA-1 of the tagged object (usually a commit).
      getter object : Id

      # Type string of the tagged object, e.g. `"commit"` or `"tag"`.
      getter type : String

      # Tag name as written in the object, e.g. `"v1.0.0"`.
      getter name : String

      # Raw `tagger` header value, same format as a commit author line.
      getter tagger : String

      # Tag annotation message body.
      getter message : String

      def initialize(@object, @type, @name, @tagger, @message)
      end

      # Parses raw tag object bytes. Raises `ProtocolError` if the `object` header line is absent.
      def self.parse(data : Bytes) : Tag
        object = nil.as(Id?)
        type = ""
        name = ""
        tagger = ""
        message = Object.each_header(data) do |key, value|
          case key
          when "object" then object = Id.from_hex(value[0, 40])
          when "type"   then type = value
          when "tag"    then name = value
          when "tagger" then tagger = value
          end
        end
        raise ProtocolError.new("Tag object missing 'object' line") unless object
        new(object, type, name, tagger, message)
      end
    end
  end
end
