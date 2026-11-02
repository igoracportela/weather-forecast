module Weather
  # Address in, Forecast out. Forecasts are cached per zip for 30 minutes.
  module Lookup
    CACHE_TTL = 30.minutes
    # Just after expiry, one request refreshes while others get the stale copy.
    RACE_TTL = 10.seconds
    MAX_LENGTH = 200
    BARE_ZIP = /\A(\d{5})(?:-\d{4})?\z/

    module_function

    def call(address)
      address = address.to_s.squish
      raise InvalidInput, "Please enter an address" if address.empty?
      raise InvalidInput, "Address must be #{MAX_LENGTH} characters or fewer" if address.length > MAX_LENGTH

      if (zip = address[BARE_ZIP, 1])
        # The zip is already the key: check the cache before geocoding.
        # Only the zip-level "place" is shared through the cache, never another
        # visitor's street address.
        payload, cached = cached_payload(zip) { ZipGeocoder.call(zip) }
        build(zip, payload["place"], payload, cached)
      else
        location = AddressGeocoder.call(address)
        payload, cached = cached_payload(location.zip) { location }
        build(location.zip, location.name, payload, cached)
      end
    end

    # The block yields the Location to forecast for; it only runs on a miss.
    # `cached` is flipped inside the miss block, so it can't race expiry.
    def cached_payload(zip)
      cached = true
      payload = Rails.cache.fetch(cache_key(zip), expires_in: CACHE_TTL, race_condition_ttl: RACE_TTL) do
        cached = false
        location = yield
        ForecastClient.call(latitude: location.latitude, longitude: location.longitude)
          .merge("place" => location.place, "fetched_at" => Time.current.iso8601(6))
      end
      [ payload, cached ]
    end

    def cache_key(zip)
      "forecast/v1/#{zip}"
    end

    def build(zip, location_name, payload, cached)
      Forecast.new(
        zip: zip,
        location_name: location_name,
        current_temperature: payload["current_temperature"],
        current_conditions: payload["current_conditions"],
        today_high: payload["today_high"],
        today_low: payload["today_low"],
        days: payload["days"],
        fetched_at: Time.iso8601(payload["fetched_at"]).in_time_zone,
        cached: cached
      )
    end
  end
end
