module Weather
  # An upstream API was unreachable or answered with something unusable.
  class ServiceError < StandardError; end
end
