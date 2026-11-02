require "rails_helper"

RSpec.describe Weather::Lookup do
  let(:forecast_body) do
    ForecastFixture.week({
      "current" => { "temperature_2m" => 66.6, "weather_code" => 0 },
      "daily" => { "time" => %w[2026-10-29], "temperature_2m_max" => [ 70.0 ],
                   "temperature_2m_min" => [ 50.0 ], "weather_code" => [ 0 ] }
    })
  end

  def census_body(address, zip: "20500")
    { "result" => { "addressMatches" => [ {
      "matchedAddress" => address.upcase, "coordinates" => { "x" => -77.03, "y" => 38.89 },
      "addressComponents" => { "zip" => zip, "city" => "WASHINGTON", "state" => "DC" } } ] } }
  end

  def stub_census(address, zip: "20500")
    stub_request(:get, Weather::AddressGeocoder::URL)
      .with(query: hash_including("address" => address))
      .to_return(body: census_body(address, zip: zip).to_json)
  end

  def stub_zip_geocoder(zip)
    stub_request(:get, Weather::ZipGeocoder::URL).with(query: hash_including("name" => zip))
      .to_return(body: { "results" => [ { "name" => "Washington", "admin1" => "District of Columbia",
                                          "latitude" => 38.89, "longitude" => -77.03, "postcodes" => [ zip ] } ] }.to_json)
  end

  def stub_forecast
    stub_request(:get, Weather::ForecastClient::URL).with(query: hash_including({}))
      .to_return(body: forecast_body.to_json)
  end

  describe "caching by zip" do
    it "is live on the first lookup and cached on the second for the same address" do
      stub_census("1600 Pennsylvania Ave")
      forecast = stub_forecast

      first = described_class.call("1600 Pennsylvania Ave")
      second = described_class.call("1600 Pennsylvania Ave")

      expect(first).not_to be_cached
      expect(second).to be_cached
      expect(second.zip).to eq("20500")
      expect(second.current_temperature).to eq(66.6)
      expect(forecast).to have_been_requested.times(1)
    end

    it "shares one forecast between different addresses in the same zip" do
      stub_census("1600 Pennsylvania Ave")
      stub_census("1 Lafayette Sq")
      forecast = stub_forecast

      described_class.call("1600 Pennsylvania Ave")
      second = described_class.call("1 Lafayette Sq")

      expect(second).to be_cached
      expect(second.location_name).to eq("1 LAFAYETTE SQ")
      expect(forecast).to have_been_requested.times(1)
    end

    it "caches different zips separately" do
      stub_census("1600 Pennsylvania Ave", zip: "20500")
      stub_census("1 Main St", zip: "10001")
      forecast = stub_forecast

      described_class.call("1600 Pennsylvania Ave")
      other = described_class.call("1 Main St")

      expect(other).not_to be_cached
      expect(forecast).to have_been_requested.times(2)
    end

    it "does not cache a failed forecast" do
      stub_census("1600 Pennsylvania Ave")
      stub_request(:get, Weather::ForecastClient::URL).with(query: hash_including({}))
        .to_return({ status: 500 }, { body: forecast_body.to_json })

      expect { described_class.call("1600 Pennsylvania Ave") }.to raise_error(Weather::ServiceError)
      result = described_class.call("1600 Pennsylvania Ave")

      expect(result).not_to be_cached
      expect(result.current_temperature).to eq(66.6)
    end
  end

  describe "bare zip input" do
    context "with a cache entry" do
      before do
        stub_census("1600 Pennsylvania Ave")
      end

      it "calls no external API at all" do
        forecast = stub_forecast
        zip_geocoder = stub_zip_geocoder("20500")
        described_class.call("1600 Pennsylvania Ave")

        result = described_class.call("20500")

        expect(result).to be_cached
        expect(zip_geocoder).not_to have_been_requested
        expect(forecast).to have_been_requested.times(1)
      end

      it "never reveals the earlier visitor's street address" do
        stub_forecast
        described_class.call("1600 Pennsylvania Ave")

        result = described_class.call("20500")

        expect(result.location_name).to eq("WASHINGTON, DC")
        expect(Rails.cache.read("forecast/v1/20500").to_s).not_to match(/PENNSYLVANIA/)
      end
    end

    context "without a cache entry" do
      it "geocodes the zip and fetches live" do
        zip_geocoder = stub_zip_geocoder("20500")
        stub_forecast

        result = described_class.call(" 20500-0003 ")

        expect(result).not_to be_cached
        expect(result.zip).to eq("20500")
        expect(result.location_name).to eq("Washington, District of Columbia")
        expect(zip_geocoder).to have_been_requested.times(1)
      end

      it "does not cache a failed zip geocode and retries it with the right coordinates" do
        zip_geocoder = stub_request(:get, Weather::ZipGeocoder::URL).with(query: hash_including("name" => "20500"))
          .to_return({ status: 500 }, { body: { "results" => [ { "name" => "Washington", "latitude" => 38.89,
                                                                 "longitude" => -77.03, "postcodes" => [ "20500" ] } ] }.to_json })
        forecast = stub_request(:get, Weather::ForecastClient::URL)
          .with(query: hash_including("latitude" => "38.89", "longitude" => "-77.03"))
          .to_return(body: forecast_body.to_json)

        expect { described_class.call("20500") }.to raise_error(Weather::ServiceError)
        expect(Rails.cache.read("forecast/v1/20500")).to be_nil
        result = described_class.call("20500")

        expect(result).not_to be_cached
        expect(zip_geocoder).to have_been_requested.times(2)
        expect(forecast).to have_been_requested.times(1)
      end
    end

    it "keeps the street address out of the cache even when Census gives no city or state" do
      stub_request(:get, Weather::AddressGeocoder::URL).with(query: hash_including({}))
        .to_return(body: { "result" => { "addressMatches" => [ {
          "matchedAddress" => "1600 PENNSYLVANIA AVE NW", "coordinates" => { "x" => -77.03, "y" => 38.89 },
          "addressComponents" => { "zip" => "20500" } } ] } }.to_json)
      stub_forecast
      described_class.call("1600 Pennsylvania Ave")

      result = described_class.call("20500")

      expect(result.location_name).to eq("20500")
      expect(Rails.cache.read("forecast/v1/20500").to_s).not_to match(/PENNSYLVANIA/)
    end
  end

  describe "addresses that merely contain 5 digits" do
    [ "10100 Santa Monica Blvd, Los Angeles, CA", "1600 Pennsylvania Ave NW, Washington, DC 20500" ].each do |address|
      it "sends #{address.inspect} to the address geocoder" do
        census = stub_census(address)
        stub_forecast
        zip_geocoder = stub_request(:get, Weather::ZipGeocoder::URL).with(query: hash_including({}))

        described_class.call(address)

        expect(census).to have_been_requested.times(1)
        expect(zip_geocoder).not_to have_been_requested
      end
    end
  end

  describe "expiry" do
    before do
      stub_census("1600 Pennsylvania Ave")
      freeze_time
    end

    it "expires the cache at 30 minutes, not before" do
      forecast = stub_forecast
      described_class.call("1600 Pennsylvania Ave")

      travel 29.minutes + 59.seconds
      expect(described_class.call("1600 Pennsylvania Ave")).to be_cached

      travel 1.second
      refreshed = described_class.call("1600 Pennsylvania Ave")
      expect(refreshed).not_to be_cached
      expect(refreshed.fetched_at).to eq(Time.current)
      expect(forecast).to have_been_requested.times(2)
    end

    it "reports when a cached result was originally fetched" do
      stub_forecast
      fetched = Time.current
      described_class.call("1600 Pennsylvania Ave")

      travel 10.minutes
      expect(described_class.call("1600 Pennsylvania Ave").fetched_at).to eq(fetched)
    end
  end

  describe "input validation" do
    it "rejects blank input before any request" do
      expect { described_class.call("   ") }.to raise_error(Weather::InvalidInput)
    end

    it "rejects over-long input before any request" do
      expect { described_class.call("a" * 201) }.to raise_error(Weather::InvalidInput)
    end

    it "accepts an address of exactly 200 characters" do
      address = "1 Main St " + ("x" * 190)
      expect(address.length).to eq(200)
      stub_census(address)
      stub_forecast

      expect(described_class.call(address).zip).to eq("20500")
    end
  end

  # The cache is an optimisation, so its failures and expiry edges must never break a lookup.
  describe "cache resilience" do
    def with_cache(store)
      original = Rails.cache
      Rails.cache = store
      yield
    ensure
      Rails.cache = original
    end

    before do
      stub_request(:get, Weather::ZipGeocoder::URL).with(query: hash_including("name" => "20500"))
        .to_return(body: { "results" => [ { "name" => "Washington", "latitude" => 38.89, "longitude" => -77.03,
                                            "postcodes" => [ "20500" ] } ] }.to_json)
    end

    it "degrades an unreachable Redis to a Live lookup, logged, without raising or hanging" do
      errors = []
      _, options = CacheStoreConfig.for("REDIS_URL" => "redis://127.0.0.1:1/0")
      options[:error_handler] = ->(method:, returning:, exception:) { errors << [ method, exception.class ] }
      forecast = stub_request(:get, Weather::ForecastClient::URL).with(query: hash_including({}))
        .to_return(body: forecast_body.to_json)

      with_cache(ActiveSupport::Cache::RedisCacheStore.new(**options)) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        results = Array.new(2) { described_class.call("20500") }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(results.none?(&:cached?)).to be(true), "a broken cache must never be reported as Cached"
        expect(results.map(&:current_temperature)).to eq([ 66.6, 66.6 ])
        expect(elapsed).to be < 3
      end
      expect(forecast).to have_been_requested.times(2)
      expect(errors).not_to be_empty
    end

    it "logs cache failures through the configured error handler" do
      _, options = CacheStoreConfig.for("REDIS_URL" => "redis://127.0.0.1:1/0")

      log = capture_log(level: :warn) do
        options[:error_handler].call(method: :read, returning: nil, exception: Redis::CannotConnectError.new("refused"))
      end

      expect(log).to match(/\[cache\] read failed: Redis::CannotConnectError/)
    end

    it "lets the next request use the stale copy when a refresh just after expiry fails" do
      stub_request(:get, Weather::ForecastClient::URL).with(query: hash_including({}))
        .to_return({ body: forecast_body.to_json }, { status: 500 })
      freeze_time
      described_class.call("20500")

      travel 30.minutes + 1.second
      expect { described_class.call("20500") }.to raise_error(Weather::ServiceError)

      travel 2.seconds
      stale = described_class.call("20500")
      expect(stale).to be_cached
      expect(stale.current_temperature).to eq(66.6)
    end
  end
end
