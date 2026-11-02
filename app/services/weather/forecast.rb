module Weather
  # What the page renders. Built after the cache read, never cached itself.
  Forecast = Data.define(:zip, :location_name, :current_temperature, :current_conditions,
                         :today_high, :today_low, :days, :fetched_at, :cached) do
    alias_method :cached?, :cached
  end
end
