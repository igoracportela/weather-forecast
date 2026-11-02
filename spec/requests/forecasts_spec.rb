require "rails_helper"

RSpec.describe "Forecasts", type: :request do
  let(:address) { "1600 Pennsylvania Ave NW, Washington, DC" }
  let(:forecast_body) do
    ForecastFixture.week({
      "current" => { "temperature_2m" => 66.6, "weather_code" => 2 },
      "daily" => { "time" => %w[2026-10-29 2026-10-30], "temperature_2m_max" => [ 70.4, 61.0 ],
                   "temperature_2m_min" => [ 52.5, 48.9 ], "weather_code" => [ 2, 61 ] }
    })
  end

  def stub_census(matches:)
    stub_request(:get, Weather::AddressGeocoder::URL).with(query: hash_including({}))
      .to_return(body: { "result" => { "addressMatches" => matches } }.to_json)
  end

  def stub_forecast(response = { body: forecast_body.to_json })
    stub_request(:get, Weather::ForecastClient::URL).with(query: hash_including({})).to_return(response)
  end

  def stub_happy_path
    stub_census(matches: [ { "matchedAddress" => "1600 PENNSYLVANIA AVE NW, WASHINGTON, DC, 20500",
                             "coordinates" => { "x" => -77.03, "y" => 38.89 },
                             "addressComponents" => { "zip" => "20500" } } ])
    stub_forecast
  end

  def texts(selector)
    html.css(selector).map { |node| node.text.strip }
  end

  describe "GET / with no address" do
    it "shows the address form and makes no request" do
      get root_path

      expect(response).to have_http_status(:ok)
      expect(html.css("form[action='/'][method='get'] input[name='address']")).not_to be_empty
      expect(html.css(".forecast")).to be_empty
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  describe "GET / with a blank address" do
    it "shows the form without an error" do
      get root_path, params: { address: "   " }

      expect(response).to have_http_status(:ok)
      expect(html.css(".error")).to be_empty
    end
  end

  describe "GET / with a non-string address param" do
    it "treats an array as blank" do
      get root_path, params: { address: [ "a", "b" ] }

      expect(response).to have_http_status(:ok)
    end

    it "treats a hash as blank" do
      get "/?address[x]=1"

      expect(response).to have_http_status(:ok)
      expect(html.css(".error")).to be_empty
    end
  end

  describe "GET / with a resolvable address" do
    before do
      stub_happy_path
      get root_path, params: { address: address }
    end

    it "responds 200 with the zip and matched location" do
      expect(response).to have_http_status(:ok)
      expect(texts(".zip")).to include(a_string_matching(/20500/))
      expect(texts(".location")).to include(a_string_matching(/1600 PENNSYLVANIA AVE NW/))
    end

    it "shows the current temperature and today's high/low" do
      expect(texts(".current-temp")).to include("67°F")
      expect(texts(".high-low")).to include(a_string_matching(/H 70°F.*L 53°F/m))
    end

    it "shows a 7-day extended forecast" do
      expect(html.css(".extended tbody tr").size).to eq(7)
      expect(texts(".extended tbody tr:last-child")).to include(a_string_matching(/Slight rain/))
    end

    it "shows a Live badge and no Cached badge" do
      expect(texts(".source.live")).to include(a_string_matching(/Live/))
      expect(html.css(".source.cached")).to be_empty
    end
  end

  describe "a repeat request" do
    it "shows the Cached badge with the original fetch time" do
      stub_happy_path
      freeze_time
      fetched_at = Time.current
      get root_path, params: { address: address }

      travel 10.minutes
      get root_path, params: { address: address }

      expect(texts(".source.cached")).to include(a_string_matching(/Cached/))
      expect(texts(".source.cached time[datetime='#{fetched_at.iso8601}']")).to include("10 minutes ago")
      expect(html.css(".source.live")).to be_empty
    end
  end

  describe "invalid addresses" do
    it "is a 422 that keeps the typed address when unresolvable" do
      stub_census(matches: [])

      get root_path, params: { address: "zzzz nowhere" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(texts(".error")).to include(a_string_matching(/couldn't find that address/))
      expect(html.css("input[name='address']").map { |input| input["value"] }).to include("zzzz nowhere")
    end

    it "is a 422 with no outbound call when too long" do
      get root_path, params: { address: "a" * 201 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(texts(".error")).to include(a_string_matching(/200 characters/))
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  describe "bare zip" do
    it "is a 422 when unknown and a 503 on a geocoder outage" do
      zip_stub = stub_request(:get, Weather::ZipGeocoder::URL).with(query: hash_including({}))
        .to_return({ body: { "results" => [] }.to_json }, { status: 503, body: "{}" })

      get root_path, params: { address: "00000" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(html.css("input[name='address']").map { |input| input["value"] }).to include("00000")

      get root_path, params: { address: "00000" }
      expect(response).to have_http_status(:service_unavailable)
      expect(html.css("input[name='address']").map { |input| input["value"] }).to include("00000")
      expect(zip_stub).to have_been_requested.times(2)
    end
  end

  describe "upstream failures" do
    it "is a 503, not a 500, when the geocoder times out" do
      stub_request(:get, Weather::AddressGeocoder::URL).with(query: hash_including({})).to_timeout

      get root_path, params: { address: address }

      expect(response).to have_http_status(:service_unavailable)
      expect(texts(".error")).to include(a_string_matching(/Weather service unavailable/))
    end

    {
      "a 500 status" => { status: 500 },
      "a non-JSON body" => { body: "<html>" },
      "JSON missing the forecast series" => { body: { "daily" => {} }.to_json }
    }.each do |label, forecast_response|
      it "is a 503 when the forecast API returns #{label}" do
        stub_happy_path
        stub_forecast(forecast_response)

        get root_path, params: { address: address }

        expect(response).to have_http_status(:service_unavailable)
        expect(texts(".error")).to include(a_string_matching(/Weather service unavailable/))
      end
    end

    it "logs the failure without the address" do
      stub_request(:get, Weather::AddressGeocoder::URL).with(query: hash_including({})).to_timeout

      log = capture_log { get root_path, params: { address: address } }

      expect(log).to match(/\[forecast\] upstream failure: geocoding\.geo\.census\.gov/)
      expect(log.lines.grep(/upstream failure/).join).not_to match(/Pennsylvania/i)
    end
  end

  describe "escaping" do
    it "escapes user input" do
      stub_census(matches: [])

      get root_path, params: { address: "<script>alert(1)</script>" }

      expect(response.body).not_to include("<script>alert(1)</script>")
    end

    it "escapes strings from the APIs" do
      stub_census(matches: [ { "matchedAddress" => "<img src=x onerror=alert(1)>",
                               "coordinates" => { "x" => -77.03, "y" => 38.89 },
                               "addressComponents" => { "zip" => "20500", "city" => "<b>X</b>" } } ])
      stub_forecast

      get root_path, params: { address: address }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("<img src=x")
      expect(response.body).to include("&lt;img src=x onerror=alert(1)&gt;")
    end
  end

  describe "parameter filtering" do
    it "filters the address from logs" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      expect(filter.filter("address" => "1 Main St")["address"]).to eq("[FILTERED]")
    end
  end
end
