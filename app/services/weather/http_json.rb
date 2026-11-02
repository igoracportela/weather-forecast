require "net/http"

module Weather
  # Minimal JSON GET client. Every transport or parse failure becomes a
  # ServiceError so callers handle exactly one upstream error type.
  module HttpJson
    TIMEOUT = 5 # seconds, open and read

    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, IOError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error
    ].freeze

    module_function

    def get(url, params = {})
      uri = URI(url)
      uri.query = URI.encode_www_form(params) if params.any?

      # max_retries: 0 so Net::HTTP's silent GET retry can't double the timeout budget.
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: TIMEOUT, read_timeout: TIMEOUT, max_retries: 0) do |http|
        http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
      end

      if response.is_a?(Net::HTTPTooManyRequests)
        raise ServiceError, "#{uri.host} rate limited (429, retry-after #{response["Retry-After"] || "unset"})"
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise ServiceError, "#{uri.host} responded #{response.code}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise ServiceError, "#{uri.host} returned invalid JSON"
    rescue *NETWORK_ERRORS => e
      raise ServiceError, "#{uri.host} unreachable: #{e.class}"
    end
  end
end
