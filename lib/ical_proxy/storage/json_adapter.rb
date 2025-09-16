require 'json'

module IcalProxy
  module Storage
    # Stores data in a single JSON file named persist.json under a folder
    class JsonAdapter
      FILE_NAME = 'persist.json'.freeze

      def initialize(folder_path)
        @folder = folder_path.to_s.strip.empty? ? '.' : folder_path.to_s
      end

      def load_calendar(calendar_key)
        data = read_all
        cal = (data['calendars'][calendar_key] ||= { 'events' => {} })
        cal['events']
      end

      def save_calendar(calendar_key, events_hash)
        data = read_all
        data['calendars'][calendar_key] = { 'events' => events_hash }
        write_all(data)
      end

      private

      def file_path
        File.expand_path(FILE_NAME, @folder)
      end

      def read_all
        if File.exist?(file_path)
          JSON.parse(File.read(file_path))
        else
          { 'calendars' => {} }
        end
      end

      def write_all(data)
        Dir.mkdir(@folder) unless Dir.exist?(@folder)
        File.write(file_path, JSON.pretty_generate(data))
      end

      public

      def load_all_calendar_configs
        (read_all['configs_calendars'] || {}).transform_values do |json|
          begin
            parsed = json.is_a?(String) ? JSON.parse(json) : json
            parsed.is_a?(Hash) ? parsed : {}
          rescue
            {}
          end
        end
      end

      def list_calendar_configs
        load_all_calendar_configs
      end

      def get_calendar_config(name)
        list_calendar_configs[name]
      end

      def upsert_calendar_config(name, hash)
        data = read_all
        data['configs_calendars'] ||= {}
        data['configs_calendars'][name] = hash
        write_all(data)
      end

      def delete_calendar_config(name)
        data = read_all
        if data['configs_calendars']
          data['configs_calendars'].delete(name)
          write_all(data)
        end
      end
    end
  end
end
