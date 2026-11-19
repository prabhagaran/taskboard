import 'dart:math';

import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidePassword = true;
  String? _status;
  bool _statusIsError = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _setStatus(String? text, {bool error = false}) => setState(() {
    _status = text;
    _statusIsError = error;
  });

  Future<void> _signIn() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) return _setStatus('Enter your email and password.', error: true);
    final store = StoreScope.of(context);
    setState(() => _busy = true);
    _setStatus('Signing in…');
    try {
      await store.signIn(email, password);
      // On first run, signing in swaps this screen for the home shell.
      if (!mounted) return;
      _password.clear();
      _setStatus('Signed in as ${store.accountEmail}.');
    } on ApiException catch (e) {
      if (mounted) _setStatus(e.message, error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signOut() async {
    final store = StoreScope.of(context);
    final waiting = store.queue.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(
          waiting > 0
              ? '$waiting change${waiting == 1 ? ' hasn\'t' : 's haven\'t'} synced yet and will be lost. '
                    'Your other tasks stay in your account.'
              : 'This removes your saved tasks from this phone. They stay in your account.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed == true) await store.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(store.isConnected ? 'Settings' : 'Sign in')),
      body: SafeArea(
        child: AutofillGroup(
          child: ListView(
            padding: EdgeInsets.symmetric(
              horizontal: max(16, (MediaQuery.sizeOf(context).width - 640) / 2),
              vertical: 16,
            ),
            children: [
              if (store.isConnected) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.cloud_done_outlined, color: scheme.primary),
                  title: Text('Signed in as ${store.accountEmail}'),
                  subtitle: Text(store.syncing ? 'Syncing…' : '${store.tasks.length} tasks'),
                  trailing: IconButton(tooltip: 'Sync now', icon: const Icon(Icons.sync), onPressed: store.refresh),
                ),
                OutlinedButton.icon(onPressed: _signOut, icon: const Icon(Icons.logout), label: const Text('Sign out')),
              ] else ...[
                Text(
                  'Sign in with your TaskBoard account to sync with the website.',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: _hidePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _busy ? null : _signIn(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _hidePassword ? 'Show password' : 'Hide password',
                      icon: Icon(_hidePassword ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _hidePassword = !_hidePassword),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _busy ? null : _signIn, child: Text(_busy ? 'Signing in…' : 'Sign in')),
              ],
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_status!, style: TextStyle(color: _statusIsError ? scheme.error : scheme.primary)),
                ),
              if (store.isConnected)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Due date reminders'),
                    subtitle: const Text('A notification at 9:00 on days with tasks due'),
                    value: store.remindersOn,
                    onChanged: (on) async {
                      if (!await store.setReminders(on)) {
                        _setStatus('Allow notifications for TaskBoard in Android settings.', error: true);
                      }
                    },
                  ),
                ),
              const SizedBox(height: 28),
              Text('Theme', style: text.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {store.themeMode},
                onSelectionChanged: (s) => store.setTheme(s.first),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
