// Take My Med — local-first medication reminders for mobile and web.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
  runApp(const TakeMyMedApp());
}

class Medication {
  Medication({
    required this.id,
    required this.name,
    required this.hour,
    required this.minute,
    required this.recurring,
    required this.days,
    required this.dates,
    this.notes = '',
    this.finished = false,
    List<String>? taken,
  }) : taken = taken ?? [];
  final int id;
  String name, notes;
  int hour, minute;
  bool recurring, finished;
  List<int> days;
  List<String> dates, taken;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'notes': notes,
    'hour': hour,
    'minute': minute,
    'recurring': recurring,
    'finished': finished,
    'days': days,
    'dates': dates,
    'taken': taken,
  };
  factory Medication.fromJson(Map<String, dynamic> j) => Medication(
    id: j['id'],
    name: j['name'],
    notes: j['notes'] ?? '',
    hour: j['hour'],
    minute: j['minute'],
    recurring: j['recurring'],
    finished: j['finished'] ?? false,
    days: List<int>.from(j['days'] ?? []),
    dates: List<String>.from(j['dates'] ?? []),
    taken: List<String>.from(j['taken'] ?? []),
  );
}

class Alerts {
  Alerts._();
  static final instance = Alerts._();
  final plugin = FlutterLocalNotificationsPlugin();
  Future<void> init() async {
    tz_data.initializeTimeZones();
    if (!kIsWeb) {
      try {
        tz.setLocalLocation(
          tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier),
        );
      } catch (_) {}
    }
    const a = AndroidInitializationSettings('@mipmap/ic_launcher');
    const i = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await plugin.initialize(
      settings: const InitializationSettings(android: a, iOS: i, macOS: i),
    );
    if (!kIsWeb) {
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestExactAlarmsPermission();
    }
  }

  Future<void> schedule(Medication m) async {
    await cancel(m.id);
    if (m.finished) return;
    const d = NotificationDetails(
      android: AndroidNotificationDetails(
        'medicine_alerts',
        'Medicine alerts',
        channelDescription: 'Time-sensitive medication reminders',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: false,
        playSound: true,
        enableVibration: true,
        actions: [
          AndroidNotificationAction('taken', 'Taken', showsUserInterface: true),
          AndroidNotificationAction(
            'snooze',
            'Remind me later',
            showsUserInterface: true,
          ),
        ],
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
        categoryIdentifier: 'medicine',
      ),
    );
    if (m.recurring) {
      for (final day in m.days) {
        var n = tz.TZDateTime.now(tz.local);
        var at = tz.TZDateTime(
          tz.local,
          n.year,
          n.month,
          n.day,
          m.hour,
          m.minute,
        );
        while (at.weekday != day || !at.isAfter(n)) {
          at = at.add(const Duration(days: 1));
        }
        await plugin.zonedSchedule(
          id: m.id * 10 + day,
          title: 'Time to take ${m.name}',
          body: m.notes.isEmpty
              ? 'Open Take My Med to confirm your dose'
              : m.notes,
          scheduledDate: at,
          notificationDetails: d,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: '${m.id}',
        );
      }
    } else {
      for (var x = 0; x < m.dates.length; x++) {
        final date = DateTime.parse(m.dates[x]);
        final at = tz.TZDateTime(
          tz.local,
          date.year,
          date.month,
          date.day,
          m.hour,
          m.minute,
        );
        if (at.isAfter(tz.TZDateTime.now(tz.local))) {
          await plugin.zonedSchedule(
            id: m.id * 100 + x,
            title: 'Time to take ${m.name}',
            body: m.notes.isEmpty
                ? 'Open Take My Med to confirm your dose'
                : m.notes,
            scheduledDate: at,
            notificationDetails: d,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            payload: '${m.id}',
          );
        }
      }
    }
  }

  Future<void> cancel(int id) async {
    for (var x = 0; x < 110; x++) {
      await plugin.cancel(id: id * 10 + x);
      await plugin.cancel(id: id * 100 + x);
    }
  }
}

class TakeMyMedApp extends StatefulWidget {
  const TakeMyMedApp({super.key});
  @override
  State<TakeMyMedApp> createState() => _AppState();
}

