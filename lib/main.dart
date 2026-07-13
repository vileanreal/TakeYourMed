// Take Your Med — local-first medication reminders for mobile and web.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

const rose = Color(0xFFE84A67), violet = Color(0xFF8B7CF6);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alerts.instance.init();
  runApp(const TakeYourMedApp());
}

class Medication {
  Medication({
    required this.id,
    required this.name,
    required List<int> times,
    required this.recurring,
    required this.days,
    required this.dates,
    this.notes = '',
    this.finished = false,
    List<String>? taken,
  }) : times = _normaliseInts(times),
       taken = {...?taken}.toList() {
    days = _normaliseInts(days);
    dates = {...dates}.toList()..sort();
  }
  final int id;
  String name, notes;
  bool recurring, finished;
  List<int> times, days;
  List<String> dates, taken;

  static List<int> _normaliseInts(Iterable<int> values) =>
      values.toSet().toList()..sort();
  static int minutesOf(TimeOfDay time) => time.hour * 60 + time.minute;
  static TimeOfDay timeOf(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
  static String dateKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);
  String doseKey(String date, int minutes) => '$date#$minutes';
  bool isTaken(String date, int minutes) =>
      taken.contains(doseKey(date, minutes));
  void setTaken(String date, int minutes, bool value) {
    final key = doseKey(date, minutes);
    value ? taken.add(key) : taken.remove(key);
    taken = taken.toSet().toList()..sort();
  }

  int takenCount(String date) =>
      times.where((time) => isTaken(date, time)).length;
  bool isScheduledOn(DateTime date) =>
      recurring ? days.contains(date.weekday) : dates.contains(dateKey(date));

  Map<String, dynamic> toJson() => {
    'schemaVersion': 2,
    'id': id,
    'name': name,
    'notes': notes,
    'times': times,
    'recurring': recurring,
    'finished': finished,
    'days': days,
    'dates': dates,
    'taken': taken,
  };
  factory Medication.fromJson(Map<String, dynamic> j) {
    final legacyTime =
        ((j['hour'] as num?)?.toInt() ?? 8) * 60 +
        ((j['minute'] as num?)?.toInt() ?? 0);
    final times = j['times'] == null
        ? <int>[legacyTime]
        : List<int>.from(j['times']);
    final rawTaken = List<String>.from(j['taken'] ?? []);
    final migratedTaken = rawTaken
        .map((value) => value.contains('#') ? value : '$value#$legacyTime')
        .toList();
    return Medication(
      id: (j['id'] as num).toInt(),
      name: j['name'],
      notes: j['notes'] ?? '',
      times: times,
      recurring: j['recurring'],
      finished: j['finished'] ?? false,
      days: List<int>.from(j['days'] ?? []),
      dates: List<String>.from(j['dates'] ?? []),
      taken: migratedTaken,
    );
  }
}

const _takenActionPrefix = 'backgroundTakenAction.';
const _resolvedAlarmActionKey = 'lastResolvedAlarmAction';

class MedicationAlarmPayload {
  const MedicationAlarmPayload({
    required this.medicationId,
    required this.minutes,
    required this.isSnoozed,
  });

  final int medicationId;
  final int minutes;
  final bool isSnoozed;

  static MedicationAlarmPayload? parse(String payload) {
    final parts = payload.split('|');
    if (parts.length != 3 ||
        (parts.first != 'med' && parts.first != 'snoozed')) {
      return null;
    }
    final medicationId = int.tryParse(parts[1]);
    final minutes = int.tryParse(parts[2]);
    if (medicationId == null || minutes == null) return null;
    return MedicationAlarmPayload(
      medicationId: medicationId,
      minutes: minutes,
      isSnoozed: parts.first == 'snoozed',
    );
  }

  String get snoozedPayload => 'snoozed|$medicationId|$minutes';
}

@visibleForTesting
bool shouldCancelMedicationAlarmPayload(
  String? payload,
  int medicationId, {
  required bool includeSnoozes,
}) {
  if (payload == null) return false;
  final parsed = MedicationAlarmPayload.parse(payload);
  return parsed != null &&
      parsed.medicationId == medicationId &&
      (includeSnoozes || !parsed.isSnoozed);
}

@visibleForTesting
bool isSnoozedMedicationDosePayload(
  String? payload,
  int medicationId,
  int minutes,
) {
  if (payload == null) return false;
  final parsed = MedicationAlarmPayload.parse(payload);
  return parsed != null &&
      parsed.isSnoozed &&
      parsed.medicationId == medicationId &&
      parsed.minutes == minutes;
}

Set<String> _applyPendingTakenActions(
  SharedPreferences preferences,
  List<Medication> medications,
) {
  final appliedKeys = <String>{};
  for (final key in preferences.getKeys().where(
    (value) => value.startsWith(_takenActionPrefix),
  )) {
    final parts = key.substring(_takenActionPrefix.length).split('|');
    if (parts.length == 3) {
      final medicationId = int.tryParse(parts[0]);
      final minutes = int.tryParse(parts[2]);
      final medication = medications
          .where((item) => item.id == medicationId)
          .firstOrNull;
      if (medication != null &&
          minutes != null &&
          medication.times.contains(minutes)) {
        medication.setTaken(parts[1], minutes, true);
      }
    }
    appliedKeys.add(key);
  }
  return appliedKeys;
}

Future<void> _clearAppliedTakenActions(
  SharedPreferences preferences,
  Set<String> keys,
) async {
  for (final key in keys) {
    await preferences.remove(key);
  }
}

Future<List<Medication>> loadStoredMedications({
  bool refresh = false,
  bool applyPendingActions = true,
}) async {
  final preferences = await SharedPreferences.getInstance();
  if (refresh) await preferences.reload();
  final raw = preferences.getString('medications');
  if (raw == null) return [];
  final medications = (jsonDecode(raw) as List)
      .map((value) => Medication.fromJson(value))
      .toList();
  final appliedKeys = applyPendingActions
      ? _applyPendingTakenActions(preferences, medications)
      : <String>{};
  if (appliedKeys.isNotEmpty) {
    await preferences.setString(
      'medications',
      jsonEncode(medications.map((medication) => medication.toJson()).toList()),
    );
    await _clearAppliedTakenActions(preferences, appliedKeys);
  }
  return medications;
}

Future<void> saveStoredMedications(List<Medication> medications) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.reload();
  final appliedKeys = _applyPendingTakenActions(preferences, medications);
  await preferences.setString(
    'medications',
    jsonEncode(medications.map((medication) => medication.toJson()).toList()),
  );
  await _clearAppliedTakenActions(preferences, appliedKeys);
}

typedef ScheduleSnooze =
    Future<void> Function(String payload, int? sourceNotificationId);

Future<void> _recordPendingTakenAction(
  int medicationId,
  String date,
  int minutes,
) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(
    '$_takenActionPrefix$medicationId|$date|$minutes',
    true,
  );
}

class ResolvedAlarmAction {
  const ResolvedAlarmAction({
    required this.payload,
    required this.notificationId,
    required this.completedAtMillis,
  });
  final String payload;
  final int? notificationId;
  final int completedAtMillis;
}

Future<void> recordResolvedAlarmAction(NotificationResponse response) async {
  if (response.actionId != 'taken' && response.actionId != 'snooze') return;
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _resolvedAlarmActionKey,
    jsonEncode({
      'payload': response.payload ?? '',
      'notificationId': response.id,
      'completedAtMillis': DateTime.now().millisecondsSinceEpoch,
    }),
  );
}

