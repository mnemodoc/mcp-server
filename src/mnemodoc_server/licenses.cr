require "baked_file_system"

module MnemodocServer
  # Third-party and project license texts embedded into the binary at compile
  # time, so the redistributed artifact (bare binary or distroless image) always
  # carries the notices required by its statically-linked dependencies. The
  # folder is assembled by the `dev:licenses` / Makefile `licenses` task.
  class Licenses
    extend BakedFileSystem

    bake_folder "../../licenses"
  end
end
