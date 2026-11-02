require "rails_helper"

RSpec.describe Weather::AddressGeocoder do
  let(:census) { described_class::URL }

  def census_match(zip: "20500")
    {
      "result" => {
        "addressMatches" => [ {
          "matchedAddress" => "1600 PENNSYLVANIA AVE NW, WASHINGTON, DC, 20500",
          "coordinates" => { "x" => -77.0352, "y" => 38.8987 },
          "addressComponents" => { "zip" => zip, "city" => "WASHINGTON", "state" => "DC" }
        } ]
      }
    }
  end

  def stub_census(body)
    stub_request(:get, census).with(query: hash_including({})).to_return(body: body)
  end

  describe ".call" do
    context "when the address matches" do
      before do
        stub_request(:get, census)
          .with(query: hash_including("address" => "1600 Pennsylvania Ave NW, Washington, DC"))
          .to_return(body: census_match.to_json)
      end

      it "returns zip, coordinates and matched address" do
        location = described_class.call("1600 Pennsylvania Ave NW, Washington, DC")

        expect(location.zip).to eq("20500")
        expect(location.latitude).to be_within(0.001).of(38.8987)
        expect(location.longitude).to be_within(0.001).of(-77.0352)
        expect(location.name).to eq("1600 PENNSYLVANIA AVE NW, WASHINGTON, DC, 20500")
        expect(location.place).to eq("WASHINGTON, DC")
      end
    end

    context "when city and state are absent" do
      it "falls back to the zip as place" do
        body = census_match
        body["result"]["addressMatches"][0]["addressComponents"] = { "zip" => "20500" }
        stub_census(body.to_json)

        expect(described_class.call("somewhere").place).to eq("20500")
      end
    end

    context "when nothing matches" do
      it "raises NotFound" do
        stub_census({ "result" => { "addressMatches" => [] } }.to_json)

        expect { described_class.call("zzzz nowhere") }.to raise_error(Weather::NotFound)
      end
    end

    context "when the match has no valid zip" do
      it "raises NotFound" do
        stub_census(census_match(zip: "").to_json)

        expect { described_class.call("somewhere") }.to raise_error(Weather::NotFound)
      end
    end

    context "with an unexpected payload" do
      it "raises ServiceError" do
        stub_census({ "errors" => [ "boom" ] }.to_json)

        expect { described_class.call("somewhere") }.to raise_error(Weather::ServiceError)
      end
    end

    context "with non-object bodies and matches" do
      [ "1", '{"result":{"addressMatches":["x"]}}', '{"result":"x"}',
        '{"result":{"addressMatches":[{"addressComponents":"x"}]}}' ].each do |body|
        it "raises ServiceError for body #{body}" do
          stub_census(body)

          expect { described_class.call("somewhere") }.to raise_error(Weather::ServiceError)
        end
      end
    end

    context "when the match has missing or bad coordinates" do
      [ nil, { "x" => "abc", "y" => 1 } ].each do |coordinates|
        it "raises ServiceError for coordinates #{coordinates.inspect}" do
          body = census_match
          body["result"]["addressMatches"][0]["coordinates"] = coordinates
          stub_census(body.to_json)

          expect { described_class.call("somewhere") }.to raise_error(Weather::ServiceError)
        end
      end
    end
  end
end