Future<ResolvedAlarmAction?> loadResolvedAlarmAction({
  bool refresh = false,
}) async {
  final preferences = await SharedPreferences.getInstance();
  if (refresh) await preferences.reload();
  final raw = preferences.getString(_resolvedAlarmActionKey);
  if (raw == null) return null;
  try {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    return ResolvedAlarmAction(
      payload: value['payload'] as String? ?? '',
      notificationId: (value['notificationId'] as num?)?.toInt(),
      completedAtMillis: (value['completedAtMillis'] as num?)?.toInt() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

Future<bool> wasAlarmResolvedRecently({
  required String payload,
  required int? notificationId,
  required DateTime since,
}) async {
  final action = await loadResolvedAlarmAction(refresh: true);
  if (action == null || action.payload != payload) return false;
  if (notificationId != null &&
      action.notificationId != null &&
      action.notificationId != notificationId) {
    return false;
  }
  return action.completedAtMillis >= since.millisecondsSinceEpoch;
}

@visibleForTesting
Future<bool> processStoredNotificationAction(
  NotificationResponse response, {
  DateTime? now,
  required ScheduleSnooze scheduleSnooze,
}) async {
  if (response.actionId != 'taken' && response.actionId != 'snooze') {
    return false;
  }
  final payload = response.payload ?? '';
  if (payload == 'test') {
    if (response.actionId == 'snooze') {
      await scheduleSnooze(payload, response.id);
    }
    return true;
  }
  final dose = MedicationAlarmPayload.parse(payload);
  if (dose == null) return false;

  final medications = await loadStoredMedications(
    refresh: true,
    applyPendingActions: false,
  );
  final medication = medications
      .where((item) => item.id == dose.medicationId)
      .firstOrNull;
  if (medication == null || !medication.times.contains(dose.minutes)) {
    return false;
  }

  if (response.actionId == 'taken') {
    await _recordPendingTakenAction(
      medication.id,
      Medication.dateKey(now ?? DateTime.now()),
      dose.minutes,
    );
  } else {
    await scheduleSnooze(payload, response.id);
  }
  return true;
}

@visibleForTesting
Future<bool> processAndRecordStoredNotificationAction(
  NotificationResponse response, {
  DateTime? now,
  required ScheduleSnooze scheduleSnooze,
}) async {
  final handled = await processStoredNotificationAction(
    response,
    now: now,
    scheduleSnooze: scheduleSnooze,
  );
  if (handled) await recordResolvedAlarmAction(response);
  return handled;
}

Future<void> _backgroundActionQueue = Future.value();

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  _backgroundActionQueue = _backgroundActionQueue.then((_) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await processAndRecordStoredNotificationAction(
        response,
        scheduleSnooze: (payload, sourceNotificationId) async {
          await Alerts.instance.init(captureLaunchDetails: false);
          await Alerts.instance.reloadPreferences();
          await Alerts.instance.snooze(
            payload,
            sourceNotificationId: sourceNotificationId,
          );
        },
      );
    } catch (error, stackTrace) {
      debugPrint('Could not process notification action: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  });
}

const alarmHostChannel = MethodChannel('take_your_med/alarm_host');

Future<bool> dismissAlarmHost() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      final dismissed = await alarmHostChannel.invokeMethod<bool>(
        'dismissAlarmHost',
      );
      if (dismissed != null) return dismissed;
    } on PlatformException catch (error) {
      debugPrint('Native alarm host dismissal was unavailable: $error');
    } on MissingPluginException catch (error) {
      debugPrint('Native alarm host bridge was unavailable: $error');
    }
    await SystemNavigator.pop(animated: true);
    return true;
  }
  return false;
}

@visibleForTesting
Future<void> runStartupAlarmSetup({
  required NotificationResponse? initialResponse,
  required Future<void> Function(NotificationResponse response)
  handleInitialResponse,
  required Future<void> Function({required bool reschedule}) refreshAlarmStatus,
}) async {
  if (initialResponse != null) {
    await refreshAlarmStatus(reschedule: false);
    await handleInitialResponse(initialResponse);
  } else {
    await refreshAlarmStatus(reschedule: true);
  }
}

List<DarwinNotificationCategory> get medicineAlarmCategories => [
  DarwinNotificationCategory(
    'medicine_alarm',
    actions: [
      DarwinNotificationAction.plain('taken', 'Taken'),
      DarwinNotificationAction.plain('snooze', 'Remind me later'),
    ],
  ),
];

class AlarmPreferences {
  const AlarmPreferences({
    this.durationSeconds = 60,
    this.sound = true,
    this.vibrate = true,
    this.autoDisplay = true,
  });
  final int durationSeconds;
  final bool sound, vibrate, autoDisplay;

  AlarmPreferences copyWith({
    int? durationSeconds,
    bool? sound,
    bool? vibrate,
    bool? autoDisplay,
  }) => AlarmPreferences(
    durationSeconds: durationSeconds ?? this.durationSeconds,
    sound: sound ?? this.sound,
    vibrate: vibrate ?? this.vibrate,
    autoDisplay: autoDisplay ?? this.autoDisplay,
  );

  static Future<AlarmPreferences> load({bool refresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (refresh) await prefs.reload();
    final storedDuration = prefs.getInt('alarmDurationSeconds') ?? 60;
    final duration = const [30, 60, 120, 300].contains(storedDuration)
        ? storedDuration
        : 60;
    return AlarmPreferences(
      durationSeconds: duration,
      sound: prefs.getBool('alarmSound') ?? true,
      vibrate: prefs.getBool('alarmVibrate') ?? true,
      autoDisplay: prefs.getBool('alarmAutoDisplay') ?? true,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setInt('alarmDurationSeconds', durationSeconds),
      prefs.setBool('alarmSound', sound),
      prefs.setBool('alarmVibrate', vibrate),
      prefs.setBool('alarmAutoDisplay', autoDisplay),
    ]);
  }

  String get durationLabel => switch (durationSeconds) {
    30 => '30 seconds',
    60 => '1 minute',
    120 => '2 minutes',
    300 => '5 minutes',
    _ => '$durationSeconds seconds',
  };
}

class Alerts {
  Alerts._();
  static final instance = Alerts._();
  static const alarmSoundResource = 'medicine_alarm';
  final plugin = FlutterLocalNotificationsPlugin();
  final ValueNotifier<NotificationResponse?> responses = ValueNotifier(null);
  NotificationResponse? initialResponse;
  AlarmPreferences preferences = const AlarmPreferences();
  bool initialized = false;

  AndroidFlutterLocalNotificationsPlugin? get _android => plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  Future<void> init({bool captureLaunchDetails = true}) async {
    if (initialized) return;
    preferences = await AlarmPreferences.load();
    tz_data.initializeTimeZones();
    if (!kIsWeb) {
      try {
        tz.setLocalLocation(
          tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier),
        );
      } catch (error) {
        debugPrint('Could not resolve the device timezone: $error');
      }
    }
    const a = AndroidInitializationSettings('notification_icon');
    final i = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: medicineAlarmCategories,
    );
    await plugin.initialize(
      settings: InitializationSettings(android: a, iOS: i, macOS: i),
      onDidReceiveNotificationResponse: (response) {
        responses.value = response;
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    await ensureAndroidAlarmChannel();
    initialized = true;
    if (captureLaunchDetails) {
      final launch = await plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        initialResponse = launch?.notificationResponse;
      }
    }
  }

  String get androidChannelId =>
      'medicine_alarms_v4_s${preferences.sound ? 1 : 0}_v${preferences.vibrate ? 1 : 0}';

  String get androidChannelName => preferences.sound
      ? preferences.vibrate
            ? 'Medicine alarms: sound + vibration'
            : 'Medicine alarms: sound'
      : preferences.vibrate
      ? 'Medicine alarms: vibration'
      : 'Medicine alarms: silent';

  AndroidNotificationSound? get androidAlarmSound => preferences.sound
      ? const RawResourceAndroidNotificationSound(alarmSoundResource)
      : null;

  AndroidNotificationChannel get androidAlarmChannel =>
      AndroidNotificationChannel(
        androidChannelId,
        androidChannelName,
        description: 'Urgent alarms for medication doses',
        importance: Importance.max,
        playSound: preferences.sound,
        sound: androidAlarmSound,
        enableVibration: preferences.vibrate,
        audioAttributesUsage: AudioAttributesUsage.alarm,
      );

  Future<void> ensureAndroidAlarmChannel() async {
    await _android?.createNotificationChannel(androidAlarmChannel);
  }

  NotificationDetails get details => NotificationDetails(
    android: AndroidNotificationDetails(
      androidChannelId,
      androidChannelName,
      channelDescription: 'Urgent alarms for medication doses',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
      fullScreenIntent: preferences.autoDisplay,
      ongoing: false,
      autoCancel: true,
      timeoutAfter: preferences.durationSeconds * 1000,
      playSound: preferences.sound,
      sound: androidAlarmSound,
      enableVibration: preferences.vibrate,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      additionalFlags: preferences.sound || preferences.vibrate
          ? Int32List.fromList([4])
          : null,
      actions: const [
        AndroidNotificationAction(
          'taken',
          'Taken',
          showsUserInterface: false,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'snooze',
          'Remind me in 10 min',
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentSound: preferences.sound,
      interruptionLevel: InterruptionLevel.timeSensitive,
      categoryIdentifier: 'medicine_alarm',
    ),
  );

  Future<void> savePreferences(AlarmPreferences value) async {
    preferences = value;
    await value.save();
    await ensureAndroidAlarmChannel();
    if (!kIsWeb && value.autoDisplay) {
      await _android?.requestFullScreenIntentPermission();
    }
  }

  Future<void> reloadPreferences() async {
    preferences = await AlarmPreferences.load(refresh: true);
  }

  Future<AlertStatus> status() async {
    if (!initialized) return const AlertStatus(true, true, 0);
    if (kIsWeb) return const AlertStatus(true, true, 0);
    final enabled = await _android?.areNotificationsEnabled() ?? true;
    final exact = await _android?.canScheduleExactNotifications() ?? true;
    final pending = (await plugin.pendingNotificationRequests()).length;
    return AlertStatus(enabled, exact, pending);
  }

  Future<AlertStatus> requestPermissions() async {
    if (kIsWeb) {
      await plugin
          .resolvePlatformSpecificImplementation<
            WebFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      return status();
    }
    await _android?.requestNotificationsPermission();
    if (!(await _android?.canScheduleExactNotifications() ?? true)) {
      await _android?.requestExactAlarmsPermission();
    }
    if (preferences.autoDisplay) {
      await _android?.requestFullScreenIntentPermission();
    }
    await plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    return status();
  }

  Future<void> schedule(Medication m) async {
    if (!initialized) return;
    if (m.finished) {
      await cancel(m.id);
      return;
    }
    await _cancelBaseSchedule(m.id);
    final exact = await _android?.canScheduleExactNotifications() ?? true;
    final mode = exact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
    for (final minutes in m.times) {
      final hour = minutes ~/ 60, minute = minutes % 60;
      final payload = 'med|${m.id}|$minutes';
      if (m.recurring) {
        for (final day in m.days) {
          final at = _nextWeekday(day, hour, minute);
          await plugin.zonedSchedule(
            id: _id('${m.id}|$minutes|weekday|$day'),
            title: 'Time to take ${m.name}',
            body: m.notes.isEmpty
                ? 'Tap to view Taken and Snooze options'
                : m.notes,
            scheduledDate: at,
            notificationDetails: details,
            androidScheduleMode: mode,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
            payload: payload,
          );
        }
      } else {
        for (final value in m.dates) {
          final date = DateTime.parse(value);
          final at = tz.TZDateTime(
            tz.local,
            date.year,
            date.month,
            date.day,
            hour,
            minute,
          );
          if (at.isAfter(tz.TZDateTime.now(tz.local))) {
            await plugin.zonedSchedule(
              id: _id('${m.id}|$minutes|$value'),
              title: 'Time to take ${m.name}',
              body: m.notes.isEmpty
                  ? 'Tap to view Taken and Snooze options'
                  : m.notes,
              scheduledDate: at,
              notificationDetails: details,
              androidScheduleMode: mode,
              payload: payload,
            );
          }
        }
      }
    }
  }

  tz.TZDateTime _nextWeekday(int weekday, int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    for (var offset = 0; offset <= 7; offset++) {
      final date = now.add(Duration(days: offset));
      final result = tz.TZDateTime(
        tz.local,
        date.year,
        date.month,
        date.day,
        hour,
        minute,
      );
      if (result.weekday == weekday && result.isAfter(now)) return result;
    }
    throw StateError('Unable to calculate next medication alarm');
  }

  int _id(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  Future<void> _cancelBaseSchedule(int id) =>
      _cancelMedicationAlarms(id, includeSnoozes: false);

  Future<void> cancel(int id) =>
      _cancelMedicationAlarms(id, includeSnoozes: true);

  Future<void> _cancelMedicationAlarms(
    int id, {
    required bool includeSnoozes,
  }) async {
    final pending = await plugin.pendingNotificationRequests();
    for (final request in pending) {
      if (shouldCancelMedicationAlarmPayload(
        request.payload,
        id,
        includeSnoozes: includeSnoozes,
      )) {
        await plugin.cancel(id: request.id);
      }
    }
  }

  Future<void> cancelSnoozedDose(int medicationId, int minutes) async {
    final pending = await plugin.pendingNotificationRequests();
    for (final request in pending) {
      if (isSnoozedMedicationDosePayload(
        request.payload,
        medicationId,
        minutes,
      )) {
        await plugin.cancel(id: request.id);
      }
    }
  }

  Future<void> snooze(String payload, {int? sourceNotificationId}) async {
    final exact = await _android?.canScheduleExactNotifications() ?? true;
    final snoozedPayload =
        MedicationAlarmPayload.parse(payload)?.snoozedPayload ?? payload;
    final snoozeSource =
        sourceNotificationId ?? DateTime.now().millisecondsSinceEpoch;
    await plugin.zonedSchedule(
      id: _id('$snoozedPayload|snooze|$snoozeSource'),
      title: 'Medication reminder',
      body: 'Your 10-minute snooze is over',
      scheduledDate: tz.TZDateTime.now(
        tz.local,
      ).add(const Duration(minutes: 10)),
      notificationDetails: details,
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: snoozedPayload,
    );
  }

  Future<void> testAlert() => plugin.show(
    id: 2147483000,
    title: 'Test medicine alarm',
    body: 'Notifications are working. Tap to open the alarm screen.',
    notificationDetails: details,
    payload: 'test',
  );
}

class AlertStatus {
  const AlertStatus(this.notifications, this.exact, this.pending);
  final bool notifications, exact;
  final int pending;
  bool get ready => notifications && exact;
}

class TodayDose {
  const TodayDose(this.medication, this.minutes);
  final Medication medication;
  final int minutes;
}

class TakeYourMedApp extends StatefulWidget {
  const TakeYourMedApp({super.key});
  @override
  State<TakeYourMedApp> createState() => _AppState();
}

class _AppState extends State<TakeYourMedApp> {
  bool dark = false;
  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => dark = prefs.getBool('darkMode') ?? false);
    });
  }

  void toggleTheme() {
    setState(() => dark = !dark);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool('darkMode', dark),
    );
  }

  @override
  Widget build(BuildContext c) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Take Your Med',
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    theme: _theme(false),
    darkTheme: _theme(true),
    home: HomePage(dark: dark, toggle: toggleTheme),
  );
  ThemeData _theme(bool d) => ThemeData(
    useMaterial3: true,
    brightness: d ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: rose,
      brightness: d ? Brightness.dark : Brightness.light,
      primary: rose,
      secondary: violet,
    ),
    scaffoldBackgroundColor: d
        ? const Color(0xFF15111D)
        : const Color(0xFFF9F4FA),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: d
          ? const Color(0xFF292233)
          : Colors.white.withValues(alpha: .8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.dark, required this.toggle});
  final bool dark;
  final VoidCallback toggle;
  @override
  State<HomePage> createState() => _HomeState();
}

