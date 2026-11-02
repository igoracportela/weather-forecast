require "rails_helper"

RSpec.describe Weather::ForecastClient do
  subject(:call) { described_class.call(latitude: 1, longitude: 2) }

  let(:url) { described_class::URL }
  let(:base_body) do
    ForecastFixture.week({
      "current" => { "time" => "2026-10-29T12:00", "temperature_2m" => 66.6, "weather_code" => 3 },
      "daily" => {
        "time" => %w[2026-10-29 2026-10-30],
        "temperature_2m_max" => [ 70.1, 61.0 ],
        "temperature_2m_min" => [ 52.4, 48.9 ],
        "weather_code" => [ 3, 61 ]
      }
    })
  end
  let(:body) { base_body.deep_dup }

  def stub_forecast(raw)
    stub_request(:get, url).with(query: hash_including({})).to_return(body: raw)
  end

  it "requests fahrenheit for the coordinates and maps current, high/low and days" do
    stub = stub_request(:get, url)
      .with(query: hash_including("latitude" => "38.9", "longitude" => "-77.0",
                                  "temperature_unit" => "fahrenheit", "forecast_days" => "7"))
      .to_return(body: base_body.to_json)

    data = described_class.call(latitude: 38.9, longitude: -77.0)

    expect(stub).to have_been_requested.once
    expect(data).to include("current_temperature" => 66.6, "current_conditions" => "Overcast",
                            "today_high" => 70.1, "today_low" => 52.4)
    expect(data["days"].size).to eq(7)
    expect(data["days"].second)
      .to eq({ "date" => "2026-10-30", "high" => 61.0, "low" => 48.9, "conditions" => "Slight rain" })
    expect(data["days"].last)
      .to eq({ "date" => "2026-11-04", "high" => 61.0, "low" => 48.9, "conditions" => "Slight rain" })
  end

  it "degrades unknown weather codes to a generic label" do
    body["current"]["weather_code"] = 999
    stub_forecast(body.to_json)

    expect(call["current_conditions"]).to eq("Unknown")
  end

  it "raises ServiceError when the current temperature is missing" do
    stub_forecast({ "daily" => base_body["daily"] }.to_json)

    expect { call }.to raise_error(Weather::ServiceError)
  end

  it "raises ServiceError for ragged daily arrays" do
    body["daily"]["temperature_2m_min"] = [ 1.0 ]
    stub_forecast(body.to_json)

    expect { call }.to raise_error(Weather::ServiceError)
  end

  context "with a malformed or missing date" do
    [ "29/10/2026", nil ].each do |bad|
      it "raises ServiceError for #{bad.inspect} instead of reaching the view" do
        # Corrupt one date inside a full week: replacing the whole array with two
        # entries trips the 7-day check first and never reaches the date parse.
        body["daily"]["time"][1] = bad
        expect(body["daily"]["time"].size).to eq(Weather::ForecastClient::DAYS)
        stub_forecast(body.to_json)

        expect { call }.to raise_error(Weather::ServiceError, /unexpected payload/)
      end
    end
  end

  context "with a non-object body" do
    [ "[1]", "null", "1", '"x"', '{"current":1,"daily":"x"}' ].each do |raw|
      it "raises ServiceError for #{raw}" do
        stub_forecast(raw)

        expect { call }.to raise_error(Weather::ServiceError)
      end
    end
  end

  context "with a null, non-numeric, infinite or implausible temperature" do
    [ nil, "abc", "1e400", 500.0, -300.0 ].each do |bad|
      [ %w[current temperature_2m], %w[daily temperature_2m_max], %w[daily temperature_2m_min] ]
        .each do |section, field|
          it "raises ServiceError for #{section}.#{field}=#{bad.inspect}" do
            section == "current" ? body["current"][field] = bad : body["daily"][field][3] = bad
            stub_forecast(body.to_json)

            expect { call }.to raise_error(Weather::ServiceError)
          end
        end
    end
  end

  context "with number literals that overflow to infinity" do
    [ [ '"temperature_2m":66.6', '"temperature_2m":1e400' ],
      [ '"temperature_2m_min":[52.4', '"temperature_2m_min":[-1e400' ] ].each do |from, to|
      it "raises ServiceError for #{to}" do
        raw = base_body.to_json.sub(from, to)
        expect(raw).to include(to)
        stub_forecast(raw)

        expect { call }.to raise_error(Weather::ServiceError)
      end
    end
  end

  it "raises ServiceError for fewer than 7 days" do
    body["daily"].transform_values! { |series| series.first(1) }
    stub_forecast(body.to_json)

    expect { call }.to raise_error(Weather::ServiceError)
  end
end
