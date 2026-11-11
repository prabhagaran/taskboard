import 'package:flutter/material.dart';

import 'screens/calendar_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/notes_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/tasks_screen.dart';
import 'screens/today_screen.dart';
import 'services/store.dart';
import 'widgets/common.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final store = TaskStore()..onError = showMessage;
  store.onSynced = (count) => showMessage('Synced $count waiting change${count == 1 ? '' : 's'}');
  store.onConflict = (mine, theirs) => showAction(
        '"${theirs.title}" was changed somewhere else, so your edit wasn\'t saved.',
        'Keep mine',
        () => store.forceEdit(mine),
      );
  store.onNoteConflict = (mine, theirs) => showAction(
        '"${theirs.displayTitle}" was changed somewhere else, so your edit wasn\'t saved.',
        'Keep mine',
        () => store.forceEditNote(mine),
      );
  store.init();
  runApp(StoreScope(store: store, child: const TaskBoardApp()));
}

const _seed = Color(0xFF4F46E5);

/// Tablets and phones in landscape get a side rail instead of a bottom bar.
const _railWidth = 600.0;

const _destinations = [
  (Icons.today_outlined, Icons.today, 'Today'),
  (Icons.checklist_outlined, Icons.checklist, 'Tasks'),
  (Icons.sticky_note_2_outlined, Icons.sticky_note_2, 'Notes'),
  (Icons.calendar_month_outlined, Icons.calendar_month, 'Calendar'),
  (Icons.insights_outlined, Icons.insights, 'Dashboard'),
  (Icons.settings_outlined, Icons.settings, 'Settings'),
];

ThemeData _theme(Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: brightness),
      visualDensity: VisualDensity.standard,
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );

class TaskBoardApp extends StatelessWidget {
  const TaskBoardApp({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return MaterialApp(
      title: 'TaskBoard',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: store.themeMode,
      home: !store.ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : store.isConnected
              ? const HomeShell()
              : const SettingsScreen(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Pick up edits made in the sheet or on the website while the app was away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) StoreScope.of(context).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final pages = IndexedStack(
      index: _index,
      children: const [
        TodayScreen(),
        TasksScreen(),
        NotesScreen(),
        CalendarScreen(),
        DashboardScreen(),
        SettingsScreen(),
      ],
    );
    void select(int i) => setState(() => _index = i);

    if (MediaQuery.sizeOf(context).width >= _railWidth) {
      return Scaffold(
        body: Row(
          children: [
            SafeArea(
              child: NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: select,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final (icon, selected, label) in _destinations)
                    NavigationRailDestination(
                      icon: Icon(icon),
                      selectedIcon: Icon(selected),
                      label: Text(label),
                    ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: pages),
          ],
        ),
      );
    }
    return Scaffold(
      body: pages,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: select,
        destinations: [
          for (final (icon, selected, label) in _destinations)
            NavigationDestination(
              icon: Icon(icon),
              selectedIcon: Icon(selected),
              label: label,
            ),
        ],
      ),
    );
  }
}
