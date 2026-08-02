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
  # A reader that walked away is not a failure of this program: `| head` takes
  # its lines and leaves, `| less` is quit halfway, an MCP client hangs up.
  # Crystal's runtime ignores SIGPIPE at startup, so the process is not killed
  # and the write comes back EPIPE instead — which fell straight into the
  # catch-all below and answered a perfectly ordinary `| head` with a stack
  # trace and a non-zero exit. Exit quietly and successfully: the output was
  # truncated because the reader asked for it.
  #
  # Matched on the errno rather than on the message, which is not a contract.
  exit 0 if e.is_a?(IO::Error) && e.os_error == Errno::EPIPE
  # Class and backtrace, not just the message: an exception whose message is
  # nil printed a blank line, and even a good message says nothing about where
  # it came from. This is the only diagnosis a user gets when the server fails
  # under an MCP client, which shows them nothing else.
  STDERR.puts e.inspect_with_backtrace
  exit 1
end
