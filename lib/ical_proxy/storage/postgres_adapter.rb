require 'json'

module IcalProxy
  module Storage
    class PostgresAdapter
      def initialize(uri)
        begin
          require 'pg'
        rescue LoadError
          raise "pg gem is required for postgres storage. Add `gem 'pg'` and bundle install."
        end
        @conn = PG.connect(
          host: uri.host,
          port: uri.port || 5432,
          dbname: (uri.path || '').sub(%r{^/}, ''),
          user: uri.user,
          password: uri.password
        )
        ensure_schema
      end

      def load_calendar(calendar_key)
        res = @conn.exec_params('SELECT uid, raw, dtstart, dtend, first_seen, last_seen FROM events WHERE calendar_key = $1', [calendar_key])
        out = {}
        res.each do |r|
          out[r['uid']] = row_to_record(r)
        end
        out
      end

      def save_calendar(calendar_key, events_hash)
        @conn.exec('BEGIN')
        @conn.exec_params('DELETE FROM events WHERE calendar_key = $1', [calendar_key])
        events_hash.each do |uid, rec|
          @conn.exec_params(
            'INSERT INTO events (calendar_key, uid, raw, dtstart, dtend, first_seen, last_seen) VALUES ($1,$2,$3,$4,$5,$6,$7)',
            [calendar_key, uid, rec['raw'], rec['dtstart'], rec['dtend'], rec['first_seen'], rec['last_seen']]
          )
        end
        @conn.exec('COMMIT')
      rescue
        @conn.exec('ROLLBACK')
        raise
      end

      private

      def row_to_record(r)
        {
          'uid' => r['uid'],
          'raw' => r['raw'],
          'dtstart' => r['dtstart'],
          'dtend' => r['dtend'],
          'first_seen' => r['first_seen'],
          'last_seen' => r['last_seen']
        }
      end

      def ensure_schema
        @conn.exec <<~SQL
          CREATE TABLE IF NOT EXISTS events (
            calendar_key TEXT NOT NULL,
            uid TEXT NOT NULL,
            raw TEXT,
            dtstart TEXT,
            dtend TEXT,
            first_seen TEXT,
            last_seen TEXT,
            PRIMARY KEY (calendar_key, uid)
          );
        SQL
        @conn.exec <<~SQL
          CREATE TABLE IF NOT EXISTS configs_calendars (
            name TEXT PRIMARY KEY,
            json TEXT
          );
        SQL
      end

      public

      def load_all_calendar_configs
        res = @conn.exec('SELECT name, json FROM configs_calendars')
        out = {}
        res.each do |r|
          begin
            cfg = JSON.parse(r['json'] || '{}')
            out[r['name']] = cfg if cfg.is_a?(Hash)
          rescue
            next
          end
        end
        out
      end
    end
  end
end
