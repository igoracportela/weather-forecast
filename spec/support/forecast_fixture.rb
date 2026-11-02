# Pads an Open-Meteo forecast body to the full 7 days the client requires,
# repeating the last given day on consecutive dates.
module ForecastFixture
  module_function

  def week(body)
    daily = body["daily"]
    first = Date.iso8601(daily["time"].first)
    padded = %w[temperature_2m_max temperature_2m_min weather_code].to_h do |series|
      values = daily[series]
      [ series, values + [ values.last ] * (Weather::ForecastClient::DAYS - values.size) ]
    end
    dates = Array.new(Weather::ForecastClient::DAYS) { |i| (first + i).iso8601 }
    body.merge("daily" => padded.merge("time" => dates)).freeze
  end
end
