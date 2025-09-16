module IcalProxy
  class Calendar
    attr_accessor :ical_url, :api_key, :timezone, :filter_rules, :clear_existing_alarms, :alarm_triggers, :transformations, :name, :persist_missing_days

    def initialize(ical_url, api_key, timezone = 'UTC', name = nil, persist_missing_days = nil)
      self.ical_url = ical_url
      self.api_key = api_key
      self.timezone = timezone
      self.name = name
      self.persist_missing_days = persist_missing_days

      self.filter_rules = []
      self.clear_existing_alarms = false
      self.alarm_triggers = []
      self.transformations = []
    end

    def add_rule(field, operator, value)
      self.filter_rules << FilterRule.new(field, operator, value)
    end

    def add_alarm_trigger(alarm_trigger)
      self.alarm_triggers << AlarmTrigger.new(alarm_trigger)
    end

    def add_transformation(*args)
      # Accept a prebuilt transformer object that responds to #apply
      raise ArgumentError, 'add_transformation expects a transformer object' unless args.size == 1
      transformer = args.first
      self.transformations << transformer
    end

    def proxied_calendar
      proxied_calendar = Icalendar::Calendar.new

      filtered_events.each do |original_event|
        proxied_calendar.add_event(original_event)
      end

      proxied_calendar.events.select do |e|
        e.alarms.clear if clear_existing_alarms
        alarm_triggers.each do |t|
          e.alarm do |a|
            a.action = "DISPLAY"
            a.description = e.summary
            a.trigger = t.alarm_trigger
          end
        end

        transformations.each do |t|
          next unless t.respond_to?(:apply)
          t.apply(e)
        end
      end

      proxied_calendar.to_ical
    end

    private

    def filtered_events
      combined_events.select do |e|
        filter_match?(FilterableEventAdapter.new(e, timezone: timezone))
      end
    end

    def filter_match?(event)
      filter_rules.empty? || filter_rules.all? { |rule| rule.match_event?(event) }
    end

    def original_ics
      Icalendar::Calendar.parse(raw_original_ical).first
    end

    def raw_original_ical
      URI.open(ical_url).read
    end

    def combined_events
      # Pull latest feed events
      current_events = original_ics.events

      # Update persist store and get union of current + persisted-missing events
      union_raw = PersistStore.synchronize_and_union(name || ical_url, current_events, persist_missing_days)

      # union_raw returns array of Icalendar::Event objects already
      union_raw
    end
  end
end
