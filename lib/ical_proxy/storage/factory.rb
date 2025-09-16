require 'uri'

module IcalProxy
  module Storage
    class Factory
      def self.build(uri_str)
        uri = parse_uri(uri_str)
        scheme = (uri&.scheme || 'json').downcase
        case scheme
        when 'json'
          require_relative 'json_adapter'
          path = decode_path(uri)
          JsonAdapter.new(path)
        when 'sqlite'
          require_relative 'sqlite_adapter'
          path = decode_path(uri)
          SqliteAdapter.new(path)
        when 'postgres', 'postgresql', 'pgsql'
          require_relative 'postgres_adapter'
          PostgresAdapter.new(uri)
        when 'mysql', 'mysql2'
          require_relative 'mysql_adapter'
          MysqlAdapter.new(uri)
        else
          raise "Unknown storage scheme: #{scheme}"
        end
      end

      def self.parse_uri(str)
        return nil if str.nil? || str.to_s.strip.empty?
        URI.parse(str)
      rescue URI::InvalidURIError
        nil
      end

      def self.decode_path(uri)
        # Handle windows paths and leading slashes from URI
        raw = uri&.opaque || uri&.path || '.'
        raw = raw.sub(%r{^/+}, '') if raw =~ %r{^/[A-Za-z]:/} # remove leading slash before drive
        raw
      end
    end
  end
end

