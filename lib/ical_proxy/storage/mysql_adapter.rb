require 'json'

module IcalProxy
  module Storage
    class MysqlAdapter
      def initialize(uri)
        begin
          require 'mysql2'
        rescue LoadError
          raise "mysql2 gem is required for mysql storage. Add `gem 'mysql2'` and bundle install."
        end
        @client = Mysql2::Client.new(
          host: uri.host,
          port: uri.port || 3306,
          database: (uri.path || '').sub(%r{^/}, ''),
          username: uri.user,
          password: uri.password,
          encoding: 'utf8mb4'
        )
        ensure_schema
      end

      def load_calendar(calendar_key)
        stmt = @client.prepare('SELECT uid, raw, dtstart, dtend, first_seen, last_seen FROM events WHERE calendar_key = ?')
        result = stmt.execute(calendar_key)
        out = {}
        result.each do |r|
          out[r['uid']] = row_to_record(r)
        end
        out
      end

      def save_calendar(calendar_key, events_hash)
        @client.query('START TRANSACTION')
        @client.prepare('DELETE FROM events WHERE calendar_key = ?').execute(calendar_key)
        ins = @client.prepare('INSERT INTO events (calendar_key, uid, raw, dtstart, dtend, first_seen, last_seen) VALUES (?,?,?,?,?,?,?)')
        events_hash.each do |uid, rec|
          ins.execute(calendar_key, uid, rec['raw'], rec['dtstart'], rec['dtend'], rec['first_seen'], rec['last_seen'])
        end
        @client.query('COMMIT')
      rescue
        @client.query('ROLLBACK') rescue nil
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
        @client.query <<~SQL
          CREATE TABLE IF NOT EXISTS events (
            calendar_key VARCHAR(255) NOT NULL,
            uid VARCHAR(255) NOT NULL,
            raw LONGTEXT,
            dtstart VARCHAR(64),
            dtend VARCHAR(64),
            first_seen VARCHAR(64),
            last_seen VARCHAR(64),
            PRIMARY KEY (calendar_key, uid)
          ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        SQL
        @client.query <<~SQL
          CREATE TABLE IF NOT EXISTS configs_calendars (
            name VARCHAR(255) PRIMARY KEY,
            json LONGTEXT
          ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        SQL
      end

      public

      def load_all_calendar_configs
        res = @client.query('SELECT name, json FROM configs_calendars')
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
