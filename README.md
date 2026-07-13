# Take Your Med

A calm, modern medication reminder for iOS, Android, and web. Create recurring or date-specific schedules, receive time-sensitive alerts, and keep an editable history of every taken dose.

## Highlights
- Alarm-style, high-priority reminders with notification-shade Taken and 10-minute Snooze actions that do not bring the app forward
- Configurable 30-second to 5-minute alert limit (1 minute by default)
- Independent sound, vibration, and automatic full-screen alert controls
- Several independently tracked reminder times per medication
- Weekly recurring schedules and one-calendar multi-date selection
- Per-dose daily check-in and historical tracking calendar
- In-app permission status and immediate test-alert control
- Edit, finish, restore, and delete medication plans
- Rose/violet light and dark experiences
- Local-first storage; no account required

## Run and validate
```bash
flutter pub get
flutter run
flutter analyze
flutter test
flutter build apk --release
flutter build web --release
```

Notification behavior varies by platform. Android supports exact full-screen alarm notifications after permission is granted. Notification-shade and lock-screen actions run in the background. Resolving a full-screen alarm that interrupted another app returns to that app or the lock screen; if Take Your Med was already open, it returns to the dashboard. iOS provides time-sensitive notifications subject to system settings and policy.
