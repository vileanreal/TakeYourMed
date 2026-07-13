# Take Your Med — Product & Engineering Context

Take Your Med is a clean, modern, single-page medication reminder app for iOS, Android, and web. Its visual identity uses reddish pink `#E84A67` and light violet `#8B7CF6`, with layered pastel gradients and a compact day/night control in the upper right.

## Required experience
- Show a welcome dialog on first launch.
- Add, edit, finish, restore, and delete medications.
- Support a name, optional instructions, multiple daily times, weekly recurring days, or multiple specific dates selected in one calendar.
- Track each scheduled dose independently by date and time.
- Schedule high-priority local alerts; use exact full-screen alarm notifications on Android and time-sensitive notifications on iOS where allowed. Keep the Android scheduled, boot, and action receivers configured.
- Provide Taken and 10-minute Snooze notification actions and buttons, visible permission status, and an immediate test-alert control. Notification actions must run in the background without foregrounding the app. Resolving the full-screen Android alarm must dismiss its host activity instead of revealing the home page. Do not use swipe gestures on the alarm screen.
- Keep snoozed reminders separate from the base schedule so routine refreshes cannot erase them. Clear the matching snooze when a dose is marked Taken or its time is removed, and clear every alarm when a medication is finished or deleted.
- Bundle `res/raw/medicine_alarm.wav`, generate it reproducibly with `tool/generate_alarm_sound.dart`, and use it through a versioned Android alarm channel with `AudioAttributesUsage.alarm`. Never reschedule base alarms before handling a cold-start notification response because cancelling its recurring request also silences the currently ringing notification.
- Alarm behavior is globally configurable: duration defaults to one minute, sound and vibration can be toggled independently, and automatic full-screen display can be enabled or disabled.
- Every Android alarm must have a hard `timeoutAfter` limit and active notifications must be cancelled as soon as Taken or Snooze resolves them so sound and vibration cannot continue indefinitely. Do not cancel merely because a full-screen intent cold-started the app.
- Keep the only main page focused on today's checklist and progress.
- Let users mark today directly and edit any past taken date through the history calendar.
- Persist everything locally with SharedPreferences. Store background Taken events independently so they merge safely on the next read, record resolved alarm actions for open full-screen alerts, and reload medication state only when the background-action revision changes.

## Engineering
- Flutter/Dart and Material 3. Supported folders are `android`, `ios`, and `web`.
- Keep secondary workflows in sheets/dialogs, not tabs.
- Notification logic is in `Alerts` in `lib/main.dart`.
- Before release run `flutter analyze`, `flutter test`, `flutter build web --release`, and `flutter build apk --release`.

Notification delivery remains subject to user permissions and OS policies. iOS does not permit third-party apps to fully reproduce the native incoming-call lock screen.
