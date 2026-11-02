module Weather
  # `name` is what the user asked for (may be a street address); `place` is a
  # zip-level label safe to share through the per-zip cache.
  Location = Data.define(:zip, :latitude, :longitude, :name, :place)
end
