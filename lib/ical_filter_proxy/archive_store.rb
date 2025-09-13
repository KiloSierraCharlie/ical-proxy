require 'fileutils'
require 'time'
require 'set'

module IcalFilterProxy
  # File-based archive that persists ICS events by UID.
  # - Merges all seen non-cancelled events by UID (current feed wins).
  # - Removes events when an explicit cancellation is seen.
  # - Optionally treats disappearances as deletions depending on protection rules.
  # - Optionally prunes very old events via max_age_days.
  class ArchiveStore
    attr_reader :path, :max_age_days, :window_days

    # window_days: consider the live feed to cover the last N days.
    #              If an archived event is missing from the current feed and its end time
    #              is newer than now - N days (i.e., within the window), treat as deleted and remove.
    #              If older than N days, keep (treat as timed out by source).
    # max_age_days: optional retention; events older than this are pruned from archive/output.
    def initialize(path, max_age_days: nil, window_days: nil)
      @path = path
      @max_age_days = max_age_days
      @window_days = window_days
      ensure_dir
    end

    def merge_and_get(current_events)
      existing = load_events

      # Identify cancellations from the current feed and filter them out
      cancelled_uids = uids_for_cancelled(current_events)
      current_non_cancelled = current_events.reject { |e| cancelled?(e) }

      # Index by UID (skip nil UIDs for persistence)
      existing_by_uid = index_by_uid(existing)
      current_by_uid = index_by_uid(current_non_cancelled)

      merged = existing_by_uid.dup

      # Drop any that are now explicitly cancelled
      merged.delete_if { |uid, _| cancelled_uids.include?(uid) }

      # Compute protective earliest bound from current feed if requested
      # cutoff based on configured window
      now_t = Time.now
      window_cutoff = if window_days && window_days.to_i > 0
                        now_t - (window_days.to_i * 86_400)
                      else
                        nil
                      end

      # Treat disappearances as deletions unless protected by configured rules
      current_uids = current_by_uid.keys.to_set
      merged.delete_if do |uid, ev|
        next false if current_uids.include?(uid)

        # Missing from current feed; decide deletion based on window cutoff
        if window_cutoff
          ev_end = event_end_time(ev)
          # If event is within the window (>= cutoff), treat as deleted; else keep
          ev_end >= window_cutoff
        else
          # No window configured: keep all missing (persist)
          false
        end
      end

      # Overlay current feed (wins)
      merged.merge!(current_by_uid) { |_uid, _old, new_ev| new_ev }

      # Apply retention if configured
      if max_age_days && max_age_days.to_i > 0
        cutoff = now_t - (max_age_days.to_i * 86_400)
        merged.select! { |_uid, ev| event_end_time(ev) >= cutoff }
      end

      merged_events = merged.values

      save_events(merged_events)

      # Always include any current events with nil UID (not persisted) that aren't cancelled
      merged_events + current_events.select { |e| e.uid.nil? && !cancelled?(e) }
    end

    private

    def ensure_dir
      FileUtils.mkdir_p(File.dirname(path))
    end

    def load_events
      return [] unless File.exist?(path)

      data = File.read(path, encoding: 'UTF-8')
      cal = Icalendar::Calendar.parse(data).first
      cal ? cal.events : []
    rescue StandardError
      []
    end

    def save_events(events)
      cal = Icalendar::Calendar.new
      events.each { |e| cal.add_event(e) }
      File.write(path, cal.to_ical)
    end

    def index_by_uid(events)
      events.each_with_object({}) do |ev, acc|
        next unless ev.respond_to?(:uid)
        uid = ev.uid
        next if uid.nil? || uid.to_s.strip.empty?
        acc[uid.to_s] = ev
      end
    end

    def cancelled?(ev)
      status = ev.respond_to?(:status) ? ev.status : nil
      status.to_s.upcase == 'CANCELLED'
    end

    def uids_for_cancelled(events)
      events.each_with_object(Set.new) do |ev, acc|
        next unless ev.respond_to?(:uid)
        uid = ev.uid
        next if uid.nil? || uid.to_s.strip.empty?
        acc << uid.to_s if cancelled?(ev)
      end
    end

    def event_end_time(ev)
      t = safe_event_end_time(ev)
      t || Time.now
    end

    def safe_event_end_time(ev)
      # Prefer dtend, fallback to dtstart
      t = ev.dtend || ev.dtstart
      if t.respond_to?(:to_time)
        t.to_time
      else
        Time.parse(t.to_s)
      end
    rescue StandardError
      nil
    end
  end
end
