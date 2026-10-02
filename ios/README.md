# RideLog: the iOS app

A SwiftUI app for the Ride Logger server in this repo: browse your rides, maps, records and stats, and **record rides with the phone's own
GPS** (no Overland needed). It signs in with the same Authentik account as the website and reads the server's `/api/v1` JSON API
(`app/routers/api_v1.py`). Recorded rides are uploaded to the server's existing `POST /api/ingest`, in the batch format Overland uses, so the
server builds them into rides exactly as before.

**Read this first:** the Swift was written on a Linux server with no Xcode, so it was never compiled or run by its author. The server half
(API, sign-in handshake, ingest) is covered by `python -m pytest` in the repo root; `Tests/Fixtures` lock the JSON the app decodes and the batch
it uploads. If a build fails, paste the Xcode errors to Claude Code and they get fixed. Background GPS can only be tried on a real iPhone.

## Get it onto your iPhone (Mac with Xcode 26)

```bash
brew install xcodegen
git clone https://github.com/skysurfer1508/ride-logger.git ~/ride-logger
cd ~/ride-logger/ios
cp Signing.local.xcconfig.example Signing.local.xcconfig     # then put your Apple Team ID in it
xcodegen generate
open RideLog.xcodeproj
```

Pick your iPhone and press Cmd+R. Your iPhone needs Developer Mode on (Settings > Privacy & Security). Cmd+U runs the unit tests.

Updating later: `git pull`, then `xcodegen generate` again if files were added, then Cmd+R. The server must run the matching version
(`git pull && sudo systemctl restart ride-logger`), or the app gets 404s.

