# frozen_string_literal: true

RSpec.describe Scraper do
  let(:fixture) { File.read(File.join(__dir__, "fixtures", "lodged.html")) }
  let(:saved) { [] }
  let(:requested) { [] }

  around do |example|
    period = ENV.delete("MORPH_PERIOD")
    example.run
  ensure
    ENV["MORPH_PERIOD"] = period
  end

  before do
    allow(ScraperWiki).to receive(:save_sqlite) { |_keys, record| saved << record }
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  # Runs the scraper with every request answered by html, and returns its output
  def run_with(html, period: "thisweek")
    ENV["MORPH_PERIOD"] = period
    allow_any_instance_of(Mechanize).to receive(:get) do |agent, url|
      requested << url
      Mechanize::Page.new(URI(url), { "content-type" => "text/html" }, html, 200, agent)
    end
    output = StringIO.new
    $stdout = output
    described_class.run
    output.string
  ensure
    $stdout = STDOUT
  end

  # The fixture with only the given cards, each repeated, and a matching count
  def page_with(cards)
    doc = Nokogiri::HTML(fixture)
    originals = doc.css("article.application-result-card").to_a
    list = doc.at(".application-results-list")
    originals.each(&:remove)
    cards.each { |index, times| times.times { list.add_child(originals[index].dup) } }
    doc.at(".results-summary-title").content = "#{cards.sum { |_, times| times }} applications found"
    doc.to_html
  end

  def record(reference)
    saved.find { |r| r["council_reference"] == reference }
  end

  describe "a complete application" do
    it "is saved with a clean address, its own description and its details page" do
      run_with(fixture)
      expect(record("DA-9001/2026")).to eq(
        "council_reference" => "DA-9001/2026",
        "address" => "1 Example Street BANKSTOWN NSW 2200",
        "description" => "Construction of an example dual occupancy",
        "info_url" => "https://eplanning.cbcity.nsw.gov.au/ApplicationSearch/ApplicationDetails" \
                      "?applicationNumber=DA-9001%2F2026&applicationTypeCode=21",
        "date_scraped" => Date.today.to_s,
        "date_received" => "2026-10-26"
      )
    end
  end

  describe "an application missing something PlanningAlerts can do without" do
    it "uses the application type when there is no description of its own" do
      run_with(fixture)
      expect(record("CD-9002/2026")["description"]).to eq("Private Certified Complying Development")
    end

    it "links to the search page when there is no details link" do
      run_with(fixture)
      expect(record("CC-9003/2026")["info_url"]).to eq("https://eplanning.cbcity.nsw.gov.au/ApplicationSearch")
    end

    it "leaves out date_received with a warning when the lodged date can't be read" do
      output = run_with(fixture)
      expect(record("DA-9004/2026")).not_to have_key("date_received")
      expect(output).to include('Warning: DA-9004/2026 has an unreadable lodged date "not recorded"')
    end
  end

  describe "an application with no application number or address" do
    it "is skipped and reported, and counted in the total" do
      output = run_with(fixture)
      expect(saved.map { |r| r["council_reference"] }).to eq(%w[DA-9001/2026 CD-9002/2026 CC-9003/2026 DA-9004/2026])
      expect(output).to include("Skipping bad application (thisweek card 5): DA-9005/2026 has no address")
      expect(output).to include("Skipping bad application (thisweek card 6): no application number")
      expect(output).to include("Finished - saved 4 records, skipped 2 bad applications")
    end

    it "is allowed up to 10 + 20% of the saved records" do
      expect { run_with(page_with([[0, 1], [4, 10]])) }.not_to raise_error
    end

    it "stops the run once there are more than 10 + 20% of the saved records" do
      expect { run_with(page_with([[0, 5], [4, 12]])) }
        .to raise_error(RuntimeError, "Too many bad applications: skipped 12, saved 5")
    end
  end

  describe "checks on the page" do
    it "stops when the number of cards doesn't match the stated count" do
      html = fixture.sub("6 applications found", "7 applications found")
      expect { run_with(html) }.to raise_error(RuntimeError, /Expected 7 applications but found 6/)
    end

    it "stops when the results summary isn't a count" do
      html = fixture.sub("6 applications found", "Something went wrong")
      expect { run_with(html) }.to raise_error(RuntimeError, /Unexpected results summary "Something went wrong"/)
    end

    it "stops when there are applications but no results summary" do
      html = fixture.sub("results-summary-title", "something-else")
      expect { run_with(html) }.to raise_error(RuntimeError, /No results summary found/)
    end

    it "stops when the page states applications but none are found" do
      html = page_with([]).sub("0 applications found", "3 applications found")
      expect { run_with(html) }.to raise_error(RuntimeError, /Expected 3 applications but found 0/)
    end
  end

  describe "a period with no applications" do
    it "finishes normally when the page says 0 applications found" do
      output = run_with(page_with([]))
      expect(saved).to be_empty
      expect(output).to include("No applications lodged thisweek")
      expect(output).to include("Finished - saved 0 records")
    end

    # The empty page hasn't been seen yet, so it may word or leave out the count
    it "finishes normally when the page gives no count" do
      html = page_with([]).sub("0 applications found", "No applications found")
      expect { run_with(html) }.not_to raise_error
      html = page_with([]).sub("results-summary-title", "something-else")
      expect { run_with(html) }.not_to raise_error
    end
  end

  describe "periods" do
    it "scrapes this month and last month by default" do
      run_with(fixture, period: "")
      expect(requested.map { |url| url[/filter=(\w+)/, 1] }).to eq(%w[thismonth lastmonth])
    end

    it "rejects an unknown MORPH_PERIOD" do
      expect { run_with(fixture, period: "fortnight") }.to raise_error(RuntimeError, /Unknown MORPH_PERIOD "fortnight"/)
    end
  end

  describe "MORPH_DEBUG" do
    around do |example|
      ENV["MORPH_DEBUG"] = "1"
      example.run
    ensure
      ENV.delete("MORPH_DEBUG")
    end

    it "prints each record as it is saved" do
      expect(run_with(fixture)).to include('RECORD: {"council_reference"=>"DA-9001/2026"')
    end
  end

  describe "the Australian proxy" do
    around do |example|
      ENV["MORPH_AUSTRALIAN_PROXY"] = "http://morph:example@proxy.example.org:8888"
      example.run
    ensure
      ENV.delete("MORPH_AUSTRALIAN_PROXY")
    end

    it "is used when MORPH_AUSTRALIAN_PROXY is set" do
      proxies = []
      allow_any_instance_of(Mechanize::HTTP::Agent).to receive(:set_proxy) { |_agent, proxy| proxies << proxy }
      expect(run_with(fixture)).to include("Using Australian proxy...")
      # Mechanize.new calls set_proxy(nil) itself, so the scraper's call is the last
      expect(proxies.last).to eq("http://morph:example@proxy.example.org:8888")
    end
  end
end
