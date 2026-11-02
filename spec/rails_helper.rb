require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "webmock/rspec"

Rails.root.glob("spec/support/**/*.rb").sort.each { |f| require f }

# Every outbound call must be stubbed; an unstubbed one raises.
WebMock.disable_net_connect!

RSpec.configure do |config|
  config.use_active_record = false
  config.filter_rails_from_backtrace!
  config.include ActiveSupport::Testing::TimeHelpers

  config.before { Rails.cache.clear }
  config.after { travel_back }
end
