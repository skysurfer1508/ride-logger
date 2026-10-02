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

Automatic start and stop (next), a home-screen widget, Apple Watch, a Stop button on the Lock Screen banner, deleting from the website, naming rides,
real-time traffic-camera images (none are openly published for Zurich). Next rounds, once
Start/Stop is proven on the road.
