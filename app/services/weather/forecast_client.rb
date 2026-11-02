module Weather
  # Fetches current conditions and a 7-day forecast from Open-Meteo.
  # Returns a Hash of primitives so it can be cached as-is.
  module ForecastClient
    URL = "https://api.open-meteo.com/v1/forecast".freeze
    DAYS = 7
    # Anything outside this range (°F) is a broken payload, not weather.
    PLAUSIBLE = -150.0..150.0

    # WMO weather interpretation codes, as documented by Open-Meteo.
    CONDITIONS = {
      0 => "Clear sky", 1 => "Mainly clear", 2 => "Partly cloudy", 3 => "Overcast",
      45 => "Fog", 48 => "Rime fog",
      51 => "Light drizzle", 53 => "Drizzle", 55 => "Dense drizzle",
      56 => "Freezing drizzle", 57 => "Dense freezing drizzle",
      61 => "Slight rain", 63 => "Rain", 65 => "Heavy rain",
      66 => "Freezing rain", 67 => "Heavy freezing rain",
      71 => "Slight snow", 73 => "Snow", 75 => "Heavy snow", 77 => "Snow grains",
      80 => "Rain showers", 81 => "Heavy rain showers", 82 => "Violent rain showers",
      85 => "Snow showers", 86 => "Heavy snow showers",
      95 => "Thunderstorm", 96 => "Thunderstorm with hail", 99 => "Thunderstorm with heavy hail"
    }.freeze

    module_function

    def call(latitude:, longitude:)
      body = HttpJson.get(URL,
        latitude: latitude, longitude: longitude,
        current: "temperature_2m,weather_code",
        daily: "temperature_2m_max,temperature_2m_min,weather_code",
        temperature_unit: "fahrenheit", timezone: "auto", forecast_days: DAYS)

      days = build_days(body.fetch("daily"))
      current = body.fetch("current")

      {
        "current_temperature" => temperature(current.fetch("temperature_2m")),
        "current_conditions" => conditions(current["weather_code"]),
        "today_high" => days.first.fetch("high"),
        "today_low" => days.first.fetch("low"),
        "days" => days
      }
    rescue KeyError, TypeError, ArgumentError, NoMethodError, Date::Error
      raise ServiceError, "forecast API returned an unexpected payload"
    end

    def build_days(daily)
      dates, highs, lows, codes = daily.values_at("time", "temperature_2m_max", "temperature_2m_min", "weather_code")
      raise ServiceError, "forecast has #{Array(dates).size} days, expected #{DAYS}" unless dates.is_a?(Array) && dates.size == DAYS
      unless [ highs, lows, codes ].all? { |series| series.is_a?(Array) && series.size == dates.size }
        raise ServiceError, "forecast daily series differ in length"
      end

      dates.each_index.map do |i|
        # Parse here, not in the view: a bad date must fail before it is cached.
        { "date" => Date.iso8601(dates[i]).iso8601, "high" => temperature(highs[i]), "low" => temperature(lows[i]),
          "conditions" => conditions(codes[i]) }
      end
    end

    # Float() alone lets Infinity (JSON "1e400") through, which would be cached
    # and then raise in the view on every hit.
    def temperature(value)
      Float(value).tap { |t| raise ServiceError, "implausible temperature #{t}" unless PLAUSIBLE.cover?(t) }
    end

    def conditions(code)
      CONDITIONS.fetch(code, "Unknown")
    end
  end
end
