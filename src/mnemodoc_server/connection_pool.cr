module MnemodocServer
  # A small per-host pool of reusable HTTP clients, used to avoid reopening a
  # connection for every Ollama embedding request. Idle clients are retained
  # up to IDLE_PER_HOST per host; extras are closed. The cap is sized to cover
  # the default indexing concurrency so workers reuse connections instead of
  # constantly reopening them.
  class ConnectionPool
    IDLE_PER_HOST = 8

    def initialize(@timeout : Int32 = 30)
      @idle = {} of String => Array(HTTP::Client)
      @mutex = Mutex.new
    end

    # Returns a healthy client to the pool, or closes it if the pool is full.
    def checkin(uri : URI, client : HTTP::Client) : Nil
      key = host_key(uri)
      @mutex.synchronize do
        pool = (@idle[key] ||= [] of HTTP::Client)
        pool.size < IDLE_PER_HOST ? pool.push(client) : client.close
      end
    end

    # Reuses an idle client for the host, or creates a fresh one with the
    # configured connect and read timeouts applied.
    def checkout(uri : URI) : HTTP::Client
      key = host_key(uri)
      client = @mutex.synchronize { @idle[key]?.try(&.pop?) }
      unless client
        client = HTTP::Client.new(uri)
        client.connect_timeout = @timeout.seconds
        client.read_timeout = @timeout.seconds
      end
      client
    end

    # Closes a client that must not be reused (e.g. after a connection error).
    def discard(client : HTTP::Client) : Nil
      client.close rescue nil
    end

    # Closes all idle clients in the pool and clears the idle map.
    def close_all : Nil
      @mutex.synchronize do
        @idle.each_value { |clients| clients.each { |client| client.close rescue nil } }
        @idle.clear
      end
    end

    # Builds the pool bucket key from scheme, host and resolved port.
    private def host_key(uri : URI) : String
      port = uri.port || URI.default_port(uri.scheme || "http") || 80
      "#{uri.scheme}://#{uri.host}:#{port}"
    end
  end
end
