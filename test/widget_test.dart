import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
