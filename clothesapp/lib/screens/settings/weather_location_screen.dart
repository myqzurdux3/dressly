import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../l10n/app_text.dart';
import '../../models/weather.dart';

/// Where to look up the forecast.
///
/// A town by name, not a pair of coordinates, and stored on the account — so
/// the app asks for no location permission and the answer does not change
/// because the phone spent a weekend elsewhere.
class WeatherLocationScreen extends StatefulWidget {
  const WeatherLocationScreen({super.key});

  @override
  State<WeatherLocationScreen> createState() => _WeatherLocationScreenState();
}

class _WeatherLocationScreenState extends State<WeatherLocationScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<PlaceHit> _hits = const [];
  WeatherLocation? _current;
  DayWeather? _preview;
  bool _searching = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final svc = weatherServiceOf(context);
    try {
      final loc = await svc.location();
      if (!mounted) return;
      setState(() {
        _current = loc;
        _loading = false;
      });
      if (loc.isSet) await _loadPreview();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Show today's forecast for the saved town: proof the setting works, which
  /// a latitude on its own never gives.
  Future<void> _loadPreview() async {
    final svc = weatherServiceOf(context);
    try {
      final got = await svc.forecast();
      if (mounted) setState(() => _preview = got);
    } catch (_) {
      if (mounted) setState(() => _preview = null);
    }
  }

  /// One search per pause in typing, not one per keystroke.
  void _onQueryChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() => _hits = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  Future<void> _search(String value) async {
    final svc = weatherServiceOf(context);
    final lang = Localizations.localeOf(context).languageCode;
    setState(() => _searching = true);
    try {
      final hits = await svc.searchPlaces(value, lang: lang);
      if (mounted) {
        setState(() {
          _hits = hits;
          _searching = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _hits = const [];
          _searching = false;
        });
      }
    }
  }

  Future<void> _choose(PlaceHit hit) async {
    final svc = weatherServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await svc.setLocation(
          lat: hit.lat, lon: hit.lon, place: hit.label);
      if (!mounted) return;
      setState(() {
        _current = saved;
        _hits = const [];
        _query.clear();
        _preview = null;
      });
      await _loadPreview();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(tr(context, 'weather.saved', {'place': hit.label}))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _clear() async {
    final svc = weatherServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final cleared = await svc.setLocation();
      if (!mounted) return;
      setState(() {
        _current = cleared;
        _preview = null;
      });
      messenger.showSnackBar(
          SnackBar(content: Text(tr(context, 'weather.cleared'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'weather.title'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(tr(context, 'weather.explain'),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                if (_current?.isSet == true) _currentCard(),
                const SizedBox(height: 8),
                TextField(
                  controller: _query,
                  onChanged: _onQueryChanged,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _search,
                  decoration: InputDecoration(
                    labelText: tr(context, 'weather.searchLabel'),
                    hintText: tr(context, 'weather.searchHint'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                if (_hits.isEmpty &&
                    !_searching &&
                    _query.text.trim().length >= 2)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(tr(context, 'weather.noMatch'),
                        style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ),
                for (final hit in _hits)
                  ListTile(
                    leading: const Icon(Icons.location_city_outlined),
                    title: Text(hit.name),
                    subtitle: Text(hit.label),
                    onTap: () => _choose(hit),
                  ),
              ],
            ),
    );
  }

  Widget _currentCard() {
    final theme = Theme.of(context);
    final preview = _preview;
    return Card(
      child: ListTile(
        leading: Icon(Icons.place, color: theme.colorScheme.primary),
        title: Text(_current!.place.isEmpty
            ? '${_current!.lat!.toStringAsFixed(2)}, '
                '${_current!.lon!.toStringAsFixed(2)}'
            : _current!.place),
        subtitle: preview != null && preview.available
            ? Text(tr(context, 'weather.todayIs', {
                'temp': preview.shortTemp,
                'mode': preview.isHot
                    ? tr(context, 'algo.hot')
                    : tr(context, 'algo.cold'),
              }))
            : Text(tr(context, 'weather.savedPlace')),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          tooltip: tr(context, 'weather.clear'),
          onPressed: _clear,
        ),
      ),
    );
  }
}