class _HomeState extends State<HomePage> with WidgetsBindingObserver {
  List<Medication> meds = [];
  bool loaded = false;
  AlertStatus? alertStatus;
  int lastResolvedAlarmAt = 0;
  String get today => DateFormat('yyyy-MM-dd').format(DateTime.now());
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Alerts.instance.responses.addListener(_notificationReceived);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Alerts.instance.responses.removeListener(_notificationReceived);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (loaded) {
        _reloadAfterBackgroundAction();
      } else {
        _refreshAlertStatus();
      }
    }
  }

  Future<void> load() async {
    meds = await loadStoredMedications(refresh: true);
    lastResolvedAlarmAt =
        (await loadResolvedAlarmAction())?.completedAtMillis ?? 0;
    final p = await SharedPreferences.getInstance();
    final welcomed = p.getBool('welcomed') ?? false;
    if (mounted) {
      setState(() => loaded = true);
      if (!welcomed) {
        WidgetsBinding.instance.addPostFrameCallback((_) => welcome());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final initial = Alerts.instance.initialResponse;
        Alerts.instance.initialResponse = null;
        await runStartupAlarmSetup(
          initialResponse: initial,
          refreshAlarmStatus: ({required bool reschedule}) =>
              _refreshAlertStatus(reschedule: reschedule),
          handleInitialResponse: _handleNotification,
        );
      });
    }
  }

  Future<void> _reloadAfterBackgroundAction() async {
    try {
      final resolved = await loadResolvedAlarmAction(refresh: true);
      if (resolved == null ||
          resolved.completedAtMillis <= lastResolvedAlarmAt) {
        await _refreshAlertStatus();
        return;
      }
      lastResolvedAlarmAt = resolved.completedAtMillis;
      final stored = await loadStoredMedications();
      if (!mounted) return;
      setState(() {
        for (final storedMedication in stored) {
          final current = meds
              .where((item) => item.id == storedMedication.id)
              .firstOrNull;
          if (current == null) {
            meds.add(storedMedication);
          } else {
            current.taken = {
              ...current.taken,
              ...storedMedication.taken,
            }.toList()..sort();
          }
        }
      });
      await _refreshAlertStatus();
    } catch (error) {
      debugPrint('Could not refresh medication actions: $error');
    }
  }

  Future<void> _refreshAlertStatus({bool reschedule = false}) async {
    try {
      if (reschedule) {
        for (final med in meds.where((m) => !m.finished)) {
          await Alerts.instance.schedule(med);
        }
      }
      final status = await Alerts.instance.status();
      if (mounted) setState(() => alertStatus = status);
    } catch (error) {
      debugPrint('Medication alarm setup failed: $error');
      if (mounted) {
        setState(() => alertStatus = const AlertStatus(false, false, 0));
      }
    }
  }

  void _notificationReceived() {
    final response = Alerts.instance.responses.value;
    if (response != null) {
      Alerts.instance.responses.value = null;
      if (!loaded) {
        Alerts.instance.initialResponse = response;
        return;
      }
      _handleNotification(response);
    }
  }

  Future<void> _handleNotification(NotificationResponse response) async {
    if (!mounted) return;
    final payload = response.payload ?? '';
    if (payload == 'test') {
      await _openAlarm(
        name: 'Test alarm',
        instructions: 'Your Take Your Med alerts are working.',
        payload: payload,
        notificationId: response.id,
      );
      return;
    }
    final dose = MedicationAlarmPayload.parse(payload);
    if (!(response.actionId?.isNotEmpty ?? false) &&
        dose != null &&
        await wasAlarmResolvedRecently(
          payload: payload,
          notificationId: response.id,
          since: DateTime.now().subtract(const Duration(seconds: 30)),
        )) {
      await dismissAlarmHost();
      return;
    }
    if (dose == null) return;
    final med = meds.where((m) => m.id == dose.medicationId).firstOrNull;
    if (med == null || !med.times.contains(dose.minutes)) return;
    if (response.actionId == 'taken') {
      await _completeDose(med, dose.minutes, response.id);
      await dismissAlarmHost();
    } else if (response.actionId == 'snooze') {
      await _snooze(payload, response.id, showConfirmation: false);
      await dismissAlarmHost();
    } else {
      await _openAlarm(
        name: med.name,
        instructions: med.notes,
        payload: payload,
        notificationId: response.id,
        onTaken: () => _completeDose(med, dose.minutes, response.id),
      );
    }
  }

  Future<void> _completeDose(
    Medication med,
    int minutes,
    int? notificationId,
  ) async {
    await _setDoseTaken(med, today, minutes, true);
    if (notificationId != null) {
      await Alerts.instance.plugin.cancel(id: notificationId);
    }
    await Alerts.instance.schedule(med);
  }

  Future<void> _snooze(
    String payload,
    int? notificationId, {
    bool showConfirmation = true,
  }) async {
    if (notificationId != null) {
      await Alerts.instance.plugin.cancel(id: notificationId);
    }
    final dose = MedicationAlarmPayload.parse(payload);
    if (dose != null) {
      final med = meds
          .where((item) => item.id == dose.medicationId)
          .firstOrNull;
      if (med != null) await Alerts.instance.schedule(med);
    }
    await Alerts.instance.snooze(payload, sourceNotificationId: notificationId);
    if (mounted && showConfirmation) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('We’ll remind you again in 10 minutes.')),
      );
    }
  }

  Future<void> _openAlarm({
    required String name,
    required String instructions,
    required String payload,
    required int? notificationId,
    Future<void> Function()? onTaken,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => DoseAlarmPage(
          medicineName: name,
          instructions: instructions,
          onTaken: () async {
            if (onTaken != null) {
              await onTaken();
            } else if (notificationId != null) {
              await Alerts.instance.plugin.cancel(id: notificationId);
            }
          },
          onSnooze: () =>
              _snooze(payload, notificationId, showConfirmation: false),
          dismissHost: MedicationAlarmPayload.parse(payload) != null
              ? dismissAlarmHost
              : null,
          alarmPayload: payload,
          notificationId: notificationId,
          onBackgroundResolved: _reloadAfterBackgroundAction,
        ),
      ),
    );
  }

  Future<void> save() => saveStoredMedications(meds);

  Future<void> _setDoseTaken(
    Medication med,
    String date,
    int minutes,
    bool value,
  ) async {
    if (mounted) setState(() => med.setTaken(date, minutes, value));
    await save();
    if (value && date == today) {
      try {
        await Alerts.instance.cancelSnoozedDose(med.id, minutes);
      } catch (error) {
        debugPrint('Could not cancel the completed dose snooze: $error');
      }
    }
  }

  Future<void> welcome() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.favorite_rounded, color: rose, size: 44),
        title: const Text('Welcome to Take Your Med'),
        content: const Text(
          'A calmer, clearer way to stay on top of every dose. Add your first medication and we’ll keep watch.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Let’s begin'),
          ),
        ],
      ),
    );
    (await SharedPreferences.getInstance()).setBool('welcomed', true);
  }

  @override
  Widget build(BuildContext c) {
    final now = DateTime.now();
    final active =
        meds.where((m) => !m.finished && m.isScheduledOn(now)).toList()
          ..sort((a, b) => a.times.first.compareTo(b.times.first));
    final doses = [
      for (final med in active)
        for (final minutes in med.times) TodayDose(med, minutes),
    ]..sort((a, b) => a.minutes.compareTo(b.minutes));
    final taken = doses
        .where((dose) => dose.medication.isTaken(today, dose.minutes))
        .length;
    final next = doses
        .where((dose) => !dose.medication.isTaken(today, dose.minutes))
        .firstOrNull;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => edit(),
        backgroundColor: rose,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add medicine'),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: widget.dark
                ? [const Color(0xFF261A2D), const Color(0xFF121019)]
                : [
                    const Color(0xFFFFE9EF),
                    const Color(0xFFF0EDFF),
                    const Color(0xFFFFF8F4),
                  ],
          ),
        ),
        child: SafeArea(
          child: loaded
              ? CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: rose,
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: const Icon(
                                Icons.medication_rounded,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'TAKE YOUR MED',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.8,
                                      color: rose,
                                    ),
                                  ),
                                  Text(
                                    'Good day!',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton.filledTonal(
                              tooltip: 'Alert status and test',
                              onPressed: _showAlertCenter,
                              icon: Icon(
                                alertStatus?.ready ?? false
                                    ? Icons.notifications_active_rounded
                                    : Icons.notifications_off_rounded,
                                color: alertStatus?.ready ?? false
                                    ? rose
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 6),
                            IconButton.filledTonal(
                              tooltip: widget.dark ? 'Day mode' : 'Night mode',
                              onPressed: widget.toggle,
                              icon: Icon(
                                widget.dark
                                    ? Icons.light_mode
                                    : Icons.dark_mode,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.all(20),
                      sliver: SliverToBoxAdapter(
                        child: Summary(
                          taken: taken,
                          total: doses.length,
                          next: next,
                        ),
                      ),
                    ),
                    if (alertStatus != null && !alertStatus!.ready)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                        sliver: SliverToBoxAdapter(
                          child: AlertBanner(
                            status: alertStatus!,
                            onFix: _enableAlerts,
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Today’s medicines',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            Text(
                              '${doses.length} dose${doses.length == 1 ? '' : 's'}',
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (active.isEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.all(20),
                        sliver: SliverToBoxAdapter(child: Empty(onAdd: edit)),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                        sliver: SliverList.separated(
                          itemCount: active.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, i) => MedCard(
                            med: active[i],
                            today: today,
                            toggle: (minutes) async {
                              final current = active[i].isTaken(today, minutes);
                              await _setDoseTaken(
                                active[i],
                                today,
                                minutes,
                                !current,
                              );
                            },
                            edit: () => edit(active[i]),
                            history: () => history(active[i]),
                            delete: () => remove(active[i]),
                          ),
                        ),
                      ),
                    if (meds.any((m) => !m.finished))
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        sliver: SliverToBoxAdapter(
                          child: OutlinedButton.icon(
                            onPressed: _manageSchedules,
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: Text(
                              'Manage all schedules (${meds.where((m) => !m.finished).length})',
                            ),
                          ),
                        ),
                      ),
                    if (meds.any((m) => m.finished))
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                        sliver: SliverToBoxAdapter(
                          child: OutlinedButton.icon(
                            onPressed: finished,
                            icon: const Icon(Icons.inventory_2_outlined),
                            label: Text(
                              'View finished (${meds.where((m) => m.finished).length})',
                            ),
                          ),
                        ),
                      ),
                  ],
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }

  Future<void> edit([Medication? m]) async {
    final previousTimes = {...?m?.times};
    final r = await showModalBottomSheet<Medication>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Editor(existing: m),
    );
    if (r != null) {
      setState(() {
        if (m == null) meds.add(r);
      });
      await save();
      if (!(alertStatus?.ready ?? false)) {
        await _enableAlerts();
      }
      try {
        for (final removedTime in previousTimes.difference(r.times.toSet())) {
          await Alerts.instance.cancelSnoozedDose(r.id, removedTime);
        }
        await Alerts.instance.schedule(r);
        await _refreshAlertStatus();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not schedule this alarm: $error')),
          );
        }
      }
    }
  }

  Future<void> _enableAlerts() async {
    final proceed =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            icon: const Icon(Icons.alarm_rounded, color: rose, size: 42),
            title: const Text('Allow medicine alarms'),
            content: const Text(
              'Take Your Med needs notification, precise alarm, and full-screen alarm access so reminders can ring on time while the app is closed or your phone is locked.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
    if (!proceed) return;
    final status = await Alerts.instance.requestPermissions();
    if (mounted) setState(() => alertStatus = status);
    await _refreshAlertStatus(reschedule: true);
  }

  Future<void> _showAlertCenter() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AlertCenterSheet(
        loadStatus: Alerts.instance.status,
        initialPreferences: Alerts.instance.preferences,
        onEnable: _enableAlerts,
        onSave: (preferences) async {
          await Alerts.instance.savePreferences(preferences);
          for (final med in meds.where((item) => !item.finished)) {
            await Alerts.instance.schedule(med);
          }
          await _refreshAlertStatus();
        },
        onTest: () async {
          if (!(alertStatus?.notifications ?? false)) {
            await _enableAlerts();
          }
          await Alerts.instance.testAlert();
        },
      ),
    );
    await _refreshAlertStatus();
  }

  Future<void> _manageSchedules() async {
    final action = await showModalBottomSheet<ScheduleAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          ScheduleManager(medications: meds.where((m) => !m.finished).toList()),
    );
    if (action == null || !mounted) return;
    if (action.type == ScheduleActionType.edit) await edit(action.medication);
    if (action.type == ScheduleActionType.history) {
      await history(action.medication);
    }
    if (action.type == ScheduleActionType.delete) {
      await remove(action.medication);
    }
  }

  Future<void> remove(Medication m) async {
    final yes =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete medication?'),
            content: Text('${m.name} and its history will be removed.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (yes) {
      setState(() => meds.remove(m));
      await Alerts.instance.cancel(m.id);
      await save();
    }
  }

  Future<void> history(Medication m) async => showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => History(
      med: m,
      changed: (date, minutes, value) => _setDoseTaken(m, date, minutes, value),
    ),
  );
  Future<void> finished() async => showModalBottomSheet(
    context: context,
    builder: (_) => ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Finished medications',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        ...meds
            .where((m) => m.finished)
            .map(
              (m) => ListTile(
                title: Text(m.name),
                subtitle: Text('${m.taken.length} doses recorded'),
                trailing: IconButton(
                  icon: const Icon(Icons.restore),
                  onPressed: () {
                    setState(() => m.finished = false);
                    save();
                    Alerts.instance.schedule(m);
                    Navigator.pop(context);
                  },
                ),
              ),
            ),
      ],
    ),
  );
}

