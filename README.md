# ical-proxy

A fork of the original [ical-filter-proxy](https://github.com/darkphnx/ical-filter-proxy) from darkphnx!

Got an iCal feed full of nonsense that you don't need? Does your calendar client have piss-poor
filtering options (looking at your Google Calendar)?

Use ical-proxy to proxy and filter your iCal feed, as well as complete some transformations to make each event more to your need. Define your source
calendar and filtering options in `config.yml` and you're good to go.

In addition, display alarms can be created or cleared.

## Configuration

```yaml
storage: postgres://user:password@server:5432/database_name # optional, or set ICAL_PROXY_STORAGE

my_calendar_name:
   ical_url: https://source-calendar.com/my_calendar.ics # Source calendar
   api_key: myapikey # (optional) append ?key=myapikey to your URL to grant access
   timezone: Europe/London # (optional) ensure all time comparisons are done in this TZ
   persist_missing_days: 30 # (optional) keep disappeared events if they ended > N days ago
   rules:
      - field: start_time # start_time and end_time supported
        operator: not-equals # equals and not-equals supported
        val: "09:00" # A time in 24hour format, zero-padded
      - field: summary # summary and description supported
        operator: startswith # (not-)startswith, (not-)equals and (not-)includes supported
        val: # array of values also supported
          - Planning
          - Daily Standup
      - field: summary # summary and description supported
        operator: matches # match against regex pattern
        val: # array of values also supported
          - '/Team A/i'
   alarms: # (optional) create/clear alarms for filtered events
     clear_existing: true # (optional) if true, existing alarms will be removed, default: false 
     triggers: # (optional) triggers for new alarms. Description will be the alarm summary, action is 'DISPLAY'
       - '-P1DT0H0M0S' # iso8061 supported
       - 2 days # supports full day[s], hour[s], minute[s], no combination in one trigger
    transformations:
      # Rename/normalize event summaries. Each rule can be a plain string match or a regex.
      # Use `regex: true` to force compiling a string as a regex, or provide a
      # string that looks like a regex (e.g. "/pattern/i").
      rename:
        # Normalizer style: if it matches the pattern (in summary or description), set the summary to a fixed value.
        - pattern: '/spin( class)?/i'
          to: 'Spin'
          search: ['summary', 'description']
          regex: true
        # Search and replace within summary only (gsub on summary)
        - pattern: 'Draft'
          replace: 'Final'
      location: # (optional) use regex to extract a location from title/description or add fixed location data
        - extract_from: 'description' # extract location from description (first capture group). Only sets when current location is blank (default).
          pattern: '/Location:\\s*([^\\n]+)/i'
          set_if_blank: true
        - pattern: '/Watford/i' # add GEO when a place name appears in summary or description
          search: ['summary', 'description']
          geo: { lat: 51.6565, lon: -0.3903 }
        - pattern: '/Hemel/i' # normalize location to a fixed string based on a match
          search: ['summary', 'description']
          location: 'HP1 2AA'
```

### Variable substitution

It might be useful to inject configuration values as environment variable.  
Variables are substituted if they begin with `ICAL_PROXY_<value>` and are defined in the configuration like `${ICAL_PROXY_<value>}`.  

Example: 
```yaml
  api_key: ${ICAL_PROXY_API_KEY}
```

If a placeholder is defined but environment variable is missing, it is substituted with an empty string!

## Additional Rules

At the moment rules are pretty simple, supporting only start times, end times, equals and
not-equals as that satisfies my use case. To add support for additional rules please extend
`lib/ical_proxy/filter/filter_rule.rb`. Pull requests welcome.

## Installing/Running

After you've created a `config.yml` simply bundle and run Puma.

```bash
bundle install
bundle exec puma -C config/puma.rb
```

Voila! Your calendar will now be available at http://localhost:8000/my_calendar_name?key=myapikey.


I'd recommend running it behind something like nginx, but you can do what you like.

### Docker

Create a `config.yml` as shown above.

```bash
docker build -t ical-proxy .
docker run -d --name ical-proxy -v $(pwd)/config.yml:/app/config.yml -p 8000:8000 ical-proxy
```

### Lambda

ical-proxy can be run as an AWS Lambda process using their API Gateway.

Create a new API Gateway in the AWS Console and link to to a new Lambda process. This should create all of the permissions required in AWS land.

Next we need to package the app up ready for Lambda. First of all, craft your config.yml and place it in the root of the source directory. A handy rake task is included which will fetch any dependencies and zip them up ready to be uploaded.

```bash
bundle exec rake lamba:build
```

This task will output the file `ical-proxy.zip`. Note that you must have the `zip` utility installed locally to use this task.

When prompted during the Lambda setup, provide this zip file and set the handler to `lambda.handle`.

That's it! Your calendar should now be available at `https://aws-api-gateway-host/default/gateway_name?calendar=my_calendar_name&key=my_api_key`

## Persistence

- File: `persist.json` at the project root (ignored by git by default).
- Content: Stores raw `VEVENT` blocks (unmodified) keyed by UID per calendar.
- Update: Each request fetches the live ICS, upserts current events (raw) into the store, and evaluates disappeared events.
- Disappeared events:
  - With `persist_missing_days`: keep if the event ended more than N days ago; otherwise remove.
  - Without the setting: keep only if an older event still exists in the current feed; otherwise remove.
- Serving: The calendar serves the union of live events and persisted-only events, then applies your configured filters/transformations. The persisted data itself remains raw and untransformed.
- Reset: Delete `persist.json` to clear the history for all calendars.

### Storage backends

You can choose where persistence data is stored via either the `ICAL_PROXY_STORAGE` environment variable or a top‑level `storage:` key in `config.yml`. Format is a URI similar to Doctrine DSNs:

- JSON file (default): `json://path_to_folder`
  - Stores a single `persist.json` inside the folder.
  - Backwards compatible with previous behavior when pointed at the project root.
- SQLite: `sqlite://path_to_sqlite`
  - Requires `gem 'sqlite3'`.
  - Creates a table `events(calendar_key, uid, raw, dtstart, dtend, first_seen, last_seen)`.
- PostgreSQL: `postgres://user:password@server:port/database_name`
  - Requires `gem 'pg'`.
  - Creates the same `events` table if missing.
- MySQL: `mysql://user:password@server:port/database_name`
  - Requires `gem 'mysql2'`.
  - Creates the same `events` table if missing.

Config precedence: `ICAL_PROXY_STORAGE` overrides `storage:` in YAML. If neither is set, defaults to `json://<project_root>`.

You can optionally nest calendars under a `calendars:` key. Otherwise, all top‑level keys except `storage` are treated as calendars.

### Database-backed configuration

You can store calendar configuration in the database as well (SQLite/Postgres/MySQL). YAML remains the source of truth and overrides any DB values:

- YAML takes precedence: if a calendar exists in YAML, the DB will not overwrite it.
- DB fills in anything not present in YAML (e.g., extra calendars). Field-level merging is not performed; presence of a calendar in YAML means use the YAML version entirely.

Schema used by SQL backends (auto-created):
- `configs_calendars(name PRIMARY KEY, json TEXT)` — `json` holds a serialized hash of each calendar’s config.

To add or update configs in DB, insert rows into `configs_calendars` with `name` and `json` (stringified JSON matching the calendar’s YAML shape).

## Management API

ical-proxy exposes a JSON API under `/api/v1` intended to be consumed by your Symfony application (which can enforce user permissions). If `ICAL_PROXY_ADMIN_TOKEN` is set, management endpoints require `Authorization: Bearer <token>`.

- GET `/api/v1/health`: Service status.
- GET `/api/v1/calendars`: List calendars with their source (`yaml` or `db`).
- GET `/api/v1/calendars/:name`: Effective config for a calendar.
- POST `/api/v1/calendars`: Create a DB-backed calendar. Body: `{ name, config }`.
- PATCH `/api/v1/calendars/:name`: Update DB-backed calendar config. YAML-defined calendars cannot be modified.
- DELETE `/api/v1/calendars/:name`: Delete a DB-backed calendar.
- GET `/api/v1/calendars/:name/events?source=live|persisted|union`: List events as JSON.
- POST `/api/v1/calendars/:name/sync`: Trigger a sync (fetch + persist) and return basic counts.
- GET `/api/v1/calendars/:name/preview.ics`: Proxied ICS output (respects `?key=` if provided).
- GET `/api/v1/calendars/:name/preview.json`: Proxied events after transformations as JSON.

Note: YAML remains the source of truth. If a calendar exists in YAML, API modifications are rejected with 409.

### OpenAPI

An OpenAPI 3.1 spec is included at `openapi.yaml`. Point your Symfony client/codegen at it to generate clients or docs.

## Plugins / Addons

To make transformations modular, ical-proxy now auto-loads all Ruby files under:
- `lib/ical_proxy/**/*.rb` (core modules)
- `lib/ical_proxy/addons/**/*.rb` (your drop-in addons)

You no longer need to add `require_relative` lines in `lib/ical_proxy.rb`.

### Transformer registry

Transformers can register themselves against a key in your `transformations` config using a tiny registry:

```ruby
# lib/ical_proxy/transformer/your_transformer.rb
module IcalProxy
  module Transformer
    class YourTransformer
      def initialize(opts); @opts = opts; end
      def apply(event); /* mutate event */ end
    end
  end
end

IcalProxy::Transformer::Registry.register('your_key') do |section|
  # `section` is the hash/value from `transformations.your_key`
  IcalProxy::Transformer::YourTransformer.new(section)
end
```

Then in `config.yml`:

```yaml
transformations:
  your_key: { option: value }
```

Core transformers are pre-registered:
- `transformations.rename: [ ... ]`
- `transformations.location_rules: [ ... ]`
- `transformations.location: [ ... ]`

Addons can be dropped into `lib/ical_proxy/addons/transformer/*.rb` and will be discovered automatically.

Example addon included: `lib/ical_proxy/addons/transformer/uppercase_summary.rb`
