require "spectator"
require "crystal-env/spec"

Spectator.configure do |config|
  config.randomize
  config.profile
end

require "../src/mnemodoc-server"

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
