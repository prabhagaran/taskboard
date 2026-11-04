import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  bool _hideToken = true;
  String? _status;
  bool _statusIsError = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  // Tolerates pasting the whole "API token: ..." line from the Apps Script log.
  String get _cleanToken =>
      _token.text.replaceFirst(RegExp(r'^\s*(info\s+)?api token:\s*', caseSensitive: false), '').trim();

  String? _validate() {
    if (!_url.text.trim().startsWith('https://script.google.com/')) {
      return 'The URL should start with https://script.google.com/';
    }
    if (_cleanToken.isEmpty) return 'Enter the API token.';
    return null;
  }

  void _setStatus(String? text, {bool error = false}) => setState(() {
        _status = text;
        _statusIsError = error;
      });

  Future<void> _connect() async {
    final problem = _validate();
    if (problem != null) return _setStatus(problem, error: true);
    final store = StoreScope.of(context);
    final url = _url.text.trim();
    final token = _cleanToken;
    setState(() => _busy = true);
    _setStatus('Connecting…');
    try {
      final count = await store.testConnection(url, token);
      await store.connect(url, token);
      // On first run, connecting swaps this screen for the home shell.
      if (!mounted) return;
      _token.clear();
      _url.clear();
      _setStatus('Connected. $count task${count == 1 ? '' : 's'} in the sheet.');
    } on ApiException catch (e) {
      if (mounted) _setStatus(e.message, error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _disconnect() async {
    final store = StoreScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Disconnect?'),
        content: const Text(
          'This removes the URL, token and saved tasks from this phone. Your Google Sheet is not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed == true) await store.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(store.isConnected ? 'Settings' : 'Connect Google Sheet')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (store.isConnected) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.cloud_done_outlined, color: scheme.primary),
                title: const Text('Connected to Google Sheets'),
                subtitle: Text(
                  store.syncing ? 'Syncing…' : '${store.tasks.length} tasks',
                ),
                trailing: IconButton(
                  tooltip: 'Sync now',
                  icon: const Icon(Icons.sync),
                  onPressed: store.refresh,
                ),
              ),
              OutlinedButton.icon(
                onPressed: _disconnect,
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              ),
            ] else ...[
              Text(
                'Enter the Apps Script web app URL and the API token printed by setup(). '
                'The token is kept in encrypted storage on this phone.',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Web app URL',
                  hintText: 'https://script.google.com/macros/s/…/exec',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                obscureText: _hideToken,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API token',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _hideToken ? 'Show token' : 'Hide token',
                    icon: Icon(_hideToken ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _hideToken = !_hideToken),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: Text(_busy ? 'Connecting…' : 'Connect'),
              ),
            ],
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _status!,
                  style: TextStyle(color: _statusIsError ? scheme.error : scheme.primary),
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
    );
  }
}
