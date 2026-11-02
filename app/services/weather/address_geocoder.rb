module Weather
  # Resolves a US street address via the US Census geocoder.
  module AddressGeocoder
    URL = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress".freeze
    ZIP = /\A\d{5}\z/

    module_function

    def call(address)
      body = HttpJson.get(URL, address: address, benchmark: "Public_AR_Current", format: "json")
      matches = body.dig("result", "addressMatches") if body.is_a?(Hash) && body["result"].is_a?(Hash)
      raise ServiceError, "census geocoder returned an unexpected payload" unless matches.is_a?(Array)

      match = matches.first or raise NotFound, "no match for address"
      unless match.is_a?(Hash) && match["addressComponents"].is_a?(Hash)
        raise ServiceError, "census geocoder returned an unexpected match"
      end

      zip = match["addressComponents"]["zip"].to_s
      raise NotFound, "match has no zip" unless zip.match?(ZIP)

      Location.new(
        zip: zip,
        latitude: Float(match.dig("coordinates", "y")),
        longitude: Float(match.dig("coordinates", "x")),
        name: match["matchedAddress"],
        place: match["addressComponents"].values_at("city", "state").compact_blank.join(", ").presence || zip
      )
    rescue TypeError, ArgumentError
      raise ServiceError, "census geocoder returned bad coordinates"
    end
  end
end