class _AppState extends State<TakeMyMedApp> {
  bool dark = false;
  @override
  Widget build(BuildContext c) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Take My Med',
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    theme: _theme(false),
    darkTheme: _theme(true),
    home: HomePage(dark: dark, toggle: () => setState(() => dark = !dark)),
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

class _HomeState extends State<HomePage> {
  List<Medication> meds = [];
  bool loaded = false;
  String get today => DateFormat('yyyy-MM-dd').format(DateTime.now());
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('medications');
    meds = raw == null
        ? []
        : (jsonDecode(raw) as List).map((e) => Medication.fromJson(e)).toList();
    final welcomed = p.getBool('welcomed') ?? false;
    if (mounted) {
      setState(() => loaded = true);
      if (!welcomed) {
        WidgetsBinding.instance.addPostFrameCallback((_) => welcome());
      }
    }
  }

  Future<void> save() async =>
      (await SharedPreferences.getInstance()).setString(
        'medications',
        jsonEncode(meds.map((m) => m.toJson()).toList()),
      );
  Future<void> welcome() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.favorite_rounded, color: rose, size: 44),
        title: const Text('Welcome to Take My Med'),
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
    final active = meds.where((m) => !m.finished).toList()
      ..sort(
        (a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute),
      );
    final taken = meds.where((m) => m.taken.contains(today)).length;
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
                                    'TAKE MY MED',
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
                          total: active.length,
                          next: active.firstOrNull,
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
                            Text('${active.length} scheduled'),
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
                            toggle: () {
                              setState(
                                () => active[i].taken.contains(today)
                                    ? active[i].taken.remove(today)
                                    : active[i].taken.add(today),
                              );
                              save();
                            },
                            edit: () => edit(active[i]),
                            history: () => history(active[i]),
                            delete: () => remove(active[i]),
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
      await Alerts.instance.schedule(r);
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
      changed: () {
        setState(() {});
        save();
      },
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
  final Medication? next;
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
                  next!.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                TimeOfDay(hour: next!.hour, minute: next!.minute).format(c),
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
  final VoidCallback toggle, edit, history, delete;
  @override
  Widget build(BuildContext c) {
    final done = med.taken.contains(today);
    return Material(
      color: Theme.of(c).colorScheme.surface.withValues(alpha: .86),
      borderRadius: BorderRadius.circular(23),
      child: InkWell(
        borderRadius: BorderRadius.circular(23),
        onTap: toggle,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
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
                      '${TimeOfDay(hour: med.hour, minute: med.minute).format(c)} • ${med.recurring ? 'Recurring' : '${med.dates.length} dates'}',
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
  late TimeOfDay time;
  late bool recurring, finished;
  late List<int> days;
  late List<String> dates;
  @override
  void initState() {
    super.initState();
    final m = widget.existing;
    name = TextEditingController(text: m?.name);
    notes = TextEditingController(text: m?.notes);
    time = TimeOfDay(hour: m?.hour ?? 8, minute: m?.minute ?? 0);
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
          ListTile(
            tileColor: rose.withValues(alpha: .1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            leading: const Icon(Icons.schedule, color: rose),
            title: Text(
              time.format(c),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            onTap: () async {
              final t = await showTimePicker(context: c, initialTime: time);
              if (t != null) setState(() => time = t);
            },
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
              children: [
                ...dates.map(
                  (d) => ListTile(
                    title: Text(DateFormat.yMMMd().format(DateTime.parse(d))),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => dates.remove(d)),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: addDate,
                  icon: const Icon(Icons.add),
                  label: const Text('Add a date'),
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
  Future<void> addDate() async {
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (d != null) {
      setState(() => dates.add(DateFormat('yyyy-MM-dd').format(d)));
    }
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
          id: DateTime.now().millisecondsSinceEpoch.remainder(20000000),
          name: '',
          hour: time.hour,
          minute: time.minute,
          recurring: recurring,
          days: days,
          dates: dates,
        );
    m
      ..name = name.text.trim()
      ..notes = notes.text.trim()
      ..hour = time.hour
      ..minute = time.minute
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
  final VoidCallback changed;
  @override
  State<History> createState() => _HistoryState();
}

class _HistoryState extends State<History> {
  late DateTime month;
  @override
  void initState() {
    super.initState();
    month = DateTime(DateTime.now().year, DateTime.now().month);
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
                    const Text('Tap a date to update its status'),
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
                final yes = widget.med.taken.contains(key);
                return InkWell(
                  onTap: () {
                    setState(
                      () => yes
                          ? widget.med.taken.remove(key)
                          : widget.med.taken.add(key),
                    );
                    widget.changed();
                  },
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: yes
                          ? rose
                          : Theme.of(c).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${d.day}',
                      style: TextStyle(
                        color: yes ? Colors.white : null,
                        fontWeight: FontWeight.w700,
                      ),
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
