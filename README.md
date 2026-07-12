# Take Your Med

A calm, modern medication reminder for iOS, Android, and web. Create recurring or date-specific schedules, receive time-sensitive alerts, and keep an editable history of every taken dose.

## Highlights
- Alarm-style, high-priority reminders with Taken and 10-minute Snooze actions
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

Notification behavior varies by platform. Android supports exact full-screen alarm notifications after permission is granted. iOS provides time-sensitive notifications subject to system settings and policy.
