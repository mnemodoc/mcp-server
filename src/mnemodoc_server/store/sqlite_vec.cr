# Links the upstream sqlite-vec amalgamation (from the ext/sqlite-vec submodule,
# compiled with -DSQLITE_CORE) and our per-connection registration shim
# (vendor/vec0_shim.c). Both objects are produced under vendor/ by the
# dev:vec0-objects task. The absolute paths ensure the linker finds them
# regardless of the working directory at link time.
@[Link(ldflags: "#{__DIR__}/../../../vendor/sqlite-vec.o #{__DIR__}/../../../vendor/vec0_shim.o")]
lib LibVec
  # Registers the vec0 extension on one SQLite connection handle. Returns the
  # SQLite result code (0 = SQLITE_OK). Called from DB#setup_connection so every
  # connection in the crystal-db pool has vec0 available before any query.
  fun mnemo_vec_init(db : Void*) : Int32
end
