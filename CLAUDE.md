# Public Land Voting Tool

Owner: Tim (Planning and Design Specialist, Western Reserve Land Conservancy). Started as a Data Day demo ("Common Ground"), then "Public Land Record", then "Cleveland Land Ballot". The current name is **Public Land Voting Tool**. Don't use "Ballot".

## Where things stand (Oct 4, 2026)

- **`index.html` is the app**, connected to the shared database (Supabase project `parcel-vote`, tables and functions `pv_*`, defined in `schema.sql`). It's meant to be hosted on GitHub Pages; only `index.html` needs to be published.
- **`index.html?prototype`** runs the same page against a private copy in the browser (localStorage) with sample maps and record tools, for trying design changes without touching the real record. `prototype/index.html` just redirects there.
- **Database status:** tables, map/code/vote functions, and access rules are applied to `parcel-vote` and checked as `anon`. Still to apply: `finish-setup.sql` (take-back function, the pv city sync and its hourly schedule, and removal of the old `lb_*` tables). Supabase's approval prompt blocked those from here, so Tim pastes it into the SQL editor. Until then, taking a vote back fails, and the old `lb-city-sync` job runs hourly and fails harmlessly (its table was renamed).
- `archive/` holds the earlier Cleveland Land Ballot page and schema (green/grey votes on one shared map). Superseded; don't build on it.

## Purpose

Cleveland's public vacant land has no market, so nothing signals what it should become. This tool builds a standing public record of what organized groups of people want, to hold those in power accountable and give everyone a voice. It records votes. Interpretation happens in meetings and conversations.

## The design (Tim's spec, Oct 4, 2026)

- **The land.** Every map is the city's full land bank inventory, pulled from the city's open data portal. The city decides what's published. When a parcel enters or leaves the inventory, every map updates, and votes on parcels that leave stay in the record. Coalitions don't pick lots.
- **The record.** Votes are stored outside the city, keyed by parcel, with the map and a timestamp. Anyone can view and download them. There's no site admin.
- **Maps.** A coalition creates a map and sets its terms:
  - The question, which defines what a vote means. No built-in categories.
  - The vote budget: how many votes each member gets (artificial scarcity, so the map shows where members agree most).
  - Invite codes, one per member. They define membership, prevent repeat voting, and show turnout (issued vs. used).
  - On-site voting, optional: a vote counts only if cast near the lot.
  The terms are shown on the map, and the coalition's steward is responsible for them.
- **Voting.** One parcel at a time, through a parcel card filled with the city's own data, blanks included. Location centers the map on the voter, and the voter picks the lot. Working through the whole inventory with a few votes is slow on purpose. Votes are public as they're cast, with an Everyone/Mine toggle. Lots darken as agreement grows, and an address list view covers lots without addresses. One person can vote on any map they have a code for. One vote per lot per map.
- **Connections between maps.** The parcel card lists the other maps where that lot got votes, with each map's question and vote count, linked to its public view. That's how maps are compared and how coalitions find each other.
- **Privacy.** No personal data is stored. On-site voting records a yes/no flag, never coordinates.
- **Removed:** bulk and GeoJSON upload, lot selection at map creation, green/grey categories, map overlay, phone verification (shelved), the "Ballot" name.
- **Still open:** assemblages (groups of adjacent lots); likely left out.
- **Data Day demo:** printed invite cards at the door, on-site voting off, the room votes as one coalition.

## How the app works

One file, `index.html`. Plain HTML/CSS/JS, MapLibre GL 4.7.1 from jsdelivr, supabase-js 2 from jsdelivr (live mode only), qrcode-generator 1.4.4 from cdnjs (loaded only when printing invite cards). No build step.

