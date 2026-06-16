require "./spec_helper"

# Guards against adding a runtime shard without recording its license notice.
Spectator.describe "license manifest coverage" do
  # Shards present only for development, never compiled into the binary.
  DEV_ONLY = %w[ameba spectator]

  it "lists every runtime shard in licenses.manifest" do
    manifest = File.read("licenses.manifest")
    shard_dirs = Dir.children("lib").select { |entry| Dir.exists?(File.join("lib", entry)) }
    runtime = shard_dirs.reject { |entry| DEV_ONLY.includes?(entry) }

    missing = runtime.reject { |name| manifest.includes?("| #{name} ") || manifest.includes?("| #{name}\n") }
    expect(missing).to be_empty
  end
end