class Summary extends StatelessWidget {
  const Summary({
    super.key,
    required this.taken,
    required this.total,
    this.next,
  });
  final int taken, total;
  final TodayDose? next;
  @override
  Widget build(BuildContext c) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Theme.of(c).colorScheme.surface.withValues(alpha: .88),
      borderRadius: BorderRadius.circular(28),
      boxShadow: [
        BoxShadow(
          color: rose.withValues(alpha: .12),
          blurRadius: 30,
          offset: const Offset(0, 12),
        ),
      ],
    ),
    child: Column(
      children: [
        Row(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 70,
                  height: 70,
                  child: CircularProgressIndicator(
                    value: total == 0 ? 0 : taken / total,
                    strokeWidth: 8,
                    backgroundColor: rose.withValues(alpha: .12),
                    color: rose,
                  ),
                ),
                Text(
                  '$taken/$total',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Today’s progress',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    total == 0
                        ? 'Add a medicine to get started'
                        : taken == total
                        ? 'All done. Beautiful work!'
                        : '${total - taken} dose${total - taken == 1 ? '' : 's'} left today',
                  ),
                ],
              ),
            ),
          ],
        ),
        if (next != null) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(),
          ),
          Row(
            children: [
              const Icon(Icons.notifications_active, color: violet),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  next!.medication.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                Medication.timeOf(next!.minutes).format(c),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

class Empty extends StatelessWidget {
  const Empty({super.key, required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext c) => Container(
    padding: const EdgeInsets.all(32),
    decoration: BoxDecoration(
      color: Theme.of(c).colorScheme.surface.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(26),
    ),
    child: Column(
      children: [
        const Icon(Icons.medication_liquid, size: 52, color: rose),
        const Text(
          'Your schedule is clear',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Add your first medication and choose when you’d like to be reminded.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: const Text('Add medicine'),
        ),
      ],
    ),
  );
}

class MedCard extends StatelessWidget {
  const MedCard({
    super.key,
    required this.med,
    required this.today,
    required this.toggle,
    required this.edit,
    required this.history,
    required this.delete,
  });
  final Medication med;
  final String today;
  final Future<void> Function(int minutes) toggle;
  final VoidCallback edit, history, delete;
  @override
  Widget build(BuildContext c) {
    final done = med.takenCount(today) == med.times.length;
    return Material(
      color: Theme.of(c).colorScheme.surface.withValues(alpha: .86),
      borderRadius: BorderRadius.circular(23),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: done ? rose : rose.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(
                    done ? Icons.check : Icons.medication,
                    color: done ? Colors.white : rose,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        med.name,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          decoration: done ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      Text(
                        med.recurring
                            ? 'Recurring • ${med.times.length} time${med.times.length == 1 ? '' : 's'} daily'
                            : '${med.dates.length} selected date${med.dates.length == 1 ? '' : 's'}',
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'e') edit();
                    if (v == 'h') history();
                    if (v == 'd') delete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'e', child: Text('Edit details')),
                    PopupMenuItem(value: 'h', child: Text('Taken history')),
                    PopupMenuItem(value: 'd', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: med.times.map((minutes) {
                final checked = med.isTaken(today, minutes);
                return FilterChip(
                  avatar: Icon(
                    checked ? Icons.check_circle : Icons.schedule,
                    size: 18,
                    color: checked ? Colors.white : rose,
                  ),
                  label: Text(Medication.timeOf(minutes).format(c)),
                  selected: checked,
                  selectedColor: rose,
                  checkmarkColor: Colors.white,
                  labelStyle: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: checked ? Colors.white : null,
                  ),
                  onSelected: (_) => unawaited(toggle(minutes)),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class Editor extends StatefulWidget {
  const Editor({super.key, this.existing});
  final Medication? existing;
  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  late TextEditingController name, notes;
  late bool recurring, finished;
  late List<int> times, days;
  late List<String> dates;
  @override
  void initState() {
    super.initState();
    final m = widget.existing;
    name = TextEditingController(text: m?.name);
    notes = TextEditingController(text: m?.notes);
    times = List.from(m?.times ?? [8 * 60]);
    recurring = m?.recurring ?? true;
    finished = m?.finished ?? false;
    days = List.from(m?.days ?? [1, 2, 3, 4, 5, 6, 7]);
    dates = List.from(m?.dates ?? []);
  }

  @override
  Widget build(BuildContext c) => Container(
    decoration: BoxDecoration(
      color: Theme.of(c).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
    ),
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.viewInsetsOf(c).bottom + 28,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.existing == null ? 'Add medication' : 'Edit medication',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: name,
            decoration: const InputDecoration(
              labelText: 'Medication name',
              prefixIcon: Icon(Icons.medication),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: notes,
            decoration: const InputDecoration(
              labelText: 'Instructions (optional)',
              prefixIcon: Icon(Icons.notes),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Times each day',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              Text('${times.length} dose${times.length == 1 ? '' : 's'}'),
            ],
          ),
          const SizedBox(height: 8),
          ...times.map(
            (minutes) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                tileColor: rose.withValues(alpha: .1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                leading: const Icon(Icons.schedule, color: rose),
                title: Text(
                  Medication.timeOf(minutes).format(c),
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: const Text('Tap to change'),
                trailing: times.length > 1
                    ? IconButton(
                        tooltip: 'Remove this time',
                        onPressed: () => setState(() => times.remove(minutes)),
                        icon: const Icon(Icons.close),
                      )
                    : null,
                onTap: () => changeTime(minutes),
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: addTime,
            icon: const Icon(Icons.add_alarm_rounded),
            label: const Text('Add another time'),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('Recurring'),
                icon: Icon(Icons.repeat),
              ),
              ButtonSegment(
                value: false,
                label: Text('Specific dates'),
                icon: Icon(Icons.event),
              ),
            ],
            selected: {recurring},
            onSelectionChanged: (s) => setState(() => recurring = s.first),
          ),
          const SizedBox(height: 14),
          if (recurring)
            Wrap(
              spacing: 6,
              children: List.generate(
                7,
                (i) => FilterChip(
                  label: Text(DateFormat.E().format(DateTime(2024, 1, i + 1))),
                  selected: days.contains(i + 1),
                  onSelected: (v) =>
                      setState(() => v ? days.add(i + 1) : days.remove(i + 1)),
                ),
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: violet.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    dates.isEmpty
                        ? 'No dates selected yet'
                        : '${dates.length} date${dates.length == 1 ? '' : 's'} selected\n${_dateSummary()}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: selectDates,
                  icon: const Icon(Icons.calendar_month_rounded),
                  label: Text(dates.isEmpty ? 'Select dates' : 'Edit dates'),
                ),
              ],
            ),
          if (widget.existing != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Medication finished'),
              subtitle: const Text('Stops future reminders'),
              value: finished,
              onChanged: (v) => setState(() => finished = v),
            ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: submit,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Save medication'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  Future<void> addTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: Medication.timeOf(times.last),
    );
    if (picked == null) return;
    final value = Medication.minutesOf(picked);
    if (times.contains(value)) {
      _duplicateTimeMessage();
      return;
    }
    setState(() => times = Medication._normaliseInts([...times, value]));
  }

  Future<void> changeTime(int current) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: Medication.timeOf(current),
    );
    if (picked == null) return;
    final value = Medication.minutesOf(picked);
    if (value != current && times.contains(value)) {
      _duplicateTimeMessage();
      return;
    }
    setState(() {
      times = Medication._normaliseInts([
        ...times.where((time) => time != current),
        value,
      ]);
    });
  }

  void _duplicateTimeMessage() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('That reminder time is already added.')),
  );

  Future<void> selectDates() async {
    final selected = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => MultiDatePicker(initialDates: dates),
    );
    if (selected != null) setState(() => dates = selected);
  }

  String _dateSummary() {
    final formatted = dates
        .take(3)
        .map((date) => DateFormat.MMMd().format(DateTime.parse(date)))
        .join(', ');
    return dates.length > 3
        ? '$formatted +${dates.length - 3} more'
        : formatted;
  }

  void submit() {
    if (name.text.trim().isEmpty ||
        (recurring && days.isEmpty) ||
        (!recurring && dates.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add a name and at least one scheduled day.'),
        ),
      );
      return;
    }
    final m =
        widget.existing ??
        Medication(
          id: DateTime.now().millisecondsSinceEpoch.remainder(1000000000),
          name: '',
          times: times,
          recurring: recurring,
          days: days,
          dates: dates,
        );
    m
      ..name = name.text.trim()
      ..notes = notes.text.trim()
      ..times = Medication._normaliseInts(times)
      ..recurring = recurring
      ..days = days
      ..dates = dates
      ..finished = finished;
    Navigator.pop(context, m);
  }
}

class History extends StatefulWidget {
  const History({super.key, required this.med, required this.changed});
  final Medication med;
  final Future<void> Function(String date, int minutes, bool value) changed;
  @override
  State<History> createState() => _HistoryState();
}

class _HistoryState extends State<History> {
  late DateTime month;
  late int selectedTime;
  @override
  void initState() {
    super.initState();
    month = DateTime(DateTime.now().year, DateTime.now().month);
    selectedTime = widget.med.times.first;
  }

  @override
  Widget build(BuildContext c) {
    final first = DateTime(month.year, month.month, 1),
        count = DateTime(month.year, month.month + 1, 0).day;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.med.name,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Text('Choose a time, then tap dates to update it'),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(c),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed: () => setState(
                  () => month = DateTime(month.year, month.month - 1),
                ),
                icon: const Icon(Icons.chevron_left),
              ),
              Text(
                DateFormat.yMMMM().format(month),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              IconButton(
                onPressed: () => setState(
                  () => month = DateTime(month.year, month.month + 1),
                ),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.med.times.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, index) {
                final minutes = widget.med.times[index];
                return ChoiceChip(
                  selected: selectedTime == minutes,
                  label: Text(Medication.timeOf(minutes).format(c)),
                  onSelected: (_) => setState(() => selectedTime = minutes),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: first.weekday - 1 + count,
              itemBuilder: (_, i) {
                if (i < first.weekday - 1) return const SizedBox();
                final d = DateTime(
                      month.year,
                      month.month,
                      i - first.weekday + 2,
                    ),
                    key = DateFormat('yyyy-MM-dd').format(d);
                final yes = widget.med.isTaken(key, selectedTime);
                final count = widget.med.takenCount(key);
                return InkWell(
                  onTap: () {
                    unawaited(widget.changed(key, selectedTime, !yes));
                    setState(() {});
                  },
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: yes
                          ? rose
                          : Theme.of(c).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${d.day}',
                          style: TextStyle(
                            color: yes ? Colors.white : null,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (count > 0)
                          Text(
                            '$count/${widget.med.times.length}',
                            style: TextStyle(
                              fontSize: 9,
                              color: yes ? Colors.white70 : rose,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum ScheduleActionType { edit, history, delete }

class ScheduleAction {
  const ScheduleAction(this.medication, this.type);
  final Medication medication;
  final ScheduleActionType type;
}

class ScheduleManager extends StatelessWidget {
  const ScheduleManager({super.key, required this.medications});
  final List<Medication> medications;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .72,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'All schedules',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const Text('Manage today’s and upcoming medication plans.'),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: medications.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, index) {
                final med = medications[index];
                final times = med.times
                    .map((time) => Medication.timeOf(time).format(context))
                    .join(', ');
                return Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                  decoration: BoxDecoration(
                    color: rose.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.medication_rounded, color: rose),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              med.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                            Text(times),
                            Text(
                              med.recurring
                                  ? '${med.days.length} recurring day${med.days.length == 1 ? '' : 's'}'
                                  : '${med.dates.length} specific date${med.dates.length == 1 ? '' : 's'}',
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<ScheduleActionType>(
                        onSelected: (type) =>
                            Navigator.pop(context, ScheduleAction(med, type)),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: ScheduleActionType.edit,
                            child: Text('Edit details'),
                          ),
                          PopupMenuItem(
                            value: ScheduleActionType.history,
                            child: Text('Taken history'),
                          ),
                          PopupMenuItem(
                            value: ScheduleActionType.delete,
                            child: Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class MultiDatePicker extends StatefulWidget {
  const MultiDatePicker({super.key, required this.initialDates});
  final List<String> initialDates;
  @override
  State<MultiDatePicker> createState() => _MultiDatePickerState();
}

class _MultiDatePickerState extends State<MultiDatePicker> {
  late DateTime month;
  late Set<String> selected;
  @override
  void initState() {
    super.initState();
    selected = widget.initialDates.toSet();
    final start = selected.isEmpty
        ? DateTime.now()
        : DateTime.parse(selected.first);
    month = DateTime(start.year, start.month);
  }

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    final days = DateTime(month.year, month.month + 1, 0).day;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          children: [
            Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Select specific dates',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text('Tap as many dates as you need'),
                    ],
                  ),
                ),
                if (selected.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(selected.clear),
                    child: const Text('Clear'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: violet.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: () => setState(
                      () => month = DateTime(month.year, month.month - 1),
                    ),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    DateFormat.yMMMM().format(month),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  IconButton(
                    onPressed: () => setState(
                      () => month = DateTime(month.year, month.month + 1),
                    ),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: List.generate(
                7,
                (index) => Expanded(
                  child: Center(
                    child: Text(
                      DateFormat.E().format(DateTime(2024, 1, index + 1)),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 7,
                  crossAxisSpacing: 7,
                ),
                itemCount: first.weekday - 1 + days,
                itemBuilder: (_, index) {
                  if (index < first.weekday - 1) return const SizedBox();
                  final date = DateTime(
                    month.year,
                    month.month,
                    index - first.weekday + 2,
                  );
                  final key = Medication.dateKey(date);
                  final isSelected = selected.contains(key);
                  return InkWell(
                    borderRadius: BorderRadius.circular(13),
                    onTap: () => setState(
                      () =>
                          isSelected ? selected.remove(key) : selected.add(key),
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? rose
                            : Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Text(
                        '${date.day}',
                        style: TextStyle(
                          color: isSelected ? Colors.white : null,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${selected.length} selected',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final result = selected.toList()..sort();
                    Navigator.pop(context, result);
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AlertBanner extends StatelessWidget {
  const AlertBanner({super.key, required this.status, required this.onFix});
  final AlertStatus status;
  final VoidCallback onFix;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.orange.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.orange.withValues(alpha: .28)),
    ),
    child: Row(
      children: [
        const Icon(Icons.warning_amber_rounded, color: Colors.orange),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            !status.notifications
                ? 'Notifications are off. Medicine alarms cannot appear.'
                : 'Precise alarms are off. Reminders may arrive late.',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        TextButton(onPressed: onFix, child: const Text('Fix')),
      ],
    ),
  );
}

class AlertCenterSheet extends StatefulWidget {
  const AlertCenterSheet({
    super.key,
    required this.loadStatus,
    required this.initialPreferences,
    required this.onEnable,
    required this.onSave,
    required this.onTest,
  });
  final Future<AlertStatus> Function() loadStatus;
  final AlarmPreferences initialPreferences;
  final Future<void> Function() onEnable, onTest;
  final Future<void> Function(AlarmPreferences) onSave;
  @override
  State<AlertCenterSheet> createState() => _AlertCenterSheetState();
}

class _AlertCenterSheetState extends State<AlertCenterSheet> {
  late Future<AlertStatus> status;
  late AlarmPreferences preferences;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    status = widget.loadStatus();
    preferences = widget.initialPreferences;
  }

  void refresh() {
    setState(() {
      status = widget.loadStatus();
    });
  }

  Future<void> applySettings() async {
    if (saving) return;
    setState(() => saving = true);
    await widget.onSave(preferences);
    if (!mounted) return;
    setState(() => saving = false);
    refresh();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Alarm settings applied.')));
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .88,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      children: [
        Center(
          child: Container(
            width: 42,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: .35),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Medicine alarm check',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          'Configure how long alarms run and how they get your attention.',
        ),
        const SizedBox(height: 16),
        FutureBuilder<AlertStatus>(
          future: status,
          builder: (_, snapshot) {
            final value = snapshot.data;
            return Column(
              children: [
                _StatusRow(
                  label: 'Notifications',
                  ready: value?.notifications ?? false,
                ),
                _StatusRow(
                  label: 'Precise alarm timing',
                  ready: value?.exact ?? false,
                ),
                _StatusRow(
                  label: '${value?.pending ?? 0} alarms scheduled',
                  ready: (value?.pending ?? 0) > 0,
                  neutral: (value?.pending ?? 0) == 0,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: violet.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: violet.withValues(alpha: .15)),
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Alert behavior',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Duration, vibration, and automatic display apply to Android. iOS follows its system alert rules.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: const ValueKey('alarm-duration'),
                  initialValue: preferences.durationSeconds,
                  decoration: const InputDecoration(
                    labelText: 'Alert duration',
                    prefixIcon: Icon(Icons.timer_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 30, child: Text('30 seconds')),
                    DropdownMenuItem(value: 60, child: Text('1 minute')),
                    DropdownMenuItem(value: 120, child: Text('2 minutes')),
                    DropdownMenuItem(value: 300, child: Text('5 minutes')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(
                        () => preferences = preferences.copyWith(
                          durationSeconds: value,
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const ValueKey('alarm-sound'),
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('Sound'),
                  subtitle: const Text(
                    'Uses Android alarm volume and plays while locked',
                  ),
                  value: preferences.sound,
                  onChanged: (value) => setState(
                    () => preferences = preferences.copyWith(sound: value),
                  ),
                ),
                SwitchListTile(
                  key: const ValueKey('alarm-vibrate'),
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.vibration_rounded),
                  title: const Text('Vibrate'),
                  value: preferences.vibrate,
                  onChanged: (value) => setState(
                    () => preferences = preferences.copyWith(vibrate: value),
                  ),
                ),
                SwitchListTile(
                  key: const ValueKey('alarm-auto-display'),
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.open_in_new_rounded),
                  title: const Text('Open alert automatically'),
                  subtitle: const Text(
                    'Show the full-screen alert when Android permits it',
                  ),
                  value: preferences.autoDisplay,
                  onChanged: (value) => setState(
                    () =>
                        preferences = preferences.copyWith(autoDisplay: value),
                  ),
                ),
                if (!preferences.sound && !preferences.vibrate)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.volume_off_rounded, color: Colors.orange),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'This alarm will be silent.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('apply-alarm-settings'),
            onPressed: saving ? null : applySettings,
            icon: const Icon(Icons.save_outlined),
            label: Text(saving ? 'Applying…' : 'Apply alarm settings'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () async {
              await widget.onEnable();
              refresh();
            },
            icon: const Icon(Icons.settings_rounded),
            label: const Text('Enable required access'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () async {
              await widget.onTest();
              refresh();
            },
            icon: const Icon(Icons.notifications_active_rounded),
            label: const Text('Send test alert now'),
          ),
        ),
      ],
    ),
  );
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.ready,
    this.neutral = false,
  });
  final String label;
  final bool ready, neutral;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    leading: Icon(
      neutral
          ? Icons.info_outline_rounded
          : ready
          ? Icons.check_circle_rounded
          : Icons.cancel_rounded,
      color: neutral
          ? violet
          : ready
          ? Colors.green
          : Colors.orange,
    ),
    title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}

class DoseAlarmPage extends StatefulWidget {
  const DoseAlarmPage({
    super.key,
    required this.medicineName,
    required this.instructions,
    required this.onTaken,
    required this.onSnooze,
    this.dismissHost,
    this.alarmPayload,
    this.notificationId,
    this.onBackgroundResolved,
  });
  final String medicineName, instructions;
  final Future<void> Function() onTaken, onSnooze;
  final Future<bool> Function()? dismissHost;
  final String? alarmPayload;
  final int? notificationId;
  final Future<void> Function()? onBackgroundResolved;
  @override
  State<DoseAlarmPage> createState() => _DoseAlarmPageState();
}

class _DoseAlarmPageState extends State<DoseAlarmPage>
    with WidgetsBindingObserver {
  bool working = false, allowPop = false;
  bool checkingResolution = false, dismissalStarted = false;
  Timer? resolutionTimer;
  late final DateTime openedAt;

  @override
  void initState() {
    super.initState();
    openedAt = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    _startResolutionChecks();
  }

  @override
  void dispose() {
    resolutionTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _startResolutionChecks();
  }

  void _startResolutionChecks() {
    if (widget.dismissHost == null ||
        widget.alarmPayload == null ||
        dismissalStarted) {
      return;
    }
    resolutionTimer?.cancel();
    var remainingChecks = 20;
    unawaited(_checkForBackgroundResolution());
    resolutionTimer = Timer.periodic(const Duration(milliseconds: 250), (
      timer,
    ) {
      if (--remainingChecks <= 0 || dismissalStarted) {
        timer.cancel();
      } else {
        unawaited(_checkForBackgroundResolution());
      }
    });
  }

  Future<void> _checkForBackgroundResolution() async {
    if (checkingResolution || dismissalStarted) return;
    checkingResolution = true;
    try {
      final resolved = await wasAlarmResolvedRecently(
        payload: widget.alarmPayload!,
        notificationId: widget.notificationId,
        since: openedAt.subtract(const Duration(seconds: 30)),
      );
      if (resolved && mounted) {
        dismissalStarted = true;
        resolutionTimer?.cancel();
        await widget.onBackgroundResolved?.call();
        await _dismissAlarm();
      }
    } catch (error) {
      debugPrint('Could not check resolved alarm state: $error');
    } finally {
      checkingResolution = false;
    }
  }

  Future<void> _dismissAlarm() async {
    var hostDismissed = false;
    try {
      hostDismissed = await widget.dismissHost?.call() ?? false;
    } catch (error) {
      debugPrint('Could not dismiss the alarm host: $error');
    }
    if (mounted && !hostDismissed) {
      setState(() => allowPop = true);
      Navigator.pop(context);
    }
  }

  Future<void> finish(bool taken) async {
    if (working) return;
    setState(() {
      working = true;
      dismissalStarted = true;
    });
    resolutionTimer?.cancel();
    try {
      taken ? await widget.onTaken() : await widget.onSnooze();
    } catch (error) {
      debugPrint('Could not finish alarm action: $error');
    } finally {
      if (mounted) await _dismissAlarm();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowPop,
    child: Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF381B3D), Color(0xFFB63368), Color(0xFF6D5AE8)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .16),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 2),
                  ),
                  child: const Icon(
                    Icons.medication_rounded,
                    size: 54,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 26),
                const Text(
                  'TIME FOR YOUR MEDICINE',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.medicineName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (widget.instructions.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    widget.instructions,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 17),
                  ),
                ],
                const Spacer(),
                const Text(
                  'Choose an action to stop this alert.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 58,
                  child: FilledButton.icon(
                    key: const ValueKey('dose-taken-button'),
                    onPressed: working ? null : () => finish(true),
                    icon: const Icon(Icons.check_rounded),
                    label: Text(working ? 'Please wait…' : 'I took it'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: rose,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 58,
                  child: OutlinedButton.icon(
                    key: const ValueKey('dose-snooze-button'),
                    onPressed: working ? null : () => finish(false),
                    icon: const Icon(Icons.snooze_rounded),
                    label: const Text('Remind me in 10 minutes'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
