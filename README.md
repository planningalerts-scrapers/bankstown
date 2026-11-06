# Canterbury-Bankstown Council scraper

This is a scraper that runs on [Morph](https://morph.io). To get started [see the documentation](https://morph.io/documentation).

It scrapes development applications for [Canterbury-Bankstown Council](https://www.cbcity.nsw.gov.au/) from the council's [DA tracker](https://eplanning.cbcity.nsw.gov.au/ApplicationSearch) and feeds [PlanningAlerts](https://www.planningalerts.org.au/authorities/bankstown).

Issues with this authority are tracked in the shared issue tracker: [planningalerts-scrapers/issues#1459](https://github.com/planningalerts-scrapers/issues/issues/1459).

## How the site is structured

- The tracker lists every application lodged in a period (`yesterday`, `thisweek`, `lastweek`, `thismonth` or `lastmonth`) on one page, with no paging. It covers development applications, complying development and construction certificates, including those from private certifiers.
- Each application is an `article.application-result-card` with the reference, a `Type - description` paragraph, and `dt`/`dd` pairs for Address and Lodged.
- The page says how many applications it found. The scraper raises an error if the number of cards doesn't match.
- A period with no applications, such as a quiet 1st of the month, is normal. The scraper prints `No applications lodged <period>` and carries on, even if the page gives no count. PlanningAlerts flags long gaps in new applications itself.
- DAs on exhibition are only published on the NSW Planning Portal, under PAN references, so they are not scraped here.

## Running

```
bundle install
bundle exec ruby scraper.rb
```

To run the tests and style checks:

```
bundle exec rake
bundle exec rubocop
```

The tests use a saved copy of the tracker's page in `spec/fixtures/lodged.html`, cut down to one card per case, with made-up references and addresses. They don't contact the council's site. A coverage summary is printed at the end, and the full report is written to `coverage/index.html`.

Environment variables:

- `MORPH_AUSTRALIAN_PROXY` - optional; when set (e.g. `http://morph:password@au.proxy.oaf.org.au:8888`) all requests go through the Australian proxy.
- `MORPH_PERIOD` - optional; one of `yesterday`, `thisweek`, `lastweek`, `thismonth` or `lastmonth`. By default both `thismonth` and `lastmonth` are scraped.
- `MORPH_DEBUG` - optional; when set, prints each record as it is saved.

Expected output is a heading for each period, a `Storing <reference> - <address>` line for each application, a count per period and a final total, for example:

```
Running ruby 3.2.2

Scraping applications lodged thismonth...
Storing CD-1556/2026 - 94 Old Kent Road MOUNT LEWIS NSW 2190
Storing CD-1555/2026 - 92 Old Kent Road MOUNT LEWIS NSW 2190
...
Storing CC-401/2026 - 71 Helen Street SEFTON NSW 2162
Storing CC-400/2026 - 52 Roberts Road GREENACRE NSW 2190
Finished thismonth - processed 238 records

Scraping applications lodged lastmonth...
Storing CD-1363/2026 - 43 Victor Avenue PICNIC POINT NSW 2213
Storing CD-1362/2026 - 13 Byloss Street CHESTER HILL NSW 2162
...
Storing DA-1044/2026 - 7 Sir Joseph Banks Street BANKSTOWN NSW 2200
Storing CC-360/2026 - 808 Henry Lawson Drive PICNIC POINT NSW 2213
Finished lastmonth - processed 213 records

Finished - saved 451 records
```

An application with no application number or address is skipped with a `Skipping bad application` line, and the total then also says how many were skipped. Other gaps don't skip it. With no description of its own it gets its application type, for example "Development Application". With no details link it links to the tracker's search page. With an unreadable lodged date, `date_received` is left out and a warning is printed. The run stops with an error once more than 10 + 20% of the saved count have been skipped.

The total is usually a few hundred. The records are saved to `data.sqlite` in the working directory.
