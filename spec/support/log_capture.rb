# Swaps Rails.logger for one writing to a StringIO and yields the IO.
module LogCapture
  def capture_log(level: :debug)
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io, level: level)
    yield io
    io.string
  ensure
    Rails.logger = original
  end
end

RSpec.configure { |config| config.include LogCapture }
