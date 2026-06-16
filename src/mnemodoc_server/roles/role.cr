module MnemodocServer
  module Roles
    # A role at runtime: its declared config plus the resolved absolute path of
    # its markdown file. The markdown is read lazily and cached, so a role that
    # is never selected costs nothing.
    class Role
      getter config : RoleConfig
      getter resolved_file : String
      getter name : String

      @content : String? = nil

      def initialize(@config : RoleConfig, @resolved_file : String)
        @name = File.basename(@config.file, File.extname(@config.file))
      end

      # Reads the role markdown once and caches it. Raises File::Error when the
      # file is missing or unreadable; callers surface this as a tool error.
      def content : String
        @content ||= File.read(@resolved_file)
      end

      # True when the role file is present on disk.
      def file_exists? : Bool
        File.file?(@resolved_file)
      end
    end
  end
end
