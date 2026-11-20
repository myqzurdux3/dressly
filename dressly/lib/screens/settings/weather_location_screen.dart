import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
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
        lat: hit.lat,
        lon: hit.lon,
        place: hit.label,
      );
      if (!mounted) return;
      setState(() {
        _current = saved;
        _hits = const [];
        _query.clear();
        _preview = null;
      });
      await _loadPreview();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr(context, 'weather.saved', {'place': hit.label})),
        ),
      );
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
        SnackBar(content: Text(tr(context, 'weather.cleared'))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final muted = ds.typo.label.copyWith(color: ds.colors.textMuted);
    return DsSubPage(
      title: tr(context, 'weather.title'),
      children: [
        if (_loading)
          Padding(
            padding: EdgeInsets.all(ds.space.xl),
            child: Center(
              child: CircularProgressIndicator(color: ds.colors.accent),
            ),
          )
        else ...[
          Text(tr(context, 'weather.explain'), style: muted),
          SizedBox(height: ds.space.m),
          if (_current?.isSet == true) _currentCard(),
          SizedBox(height: ds.space.xs),
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
                  ? Padding(
                      padding: EdgeInsets.all(ds.space.s),
                      child: const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
          ),
          SizedBox(height: ds.space.s),
          if (_hits.isEmpty && !_searching && _query.text.trim().length >= 2)
            Padding(
              padding: EdgeInsets.symmetric(vertical: ds.space.s),
              child: Text(tr(context, 'weather.noMatch'), style: muted),
            ),
          for (final hit in _hits)
            DsInfoRow(
              icon: Icons.location_city_outlined,
              title: hit.name,
              detail: hit.label,
              onTap: () => _choose(hit),
            ),
        ],
      ],
    );
  }

  Widget _currentCard() {
    final preview = _preview;
    return DsInfoRow(
      icon: Icons.place,
      title: _current!.place.isEmpty
          ? '${_current!.lat!.toStringAsFixed(2)}, '
                '${_current!.lon!.toStringAsFixed(2)}'
          : _current!.place,
      detail: preview != null && preview.available
          ? tr(context, 'weather.todayIs', {
              'temp': preview.shortTemp,
              'mode': preview.isHot
                  ? tr(context, 'algo.hot')
                  : tr(context, 'algo.cold'),
            })
          : tr(context, 'weather.savedPlace'),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: tr(context, 'weather.clear'),
        onPressed: _clear,
      ),
    );
  }
}
