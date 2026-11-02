require "rails_helper"

RSpec.describe CacheStoreConfig do
  describe ".for" do
    context "with a REDIS_URL" do
      subject(:config) { described_class.for("REDIS_URL" => "redis://cache:6379/0") }

      let(:store) { config[0] }
      let(:options) { config[1] }

      it "selects a fail-fast shared Redis store" do
        expect(store).to eq(:redis_cache_store)
        expect(options[:url]).to eq("redis://cache:6379/0")
        expect(options[:connect_timeout]).to be <= 1
        expect(options[:read_timeout]).to be <= 1
        expect(options[:write_timeout]).to be <= 1
        expect(options[:reconnect_attempts]).to eq(0)
      end

      it "provides a callable error handler" do
        expect(options[:error_handler]).to respond_to(:call)
      end
    end

    [ {}, { "REDIS_URL" => "" } ].each do |env|
      context "with env #{env.inspect}" do
        subject(:config) { described_class.for(env) }

        it "selects a bounded in-process memory store" do
          store, options = config

          expect(store).to eq(:memory_store)
          expect(options[:size]).to be > 0
        end
      end
    end
  end

  describe "the running app" do
    it "uses the store REDIS_URL asks for" do
      expected = ENV["REDIS_URL"].present? ? ActiveSupport::Cache::RedisCacheStore : ActiveSupport::Cache::MemoryStore

      expect(Rails.cache).to be_an_instance_of(expected)
    end
  end
end
