module IcalProxy
  module Transformer
    # Renames an event's summary based on a regex or string match.
    # Supports matching against summary and/or description, and normalization
    # (set summary to a fixed string when a match occurs). Optionally, you can
    # take a regex capture group and set the summary to that value.
    class Rename
      attr_reader :pattern, :replacement, :search_in, :set_on_match, :capture_group

      # pattern: Regexp or String
      # replacement: String
      # options:
      #   search_in: Array of 'summary'|'description' (default: ['summary'])
      #   set_on_match: when true, set summary to replacement (or capture) on any match
      #   capture_group: Integer index of capture group to use when setting summary (default: nil)
      def initialize(pattern, replacement, search_in: ['summary'], set_on_match: false, capture_group: nil)
        @pattern = pattern.is_a?(Regexp) ? pattern : pattern.to_s
        @replacement = replacement.to_s
        @search_in = Array(search_in).map(&:to_s)
        @set_on_match = !!set_on_match
        @capture_group = capture_group.nil? ? nil : capture_group.to_i
      end

      # Mutates the event summary if it matches the pattern
      def apply(event)
        fields = search_in
        fields = ['summary', 'description'] if fields.empty?

        matched = false
        first_match_data = nil

        fields.each do |field|
          value = safe_string(event, field)
          next if value.empty?
          if pattern.is_a?(Regexp)
            m = value.match(pattern)
            if m
              matched = true
              first_match_data ||= m
              break
            end
          else
            if value.include?(pattern)
              matched = true
              break
            end
          end
        end

        return unless matched

        if set_on_match
          if pattern.is_a?(Regexp) && !capture_group.nil? && first_match_data
            captured = begin
              first_match_data[capture_group]
            rescue
              nil
            end
            event.summary = (captured && !captured.to_s.empty?) ? captured.to_s : replacement
          else
            event.summary = replacement
          end
        else
          current = event.summary.to_s
          return if current.empty?
          event.summary = pattern.is_a?(Regexp) ? current.gsub(pattern, replacement) : current.gsub(pattern, replacement)
        end
      end

      private

      def safe_string(event, field)
        case field
        when 'summary'
          event.summary.to_s
        when 'description'
          event.description.to_s
        else
          ''
        end
      end
    end
  end
end

# Register as a plugin for transformations.rename
begin
  IcalProxy::Transformer::Registry.register('rename') do |rename_rules|
    rules = Array(rename_rules)

    rules.map do |rule|
      pattern_str = rule["pattern"] || rule["match"] || rule["matches"]
      next nil unless pattern_str
      replacement = rule["replace"] || rule["replacement"] || rule["to"] || ""

      search_in = rule["search_in"] || rule["search"] || rule["in"] || ["summary"]
      capture_group = rule["capture_group"] || rule["capture"] || (rule["use_capture"] ? 1 : nil)
      set_on_match = if rule.key?("set_on_match")
                       rule["set_on_match"]
                     else
                       (!!rule["to"] || !!rule["normalize"] || !capture_group.nil?)
                     end

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

      IcalProxy::Transformer::Rename.new(
        pattern,
        replacement,
        search_in: search_in,
        set_on_match: set_on_match,
        capture_group: capture_group
      )
    end.compact
  end
rescue NameError
  # Registry may be required later; ignore registration if missing
end
