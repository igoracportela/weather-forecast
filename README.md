# Weather Forecast

A Ruby on Rails app. Enter a US address (or a bare 5-digit zip code) and it
shows the current temperature, today's high and low, and a 7-day forecast.
Forecasts are cached per zip code for 30 minutes, and every result is labelled
**Live** or **Cached** (with when it was fetched).

- Ruby 3.4.9, Rails 8.1. There is no database, no JavaScript bundler and no API keys.
- Geocoding: [US Census Geocoder](https://geocoding.geo.census.gov/) for street
  addresses, [Open-Meteo geocoding](https://open-meteo.com/en/docs/geocoding-api)
  for bare zips.
- Forecast: [Open-Meteo](https://open-meteo.com/en/docs).
- Cache: `Rails.cache`, backed by Redis when `REDIS_URL` is set, otherwise an
  in-process memory store.

## Run

**With Docker (app + Redis):**

```bash
docker compose up --build        # http://localhost:3000
```

**Locally (no services needed):**

```bash
bundle install
bin/rails server                 # http://localhost:3000, in-memory cache
bin/rspec                        # WebMock blocks real HTTP; fails below 95% line coverage
REDIS_URL=redis://localhost:6379/1 bin/rspec   # same suite against Redis
bin/rubocop && bin/brakeman      # lint + security scan
```

CI (`.github/workflows/ci.yml`) runs these jobs:

- **Lint:** RuboCop, Brakeman (fails on any warning) and bundler-audit.
- **Tests:** the RSpec suite twice, once on the memory store and once against
  a Redis service.
- **Docker:** builds the image, boots it with `docker compose`, and checks
  `/up` and the lookup page.

## How it works

```
ForecastsController#show (GET /?address=...)
  └─ Weather::Lookup.call(address)          validation, cache, Forecast
       ├─ AddressGeocoder / ZipGeocoder      address → Location (zip, lat/lon)
       ├─ Rails.cache.fetch("forecast/v1/<zip>", expires_in: 30.minutes,
       │                    race_condition_ttl: 10.seconds)
       │    └─ ForecastClient                Open-Meteo → validated plain Hash
       └─ HttpJson                           5 s timeouts, no retry; every failure → ServiceError
```

- Every third-party call lives in a service object under
  `app/services/weather/`. The controller only maps three error types to HTTP
  statuses: `InvalidInput` and `NotFound` become 422, and `ServiceError`
  becomes 503.
- `HttpJson` is the one place that talks HTTP. It turns timeouts, DNS failures,
  TLS errors, connection resets, corrupt gzip, non-2xx responses (429 is logged
  as "rate limited") and unparseable JSON into a `ServiceError`. A worker
  thread never sees a raw `Net::*` exception, so there is no 500.
- Payloads are validated before they are cached: finite temperatures between
  −150 and 150 °F, ISO dates, exactly 7 days. A malformed upstream response
  can therefore never be cached and served for 30 minutes.

## Architecture decisions

### Trade-offs

| Decision | Chosen | Rejected because |
|---|---|---|
| Cache mechanism | `Rails.cache` (native) | A table of cached payloads hand-rolls the TTL and eviction that the framework already gives |
| Shared backend | Redis (`:redis_cache_store`) | Solid Cache needs a database, which this app deliberately doesn't have |
| Fallback backend | `:memory_store` when `REDIS_URL` is unset | `:null_store` (the test default) would make the cache specs vacuous |
| Cache key | `forecast/v1/<zip>` only | Keying by address gives a near-zero hit rate and unbounded keys. `v1` allows a payload change to invalidate old entries |
| Cached value | Plain Hash of primitives | Marshalled objects break across deploys |
| Providers | Census + Open-Meteo (no keys) | Key-based APIs add secret management for no functional gain |
| Bare-zip input | Cache checked *before* geocoding | A street address must be geocoded to learn its zip, but a zip already is the key, so a hit costs no external call |
| Location label in cache | City/state only | A street address in a shared entry would leak one visitor's input to the next |

**Accepted costs:**

- **Location precision.** The forecast for a zip uses the coordinates of the
  first address looked up in it, which is fine at zip-code scale.
- **"Today" can lag** for up to 30 minutes after local midnight.
- **US only.** The requirement is keyed by zip code.

### Cache eviction policy

- **Time-based.** Entries are logically fresh for 30 minutes (`expires_in`). At
  30:00 the next request fetches fresh data and shows **Live**. When
  `race_condition_ttl` is set, Rails pads the physical Redis TTL by 5 minutes
  (observed: `TTL weather:forecast/v1/20500` = 2100 s). The 30-minute cutoff is
  enforced by Rails on every read, and the padding means Redis still reclaims
  abandoned keys on its own.
- **Memory pressure.** The compose Redis runs `maxmemory 64mb` with
  `allkeys-lru` and persistence off. Every key is a disposable cache entry, so
  least-recently-used eviction is always safe. An entry is about 1 KB, so 64 MB
  holds about 60k zips. That is more than the ~42k US zip codes, so LRU is a
  backstop, not the steady state. The memory store has its own 32 MB LRU.
- **Failures are never written.** An exception inside the `fetch` block
  propagates, and nothing is cached.

### Concurrency

- **An honest indicator under concurrency.** `cached` is set to `false` only
  inside the `fetch` miss block. No separate `exist?` check can race expiry,
  so each response reports exactly what the cache did for it.
- **Stampede protection.** With `race_condition_ttl: 10.seconds`, when a
  popular zip's entry expires, the first request extends the stale copy by
  10 s and refetches, while concurrent requests keep getting the stale copy
  (honestly labelled **Cached**). If the refresh fails, the stale copy keeps
  serving for those 10 s instead of every request hitting a struggling
  upstream.
- **Cold misses are not deduplicated** across processes. A distributed lock
  would add a failure mode bigger than the cost it saves, which is a few
  duplicate Open-Meteo calls per zip per 30 minutes.

### Scaling under heavy load

- **Stateless app tier.** Apart from Redis there is no state, so it scales
  horizontally behind a load balancer. Inside a node, scale with Puma
  `WEB_CONCURRENCY` (processes) × `RAILS_MAX_THREADS` (threads). Every
  replica shares one Redis cache, so the hit rate improves as traffic grows.
- **Bounded thread hold time.**
  - A cache hit for a bare zip costs one Redis round trip.
  - A cache hit for a street address costs one Census call.
  - A miss for a street address is capped at about 10 s: two calls with 5 s
    timeouts each, and `max_retries: 0` stops Net::HTTP's silent retry from
    doubling that.

  A slow upstream can therefore tie up threads, but it can't hang them
  forever. Throughput under an upstream outage is roughly
  `threads ÷ 5 s` per process.
- **Redis is an optimisation, not a dependency.** The client fails fast
  (connect timeout 1 s, read/write timeouts 0.5 s, no reconnect attempts), and
  every cache error becomes a logged miss. If Redis goes down, every lookup is
  served **Live**, with no 500s (verified by stopping Redis under a running
  production server).
- **Next steps if load grows:**
  - Cache Census geocodes by normalised address (currently every
    street-address request makes one Census call).
  - Add a short negative cache or a circuit breaker for upstream outages, so
    failing requests return in milliseconds instead of 5 s.
  - Add rate limiting at the edge (Rails 8 `rate_limit` or Rack::Attack).
  - Run Redis as a managed instance with replicas.

## Production notes

- **Image.** Multi-stage, non-root user, `HEALTHCHECK` on `/up`.
- **TLS.** Forced by default (`RAILS_FORCE_SSL`). Compose turns it off for
  local HTTP.
- **Secrets.** None are baked in. If `SECRET_KEY_BASE` is unset, the
  entrypoint generates an ephemeral one per boot. That is safe because the app
  keeps no sessions. Set it explicitly when running several replicas.
- **Logs.** Addresses are filtered from request logs (`[FILTERED]`), and
  upstream errors log only the host.
