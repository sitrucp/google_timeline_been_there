# google_timeline_been_there

Google Timeline Been There

Android app to check if you have been at a location before.

## What It Does

- Imports your Google Timeline JSON export into a local SQLite database on device.
- Lets you search by address or latitude/longitude.
- Shows historical movement traces and visit points on a map.
- Keeps data local on device after import.

## Privacy Notes

- Timeline export files contain highly sensitive personal location history.
- Do not commit timeline JSON files to source control.
- This repository is configured to ignore timeline export JSON files.

## Requirements

- Flutter SDK (stable)
- Android device or emulator
- Android USB debugging enabled (for physical device)

## How To Export Timeline Data From Google Maps

Use the Google Maps mobile app Timeline export flow:

1. Open Google Maps on your phone.
2. Open Timeline.
3. Use the export option to export Timeline data as a JSON file.
4. Save the exported file locally on your phone (for example in Download).
5. Use that exported JSON file directly in this app.

## Timeline JSON Location

- If you exported from Google Maps on the same phone, the file is already local and ready to import.
- If you exported on another device, copy the JSON file to this Android phone first (for example into Download).

## Run The App

1. Install dependencies:
	flutter pub get
2. Run on Android:
	flutter run -d <device_id>

## Import Timeline JSON In The App

1. Launch the app on Android.
2. Open the menu in the app bar.
3. Tap Import timeline.json.
4. Pick the exported Timeline JSON file from local storage.
5. Wait for import completion status.

## Basic Usage

- Enter an address and tap Go to center and inspect history.
- Or enter coordinates as lat,lon and tap Go.
- Use Refresh to reload map data for current viewport.

## Repository Safety Checklist Before Public Push

- Ensure timeline JSON files are not staged.
- Ensure no local secrets or personal exports are in git status.
- Verify .gitignore is active before first commit.
