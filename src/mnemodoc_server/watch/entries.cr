module MnemodocServer
  module Watch
    # Yields each entry of *dir* with whether it is a directory: true, false,
    # or nil when the listing does not say (a symlink, or a filesystem that
    # leaves `d_type` unset). An unreadable directory — gone, or not ours —
    # yields nothing.
    #
    # Reads `d_type` straight from readdir so that telling a file from a
    # directory costs no stat; Dir#each_child exposes names only, and the
    # stdlib's own entry type is internal.
    def self.each_entry(dir : String, & : String, Bool? ->) : Nil
      handle = LibC.opendir(dir)
      return if handle.null?
      begin
        while entry = LibC.readdir(handle)
          name = String.new(entry.value.d_name.to_unsafe)
          next if name == "." || name == ".."
          is_dir =
            case entry.value.d_type
            when LibC::DT_DIR                   then true
            when LibC::DT_UNKNOWN, LibC::DT_LNK then nil
            else                                     false
            end
          yield name, is_dir
        end
      ensure
        LibC.closedir(handle)
      end
    end

    # Resolves an entry whose type readdir left unknown. A symlinked directory
    # is reported as :skip — never followed, as the glob this code replaced,
    # and to stay out of cycles — while a symlinked file counts as a file.
    def self.resolve_unknown(path : String) : Symbol
      link = File.info?(path, follow_symlinks: false)
      return :skip unless link
      if link.symlink?
        File.info?(path).try(&.file?) ? :file : :skip
      elsif link.directory?
        :dir
      else
        :file
      end
    end
  end
end
