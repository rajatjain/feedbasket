# Publisher test data

Source: NASA, captured 13 November 2026.

- `nasa.xml` and `nasa-2.xml` are the first two pages of the [NASA RSS feed](https://www.nasa.gov/feed/) ([page 2](https://www.nasa.gov/feed/?paged=2)). The snapshots retain publisher titles, GUIDs, URLs, authors, and publication dates. Embedded bodies and media were removed.
- `nasa-artemis.html` retains the title, canonical link, and article paragraphs from [I Am Artemis Katie Spicer](https://www.nasa.gov/missions/artemis/i-am-artemis-katie-spicer/) by Beverly Perry. Images, site chrome, and scripts were removed.

The suite creates and populates a fresh on-disk SQLite database from these sources for each workflow. It uses disposable account records and real FeedBasket sessions.

The job workflow tests serve these samples from a temporary loopback HTTP server. They rewrite article links and add a next-page link to exercise redirects, canonical URLs, and pagination. The server also returns HTTP 503 to exercise retry and recovery.
