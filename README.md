# Take My Med

A calm, modern medication reminder for iOS, Android, and web. Create recurring or date-specific schedules, receive time-sensitive alerts, and keep an editable history of every taken dose.

## Highlights
- Alarm-style, high-priority reminders
- Weekly recurring and specific-date schedules
- Daily check-in and historical tracking calendar
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
