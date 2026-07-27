require "./mnemodoc_server"

# Entry point. Everything else lives in src/mnemodoc_server.cr, which is a
# library: requiring it has no side effect and starts nothing.
#
# The two were one file until they weren't: the bench/ harness required it and
# the application's argument parser silently ate the harness's own ARGV. Keep
# this file to the program's own concern — running — so anything that needs the
# code can require the library instead.
begin
  MnemodocServer::CLI.run
rescue e : Exception
  STDERR.puts e.message
  exit 1
end
