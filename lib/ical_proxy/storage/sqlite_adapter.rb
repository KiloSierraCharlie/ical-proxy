require 'json'

module IcalProxy
  module Storage
    class SqliteAdapter
      def initialize(db_path)
        begin
          require 'sqlite3'
        rescue LoadError
          raise "sqlite3 gem is required for sqlite storage. Add `gem 'sqlite3'` and bundle install."
        end
        @db_path = db_path.to_s
        @db = SQLite3::Database.new(@db_path)
        @db.results_as_hash = true
        ensure_schema
      end

      def load_calendar(calendar_key)
        rows = @db.execute('SELECT uid, raw, dtstart, dtend, first_seen, last_seen FROM events WHERE calendar_key = ?', [calendar_key])
        out = {}
        rows.each do |r|
          out[r['uid']] = row_to_record(r)
        end
        out
      end

      def save_calendar(calendar_key, events_hash)
        @db.transaction
        @db.execute('DELETE FROM events WHERE calendar_key = ?', [calendar_key])
        stmt = @db.prepare('INSERT INTO events (calendar_key, uid, raw, dtstart, dtend, first_seen, last_seen) VALUES (?,?,?,?,?,?,?)')
        events_hash.each do |uid, rec|
          stmt.execute(calendar_key, uid, rec['raw'], rec['dtstart'], rec['dtend'], rec['first_seen'], rec['last_seen'])
        end
        stmt.close
        @db.commit
      rescue
        @db.rollback
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
        @db.execute <<~SQL
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
        @db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS configs_calendars (
            name TEXT PRIMARY KEY,
            json TEXT
          );
        SQL
      end

      public

      def load_all_calendar_configs
        rows = @db.execute('SELECT name, json FROM configs_calendars')
        out = {}
        rows.each do |r|
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
