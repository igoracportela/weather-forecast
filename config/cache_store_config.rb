# Picks the Rails.cache backend from the environment.
# Loaded from config/application.rb, before autoloading exists.
module CacheStoreConfig
  MEMORY_SIZE = 32 * 1024 * 1024

  module_function

  def for(env)
    url = env["REDIS_URL"].presence
    return [ :memory_store, { size: MEMORY_SIZE } ] unless url

    [ :redis_cache_store, {
      url: url,
      namespace: "weather",
      # Fail fast: a slow cache must not cost more than the fetch it saves.
      connect_timeout: 1,
      read_timeout: 0.5,
      write_timeout: 0.5,
      reconnect_attempts: 0,
      error_handler: method(:log_error)
    } ]
  end

  # RedisCacheStore already treats the failure as a miss; this only makes it visible.
  def log_error(method:, returning:, exception:)
    Rails.logger.warn("[cache] #{method} failed: #{exception.class}: #{exception.message}")
  end
end
