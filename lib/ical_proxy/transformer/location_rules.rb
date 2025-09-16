module IcalProxy
  module Transformer
    class LocationRules
      Rule = Struct.new(
        :pattern, :search_in, :set_location, :geo,
        :extract_from, :capture_group, :set_if_blank
      )

      def initialize(rules)
        @rules = rules
      end

      def apply(event)
        @rules.each do |rule|
          if rule.extract_from
            apply_extract_rule(event, rule)
          else
            apply_match_rule(event, rule)
          end
        end
      end

      private

      def apply_match_rule(event, rule)
        return unless matches?(event, rule)

        if rule.set_location && !rule.set_location.to_s.empty?
          event.location = rule.set_location
        end

        apply_geo(event, rule.geo)
      end

      def apply_extract_rule(event, rule)
        src = field_value(event, rule.extract_from)
        return if src.empty?

        pat = rule.pattern
        m = pat.is_a?(Regexp) ? src.match(pat) : (src.include?(pat.to_s) && [nil, pat.to_s])
        return unless m

        target = begin
          idx = (rule.capture_group || 1).to_i
          m.is_a?(MatchData) ? m[idx] : m[1]
        rescue
          nil
        end
        return unless target && !target.to_s.empty?

        if rule.set_if_blank
          return unless field_value(event, 'location').strip.empty?
        end

        event.location = target.to_s.strip
        apply_geo(event, rule.geo)
      end

      def matches?(event, rule)
        fields = Array(rule.search_in)
        fields = ['summary'] if fields.empty?

        fields.any? do |field|
          value = field_value(event, field)
          next false if value.empty?

          pat = rule.pattern
          pat.is_a?(Regexp) ? !!value.match(pat) : value.include?(pat.to_s)
        end
      end

      def field_value(event, field)
        case field.to_s
        when 'summary' then event.summary.to_s
        when 'description' then event.description.to_s
        when 'location' then event.location.to_s
        else ''
        end
      end

      def apply_geo(event, geo)
        return unless geo && geo['lat'] && geo['lon']
        event.geo = [geo['lat'], geo['lon']]
      end
    end
  end
end

# Register builders for transformations.location_rules and transformations.location
begin
  IcalProxy::Transformer::Registry.register('location_rules') do |rules_cfg|
    rules = Array(rules_cfg).map do |rule|
      pattern_str = rule["pattern"]
      next nil unless pattern_str

      pattern = begin
        if rule.key?("regex") && rule["regex"] == true
          pattern_str.to_regexp
        elsif pattern_str.is_a?(String) && pattern_str.strip.start_with?("/")
          pattern_str.to_regexp
        elsif pattern_str.is_a?(Regexp)
          pattern_str
        else
          pattern_str.to_s
        end
      rescue
        pattern_str.to_s
      end

      search = rule["search"]
      location = rule["location"]

      geo = if rule["geo"].is_a?(Hash)
              rule["geo"]
            elsif rule.key?("lat") && rule.key?("lon")
              { 'lat' => rule["lat"], 'lon' => rule["lon"] }
            else
              nil
            end

      IcalProxy::Transformer::LocationRules::Rule.new(pattern, search, location, geo)
    end.compact

    next [] if rules.empty?
    IcalProxy::Transformer::LocationRules.new(rules)
  end

  IcalProxy::Transformer::Registry.register('location') do |unified_cfg|
    rules = Array(unified_cfg).map do |rule|
      pattern_str = rule["pattern"]
      next nil unless pattern_str

      pattern = begin
        if rule.key?("regex") && rule["regex"] == true
          pattern_str.to_regexp
        elsif pattern_str.is_a?(String) && pattern_str.strip.start_with?("/")
          pattern_str.to_regexp
        elsif pattern_str.is_a?(Regexp)
          pattern_str
        else
          pattern_str.to_s
        end
      rescue
        pattern_str.to_s
      end

      if rule["extract_from"]
        IcalProxy::Transformer::LocationRules::Rule.new(
          pattern,
          nil,
          nil,
          extract_geo(rule),
          rule["extract_from"].to_s,
          (rule["capture_group"] || 1),
          rule.key?("set_if_blank") ? !!rule["set_if_blank"] : true
        )
      else
        search = rule["search"]
        location = rule["location"]
        geo = extract_geo(rule)

        IcalProxy::Transformer::LocationRules::Rule.new(
          pattern,
          search,
          location,
          geo,
          nil,
          nil,
          nil
        )
      end
    end.compact

    next [] if rules.empty?
    IcalProxy::Transformer::LocationRules.new(rules)
  end

  module IcalProxy
    module Transformer
      class LocationRules
        def self.extract_geo(rule)
          if rule["geo"].is_a?(Hash)
            rule["geo"]
          elsif rule.key?("lat") && rule.key?("lon")
            { 'lat' => rule["lat"], 'lon' => rule["lon"] }
          else
            nil
          end
        end
      end
    end
  end
rescue NameError
  # Registry may be required later; ignore registration if missing
end
