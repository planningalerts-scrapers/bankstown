#!/usr/bin/env ruby
# frozen_string_literal: true

# Scrapes development applications for Canterbury-Bankstown Council.
#
# The council's DA tracker lists every application lodged in a period (this
# week, this month, last month and so on) on a single page with no paging.
# Each application is an article card holding the reference, a
# "Type - description" paragraph and dt/dd pairs for Address and Lodged.
# It covers DAs, complying development and construction certificates,
# including those from private certifiers.
#
# DAs on exhibition are only published on the NSW Planning Portal, under PAN
# references, so they are not scraped here.
#
# See https://github.com/planningalerts-scrapers/issues/issues/1459

require "bundler/setup"
Bundler.require

require "scraperwiki"
require "mechanize"
require "date"

class Scraper
  BASE_URL = "https://eplanning.cbcity.nsw.gov.au"
  LIST_URL = "#{BASE_URL}/ApplicationSearch/SearchByLodgementDate?mode=view-applications-lodged&filter=".freeze

  # Last month as well as this month, so there are always at least 30 days of
  # applications early in the month
  DEFAULT_PERIODS = %w[thismonth lastmonth].freeze
  PERIODS = %w[yesterday thisweek lastweek thismonth lastmonth].freeze

  # An application missing something PlanningAlerts needs is skipped with a
  # warning, but the run stops once there are more than 10 + 20% of good ones
  class BadApplication < StandardError; end

  def self.run
    new.run
  end

  def initialize
    @agent = Mechanize.new
    if ENV["MORPH_AUSTRALIAN_PROXY"]
      # On morph.io set the environment variable MORPH_AUSTRALIAN_PROXY to
      # http://morph:password@au.proxy.oaf.org.au:8888 replacing password with
      # the real password.
      puts "Using Australian proxy..."
      @agent.agent.set_proxy(ENV["MORPH_AUSTRALIAN_PROXY"])
    end
    @debug = !ENV["MORPH_DEBUG"].to_s.empty?
    @saved = 0
    @skipped = 0
  end

  def run
    puts "Running ruby #{RUBY_VERSION}"
    periods.each_with_index do |period, index|
      sleep 1 if index.positive?
      scrape_period(period)
    end
    # Doesn't check which records are new, so reports them all as saved
    puts "", "Finished - saved #{@saved} records#{", skipped #{@skipped} bad applications" if @skipped.positive?}"
  end

  private

  # MORPH_PERIOD picks a single period, for example lastweek, for data recovery
  def periods
    period = ENV["MORPH_PERIOD"].to_s
    return DEFAULT_PERIODS if period.empty?
    return [period] if PERIODS.include?(period)

    raise "Unknown MORPH_PERIOD #{period.inspect}, expected one of #{PERIODS.join(', ')}"
  end

  def scrape_period(period)
    url = LIST_URL + period
    puts "", "Scraping applications lodged #{period}..."
    page = @agent.get(url)
    cards = page.search("article.application-result-card")
    check_count(page, cards.size, url)
    puts "No applications lodged #{period}" if cards.empty?

    cards.each_with_index { |card, index| save_card(card, "#{period} card #{index + 1}") }
    puts "Finished #{period} - processed #{cards.size} records"
  end

  # Checks the cards found against the count the page states. A period with no
  # applications is normal, for example a quiet 1st of the month, and the page
  # may then not give a count. PlanningAlerts flags long gaps itself.
  def check_count(page, found, url)
    summary = clean_text(page.at("#application-search-results .results-summary-title")&.text)
    expected = summary[/\A(\d+) applications? found/, 1]
    return if expected.nil? && found.zero?
    raise "No results summary found at #{url}" if summary.empty?
    raise "Unexpected results summary #{summary.inspect} at #{url}" unless expected
    raise "Expected #{expected} applications but found #{found} at #{url}" unless found == expected.to_i
  end

  def save_card(card, position)
    save(parse_card(card))
  rescue BadApplication => e
    @skipped += 1
    puts "Skipping bad application (#{position}): #{e.message}"
    return if @skipped <= 10 + (@saved / 5.0)

    raise "Too many bad applications: skipped #{@skipped}, saved #{@saved}"
  end

  # Raises BadApplication when the reference or address is missing, as
  # PlanningAlerts can't use the record without them
  def parse_card(card)
    link = card.at("a.application-details-link")
    reference = clean_text(link&.text)
    raise BadApplication, "no application number" if reference.empty?

    fields = card_fields(card)
    address = fields["Address"].to_s
    raise BadApplication, "#{reference} has no address" if address.empty?

    {
      "council_reference" => reference,
      "address" => address,
      "description" => description(card),
      "info_url" => info_url(link),
      "date_scraped" => Date.today.to_s,
      "date_received" => parse_lodged(reference, fields["Lodged"]),
    }.compact
  end

  # Falls back to the tracker's search page when a card has no details link
  def info_url(link)
    href = link["href"].to_s
    URI.join(BASE_URL, href.empty? ? "/ApplicationSearch" : href).to_s
  end

  # Leaves date_received out, with a warning, when the lodged date can't be read
  def parse_lodged(reference, lodged)
    Date.strptime(lodged.to_s, "%d/%m/%Y").to_s
  rescue Date::Error
    puts "Warning: #{reference} has an unreadable lodged date #{lodged.inspect}"
    nil
  end

  # Maps each dt label to its dd value, keeping the first of any repeated label
  def card_fields(card)
    card.search("dt").each_with_object({}) do |dt, fields|
      fields[clean_text(dt.text)] ||= clean_text(dt.next_element&.text)
    end
  end

  # The description starts with the application type, for example
  # "Development Application - Construction of a dual occupancy". Falls back
  # to the type when the application has no description of its own.
  def description(card)
    text = clean_text(card.at("p.application-result-description")&.text)
    type, description = text.delete_suffix(" -").split(" - ", 2)
    description.to_s.empty? ? type.to_s : description
  end

  # Collapses whitespace, including the non-breaking spaces used in addresses
  def clean_text(text)
    text.to_s.gsub(/[[:space:]]+/, " ").strip
  end

  def save(record)
    puts "Storing #{record['council_reference']} - #{record['address']}"
    puts "RECORD: #{record.inspect}" if @debug
    ScraperWiki.save_sqlite(["council_reference"], record)
    @saved += 1
  end
end

Scraper.run if __FILE__ == $PROGRAM_NAME
