module IcalFilterProxy
  class CalendarBuilder

    attr_reader :calendar_config, :calendar, :calendar_name

    def initialize(calendar_config, calendar_name = nil)
      @calendar_config = calendar_config
      @calendar_name = calendar_name
    end

    def build
      create_calendar
      add_rules
      add_alarms
      setup_archive

      calendar
    end

    private

    def create_calendar
      @calendar = Calendar.new(calendar_config["ical_url"],
                               calendar_config["api_key"],
                               calendar_config["timezone"])
    end

    def add_rules
      rules = calendar_config["rules"]
      return unless rules

      rules.each do |rule|
        calendar.add_rule(rule["field"],
                          rule["operator"],
                          rule["val"])
      end
    end

    def add_alarms
      alarms = calendar_config["alarms"]
      return unless alarms

      calendar.clear_existing_alarms = true if alarms['clear_existing']

      triggers = alarms["triggers"]
      return unless triggers

      triggers.each do |trigger|
        calendar.add_alarm_trigger(trigger)
      end
    end

    def setup_archive
      archive_cfg = calendar_config["archive"]
      return unless archive_cfg

      enabled = archive_cfg == true || archive_cfg["enabled"]
      return unless enabled

      path = archive_cfg.is_a?(Hash) ? archive_cfg["path"] : nil
      if path.nil? || path.to_s.strip.empty?
        # Default to ./archive/<calendar_name>.ics if name known; else ./archive/default.ics
        fname = (calendar_name && !calendar_name.to_s.empty?) ? calendar_name.to_s : 'default'
        path = File.expand_path("../../archive/#{fname}.ics", __dir__)
      end

      max_age_days = archive_cfg.is_a?(Hash) ? archive_cfg["max_age_days"] : nil
      window_days = archive_cfg.is_a?(Hash) ? archive_cfg["window_days"] : nil

      calendar.archive_store = ArchiveStore.new(
        path,
        max_age_days: max_age_days,
        window_days: window_days
      )
    end

  end
end
