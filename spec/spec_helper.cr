require "spectator"

# Parallelism is a runtime decision now, not a compile flag: the default
# execution context starts at 1 and is resized on demand. `-Dpreview_mt` still
# works but the compiler deprecates it, pointing here.
#
# Off unless asked for, because the two schedulers answer different questions.
# The cooperative run is the reference — deterministic, and what every other
# job checks. The parallel one exists to catch what cooperation hides: state
# shared across fibers that only collides when two of them truly run at once.
# The constant check is not decoration: execution contexts are gated
# differently across the versions this project is built with. On the pinned
# 1.20.3 they need `-Dpreview_mt -Dexecution_context`; from 1.21 they are the
# default and `-Dpreview_mt` disables them. Without this guard the suite fails
# to COMPILE wherever they are absent — every job, not just the parallel one.
{% if Fiber.has_constant?("ExecutionContext") %}
  if ENV["MNEMODOC_SPEC_PARALLEL"]?.try { |value| value != "0" && !value.empty? }
    Fiber::ExecutionContext.default.resize(Fiber::ExecutionContext.default_workers_count)
  end
{% end %}

Spectator.configure do |config|
  config.randomize
  config.profile
end

require "../src/mnemodoc_server"

def with_env(values : Hash(String, String), &)
  old_values = {} of String => String?
  begin
    values.each do |key, value|
      old_values[key] = ENV[key]?
      ENV[key] = value
    end
    yield
  ensure
    old_values.each do |key, old_value|
      if old_value
        ENV[key] = old_value
      else
        ENV.delete(key)
      end
    end
  end
end
