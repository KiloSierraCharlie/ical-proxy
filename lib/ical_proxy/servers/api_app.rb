require 'json'
require 'cgi'
require 'uri'
require 'open-uri'

module IcalProxy
  module Servers
    class ApiApp
      def initialize
      end

      def call(env)
        req = Rack::Request.new(env)
        path = req.path_info

        # Basic routing under /api/v1
        unless path.start_with?('/api')
          return not_found
        end

        # Serve OpenAPI spec without auth
        if req.get? && path == '/api/openapi.yaml'
          return serve_openapi
        end

        # Auth: require admin token for non-ICS endpoints if configured
        if requires_auth?(req)
          return unauthorized unless authorized?(req)
        end

        case [req.request_method, path]
        when ['GET', %r{^/api/v1/health$}]
          return ok_json({ status: 'ok' })
        end

        # Calendars collection
        if req.get? && path == '/api/v1/calendars'
          return list_calendars
        elsif req.post? && path == '/api/v1/calendars'
          body = parse_json(req)
          return bad_request('Invalid JSON') unless body
          name = body['name'] || body['calendar_name']
          return bad_request('Missing name') if !name || name.to_s.strip.empty?
          cfg = body['config'] || body.reject { |k,_| %w[name calendar_name].include?(k) }
          IcalProxy.storage_adapter.upsert_calendar_config(name, cfg)
          return ok_json({ ok: true })
        end

        # Calendar item routes
        if m = path.match(%r{^/api/v1/calendars/([^/]+)(/.*)?$})
          name = CGI.unescape(m[1])
          tail = m[2].to_s

          case req.request_method
          when 'GET'
            if tail.empty? || tail == '/'
              return get_calendar(name)
            elsif tail == '/events'
              return get_events(name, req)
            elsif tail == '/preview.ics'
              return get_preview_ics(name, req)
            elsif tail == '/preview.json'
              return get_preview_json(name, req)
            end
          when 'PATCH'
            body = parse_json(req)
            return bad_request('Invalid JSON') unless body
            return patch_calendar(name, body)
          when 'DELETE'
            return delete_calendar(name)
          when 'POST'
            if tail == '/sync'
              return sync_calendar(name)
            end
          end
        end

        not_found
      end

      private

      def requires_auth?(req)
        token = ENV['ICAL_PROXY_ADMIN_TOKEN']
        return false if token.nil? || token.strip.empty?
        # Protect everything under /api except preview.ics which may rely on calendar key
        !(req.path_info.end_with?('/preview.ics'))
      end

      def authorized?(req)
        token = ENV['ICAL_PROXY_ADMIN_TOKEN']
        hdr = req.get_header('HTTP_AUTHORIZATION').to_s
        return false if hdr.empty?
        scheme, cred = hdr.split(' ', 2)
        scheme&.downcase == 'bearer' && cred == token
      end

      def list_calendars
        # Merge view, with source for each
        yaml_cfg = IcalProxy.config
        effective = IcalProxy.calendar_configs
        db = IcalProxy.db_calendar_configs
        arr = effective.map do |name, cfg|
          source = if yaml_cfg['calendars']&.key?(name) || (yaml_cfg.key?(name) && name != 'storage')
                     'yaml'
                   elsif db.key?(name)
                     'db'
                   else
                     'unknown'
                   end
          { 'name' => name, 'source' => source }
        end
        ok_json(arr)
      end

      def get_calendar(name)
        effective = IcalProxy.calendar_configs
        cfg = effective[name]
        return not_found unless cfg

        yaml_cfg = IcalProxy.config
        source = if yaml_cfg['calendars']&.key?(name) || (yaml_cfg.key?(name) && name != 'storage')
                   'yaml'
                 elsif IcalProxy.db_calendar_configs.key?(name)
                   'db'
                 else
                   'unknown'
                 end
        ok_json({ 'name' => name, 'config' => cfg, 'source' => source })
      end

      def patch_calendar(name, body)
        yaml_effective = IcalProxy.calendar_configs
        if yaml_effective.key?(name) && defined_in_yaml?(name)
          return conflict('Calendar defined in YAML; cannot modify via API')
        end
        cfg = body['config'] || body
        IcalProxy.storage_adapter.upsert_calendar_config(name, cfg)
        ok_json({ ok: true })
      end

      def delete_calendar(name)
        if defined_in_yaml?(name)
          return conflict('Calendar defined in YAML; cannot delete via API')
        end
        IcalProxy.storage_adapter.delete_calendar_config(name)
        ok_json({ ok: true })
      end

      def sync_calendar(name)
        effective = IcalProxy.calendar_configs
        cfg = effective[name]
        return not_found unless cfg
        # Trigger a synchronize by reading union; gather simple counts
        current_events = fetch_live_events(cfg)
        before = fetch_persisted_map(name)
        union = IcalProxy::PersistStore.synchronize_and_union(name, current_events, cfg['persist_missing_days'])
        after = fetch_persisted_map(name)
        inserted = (after.keys - before.keys).size
        deleted = (before.keys - after.keys).size
        ok_json({ ok: true, counts: { inserted: inserted, deleted: deleted, union: union.size } })
      end

      def get_events(name, req)
        effective = IcalProxy.calendar_configs
        cfg = effective[name]
        return not_found unless cfg
        source = req.params['source'].to_s
        case source
        when 'live'
          events = fetch_live_events(cfg)
          json = events.map { |e| event_json(e) }
          ok_json(json)
        when 'persisted'
          persisted = fetch_persisted_events_only(name)
          ok_json(persisted.map { |e| event_json(e).merge('source' => 'persisted') })
        else # 'union' or empty
          union = IcalProxy::PersistStore.synchronize_and_union(name, fetch_live_events(cfg), cfg['persist_missing_days'])
          # identify persisted-only by comparing uids
          live_map = index_by_uid(fetch_live_events(cfg))
          json = union.map do |e|
            h = event_json(e)
            h['source'] = live_map.key?(h['uid']) ? 'live' : 'persisted'
            h
          end
          ok_json(json)
        end
      end

      def get_preview_ics(name, req)
        calendars = IcalProxy.calendars
        cal = calendars[name]
        return not_found unless cal
        # Respect calendar key if provided
        if req.params['key'] && req.params['key'] != cal.api_key
          return forbidden('Authentication incorrect')
        end
        [200, { 'content-type' => 'text/calendar' }, [cal.proxied_calendar]]
      end

      def get_preview_json(name, req)
        calendars = IcalProxy.calendars
        cal = calendars[name]
        return not_found unless cal
        # Optionally enforce api key
        if req.params['key'] && req.params['key'] != cal.api_key
          return forbidden('Authentication incorrect')
        end
        # Build ICS then parse to events JSON after transformations
        ics = cal.proxied_calendar
        evs = Icalendar::Calendar.parse(ics).first.events
        ok_json(evs.map { |e| event_json(e) })
      end

      # Helpers
      def fetch_live_events(cfg)
        ics = URI.open(cfg['ical_url']).read
        Icalendar::Calendar.parse(ics).first.events
      end

      def index_by_uid(events)
        map = {}
        events.each do |e|
          uid = (e.respond_to?(:uid) ? e.uid.to_s : nil)
          map[uid] = true if uid && !uid.empty?
        end
        map
      end

      def fetch_persisted_map(name)
        # Use adapter to load stored hash
        if IcalProxy.storage_adapter.respond_to?(:load_calendar)
          IcalProxy.storage_adapter.load_calendar(name)
        else
          {}
        end
      end

      def fetch_persisted_events_only(name)
        store = fetch_persisted_map(name)
        store.values.map do |rec|
          vevent_raw = rec['raw']
          next nil unless vevent_raw && vevent_raw.include?('BEGIN:VEVENT')
          ical = "BEGIN:VCALENDAR\nVERSION:2.0\n#{vevent_raw}\nEND:VCALENDAR\n"
          cal = Icalendar::Calendar.parse(ical).first
          cal && cal.events && cal.events.first
        end.compact
      end

      def event_json(e)
        {
          'uid' => (e.respond_to?(:uid) ? e.uid.to_s : nil),
          'summary' => e.summary.to_s,
          'description' => e.description.to_s,
          'location' => e.location.to_s,
          'dtstart' => IcalProxy::PersistStore.event_time_iso(e, :dtstart),
          'dtend' => IcalProxy::PersistStore.event_time_iso(e, :dtend)
        }
      end

      # Response helpers
      def ok_json(obj)
        [200, { 'content-type' => 'application/json' }, [JSON.generate(obj)]]
      end

      def bad_request(msg)
        [400, { 'content-type' => 'application/json' }, [JSON.generate({ error: msg })]]
      end

      def conflict(msg)
        [409, { 'content-type' => 'application/json' }, [JSON.generate({ error: msg })]]
      end

      def unauthorized
        [401, { 'content-type' => 'application/json' }, [JSON.generate({ error: 'Unauthorized' })]]
      end

      def forbidden(msg)
        [403, { 'content-type' => 'application/json' }, [JSON.generate({ error: msg })]]
      end

      def not_found
        [404, { 'content-type' => 'application/json' }, [JSON.generate({ error: 'Not found' })]]
      end

      def parse_json(req)
        body = req.body.read
        req.body.rewind
        return {} if body.nil? || body.strip.empty?
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def defined_in_yaml?(name)
        cfg = IcalProxy.config
        return true if cfg['calendars'].is_a?(Hash) && cfg['calendars'].key?(name)
        cfg.key?(name) && name != 'storage'
      end

      def serve_openapi
        path = File.expand_path('../../../openapi.yaml', __dir__)
        return not_found unless File.exist?(path)
        content = File.read(path)
        [200, { 'content-type' => 'application/yaml' }, [content]]
      end
    end
  end
end
