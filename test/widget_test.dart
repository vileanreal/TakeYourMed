import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:take_your_med/main.dart';

void main() {
  group('Medication model', () {
    test('migrates legacy single-time data and taken history', () {
      final med = Medication.fromJson({
        'id': 1,
        'name': 'Vitamin C',
        'hour': 8,
        'minute': 30,
        'recurring': true,
        'days': [1, 2, 3],
        'dates': <String>[],
        'taken': ['2026-07-12'],
      });

      expect(med.times, [510]);
      expect(med.isTaken('2026-07-12', 510), isTrue);
      expect(med.toJson()['schemaVersion'], 2);
    });

    test('tracks multiple daily doses independently', () {
      final med = Medication(
        id: 2,
        name: 'Antibiotic',
        times: [1200, 480, 480],
        recurring: true,
        days: [7, 1, 1],
        dates: const [],
      );

      expect(med.times, [480, 1200]);
      med.setTaken('2026-07-12', 480, true);
      expect(med.isTaken('2026-07-12', 480), isTrue);
      expect(med.isTaken('2026-07-12', 1200), isFalse);
      expect(med.takenCount('2026-07-12'), 1);
    });

    test('evaluates recurring and specific-date schedules', () {
      final monday = DateTime(2026, 7, 13);
      final recurring = Medication(
        id: 3,
        name: 'Weekly',
        times: [480],
        recurring: true,
        days: [DateTime.monday],
        dates: const [],
      );
      final specific = Medication(
        id: 4,
        name: 'Specific',
        times: [480],
        recurring: false,
        days: const [],
        dates: const ['2026-07-13', '2026-07-15'],
      );

      expect(recurring.isScheduledOn(monday), isTrue);
      expect(
        recurring.isScheduledOn(monday.add(const Duration(days: 1))),
        isFalse,
      );
      expect(specific.isScheduledOn(monday), isTrue);
      expect(
        specific.isScheduledOn(monday.add(const Duration(days: 1))),
        isFalse,
      );
    });
  });

  group('Alarm preferences', () {
    test('defaults to a one-minute sound and vibration alarm', () {
      const preferences = AlarmPreferences();
      expect(preferences.durationSeconds, 60);
      expect(preferences.durationLabel, '1 minute');
      expect(preferences.sound, isTrue);
      expect(preferences.vibrate, isTrue);
      expect(preferences.autoDisplay, isTrue);
    });

    test('persists customized alert behavior', () async {
      SharedPreferences.setMockInitialValues({});
      const custom = AlarmPreferences(
        durationSeconds: 120,
        sound: false,
        vibrate: true,
        autoDisplay: false,
      );
      await custom.save();
      final loaded = await AlarmPreferences.load();
      expect(loaded.durationSeconds, 120);
      expect(loaded.sound, isFalse);
      expect(loaded.vibrate, isTrue);
      expect(loaded.autoDisplay, isFalse);
    });

    test('notification details enforce settings and hard timeout', () {
      Alerts.instance.preferences = const AlarmPreferences(
        durationSeconds: 60,
        sound: false,
        vibrate: true,
        autoDisplay: false,
      );
      final android = Alerts.instance.details.android!;
      expect(android.timeoutAfter, 60000);
      expect(android.playSound, isFalse);
      expect(android.enableVibration, isTrue);
      expect(android.fullScreenIntent, isFalse);
      expect(android.additionalFlags, isNotNull);
      expect(android.additionalFlags, contains(4));
      Alerts.instance.preferences = const AlarmPreferences();
    });

    test('Android uses the bundled sound on a fresh alarm channel', () {
      Alerts.instance.preferences = const AlarmPreferences();
      final android = Alerts.instance.details.android!;
      final channel = Alerts.instance.androidAlarmChannel;
      final sound = android.sound;

      expect(android.channelId, 'medicine_alarms_v4_s1_v1');
      expect(android.importance, Importance.max);
      expect(android.audioAttributesUsage, AudioAttributesUsage.alarm);
      expect(android.playSound, isTrue);
      expect(sound, isA<RawResourceAndroidNotificationSound>());
      expect(sound?.sound, Alerts.alarmSoundResource);
      expect(android.additionalFlags, contains(4));
      expect(channel.id, android.channelId);
      expect(channel.importance, Importance.max);
      expect(channel.audioAttributesUsage, AudioAttributesUsage.alarm);
      expect(channel.sound?.sound, Alerts.alarmSoundResource);

      final soundFile = File('android/app/src/main/res/raw/medicine_alarm.wav');
      expect(soundFile.existsSync(), isTrue);
      expect(soundFile.lengthSync(), 2646044);
      expect(
        File('android/app/src/main/res/raw/keep.xml').readAsStringSync(),
        contains('@raw/medicine_alarm'),
      );
    });

    test('Taken and Snooze notification actions never launch the UI', () {
      final actions = Alerts.instance.details.android!.actions!;
      expect(actions.map((action) => action.id), ['taken', 'snooze']);
      expect(actions.every((action) => !action.showsUserInterface), isTrue);
      expect(actions.every((action) => action.cancelNotification), isTrue);

      final darwinActions = medicineAlarmCategories.single.actions;
      expect(darwinActions.map((action) => action.identifier), [
        'taken',
        'snooze',
      ]);
      expect(
        darwinActions.every(
          (action) => !action.options.contains(
            DarwinNotificationActionOption.foreground,
          ),
        ),
        isTrue,
      );
    });
  });

  group('Alarm payload routing', () {
    test('schedule refresh preserves snoozes for the same medicine', () {
      expect(
        shouldCancelMedicationAlarmPayload(
          'med|9|540',
          9,
          includeSnoozes: false,
        ),
        isTrue,
      );
      expect(
        shouldCancelMedicationAlarmPayload(
          'snoozed|9|540',
          9,
          includeSnoozes: false,
        ),
        isFalse,
      );
      expect(
        shouldCancelMedicationAlarmPayload(
          'snoozed|9|540',
          9,
          includeSnoozes: true,
        ),
        isTrue,
      );

      final payload = MedicationAlarmPayload.parse('med|9|540');
      expect(payload?.snoozedPayload, 'snoozed|9|540');
      expect(MedicationAlarmPayload.parse('snoozed|9|540')?.medicationId, 9);
      expect(isSnoozedMedicationDosePayload('snoozed|9|540', 9, 540), isTrue);
      expect(isSnoozedMedicationDosePayload('snoozed|9|1200', 9, 540), isFalse);
      expect(isSnoozedMedicationDosePayload('med|9|540', 9, 540), isFalse);
    });
  });

  group('Background notification actions', () {
    test('Taken persists only the matching dose without opening UI', () async {
      SharedPreferences.setMockInitialValues({});
      await saveStoredMedications([
        Medication(
          id: 7,
          name: 'Antibiotic',
          times: [480, 1200],
          recurring: true,
          days: const [DateTime.monday],
          dates: const [],
        ),
      ]);
      final events = <String>[];

      final handled = await processStoredNotificationAction(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          id: 81,
          actionId: 'taken',
          payload: 'med|7|480',
        ),
        now: DateTime(2026, 7, 13, 8),
        scheduleSnooze: (payload, sourceNotificationId) async {
          events.add('snooze');
        },
      );

      final stored = (await loadStoredMedications(refresh: true)).single;
      expect(handled, isTrue);
      expect(stored.isTaken('2026-07-13', 480), isTrue);
      expect(stored.isTaken('2026-07-13', 1200), isFalse);
      expect(events, isEmpty);
    });

    test(
      'Snooze stays untaken and schedules one same-alarm reminder',
      () async {
        SharedPreferences.setMockInitialValues({});
        await saveStoredMedications([
          Medication(
            id: 9,
            name: 'Vitamin C',
            times: [540],
            recurring: true,
            days: const [DateTime.monday],
            dates: const [],
          ),
        ]);
        final events = <String>[];

        final handled = await processStoredNotificationAction(
          const NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
            id: 42,
            actionId: 'snooze',
            payload: 'med|9|540',
          ),
          now: DateTime(2026, 7, 13, 9),
          scheduleSnooze: (payload, sourceNotificationId) async {
            events.add('snooze:$payload:$sourceNotificationId');
          },
        );

        final stored = (await loadStoredMedications(refresh: true)).single;
        expect(handled, isTrue);
        expect(stored.isTaken('2026-07-13', 540), isFalse);
        expect(events, ['snooze:med|9|540:42']);
      },
    );

    test('ignores malformed actions without scheduling anything', () async {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      final handled = await processStoredNotificationAction(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          id: 1,
          actionId: 'taken',
          payload: 'not-a-dose',
        ),
        scheduleSnooze: (_, _) async => calls++,
      );
      expect(handled, isFalse);
      expect(calls, 0);
    });

    test('handles Taken from a snoozed reminder', () async {
      SharedPreferences.setMockInitialValues({});
      await saveStoredMedications([
        Medication(
          id: 9,
          name: 'Vitamin C',
          times: [540],
          recurring: true,
          days: const [DateTime.monday],
          dates: const [],
        ),
      ]);

      final handled = await processStoredNotificationAction(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          id: 43,
          actionId: 'taken',
          payload: 'snoozed|9|540',
        ),
        now: DateTime(2026, 7, 13, 9, 10),
        scheduleSnooze: (_, _) async {},
      );

      final stored = (await loadStoredMedications(refresh: true)).single;
      expect(handled, isTrue);
      expect(stored.isTaken('2026-07-13', 540), isTrue);
    });

    test('does not mark a failed Snooze as resolved', () async {
      SharedPreferences.setMockInitialValues({});
      await saveStoredMedications([
        Medication(
          id: 9,
          name: 'Vitamin C',
          times: [540],
          recurring: true,
          days: const [DateTime.monday],
          dates: const [],
        ),
      ]);
      const response = NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        id: 44,
        actionId: 'snooze',
        payload: 'med|9|540',
      );

      await expectLater(
        processAndRecordStoredNotificationAction(
          response,
          scheduleSnooze: (_, _) =>
              Future<void>.error(StateError('Could not schedule snooze')),
        ),
        throwsStateError,
      );
      expect(await loadResolvedAlarmAction(refresh: true), isNull);
    });
  });

  test('cold-start alarm is handled without rescheduling it away', () async {
    final events = <String>[];
    const response = NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotification,
      id: 72,
      payload: 'med|9|540',
    );

    await runStartupAlarmSetup(
      initialResponse: response,
      refreshAlarmStatus: ({required bool reschedule}) async {
        events.add('refresh:$reschedule');
      },
      handleInitialResponse: (value) async {
        events.add('handle:${value.id}');
      },
    );
    expect(events, ['refresh:false', 'handle:72']);

    events.clear();
    await runStartupAlarmSetup(
      initialResponse: null,
      refreshAlarmStatus: ({required bool reschedule}) async {
        events.add('refresh:$reschedule');
      },
      handleInitialResponse: (_) async {
        events.add('unexpected handle');
      },
    );
    expect(events, ['refresh:true']);
  });

  testWidgets('renders the home experience', (tester) async {
    SharedPreferences.setMockInitialValues({'welcomed': true});
    await tester.pumpWidget(const TakeYourMedApp());
    await tester.pumpAndSettle();
    expect(find.text('TAKE YOUR MED'), findsOneWidget);
    expect(find.text('Add medicine'), findsWidgets);
  });

  testWidgets('specific-date picker selects several dates at once', (
    tester,
  ) async {
    List<String>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showModalBottomSheet<List<String>>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const MultiDatePicker(initialDates: []),
                );
              },
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10'));
    await tester.tap(find.text('12'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(result, hasLength(2));
  });

  testWidgets('alarm uses buttons and Taken confirms the dose', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var taken = false;
    await tester.pumpWidget(
      MaterialApp(
        home: DoseAlarmPage(
          medicineName: 'Vitamin C',
          instructions: 'After breakfast',
          onTaken: () async => taken = true,
          onSnooze: () async {},
        ),
      ),
    );

    expect(find.byType(Dismissible), findsNothing);
    expect(find.byKey(const ValueKey('dose-snooze-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dose-taken-button')));
    await tester.pumpAndSettle();
    expect(taken, isTrue);
  });

  testWidgets('background action dismisses an already-visible alarm host', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var hostDismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DoseAlarmPage(
                    medicineName: 'Vitamin C',
                    instructions: '',
                    onTaken: () async {},
                    onSnooze: () async {},
                    dismissHost: () async {
                      hostDismissed = true;
                      return true;
                    },
                    alarmPayload: 'med|9|540',
                    notificationId: 42,
                  ),
                ),
              ),
              child: const Text('Home sentinel'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Home sentinel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await recordResolvedAlarmAction(
      const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        id: 42,
        actionId: 'snooze',
        payload: 'med|9|540',
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(hostDismissed, isTrue);
    expect(find.text('Home sentinel'), findsNothing);
    expect(find.text('Vitamin C'), findsOneWidget);
  });

  testWidgets('alarm still dismisses when its action callback fails', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var hostDismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: DoseAlarmPage(
          medicineName: 'Vitamin C',
          instructions: '',
          onTaken: () async => throw StateError('storage unavailable'),
          onSnooze: () async {},
          dismissHost: () async {
            hostDismissed = true;
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('dose-taken-button')));
    await tester.pumpAndSettle();
    expect(hostDismissed, isTrue);
  });

  testWidgets('alarm returns to Home when Take Your Med was already open', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DoseAlarmPage(
                    medicineName: 'Vitamin C',
                    instructions: '',
                    onTaken: () async {},
                    onSnooze: () async {},
                    dismissHost: () async => false,
                  ),
                ),
              ),
              child: const Text('Home sentinel'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Home sentinel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dose-taken-button')));
    await tester.pumpAndSettle();
    expect(find.text('Home sentinel'), findsOneWidget);
  });

  testWidgets('Android alarm host dismissal delegates to the native host', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    MethodCall? platformCall;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(alarmHostChannel, (call) async {
      platformCall = call;
      return true;
    });
    try {
      expect(await dismissAlarmHost(), isTrue);
      expect(platformCall?.method, 'dismissAlarmHost');
      expect(platformCall?.arguments, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(alarmHostChannel, null);
    }
  });

  testWidgets('alarm check exposes duration and behavior controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AlarmPreferences? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlertCenterSheet(
            loadStatus: () async => const AlertStatus(true, true, 2),
            initialPreferences: const AlarmPreferences(),
            onEnable: () async {},
            onSave: (value) async => saved = value,
            onTest: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 minute'), findsOneWidget);
    expect(find.text('Sound'), findsOneWidget);
    expect(find.text('Vibrate'), findsOneWidget);
    expect(find.text('Open alert automatically'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('apply-alarm-settings')),
      400,
    );
    await tester.tap(find.byKey(const ValueKey('apply-alarm-settings')));
    await tester.pumpAndSettle();
    expect(saved?.durationSeconds, 60);
  });

  test('Android manifest includes scheduled alarm delivery components', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('ScheduledNotificationReceiver'));
    expect(manifest, contains('ScheduledNotificationBootReceiver'));
    expect(manifest, contains('ActionBroadcastReceiver'));
    expect(manifest, contains('android:showWhenLocked="true"'));
    expect(manifest, contains('android:turnScreenOn="true"'));

    final activity = File(
      'android/app/src/main/kotlin/com/vileanreal/take_your_med/MainActivity.kt',
    ).readAsStringSync();
    expect(activity, contains('take_your_med/alarm_host'));
    expect(activity, contains('SELECT_NOTIFICATION'));
    expect(activity, contains('finishAndRemoveTask()'));

    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(appDelegate, contains('setPluginRegistrantCallback'));
  });
}