- **Pages** (hash routes): home `#/` (purpose, a box that takes an invite code or a steward key, list of maps, start a map, download everything); start a map `#/new`; invite codes `#/m/<id>/codes` (steward only); a map `#/m/<id>` (optionally `?lot=<parcel>` to open a lot); `#/join/<code>` (what an invite card's QR code opens: joins and goes straight to the map).
- **Live updates:** an open map re-reads the tally, turnout, and your votes every 20 s (`CONFIG.refreshSeconds`) while on screen.
- **Invite cards** carry the code, the terms, the page address, and a QR code for `#/join/<code>`. Only unused codes are printed.
- **Starting a map:** question, coalition/steward name, votes per member, number of invite codes, on-site on/off. Creating it shows a **steward key** (three words, shown once) and the codes. The steward key is the only way back to the codes page, where the steward can print invite cards (unused codes only), download codes as CSV, and add more codes. There's no other admin.
- **Invite codes:** 8 characters from an unambiguous alphabet, shown as `K7P3-QX9M`; typing is forgiving (case, dashes). Each code is a member number on that map; the public record shows member numbers, never codes. A code counts as "used" once it has cast a vote. A code entered on another map's page takes you to its own map.
- **Map view:** top card with the question, steward, terms (votes per member, turnout, total votes, on-site rule), Everyone/Mine, Map/List, the darkness key, and Download votes. Bottom card: invite code box, or "Member 7 · 3 votes left of 5" with a budget bar and "Not you?". A locate button centers on the voter (automatically on phones when a map opens); the voter's position is shown as a blue dot and never saved.
- **Parcel card** (tap a lot): label, parcel number, this map's vote count and darkness, the vote button, the city's record (every field the layer publishes, with the layer's own field names; empty values show as "Blank"), and other maps with votes on this lot. On phones the card is a bottom sheet; the top card shrinks to the question and the map pans so the lot stays visible.
- **Tap to vote** (Tim, Oct 4): a member taps a lot and the vote is cast at once; the card opens showing it. Tapping a lot you voted for takes the vote back. Out of votes: the card says so and nothing is cast. Not a member: the card opens with the invite code prompt. A double tap counts once, and double-tap zoom is off because taps are votes. The card keeps "Take back your vote" and, for lots opened from the list or another map, "Vote for this lot". On on-site maps the phone's location is checked against the lot (within 100 m of its center, `CONFIG.onsiteMeters`); off-site votes are refused with the distance, and only `onsite: true/false` is stored.
- **Darkness:** five steps relative to the most-voted lot on that map (`RAMP`, light lilac to near-black). Mine view: your lots in ink, others faint.
- **List view:** every lot, searchable by street, address, or parcel number, sorted by most votes or A to Z, 200 rows at a time; tapping a row opens it on the map.
- **Lots:** read live from the city's layer with all fields (`outFields=*`), 9 parallel requests of 2,000. Saved in IndexedDB keyed by the city's edit date, so later visits load in well under a second. Labels for lots without addresses: "Lot on Canal Rd", "Next to 1218 E 79th St", else "Parcel 101-31-002".
- **Saving:** all through `Store` (maps, map, create, codes, addCodes, findByKey, join, vote, unvote, tally, mine, lotMaps, record). `RemoteStore` calls the `pv_*` functions; `LocalStore` (prototype) keeps one JSON record in localStorage (`plvt:prototype:v1`). Codes this device has entered: `plvt:my-codes:live` (or `plvt:my-codes` in the prototype).
- **Prototype tools** (bottom of home, `?prototype` only): add two sample maps with invented votes (one on-site, sharing lots with the other, to show connections), download every vote as CSV, save/load the whole record as JSON, erase everything.
- **Limits:** the on-site check happens on the voter's phone; the database only receives yes/no, so a determined person could fake it. Invite codes are 8 characters from 31 (about 850 billion combinations), and wrong codes and keys are rate-limited per network address.

## Data source

The City of Cleveland land bank inventory ("Land Bank Lots"):
`https://services3.arcgis.com/dty2kHktVXHrqO8i/arcgis/rest/services/City_Landbank/FeatureServer/0`
- Definition query `(isCityLandBank = 1) AND (landBankHoldAreas IS NULL)`; 16,437 lots as of the city's Sep 27, 2026 edit (Residential 16,392, Commercial 45).
- Max 2,000 records per request, paged by `OBJECTID`; CORS open; works from a file opened on disk.
- Fields: `parcelpin` (Parcel Number), `par_addr_all` (Parcel Address), `total_legal_front` (Legal Frontage), `total_square_ft` (Parcel Square Feet), `cityLandBankType` (City Land Bank Type). A street number of 0 means no address.

## The database (schema.sql)

- `pv_parcels` (the city's lots, synced hourly by `pv_sync_city`, archived not deleted), `pv_sync`, `pv_maps` (question, steward, budget, on-site, sha-256 of the steward key, member counter), `pv_codes` (plain codes, readable only through the steward key), `pv_votes` (map, parcel, member number, time, on-site flag), `pv_history` (every vote and take-back), `pv_attempts`.
- Public can read `pv_parcels`, `pv_sync`, `pv_votes`, `pv_history` directly. Maps only through `pv_list_maps` / `pv_get_map` (so the key hash never leaves). Codes and attempts are private.
- Functions the page calls: `pv_list_maps`, `pv_get_map`, `pv_create_map` (generates the id, the three-word steward key, and the codes), `pv_codes` / `pv_add_codes` (steward key), `pv_find_by_key`, `pv_join`, `pv_vote`, `pv_unvote`, `pv_tally`, `pv_mine`, `pv_lot_maps`, `pv_record`. Errors come back as `{"error": "<code>"}`.
- Rate limits per network address: 30 wrong codes/keys per 10 minutes, 20 new maps per hour.
- `schema.sql` is rerunnable; on a database that still has the Land Ballot tables it renames `lb_parcels`/`lb_sync` to `pv_*` (keeping the 16,437 lots) and drops the rest. The `http` extension needs a 20 s connect timeout for the city's service (set in `pv_city_get`).

## Publishing (GitHub Pages)

Repository: https://github.com/timothydehm/public-land-vote (address once Pages is on: https://timothydehm.github.io/public-land-vote/). Upload `index.html` to the repository root, then Settings > Pages > Deploy from a branch > `main` / root. Claude can't push to the repository from its session; Tim uploads through the GitHub website. The publishable Supabase key in `CONFIG` is meant to be public. After it's live, print invite cards from the hosted page so their QR codes carry the real address.

## Testing approach

- Prototype mode: Playwright with Chromium (SwiftShader for WebGL) opening the file from disk (`file://...index.html?prototype`), city layer routed to a local fixture with the real field list. Covers making a map, steward key and codes, joining with a messy code, tap to vote, budget limit, take back, a second member, Everyone/Mine, list search, download, sample maps, connections, on-site far/near, wrong steward key, double tap, reload.
- Live mode: the same page with Supabase calls routed into a local Postgres 16 running `schema.sql` as `anon` (one network address per browser). Covers creating a map, QR invite cards, joining by `#/join/<code>`, tap to vote and budget, a second member seeing votes within seconds, take back, steward key from home in another browser, on-site far/near on an on-site map, connections, CSV, and a bad join link.
- SQL: every `pv_*` function as `anon`, including bad inputs, rate limits, the Land Ballot migration, and the city sync against a fixture.

## Design rules

- Simple, sleek, doesn't look AI-generated. One typeface (Public Sans), plain sentence-case copy, no decoration that doesn't carry information.
- Only votes: no notes, comments, or free-text reasons.

## Working with Tim

- Direct, no flattery. He'll push back when it helps; commit and iterate rather than over-analyze.
- No timeline estimates unless he asks.
- Ask before creating things he didn't request; when he says build, build fully and test.
