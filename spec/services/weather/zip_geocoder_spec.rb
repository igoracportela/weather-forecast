require "rails_helper"

RSpec.describe Weather::ZipGeocoder do
  let(:open_meteo) { described_class::URL }

  def stub_open_meteo(body)
    stub_request(:get, open_meteo).with(query: hash_including({})).to_return(body: body)
  end

  describe ".call" do
    context "when a US result's postcodes contain the zip" do
      before do
        body = {
          "results" => [
            { "name" => "Elsewhere", "admin1" => "Nevada", "latitude" => 1, "longitude" => 2, "postcodes" => [ "89501" ] },
            { "name" => "San Francisco", "admin1" => "California", "latitude" => 37.77, "longitude" => -122.42,
              "postcodes" => [ "94102", "94103" ] }
          ]
        }
        stub_request(:get, open_meteo)
          .with(query: hash_including("name" => "94103", "countryCode" => "US"))
          .to_return(body: body.to_json)
      end

      it "picks that result" do
        location = described_class.call("94103")

        expect(location.zip).to eq("94103")
        expect(location.name).to eq("San Francisco, California")
        expect(location.place).to eq("San Francisco, California")
        expect(location.latitude).to be_within(0.001).of(37.77)
      end
    end

    context "when no result lists the zip" do
      it "raises NotFound" do
        stub_open_meteo({ "results" => [ { "name" => "X", "postcodes" => [ "11111" ] } ] }.to_json)

        expect { described_class.call("00000") }.to raise_error(Weather::NotFound)
      end
    end

    context "when results are absent" do
      it "raises NotFound" do
        stub_open_meteo({ "generationtime_ms" => 0.1 }.to_json)

        expect { described_class.call("00000") }.to raise_error(Weather::NotFound)
      end
    end

    context "when results have no postcodes" do
      it "treats them as not found" do
        stub_open_meteo({ "results" => [ { "name" => "X", "latitude" => 1, "longitude" => 2 } ] }.to_json)

        expect { described_class.call("94103") }.to raise_error(Weather::NotFound)
      end
    end

    context "with non-object results" do
      it "raises ServiceError" do
        stub_open_meteo({ "results" => [ "x" ] }.to_json)

        expect { described_class.call("94103") }.to raise_error(Weather::ServiceError)
      end
    end

    context "when the body or results are not the expected shape" do
      [ "[]", "null", "42", '"x"', '{"results":"x"}', '{"results":{"a":1}}' ].each do |raw|
        it "raises ServiceError for body #{raw}" do
          stub_open_meteo(raw)

          expect { described_class.call("94103") }.to raise_error(Weather::ServiceError)
        end
      end
    end

    context "when the matching result has no coordinates" do
      it "raises ServiceError" do
        stub_open_meteo({ "results" => [ { "name" => "X", "postcodes" => [ "94103" ] } ] }.to_json)

        expect { described_class.call("94103") }.to raise_error(Weather::ServiceError)
      end
    end
  end
end
