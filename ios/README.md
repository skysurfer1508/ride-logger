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

## Live speed on the Lock Screen and in the Dynamic Island

While a ride is recording, RideLog shows a Live Activity: on the **Lock Screen** a banner with the speed, distance, a running timer and your top
speed, and on iPhones with a **Dynamic Island** the speed and distance in the pill (tap or long-press it for the expanded view with the timer and top
speed). The timer is drawn by iOS itself; speed and distance are refreshed every few seconds. If the app stops updating (it crashed or was killed) the
banner shows dashes instead of a frozen speed, and it is removed the next time you open the app. Ending the ride removes it.

It needs Live Activities to be on (iPhone Settings > RideLog > Live Activities; Settings > Recording in the app says whether they are). Recording works
exactly the same without it. It runs in its own extension target (`RideLogWidgets`); if that target ever breaks the build, `project.yml` says what to delete.

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

**Deleting**
1. Rides: swipe a ride left, tap Delete, confirm. It disappears, and Home and Overview totals drop by that ride (the website too).
2. Open a ride, tap the trash icon, confirm: you land back on the list without it.
3. Record a short ride, wait for it to upload, and see that it shows up under Rides, Home and Overview without pulling to refresh.

## Not in the app (yet)

Automatic start and stop, a home-screen widget, Apple Watch, a Stop button on the Lock Screen banner, deleting from the website. Next rounds, once
Start/Stop is proven on the road.
