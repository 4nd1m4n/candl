module Candl
  class MonthModel
    # Attributes one needs to access from the "outside"
    attr_reader :delta_start_of_weekday_from_sunday
    attr_reader :summary_teaser_length

    attr_reader :view_dates
    attr_reader :grouped_events
    attr_reader :grouped_multiday_events

    # Minimal json conifg for month_model example:
    # config = { \
    #   calendar: { \
    #     google_calendar_api_host_base_path: "https://www.googleapis.com/calendar/v3/calendars/", \
    #     calendar_id: "schau-hnh%40web.de", \
    #     api_key: "AIzaSyB5F1X5hBi8vPsmt1itZTpMluUAjytf6hI" \
    #   }, \
    #   agenda: { \
    #     display_day_count: 14, \
    #     days_shift_coefficient: 7 \
    #   }, \
    #   month: { \
    #     summary_teaser_length_in_characters: 42, \
    #     delta_start_of_weekday_from_sunday: 1 \
    #   }, \
    #   general: { \
    #     maps_query_host: "https://www.google.de/maps", \
    #     maps_query_parameter: "q", \
    #     cache_update_interval_in_s: 7200 \
    #   } \
    # }
    def initialize(config, current_shift_factor, date_today = Date.today)
      self.google_calendar_base_path = config[:calendar][:google_calendar_api_host_base_path]
      self.calendar_id = config[:calendar][:calendar_id]
      self.api_key = config[:calendar][:api_key]

      self.summary_teaser_length = config[:month][:summary_teaser_length_in_characters]
      self.delta_start_of_weekday_from_sunday = config[:month][:delta_start_of_weekday_from_sunday]

      self.days_shift_coefficient = config[:agenda][:days_shift_coefficient]

      self.maps_query_host = config[:general][:maps_query_host]
      self.maps_query_parameter = config[:general][:maps_query_parameter]
      self.cache_update_interval_in_ms = config[:general][:cache_update_interval_in_ms]

      date_month_start = MonthModel.current_month_start(current_shift_factor, date_today)
      date_month_end = MonthModel.current_month_end(current_shift_factor, date_today)

      self.view_dates = generate_months_view_dates(date_month_start, date_month_end)

      events = get_month_events(view_dates.first, view_dates.last)

      self.grouped_events = MonthModel::group_events(events, view_dates.first, view_dates.last)
      self.grouped_multiday_events = MonthModel::group_multiday_events(events, view_dates)
    end

    # finds the best event, among those multiday events within a week-group, for the current day (the algorithm will find the longest events first to display them above shorter multiday events)
    def self.find_best_fit_for_day(first_weekday, day, event_heap)
      best_fit = event_heap.select{ |event| (day == first_weekday ?  (event.dtstart <= day && event.dtend >= day) : (event.dtstart == day)) }.sort_by{ |event| [event.dtstart.to_time.to_i, -event.dtend.to_time.to_i] }.first
    end

    # builds base path of current view
    def path(page_path, params = {})
      ActionDispatch::Http::URL.path_for path: page_path, params: {v: 'm'}.merge(params)
    end

    # builds path to previous/upcoming month
    def previous_path(page_path, current_shift_factor)
      month_shift_path(page_path, current_shift_factor, -1)
    end

    def upcoming_path(page_path, current_shift_factor)
      month_shift_path(page_path, current_shift_factor, 1)
    end

    def month_shift_path(page_path, current_shift_factor, shift_factor)
      path(page_path, s: (current_shift_factor.to_i + shift_factor.to_i).to_s)
    end

    # current shift factor for switching between calendar views from month to agenda
    def current_shift_for_agenda(current_shift_factor)
      today_date = Date.today
      current_shift_in_days = (MonthModel.current_month_start(current_shift_factor, today_date) - today_date).to_i

      current_shift_in_days = (MonthModel.current_month_start(current_shift_factor, today_date) + ((MonthModel.current_month_end(current_shift_factor, today_date) - MonthModel.current_month_start(current_shift_factor, today_date)).div 5) - today_date).to_i

      current_shift_factor_for_agenda = (current_shift_in_days.div days_shift_coefficient)

      current_shift_factor_for_agenda
    end

    # current shift factor for switching between calendar views from month to month
    def current_shift_for_month(current_shift_factor)
      current_shift_factor
    end

    # helps apply styling to a special date
    def self.emphasize_date(check_date, emphasized_date, emphasized, regular)
      check_date.to_date == emphasized_date.to_date ? emphasized : regular
    end

    # depending on the cutoff conditions this will apply a cutoff style to the start of the event, the end of it, both ends or neither
    def self.multiday_event_cutoff(cutoff_start_condition, cutoff_end_condition, cutoff_start_style, cutoff_both_style, cutoff_end_style)
      if (cutoff_start_condition && cutoff_end_condition)
        cutoff_both_style
      elsif (cutoff_start_condition)
        cutoff_start_style
      elsif (cutoff_end_condition)
        cutoff_end_style
      else
        ''
      end
    end

    # build a short event summary (for popups etc.)
    def self.summary_title(event)
      event.summary.to_s.force_encoding("UTF-8") + "\n" + event.location.to_s.force_encoding("UTF-8") + "\n" + event.description.to_s.force_encoding("UTF-8")
    end

    # build a google maps path from the adress details
    def address_to_maps_path(address)
      # URI::HTTP.build( host: maps_query_host, query: { maps_query_parameter: address.force_encoding("UTF-8").gsub(" ", "+") }.to_query).to_s
      ActionDispatch::Http::URL.path_for path: maps_query_host, params: Hash[maps_query_parameter.to_s, address.force_encoding("UTF-8").gsub(" ", "+")]
    end

    # will generate the dates of a whole week around the date given (starting from the configured day)
    def weekday_dates(today_date = Date.today)
      weekdays_dates = []
      first_day_of_week = today_date - (today_date.wday - delta_start_of_weekday_from_sunday)
      7.times do |day|
        weekdays_dates += [first_day_of_week + day]
      end
      weekdays_dates
    end

    # generates all needed dates within the start and the end of a month
    def generate_months_view_dates(date_month_start, date_month_end)
      dates_in_month_view = []
      ((date_month_start.wday - delta_start_of_weekday_from_sunday) % 7).times do |day|
        dates_in_month_view = dates_in_month_view + [(date_month_start - (((date_month_start.wday - delta_start_of_weekday_from_sunday) % 7) - day))]
      end

      date_month_end.day.times do |day|
        dates_in_month_view = dates_in_month_view + [date_month_start + day]
      end

      (6 - date_month_end.wday + delta_start_of_weekday_from_sunday).times do |day|
        dates_in_month_view = dates_in_month_view + [date_month_end + day + 1]
      end

      dates_in_month_view
    end

    # how many weeks are within this months view dates
    def self.weeks_in_months_view_dates(months_view_dates)
      months_view_dates.length.div 7
    end

    # get date of current months start
    def self.current_month_start(current_shift_factor, today_date = Date.today)
      (today_date + (current_shift_factor.to_i).month).beginning_of_month
    end

    # get date of current months end
    def self.current_month_end(current_shift_factor, today_date = Date.today)
      (today_date + (current_shift_factor.to_i).month).end_of_month
    end

    private

    # gets events of all kinds for the timeframe [form, to]
    def get_month_events(from, to)
      EventLoaderModel.get_month_events(google_calendar_base_path, calendar_id, api_key, from, to)
    end

    # gets events within a day grouped by day
    def self.group_events(events, from, to)
      # events = month_events(from, to)
      events.select { |event| event.dtstart.instance_of?(DateTime) }.sort_by{ |event| event.dtstart.localtime }.group_by { |event| event.dtstart.to_date }
    end

    # gets events that are multiple day's long grouped by the week
    def self.group_multiday_events(events, view_dates)
      multiday_events = events.select { |event| event.dtstart.instance_of?(Date) }

      grouped_multiday_events = []

      weeks_in_months_view_dates(view_dates).times do |week|
        first_weekday = view_dates[7 * week]
        last_weekday = view_dates[7 * week + 6]

        weeks_events = multiday_events.select{ |event| event.dtend > first_weekday && event.dtstart <= last_weekday }

        grouped_multiday_events[week] = weeks_events
      end

      grouped_multiday_events
    end

    attr_writer :delta_start_of_weekday_from_sunday
    attr_writer :summary_teaser_length

    attr_writer :view_dates
    attr_writer :grouped_events
    attr_writer :grouped_multiday_events

    attr_accessor :calendar_id
    attr_accessor :api_key

    attr_accessor :google_calendar_base_path
    attr_accessor :maps_query_host
    attr_accessor :maps_query_parameter
    attr_accessor :cache_update_interval_in_ms

    attr_accessor :days_shift_coefficient

  end
end