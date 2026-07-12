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

  testWidgets('alarm swipe right confirms the dose', (tester) async {
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

    await tester.drag(
      find.byKey(const ValueKey('dose-alarm-slider')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();
    expect(taken, isTrue);
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