The server address is in `Config.xcconfig` (`SITE_HOST`, host name only). The Xcode project is generated from `project.yml` and is not committed.
Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` for each round of changes so Settings > About shows which build you run.

## How recording works

1. **Record tab > Start.** iOS asks for location access the first time: choose **While Using the App** and keep **Precise Location** on.
2. The app asks CoreLocation for GPS fixes (best accuracy, one fix a second at speed, nothing while you stand still). It keeps running with the
   screen locked (the blue location indicator shows it), and each fix is **written to the phone the moment it arrives**.
3. Every 30 seconds, and again on Stop, the new fixes are uploaded with your account's ingest token. If there is no signal they wait on the
   phone and go up when the connection is back (also when you open the app). Uploading the same fix twice is harmless: the server ignores repeats.
4. **Stop** sends the last fixes plus a trip marker, which is what tells the server the ride is over. The ride then shows under Rides and Overview.
5. If the app is killed or the phone restarts mid-ride, the Record tab offers **Resume** (when it was under 10 minutes ago) or **Finish and upload**.
   Nothing recorded is lost. If a ride is never finished at all, the server closes it by itself about an hour after the last point.

Your rides stay on the phone until they have uploaded; the newest five uploaded ones are kept as a backup (Settings > Recording lists them).

## Where the speed comes from

The speed is **the one iOS reports with each GPS fix**, which it derives from the Doppler shift of the satellite signals. It is not calculated from positions and
not from the accelerometer, and on a clear sky it is accurate to well under 1 km/h. On a real ride (12 min, 4.2 km) it agreed with the speed worked out from the
positions to within 1.8 km/h on average. The app uses it as it is when iOS also states it is accurate (`speedAccuracy` up to 1.5 m/s). When a reading is
missing or poor, it uses the speed between two accurate positions, otherwise keeps the last speed for a moment; it never invents a speed from poor positions.
The accuracy is saved with every fix.

What can still make the number look different from what you expect: **a motorbike's own speedometer reads high** (by rule it may not read low, and many read
5-10 % high), so 100 on the bike is often 92-95 true; the fix arrives once a second, so the number changes in one-second steps; and the Lock Screen / Dynamic
Island display is refreshed every few seconds because iOS limits how often an app may update it (the in-app screen is the live one).

## Live speed on the Lock Screen and in the Dynamic Island

While a ride is recording, RideLog shows a Live Activity: on the **Lock Screen** a banner with the speed, distance, a running timer and your top
speed, and on iPhones with a **Dynamic Island** the speed and distance in the pill (tap or long-press it for the expanded view with the timer and top
speed). The timer is drawn by iOS itself; speed and distance are refreshed every few seconds. If the app stops updating (it crashed or was killed) the
banner shows dashes instead of a frozen speed, and it is removed the next time you open the app. Ending the ride removes it.

It needs Live Activities to be on (iPhone Settings > RideLog > Live Activities; Settings > Recording in the app says whether they are). Recording works
exactly the same without it. It runs in its own extension target (`RideLogWidgets`); if that target ever breaks the build, `project.yml` says what to delete.

## The ride screen: speed map, stops, replay

Tap a ride (Home, Rides, Overview records) to open it.

- **Speed map.** The route is drawn in five colours by speed (under 15, 15-40, 40-70, 70-100, 100+ km/h). **Tap the route**, drag the slider, or touch the
  speed chart to see the exact position, speed, distance ridden so far, altitude and clock time at that spot. The top speed is pinned on the map.
- **Stops.** Every time you stood still for 8 seconds or more is marked with its wait, and listed under **Stops** (tap one to jump to it). Each is
  matched to OpenStreetMap: **Traffic light**, **Stop sign**, **Level crossing**, **Give way**, or **Traffic / other** when nothing like that is within
  35 m (a queue, a jam). A wait right after pressing Start or right before Stop is not counted (getting going / parking).
- **Replay.** Press play: the bike moves along the route (1x, 4x, 10x or 30x real time), the part already ridden is drawn in colour behind it, a display
  over the map shows speed, time and distance, and the camera follows the bike (switch **Follow the bike** off to pan and zoom yourself; **Done** leaves the replay).
  Waits at lights are shown at the same speed as everything else, so a 1-minute red takes 6 seconds at 10x.

Where the stop information comes from: the **server** asks the public OpenStreetMap Overpass API for map tiles of about 4 x 5.5 km around the places you
stopped and keeps them for 60 days, so a tile is fetched once. Your phone never contacts it, and only those coarse tile corners leave your server.
If Overpass is busy or down, the stops show as plain "Stop" and a note says so; pull down to try again. Signals not mapped in OSM show as "Traffic / other",
and a queue that passes a signal you did not wait for can be mislabelled, so treat the labels as a good guess, not a record. Map data (c) OpenStreetMap
contributors, shown under the stops. Server settings: `OSM_ENABLED`, `OSM_USER_AGENT` (put a contact email in it, the public servers ask for that),
`OVERPASS_URLS` (see `.env.example`).

## Traffic tab: is the road clear?

A map of your surroundings with three layers you can switch on and off (the chips at the top):

- **Traffic** (always available): Apple Maps' live road colours (green flowing, orange slow, red jammed). It is MapKit's built-in layer, so it needs no key,
  no account and no server setup; Apple lists traffic as available in Switzerland.
- **Incidents** (needs a free key): jams, accidents and hazards from the official Swiss traffic situations feed (ASTRA, opentransportdata.swiss). The feed
  holds about 3,000 records, mostly long-running roadworks and lane closures, plus "released" notices for things that already ended. By default the map shows
  only **jams, accidents and hazards** that are valid right now (there can well be none: on the day this was built, 2 jams and 2 accidents in all of
  Switzerland); the **Works** chip adds roadworks and closures (about 1,700, titled from the feed: "Road closed", "Narrow lanes", ...). Tap a pin for the
  description and how long it lasts. Most records come with only AlertC location codes, which the server turns into map positions with Switzerland's TMC
  location tables (three small open-data files, downloaded once into the data folder on first use, about 4 MB, never committed to git).
- **Webcams** (needs a free key): public webcams near the map from the Windy Webcams API, as a snapshot with a link to the live view. Two kinds are asked for:
  *traffic* cameras and *city* cameras. **Expect few real traffic cameras**: checked against the live API on the day this was built, Windy has none in the
  "traffic" category within 25 km of Zurich centre (2 within 50 km), but 8 city cameras within 25 km (the Stadthaus, Sechselaeutenplatz, ...). A city
  camera may or may not show a road, and the sheet says which kind it is. ASTRA switched its public Zurich motorway cameras off in 2020 (data protection).
  Windy's free service only allows linking to its own player and its picture links expire after 15 minutes, so a picture is a snapshot, several minutes old.

A layer without a key shows a padlock; tapping it says what to add. Keys live **on your server only** (never in the app):

1. Incidents: register at <https://api-manager.opentransportdata.swiss>, subscribe to *Traffic situations*, copy the key into `.env` as `OPENTRANSPORTDATA_API_KEY=...`.
2. Webcams: get a key at <https://api.windy.com/keys>, put it in `.env` as `WINDY_API_KEY=...`.
3. `sudo systemctl restart ride-logger`, then check both sources once with `cd ~/ride-logger && .venv/bin/python -m app.cli check-traffic`.

**What has and has not been checked against the live services.** Incidents: the request format was found by trying it with a real key and the parser was
built and run against a real capture of the feed (3,157 records, 0.6 s to read, every code that was needed resolved to a position). What is still unverified
is the app side on a phone. `python -m app.cli check-traffic` calls each
source once and prints what came back (with the raw start of the answer if nothing could be read): if a layer fails, send that output to Claude Code. Webcams were run against the live API with a real key on 2026-10-02 (the key is accepted and the answers parse); what has not been tried yet is how they look on a phone.

The feed's limits are 5 calls per minute; the server fetches it at most once every 5 minutes and shares the answer with everyone.

Overview (totals, records, weekly chart) moved from its own tab to a row on the Home screen to keep the tab bar at five.

## Hands-free start (helmet Bluetooth, Siri, Action button)

**What iOS allows.** An app cannot be launched because a classic Bluetooth device (a helmet intercom) connected, and Core Bluetooth cannot see such
connections. What iOS does offer is **Shortcuts automations**: *When [helmet] is connected, run an action.* RideLog provides the actions *Start ride*
and *Stop ride* (they also work with Siri: "Start a ride in RideLog", and on the Action button via *Settings > Action Button > Shortcut*).

**Set it up (once).**
1. RideLog > Settings > Auto-start: tap *Allow notifications* (the safety net, see below). Make sure location is allowed.
2. Pair the helmet with the phone as usual. Then Shortcuts > Automation > + > **Bluetooth** > choose your helmet > **Is Connected** > *Run Immediately* >
   Next > *Add Action* > RideLog > **Start ride** > Done. Optionally a second automation with **Is Disconnected** and **Stop ride**.
3. iOS 18.2 had a bug where "Run Immediately" asked for confirmation anyway; if yours does, update iOS or accept the prompt.

**What happens, and the part nobody can promise.** The automation runs *Start ride* even with the phone locked. RideLog starts recording and, at the same
moment, schedules a notification for 25 seconds later ("Recording did not start by itself. Tap to start."). The first GPS fix cancels it. iOS may stop a
location session that was started inside a shortcut when the shortcut ends: if that happens no fix arrives, the notification shows up on the locked
screen, and one tap starts the ride. Whether the silent start works on your phone is **only known by trying**: the diary in Settings > Auto-start records
every attempt (time, trigger, what happened, the audio devices iOS reported) so a failure can be fixed instead of guessed at.

**Start by itself without the Shortcuts automation (optional).** Settings > Auto-start > *Notice when I start riding* (needs location set to **Always**). iOS wakes
RideLog on a significant movement, the motion sensor must say "vehicle" (or be unavailable), the GPS is watched for at most two minutes, and a ride at
15 km/h or more for 20 seconds is started, or offered in a notification, as you choose. With *Only when my helmet is connected* on, a tram or a car does not
start a ride; this depends on iOS reporting your helmet as an audio device, which a classic Bluetooth helmet often does only while audio plays to it (the
*Look for connected audio devices* button shows what iOS reports; if your helmet never appears, switch the option off).
A ride that started by itself ends by itself after 10 minutes without moving; you get a notification.

**Test protocol for your next ride** (please report the diary, not just "it worked"):
1. Phone locked in the bag, helmet off. Switch the helmet on: wait 30 s. Open Settings > Auto-start > What happened: is there a *started* and a *first location fix* line?
   If instead a notification arrived, tell me; the entry shows what iOS did.
2. Ride a few minutes, stop, park for 10+ minutes: did the ride end by itself?
3. Optionally turn the helmet off and ride to test the motion fallback (needs Always).

## Garage: odometer, service, fuel, costs

Home > *Garage*. Add your bike with the odometer reading it has today; from then on **every ride you record adds to it by itself** (rides count for your
default bike; on the ride screen, with more than one bike, the wrench menu puts a ride on another one). Changing the default bike does not move your history to
the new one. *Set odometer* corrects the reading at any time.

- **Service:** add what you want to track (oil, chain, tyres, brake fluid, the yearly inspection) with a distance, a time or both ("every 6000 km or 12
  months"): it is due at **whichever comes first**. "Due soon" starts 30 days ahead, or 500 km (or a tenth of the interval, if smaller) ahead. Say when it was
  last done, or start counting from today, then press *Done* each time you do it (date, odometer, cost, note).
- **Fuel:** enter each fill-up (odometer, litres, price, whether you filled to the top). Consumption is worked out the standard way, **between two full tanks**
  (part fills in between add their litres but do not end the interval); the first full tank is only the starting point. You need two to see a number.
- **Costs:** fuel, services and other expenses (tyres, insurance, ...) add up, with a cost per kilometre ridden in RideLog.
- **Reminders:** when you open the app and something is overdue or due soon, one notification is scheduled for the next evening at 17:00 (not more than every
  3 days, only with notification permission, nothing while nothing is due). The phone cannot count kilometres while the app is closed, so the reminder
  is only as current as your last visit.
- It is all stored on your server (your account only) and included nowhere else. Deleting a bike deletes its service, fuel and cost records; your rides stay.

## Ride insights: weather, speed against the limit, lean, elevation, smoothness

Open a ride and scroll under the speed chart (needs the server restarted on this version, and Valhalla running for the limits, see below). The panels load after the
map, so a slow service never delays the ride; each one says in words when its part is not available.

- **Weather:** temperature, rain, wind and gusts for the hours of the ride, from [Open-Meteo](https://open-meteo.com) (free, no key, CC BY 4.0, shown on the
  panel). It is the weather for the area where the ride started, not measured on your bike. Only the start position, rounded to about 10 km, is sent. Switch off
  with `WEATHER_ENABLED=false` in `.env`.
- **Speed against the limit:** the server snaps your track to roads with its own **Valhalla** map-matching service (Switzerland, runs in Docker on the server,
  reachable only from the server itself) and compares your GPS speed with the `maxspeed` written on each road in OpenStreetMap. The panel shows the time and
  distance over, the worst moment, and each stretch (tap one to jump there); stretches are drawn with a **pink glow** on the map. Things to keep in mind:
  - Only roads **with a limit on the map** count in the numbers. Where OpenStreetMap has none, the Swiss default for that road type is assumed and reported on its own
    line, as a guess (in a town an 80 default can be wrong, so a real speeding stretch can be missed there, never invented).
  - Map limits can be missing or out of date, GPS speed is good to a few km/h, and **no legal tolerance is applied**. It is raw difference for you, not a ticket.
  - Settings > Ride insights hides it in the app. The server still works it out (it is also what gives stops their road names).
- **Road names:** stops and the "At this point" card say which road you were on.
- **Elevation:** altitude along the ride (smoothed), climbed and descended, highest point. Drag over the chart to move the dot on the map. The phone's GPS altitude is
  a few metres off; the figures are chosen so flat roads read as flat.
- **Lean and G-force (estimated from GPS):** your lean angle in corners, the sideways and forward G, and your corners ranked by lean (tap one to jump there; the
  steepest has a badge on the map). It is **worked out, not measured**: a bike at speed *v* turning at yaw rate *w* pulls sideways with *v x w* and leans until
  tan(lean) = that / g. Heading comes from the phone's GPS course, which the app now sends with every fix (rides recorded before 1.10, and Overland rides, fall
  back to the direction between GPS positions: less exact, and the shortest corners can be missed). Measured on synthetic rides with realistic GPS error: with
  the course a corner is found every time and its lean is within about 3 degrees; from positions a tight 5-second corner is missed about one time in four and
  reads about 3 degrees low; a straight road never produces a corner. The real lean differs from this: it ignores tyre profile and how far you hang off the bike,
  assumes a steady corner, and GPS once a second cannot see a flick. Only spells over 12 degrees for 2 to 3 seconds count as corners, and nothing under 22 km/h
  is analysed. Use it to compare corners and rides with each other, not as a number to trust to the degree.
- **Smoothness:** hard braking and hard acceleration from the speed once a second, a 0 to 100 score, and markers on the map for hard braking. GPS at 1 Hz misses the
  sharpest peaks, so it is for comparing your own rides, not a measurement of g.

**Server setup for the limits (once):** `cd deploy/valhalla && docker compose up -d` (the first start downloads the map and builds tiles, 15 to 40 minutes), then
`python -m app.cli check-valhalla` (checks Valhalla and Open-Meteo, shows the road under a test point and the weather). `deploy/valhalla/refresh.sh` (and the systemd
timer next to it) rebuild with a newer map. If Valhalla is down, rides still open; the limits panel says so. Results are cached per ride in the database
(`ride_extras`); a ride that gets more points is looked up again.

## Roads: twisty roads you have not ridden yet

Traffic tab > the **Roads** chip. The map shows the twisty stretches of road in view (primary, secondary, tertiary and unclassified roads, 0.4 to 1.5 km each,
no motorways, tunnels, private or unpaved roads) in violet, a badge with each one's twistiness score. **New** (next to the chip) hides what you have already ridden.
Ridden stretches are faded with a tick; tap a badge for the details (score, length, how much of it is bendy, class, surface, the limit on the map, and a link
to Apple Maps).

- **Twistiness** is worked out from the shape of the road only (app/curvature.py): the road is sampled every 30 m, the radius of the bend at each sample is
  measured, and tight and medium bends count towards the score while gentle sweepers count a little and anything over 400 m radius not at all. 0 is a straight
  road and 100 is bend after bend. The list is ordered by how much *bendy road* there is, so a 1.5 km pass comes before a 300 m piece with one hairpin. Checked
  against the real Swiss map: the Klausen, Susten, Julier and Gotthard roads come out at 60 to 90, central Zurich at 25 to 45. It knows nothing about surface
  condition, traffic, cameras or winter closures, and OpenStreetMap has to hold the bends finely enough (a bend drawn with a point every 40 m is read as a polygon).
- **Ridden** comes from your own rides: each ride is matched to roads by the same Valhalla service as the speed limits, and a stretch counts as ridden when at
  least half of it has a point of one of your rides within 40 m on the same OpenStreetMap road. Rides you have never opened are matched in the background the
  first time you open the layer ("working out which you have ridden..."; a few seconds), and every new ride is matched when you open it. Nobody else's rides count.
  Without Valhalla the roads still show, just without ridden / not ridden.
- **Server setup (once):** `.venv/bin/pip install osmium`, then
  `.venv/bin/python -m app.cli build-roads --pbf /home/skysurfer1508/valhalla-data/switzerland-latest.osm.pbf` (about a minute, reads the same map file Valhalla
  uses and writes `data/roads.db`, 25 MB; it is built beside the old file and swapped in at the end). `deploy/valhalla/refresh.sh` rebuilds it with the monthly
  map. `python -m app.cli match-rides` works out the roads of every ride right away instead of waiting for the app. Without the file the layer says it has not
  been built. Restart the server after pulling this version (new endpoint).
- Not here yet: roads outside Switzerland.

## Apple Watch: glance and start / stop from the wrist

The Watch app is a **remote control and a display**: the iPhone stays the only recorder (GPS on the wrist would empty a Watch battery in a couple of hours), and
the Watch shows what the phone sends.

- **During a ride:** big speed, distance, a running timer and a Stop button (it asks to confirm). The phone sends the numbers once a second. If the phone goes quiet
  (app killed, out of range) the Watch says "Waiting for iPhone..." and shows dashes instead of a frozen speed. A tap on the wrist when the ride starts and stops.
- **Idle:** a Start button, kilometres this week and the last ride.
- **Start from the wrist, with the phone locked in a bag:** the Watch asks the phone app to start. WatchConnectivity can wake the phone app in the background
  when the Watch app is open, and the app then starts exactly as it does for the helmet Shortcut (same safety net: if the phone cannot start location from the
  background you get the "tap to start" notification, and the Auto-start log in Settings records "watch" with what happened). Whether the background start
  works with the phone locked is the same open question as for the helmet automation: it is proven only on your phone, so test it (below).
- **Complication:** kilometres this week (circular, corner, inline) and last ride too (rectangular). Add it from the watch face editor.
- **watchOS 11 and later also mirror the Lock Screen Live Activity** (speed and distance) to the Smart Stack by themselves, with nothing to set up: that is the
  quickest way to a glanceable speed and does not need the Watch app at all.
- What it does **not** do: record on its own, haptic turn-by-turn, heart rate or a workout session (adding a workout session would keep the Watch screen from
  sleeping, and needs the HealthKit capability: left out so signing stays simple). The Watch's screen returns to the watch face after a while: iPhone Watch app > General > Return to Clock >
  RideLog > "Return to App" for the longest time keeps it up while riding. The motion-sensor lean angle for a fixed mount was an optional experiment and is not built:
  the GPS estimate (Lean and G-force) is the lean angle for now.

**Installing it (once).** The iPhone app does not include the Watch app, on purpose: a problem in the Watch code cannot stop the iPhone app from building. So:
1. `cd ios && xcodegen generate` (as always after a pull), open the project, and first run the **RideLog** scheme on the iPhone as usual.
2. In Xcode choose the scheme **RideLogWatch** and, as the run destination, your paired Apple Watch (it appears under the iPhone). Press Run: Xcode puts the app on the
   watch (the first time takes a while and asks for the watch passcode). Developer Mode must be on for the watch (Watch > Settings > Privacy & Security).
3. Open RideLog on the Watch; it connects to the phone by itself. If Xcode complains about signing, set your team on the RideLogWatch and RideLogWatchWidgets targets
   (Signing.local.xcconfig covers it the same way as for the iPhone targets). The complication shares data with the Watch app through the App Group
   `group.com.skyserver1508.ridelogger.watch`; if your Apple ID cannot create it, the complication shows dashes and everything else still works.
4. If the Watch build ever fails and you just want it gone, see the comment above the RideLogWatch block in `ios/project.yml`.

## Plan a ride: where to, in four styles, loops through twisty roads, follow on the Record tab

Traffic tab > **Plan** (top left). Two tabs: **Trip** (A to B, like Maps) and **Loop**.

- **Trip:** *From* is where you are by default (tap to type another address), *To* is the finish; *Add stop* puts up to five stops in between (tap a stop to change it, the cross removes it,
  *Swap* turns the trip round). Addresses and places are found by **Apple Maps' own search** as you type (no key, nothing on your server): a street and number, a town, a shop, a pass;
  or *Choose on the map* to drop a pin. Recent places are kept on the phone; press and hold a place to save it as **Home** or **Work**, which then sit at the top of the list.
- **Four styles** (chosen with the chips, measured on real Swiss trips, Zurich to Chur: 84, 106 and 182 minutes):
  **Ultra fast** motorways and main roads, the quickest way; **Fast** quick, with a motorway only where it saves a lot; **Relaxed** no motorways and about a quarter fewer turns, a bit longer;
  **Twisty** no motorways, steered through twisty stretches of the Roads layer between your start and finish, within the extra time you allow with the slider (+5 min to +2 h).
  On the test trips Twisty found 26, 21 and 19 km of twisty road against 16, 10 and 6 for Relaxed, always inside the time allowed. With stops in between, or without the road database, Twisty
  is the Relaxed route and says so. *Ultra fast / Fast* also show up to two alternative ways.
- **Loop:** as before (a length, from where you are or from an address, avoid motorways, paved only, prefer roads you have not ridden).
- **Results:** up to three routes on a map with distance, time, twisty km and a score; pick one. **Follow** puts it on the Traffic and Record maps in blue with distance along and off the route;
  **Save** keeps it on your server together with the stops and the style that make it (so it can be ridden again with directions); **GPX** saves and opens the share sheet.
- Every route now comes with its **turns** (the server asks Valhalla for directions, in English) and a full-resolution line; the voice guidance that uses them is the next release.
- Needs Valhalla running (see the limits section); the road database is only needed for Twisty and loops through twisty roads. If the routing service is busy or down the sheet says so.

## GPX export and import

- **Export:** open a ride and tap the share icon (top right). The file contains every stored point with time, elevation and speed, so Strava, Komoot, Apple
  Files or a mail attachment can take it. It is also a backup of that ride.
- **Import:** Settings > Your data > *Import a ride from a GPX file*. Files from other apps work (a speed is worked out from the positions when the file has
  none); a file with several tracks makes several rides. It is safe to repeat: the same file, or a ride whose moments are already stored (for example
  your own export), is recognised and not added twice. Refused with a plain message: files without timestamps, tracks that do not move, files over 15 MB,
  and files containing DOCTYPE/ENTITY declarations. Imported rides are marked in the database with the device name `gpx-import`.
- Rides recorded by Overland before RideLog are already in the same database, so they need no import.

## The automatic compile check (GitHub Actions)

Every push that changes something under `ios/` makes GitHub build the app and run the unit tests on a Mac in the cloud (`.github/workflows/ios.yml`).
You will see a green tick or a red cross next to the commit on GitHub; on a red one open it, then *Summary*, and paste the compiler errors listed there to
Claude Code. This catches Swift mistakes before they reach your phone. Things to know:
- **Cost:** macOS minutes count ten times against a private repository's free allowance (2,000 minutes a month is about 200 minutes of Mac time). A run takes
  roughly 10-15 minutes, so keep an eye on *Settings > Billing > Actions* at first. Put `[skip ci]` in a commit message to skip a run, and a newer push cancels
  an older run that is still going.
- It only checks that everything compiles and the unit tests pass. It cannot test GPS, the screen-locked behaviour, Bluetooth or the Watch: those still need your phone.
- You can also start it by hand: GitHub > Actions > *iOS build and tests* > *Run workflow*.

## Deleting rides

Rides > swipe a ride to the left > **Delete**, or open a ride and tap the trash icon. Both ask first. Deleting removes the ride **and its GPS points** from
your server (`DELETE /api/v1/rides/{id}`), it can't be undone, and only your own rides can be deleted. If the ride was recorded on this phone, a backup copy of
the newest few stays in Settings > Recording > Rides on this phone until you remove it there. The website has no delete button; this is app-only.

## Switching off Overland

Overland and RideLog upload to the same place, so they can run side by side. Once a couple of RideLog rides look right on the website
(distance, top speed, route), turn off Overland's tracking. Don't run both while riding: you would get two overlapping recordings of the same ride.

## Checklist to try on the phone

**Viewer**
1. Sign in opens the system sheet, Authentik works, you land signed in. Force-quit and reopen: still signed in.
2. Home, Rides (with filters, paging), a ride's map, Overview (weekly chart, records, heatmap) show your existing data.
3. Airplane mode + reopen: screens show what was saved, with a note.
4. Settings: the Overland URL/token copy buttons work; Regenerate asks first; Sign out asks first.

**Recorder** (do these in order, ideally with a short walk or drive first)
1. Record tab: "Allow location" > While Using the App. Start. The speed, distance, timer and GPS chip update; the map follows you.
2. Lock the phone and go for 10+ minutes. The blue pill or status-bar location arrow stays. Unlock: the route has no gaps.
3. Switch to another app for a minute and back: still recording.
4. Turn on airplane mode for a few minutes mid-ride, then off: "points waiting" goes back to 0 by itself.
5. Stop > Finish. Open the website: the ride is there, and its distance is close to the one on the phone (a few metres apart is normal).
6. Start a ride, force-quit the app, reopen: "A ride was cut off" offers Resume / Finish.
7. Start and stop within a few seconds: it is discarded, and no ride appears.
8. Settings > Recording > Rides on this phone lists the ride as "Uploaded".
9. Battery: note the battery % before and after an hour of riding with the screen locked, and tell Claude what you see.

**Live Activity**
1. Start a ride and lock the phone: the banner appears on the Lock Screen with speed, distance, timer and top speed, and the speed changes as you move.
2. Go to the Home Screen or another app: on an iPhone with a Dynamic Island the speed shows on the left of the pill and the distance on the right. Long-press
   it for the expanded view. Stand still for a few seconds: the speed goes to 0.
3. Stop the ride: the banner and the pill disappear.
4. Start a ride, force-quit the app: the banner goes to dashes after about 20 seconds; opening the app removes it.
5. iPhone Settings > RideLog > Live Activities off: recording still works, and Settings > Recording says why there is no banner.

**Ride screen (needs the server restarted on the new version first)**
1. Open a ride: the route is coloured by speed, with a legend. A ride from before you used the app (Overland) works too.
2. Tap the route in a few places: the dot and the card show that spot's speed. Do the corners look slower, the straights faster? Is the top-speed pin near
   where you remember it, and does its number equal "Max speed" in the stats?
3. Drag the slider and drag over the speed chart: the dot follows on the map. Tap "Top speed", "Start", "End".
4. Stops: is every red light you remember there, with roughly the right wait? Are lights labelled "Traffic light" and queues "Traffic / other"?
   Tap a stop: the map jumps to it. Is a stop missing or invented, or a label wrong? Note where and tell Claude.
5. Replay: Play at 10x, then 1x and 30x; pause; drag the slider while it plays; turn Follow off and pan; Done. Leave the screen while playing: it stops.
6. Airplane mode: a ride you opened before still opens (the stop labels as last seen).

**Apple Watch**
1. Open RideLog on the Watch with the phone nearby: the idle screen shows Start, "km this week" and the last ride (the numbers refresh when you open the phone app).
2. Start from the wrist with the phone **in the app**: it starts recording, the Watch ticks, and shows speed, distance and the timer within a couple of seconds.
3. The real test: phone **locked** in the bag, app closed. Start from the wrist. Did the phone start recording (blue indicator, Live Activity)? If not, did the
   "tap to start" notification appear? Open Settings > Auto-start log and look for "watch": it says what happened. Tell Claude what you see.
4. During a ride: is the speed on the wrist within a second or two of the phone? Walk away from the phone: "Waiting for iPhone..." should appear after about 12 seconds.
5. Stop from the wrist: it asks, then the ride finishes and uploads. Add the complication to a watch face: it shows this week's km.

**Trip planner**
1. Traffic > Plan > Trip: From says "My location". Tap To, type a street and number you know: suggestions appear as you type; pick one. Does it find your address? Try a town, a pass, a shop.
2. Press and hold a suggestion or recent place > Save as Home. Next time Home is at the top.
3. Find routes with each of the four styles on the same trip: do they really differ (Ultra fast on the motorway, Relaxed on small roads, Twisty with more bends)? Does Twisty respect the extra time you allowed?
4. Add a stop; swap; remove a stop. Choose on the map: drop a pin in a field, it is named from the address.

**Planner**
1. Traffic tab, pan to your street, Plan > Loop 80 km > Find loops: after a few seconds up to three loops appear on the little map and in the list, each starting and
   ending at your street. Are the lengths right? Do they use roads you would actually ride, or does one send you somewhere silly (motorway, farm track, closed pass)?
   Tell Claude what is wrong and where.
2. Tap another option: the bold blue line changes. Save one, then GPX: the share sheet opens; send it to yourself and open it in another app.
3. Follow: open the Record tab: "Route ready". Start a short ride along the first kilometres: the card should say On the route, the km count goes up, and if you take a
   different street it says Off the route by some metres and recovers when you rejoin. Check the blue line on the map is where the road is.
4. A to B: tap a place 30 km away: a route comes back; Follow works the same.

**Roads**
1. Traffic tab > Roads: violet stretches with score badges appear near you (zoom in until the status line stops saying "zoom in"). Do the roads you know to be
   twisty show up, and are they among the best? Is a road you think is fun missing, or a boring one scored high? Tell Claude the road and where.
2. A few seconds after the first look the status line should say how many are "not ridden yet": are roads you rode recently faded with a tick? Tap **New**: only
   the ones you have not ridden stay.
3. Tap a badge: the sheet shows the details; "Show in Apple Maps" opens the middle of the road.

**Ride insights**
1. Open a ride: after a moment a weather panel appears (right day, right place? temperatures believable?). Airplane mode: the ride still opens, the panels explain why they are empty.
2. Speed against the limit: are the stretches you remember going fast pink on the map, with the right limit in the list? Is a stretch listed where you were not over (or a 50 zone shown that was really 30)?
   Tell Claude the road and what the sign said. Settings > Ride insights off: the pink and the panel go away.
3. Tap a stretch, a braking row, and the elevation chart: the dot and the map move there. Do the stops now show the road ("at 3.2 km · 14:03 · Hardstrasse")?
4. Lean: after a ride with corners (it needs this version of the app on the phone, and a new ride), does the "Lean and G-force" panel show corners where you remember
   them, left and right the right way round? Is the lean plausible (a brisk road corner is roughly 20 to 35 degrees; a parking-lot turn should show nothing)? Does the
   chart go up for right and down for left? Old rides say "from your GPS positions" and read lower: that is expected. Tell Claude if the numbers look wrong.
5. Is the climbed metres figure close to what you expect for the route (compare with Komoot or the like)? Does a flat ride read as flat?

**Traffic tab**
1. Open it: iOS asks to use your location; the map opens around you (or Zurich centre). Road colours show; pan and zoom, the chips and counts follow.
2. Without keys: Incidents and Webcams show a padlock, tapping explains what to add. With keys (see above): pins appear; tap one for its sheet. Tap **Works** to add roadworks and closures (many pins), and tap again to hide them.
3. Is an incident you can see out of the window really on the map? Does a webcam picture load, and "Open the live view" open Windy?
4. Switch layers off and on; refresh button; airplane mode shows a readable message instead of a crash.
5. Home > "Totals, records and weekly distance" opens the overview; tapping a record opens that ride.

**Deleting**
1. Rides: swipe a ride left, tap Delete, confirm. It disappears, and Home and Overview totals drop by that ride (the website too).
2. Open a ride, tap the trash icon, confirm: you land back on the list without it.
3. Record a short ride, wait for it to upload, and see that it shows up under Rides, Home and Overview without pulling to refresh.

## Not in the app (yet)

A home-screen widget, turn-by-turn navigation, a Watch-only recorder, heart rate, a Stop button on the Lock Screen banner, deleting from the website, naming rides,
real-time traffic-camera images (none are openly published for Zurich). Next rounds, once
Start/Stop is proven on the road.
