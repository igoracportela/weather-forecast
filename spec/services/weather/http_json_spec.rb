require "rails_helper"

RSpec.describe Weather::HttpJson do
  let(:url) { "https://api.example.test/v1/thing" }

  describe ".get" do
    it "returns parsed JSON and encodes params into the query" do
      stub = stub_request(:get, url).with(query: { "q" => "1 Main St & Co" })
        .to_return(status: 200, body: '{"ok":true}')

      expect(described_class.get(url, q: "1 Main St & Co")).to eq({ "ok" => true })
      expect(stub).to have_been_requested
    end

    it "raises ServiceError on a non-2xx status" do
      # A valid JSON body, so only the status check can make this raise.
      stub_request(:get, url).to_return(status: 502, body: '{"result":{"addressMatches":[]}}')

      expect { described_class.get(url) }.to raise_error(Weather::ServiceError)
    end

    it "raises ServiceError on an unparseable body" do
      stub_request(:get, url).to_return(status: 200, body: "<html>")

      expect { described_class.get(url) }.to raise_error(Weather::ServiceError)
    end

    it "raises ServiceError on a timeout" do
      stub_request(:get, url).to_timeout

      expect { described_class.get(url) }.to raise_error(Weather::ServiceError)
    end

    it "raises ServiceError on a connection failure" do
      stub_request(:get, url).to_raise(Errno::ECONNREFUSED)

      expect { described_class.get(url) }.to raise_error(Weather::ServiceError)
    end

    it "raises ServiceError on a corrupt compressed body" do
      stub_request(:get, url).to_raise(Zlib::DataError)

      expect { described_class.get(url) }.to raise_error(Weather::ServiceError)
    end

    # Listed explicitly, not read from NETWORK_ERRORS, so shrinking that list fails here.
    [ Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::EHOSTUNREACH, Errno::ECONNRESET, IOError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Zlib::BufError ].each do |error|
      it "turns #{error} into a ServiceError" do
        stub_request(:get, url).to_raise(error)

        expect { described_class.get(url) }.to raise_error(Weather::ServiceError)
      end
    end

    context "when rate limited" do
      it "raises a ServiceError that says it was rate limited on a 429" do
        stub_request(:get, url).to_return(status: 429, body: '{"reason":"Too many requests"}')

        expect { described_class.get(url) }.to raise_error(Weather::ServiceError, /rate limited/)
      end

      it "lets a 429 reach the user as a 503 (a ServiceError out of Lookup)" do
        stub_request(:get, Weather::ZipGeocoder::URL).with(query: hash_including({})).to_return(status: 429)

        expect { Weather::Lookup.call("20500") }.to raise_error(Weather::ServiceError)
      end
    end

    context "with a real local socket" do
      let(:server) { TCPServer.new("127.0.0.1", 0) }
      let(:connections) { [] }
      # Each context's `serve` handles one accepted connection; server.close ends the loop.
      let(:acceptor) do
        Thread.new do
          loop { serve.call(server.accept) }
        rescue IOError
          nil
        end
      end

      before { acceptor }

      around do |example|
        WebMock.allow_net_connect!
        example.run
      ensure
        WebMock.disable_net_connect!
      end

      after do
        connections.each(&:close)
        server.close
        acceptor.join(1)
      end

      def local_url
        "http://127.0.0.1:#{server.addr[1]}/x"
      end

      context "when the server drops the connection" do
        let(:serve) do
          lambda do |client|
            connections << client
            client.readpartial(4096)
            client.close
          end
        end

        it "does not retry, so the timeout budget is not doubled" do
          expect { described_class.get(local_url) }.to raise_error(Weather::ServiceError)
          expect(connections.size).to eq(1)
        end
      end

      context "when the server never answers" do
        let(:serve) { ->(client) { connections << client } }

        it "fails at the 5 s read timeout, once" do
          expect(described_class::TIMEOUT).to eq(5)

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Timeout.timeout(8) do
            expect { described_class.get(local_url) }.to raise_error(Weather::ServiceError)
          end
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

          expect(elapsed).to be_within(1).of(5)
          expect(connections.size).to eq(1)
        end
      end
    end
  end
end
