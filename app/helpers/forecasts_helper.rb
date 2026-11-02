module ForecastsHelper
  def temperature(value)
    "#{value.round}°F"
  end

  def forecast_day(iso_date)
    Date.iso8601(iso_date).strftime("%a %b %-d")
  end
end
