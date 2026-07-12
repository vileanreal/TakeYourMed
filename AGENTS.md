# Take Your Med — Product & Engineering Context

Take Your Med is a clean, modern, single-page medication reminder app for iOS, Android, and web. Its visual identity uses reddish pink `#E84A67` and light violet `#8B7CF6`, with layered pastel gradients and a compact day/night control in the upper right.

## Required experience
- Show a welcome dialog on first launch.
- Add, edit, finish, restore, and delete medications.
- Support a name, optional instructions, time, weekly recurring days, or specific dates.
- Schedule high-priority local alerts; use exact full-screen alarm notifications on Android and time-sensitive notifications on iOS where allowed.
- Keep the only main page focused on today's checklist and progress.
- Let users mark today directly and edit any past taken date through the history calendar.
- Persist everything locally with SharedPreferences.

## Engineering
- Flutter/Dart and Material 3. Supported folders are `android`, `ios`, and `web`.
- Keep secondary workflows in sheets/dialogs, not tabs.
- Notification logic is in `Alerts` in `lib/main.dart`.
- Before release run `flutter analyze`, `flutter test`, `flutter build web --release`, and `flutter build apk --release`.

Notification delivery remains subject to user permissions and OS policies. iOS does not permit third-party apps to fully reproduce the native incoming-call lock screen.
