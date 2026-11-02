module Weather
  # Resolves a bare 5-digit zip via Open-Meteo's geocoder; Census can't.
  module ZipGeocoder
    URL = "https://geocoding-api.open-meteo.com/v1/search".freeze

    module_function

    def call(zip)
      body = HttpJson.get(URL, name: zip, countryCode: "US", count: 10, format: "json")
      # Open-Meteo omits "results" entirely when nothing matches; any other shape is an upstream fault.
      results = body.fetch("results", []) if body.is_a?(Hash)
      unless results.is_a?(Array) && results.all?(Hash)
        raise ServiceError, "zip geocoder returned an unexpected payload"
      end

      match = results.find { |r| Array(r["postcodes"]).include?(zip) }
      raise NotFound, "no place lists zip #{zip}" unless match

      place = [ match["name"], match["admin1"] ].compact_blank.join(", ").presence || zip
      Location.new(zip: zip, latitude: Float(match["latitude"]), longitude: Float(match["longitude"]),
                   name: place, place: place)
    rescue TypeError, ArgumentError
      raise ServiceError, "zip geocoder returned bad coordinates"
    end
  end
end
