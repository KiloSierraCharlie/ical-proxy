require 'json'
require 'time'
require 'uri'

module IcalProxy
  class PersistStore
    # Persist the union of current feed events with previously persisted events
    # applying disappearance rules. Returns array of Icalendar::Event.
    def self.synchronize_and_union(calendar_key, current_events, persist_missing_days)
      store = adapter.load_calendar(calendar_key) # uid => record

      now_iso = Time.now.utc.iso8601

      # Index current events by UID
      current_by_uid = {}
      current_events.each do |e|
        uid = safe_uid(e)
        next unless uid
        current_by_uid[uid] = e
        rec = (store[uid] ||= {})
        rec['uid'] = uid
        rec['raw'] = e.to_ical
        rec['dtstart'] = event_time_iso(e, :dtstart)
        rec['dtend'] = event_time_iso(e, :dtend)
        rec['first_seen'] ||= now_iso
        rec['last_seen'] = now_iso
      end

      # For events in store but missing from current, decide whether to keep or remove
      store.keys.each do |uid|
        next if current_by_uid.key?(uid)
        rec = store[uid]
        event_end = parse_time(rec['dtend']) || parse_time(rec['dtstart'])

        keep = false
        if persist_missing_days && persist_missing_days.to_i > 0
          # Keep if the event ended more than N days ago
          # i.e., if now - event_end > N days
          if event_end
            age_days = ((Time.now - event_end) / 86400.0)
            keep = age_days > persist_missing_days.to_i
          else
            keep = false
          end
        else
          # No setting provided: persist the event if an older one exists in the current feed
          # Determine if any current event has end/start earlier than this missing one
          if event_end
            older_exists = current_by_uid.values.any? do |e|
              ce_end = event_time(e, :dtend) || event_time(e, :dtstart)
              ce_end && ce_end < event_end
            end
            keep = older_exists
          else
            keep = false
          end
        end

        store.delete(uid) unless keep
      end

      # Persist to configured storage
      adapter.save_calendar(calendar_key, store)

      # Build union: current events + persisted-only events
      union = []
      # include current event instances as-is
      union.concat(current_by_uid.values)
      # include missing-but-kept by parsing raw
      store.each do |uid, rec|
        next if current_by_uid.key?(uid)
        ev = parse_event_from_raw(rec['raw'])
        union << ev if ev
      end

      union
    end

    # Storage adapter resolution
    def self.adapter
      @adapter ||= begin
        storage_uri = IcalProxy.storage_uri
        Storage::Factory.build(storage_uri)
      end
    end

    def self.safe_uid(event)
      uid = (event.respond_to?(:uid) ? event.uid : nil)
      uid && uid.to_s.strip.length > 0 ? uid.to_s : nil
    end

    def self.event_time(event, field)
      val = event.send(field) if event.respond_to?(field)
      return nil unless val
      begin
        # Icalendar gem may return Icalendar::Values::Date/DateTime or Time
        if val.respond_to?(:to_time)
          t = val.to_time
          # normalize to UTC if possible
          t = t.getutc if t.respond_to?(:getutc)
          t
        else
          Time.parse(val.to_s)
        end
      rescue
        nil
      end
    end

    def self.event_time_iso(event, field)
      t = event_time(event, field)
      t ? t.utc.iso8601 : nil
    end

    def self.parse_time(str)
      return nil unless str && !str.to_s.strip.empty?
      Time.parse(str).utc rescue nil
    end

    def self.parse_event_from_raw(vevent_raw)
      return nil unless vevent_raw && vevent_raw.include?("BEGIN:VEVENT")
      ical = "BEGIN:VCALENDAR\nVERSION:2.0\n#{vevent_raw}\nEND:VCALENDAR\n"
      cal = Icalendar::Calendar.parse(ical).first
      cal && cal.events && cal.events.first
    rescue
      nil
    end
  end
end
