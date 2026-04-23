# booster_app

A new Flutter project.

## Firebase Setup (Android + iOS)

This app already includes Firebase packages and app initialization in Dart.
You only need to add the Firebase platform config files from Firebase Console.

### 1. Create Firebase Apps

- In Firebase Console, create or open your project.
- Add an Android app with package name: `com.example.booster_app`
- Add an iOS app with bundle ID: `com.example.boosterApp`

### 2. Download Config Files

- Android: download `google-services.json`
- iOS: download `GoogleService-Info.plist`

### 3. Place Config Files in This Project

- Put `google-services.json` in: `android/app/`
- Put `GoogleService-Info.plist` in: `ios/Runner/`

### 4. Install Dependencies

```bash
../flutter/bin/flutter pub get
```

If building iOS on macOS, also run:

```bash
cd ios
pod install
cd ..
```

### 5. Run The App

```bash
../flutter/bin/flutter run
```

### Notes

- Android Firebase Gradle plugin is already enabled in project settings.
- Dart startup first tries native Firebase files, then falls back to `--dart-define` values.
- If you later change package name or bundle ID, regenerate Firebase config files.

### Optional: Connect Using Dart Defines

If you do not want to place Firebase config files yet, run with:

```bash
../flutter/bin/flutter run \
	--dart-define=FIREBASE_API_KEY=YOUR_API_KEY \
	--dart-define=FIREBASE_APP_ID=YOUR_APP_ID \
	--dart-define=FIREBASE_MESSAGING_SENDER_ID=YOUR_SENDER_ID \
	--dart-define=FIREBASE_PROJECT_ID=YOUR_PROJECT_ID
```

Optional extra keys:

- `FIREBASE_STORAGE_BUCKET`
- `FIREBASE_AUTH_DOMAIN`
- `FIREBASE_MEASUREMENT_ID`

### Run Against Firebase Emulators

Start emulators in the folder that contains `firebase.json`:

```bash
cd /workspaces/boosstter/booster_app
firebase emulators:start
```

Then run the app with emulator mode enabled:

```bash
cd /workspaces/boosstter/booster_app
../flutter/bin/flutter run --dart-define=USE_FIREBASE_EMULATORS=true
```

Optional for Android emulator host override:

```bash
../flutter/bin/flutter run \
	--dart-define=USE_FIREBASE_EMULATORS=true \
	--dart-define=FIREBASE_EMULATOR_HOST=10.0.2.2
```

This project-local emulator config starts:

- Auth emulator on `9099`
- Firestore emulator on `8080`
- Realtime Database emulator on `9000`

### Seed Emulator Data

With emulators running, seed test users and sample data:

```bash
cd /workspaces/boosstter/booster_app
node tools/seed_emulators.mjs
```

Seeded login accounts:

- `customer1@booster.local` / `password123`
- `driver1@booster.local` / `password123`

### Reset And Reseed Emulators

To clear all local emulator data (Auth, Firestore, Realtime Database) and reseed:

```bash
cd /workspaces/boosstter/booster_app
./tools/reset_and_seed_emulators.sh
```

### Stripe Payment Setup

The customer payment step now uses Stripe PaymentSheet with a Firebase callable
function that creates a PaymentIntent.

Install the functions dependencies:

```bash
cd /workspaces/boosstter/booster_app/functions
npm install
```

Set the Stripe secrets for Firebase Functions:

```bash
cd /workspaces/boosstter/booster_app
firebase functions:secrets:set STRIPE_SECRET_KEY
firebase functions:secrets:set STRIPE_PUBLISHABLE_KEY
```

Deploy the payment function:

```bash
cd /workspaces/boosstter/booster_app
firebase deploy --only functions
```

Notes:

- The callable function name is `createBoostPaymentSheet`.
- The default region is `northamerica-northeast1`.
- The client currently charges `CAD 25.00` for a boost request.
- The request is marked `paid` in Firestore after Stripe PaymentSheet succeeds on the client.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
