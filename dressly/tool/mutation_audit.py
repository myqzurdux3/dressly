#!/usr/bin/env python3
"""Mutation audit for the Dart side: break the code, see which tests notice.

Same intent as backend/scripts/mutation_audit.py. Dart has no cheap AST tooling
here, so mutations are targeted textual edits declared per file — each one is a
plausible mistake a developer could actually make.

    python tool/mutation_audit.py
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (file, description, find, replace) — each must be a unique substring.
MUTATIONS = [
    # --- PagedList: paging arithmetic and guards ---
    ("lib/state/paged_list.dart", "offset always 0 (never advances)",
     "final offset = replace ? 0 : _items.length;", "final offset = 0;"),
    ("lib/state/paged_list.dart", "hasMore never becomes false",
     "_hasMore = page.length >= pageSize;", "_hasMore = true;"),
    ("lib/state/paged_list.dart", "concurrent loadMore guard removed",
     "if (_loading || !_hasMore) return;", "if (!_hasMore) return;"),
    ("lib/state/paged_list.dart", "stale-response guard removed",
     "if (generation != _generation) return; // superseded by a newer refresh",
     "if (false) return;"),
    ("lib/state/paged_list.dart", "refresh appends instead of replacing",
     "if (replace) _items.clear();", "if (false) _items.clear();"),
    ("lib/state/paged_list.dart", "replaceItem silently does nothing",
     "if (i == -1) return;\n    _items[i] = updated;",
     "if (i == -1) return;\n    // mutant: no write"),
    ("lib/state/paged_list.dart", "removeItem notifies even when nothing changed",
     "if (_items.length != before) notifyListeners();", "notifyListeners();"),
    ("lib/state/paged_list.dart", "items list is writable by callers",
     "List<T> get items => List.unmodifiable(_items);",
     "List<T> get items => _items;"),

    # --- ApiClient: headers, encoding, error mapping ---
    ("lib/services/api_client.dart", "auth header dropped",
     "if (token != null) 'Authorization': 'Bearer $token',", ""),
    ("lib/services/api_client.dart", "non-2xx no longer raises",
     "if (resp.statusCode >= 400) {", "if (false) {"),
    ("lib/services/api_client.dart", "backend `detail` message ignored",
     "detail = body['detail'].toString();", "// mutant: keep generic message"),
    ("lib/services/api_client.dart", "empty body no longer returns null",
     "if (resp.body.isEmpty) return null;", "if (false) return null;"),
    ("lib/services/api_client.dart", "JSON content-type dropped",
     "if (json) 'Content-Type': 'application/json',", ""),

    # --- i18n engine ---
    ("lib/l10n/app_text.dart", "French plural rule replaced by the English one",
     "return (count == 0 || count == 1) ? 'one' : 'other';",
     "return count == 1 ? 'one' : 'other';"),
    ("lib/l10n/app_text.dart", "placeholders no longer substituted",
     "out = out.replaceAll('{$name}', '$value');", "// mutant: no substitution"),
    ("lib/l10n/app_text.dart", "English fallback removed",
     "_strings[code]?[key] ?? _strings['en']?[key] ?? key",
     "_strings[code]?[key] ?? key"),
    ("lib/l10n/app_text.dart", "trOr ignores its fallback",
     "return v == key ? _fill(fallback, params) : _fill(v, params);",
     "return _fill(v, params);"),

    # --- models / URL building ---
    ("lib/models/cloth.dart", "thumbnail never preferred over the full image",
     "String? get thumbnailUrl => thumbUrl.isNotEmpty ? thumbUrl : displayUrl;",
     "String? get thumbnailUrl => displayUrl;"),
    ("lib/models/cloth.dart", "rejected image no longer falls back to original",
     "if (bgAccepted == 'rejected') return originalUrl;",
     "if (false) return originalUrl;"),
    ("lib/models/cloth.dart", "copyWith ignores isFavorite",
     "isFavorite: isFavorite ?? this.isFavorite,",
     "isFavorite: this.isFavorite,"),
    ("lib/models/outfit.dart", "cache-busting token dropped",
     "return '$base${sep}b=$bust';", "return base;"),

    # --- services: query building ---
    ("lib/services/clothes_service.dart", "limit never sent",
     "if (limit != null) 'limit=$limit',", ""),
    ("lib/services/clothes_service.dart", "offset sent even when zero",
     "if (limit != null && offset > 0) 'offset=$offset',",
     "if (limit != null) 'offset=$offset',"),
    ("lib/services/outfits_service.dart", "favorites ignores paging",
     "if (limit != null) 'limit=$limit',\n      if (limit != null && offset > 0) 'offset=$offset',",
     ""),
    # --- round 2: target the areas round 1 never touched ---
    ("lib/models/cloth.dart", "dress no longer fills the whole body",
     "if (category == 'dress') return {'top', 'mid', 'bottom'}; // fills the whole body",
     "if (category == 'dress') return {'top'};"),
    ("lib/models/cloth.dart", "isUpperBody forgets the outer layer",
     "return s.contains('top') || s.contains('mid') || s.contains('outer');",
     "return s.contains('top') || s.contains('mid');"),
    ("lib/models/cloth.dart", "conflict detection always says no",
     "outfitSlots(a).intersection(outfitSlots(b)).isNotEmpty;",
     "false;"),
    ("lib/models/cloth.dart", "unknown category no longer gets its own slot",
     "return {category}; // socks, underwear, bag", "return {}; // socks, underwear, bag"),
    ("lib/models/cloth.dart", "brand matched as substring, not whole word",
     "final hit = bl.contains(' ') ? lower.contains(bl) : words.contains(bl);",
     "final hit = lower.contains(bl);"),
    ("lib/models/cloth.dart", "user's own brands ignored",
     "for (final b in [...kKnownBrands, ...extra]) {",
     "for (final b in [...kKnownBrands]) {"),
    ("lib/models/cloth.dart", "empty name no longer short-circuits",
     "if (lower.trim().isEmpty) return null;", "if (false) return null;"),
    ("lib/models/cloth.dart", "category keyword priority reversed",
     "const List<MapEntry<String, List<String>>> _kCategoryKeywords = [",
     "final List<MapEntry<String, List<String>>> _kCategoryKeywords = _kRaw.reversed.toList();\nconst List<MapEntry<String, List<String>>> _kRaw = ["),
    ("lib/models/cloth.dart", "score defaults to 1 instead of 0",
     "score: json['score'] as int? ?? 0,", "score: json['score'] as int? ?? 1,"),
    ("lib/models/cloth.dart", "last_worn_at dropped on parse",
     "lastWornAt: json['last_worn_at'] as String?,", "lastWornAt: null,"),
    ("lib/models/cloth.dart", "enhance defaults changed",
     "enhanceMethod: (json['enhance_method'] ?? 'none') as String,",
     "enhanceMethod: (json['enhance_method'] ?? 'auto') as String,"),
    ("lib/models/cloth.dart", "copyWith loses the original's tags",
     "customTags: customTags ?? this.customTags,", "customTags: customTags ?? const [],"),
    ("lib/models/outfit.dart", "cloth order not preserved on parse",
     "clothIds: (json['cloth_ids'] as List?)?.map((e) => e as int).toList() ??",
     "clothIds: (json['cloth_ids'] as List?)?.map((e) => e as int).toList().reversed.toList() ??"),
    ("lib/models/outfit.dart", "withLinkedId also clobbers isFavorite",
     "        isFavorite: isFavorite,\n        wornToday: wornToday,",
     "        isFavorite: false,\n        wornToday: wornToday,"),
    ("lib/services/clothes_service.dart", "search no longer URL-encoded",
     "params.add('$key=${Uri.encodeQueryComponent(val)}');",
     "params.add('$key=$val');"),
    ("lib/services/clothes_service.dart", "min_score sent even when zero",
     "if (minScore != null && minScore! > 0) params.add('min_score=$minScore');",
     "if (minScore != null) params.add('min_score=$minScore');"),
    ("lib/services/clothes_service.dart", "clearSearch ignored",
     "search: clearSearch ? null : (search ?? this.search),",
     "search: search ?? this.search,"),
    ("lib/l10n/app_text.dart", "translationKeys reports nothing",
     "(_strings[code] ?? const {}).keys.toSet();", "<String>{};"),
    ("lib/l10n/app_text.dart", "placeholder scanner blind",
     "Set<String> placeholdersOf(String template) => RegExp(r'\\{(\\w+)\\}')",
     "Set<String> placeholdersOf(String template) => RegExp(r'NEVERMATCHES')"),
]


def run_tests() -> set:
    proc = subprocess.run(
        ["flutter", "test", "--reporter", "json"],
        cwd=ROOT, capture_output=True, text=True, timeout=1800,
    )
    names, failed = {}, set()
    for line in proc.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "testStart":
            names[ev["test"]["id"]] = ev["test"]["name"]
        elif ev.get("type") == "testDone" and ev.get("result") != "success":
            failed.add(names.get(ev["testID"], str(ev.get("testID"))))
    return {n for n in failed if not n.startswith("loading ")}


def main() -> int:
    print("baseline...", flush=True)
    base = run_tests()
    if base:
        print("baseline not green:", base)
        return 1

    kills, survivors = {}, []
    for rel, desc, find, repl in MUTATIONS:
        path = ROOT / rel
        original = path.read_text()
        if find not in original:
            print(f"  !! pattern not found, skipping: {rel} :: {desc}")
            continue
        path.write_text(original.replace(find, repl, 1))
        try:
            failed = run_tests()
        finally:
            path.write_text(original)
        if failed:
            for t in failed:
                kills[t] = kills.get(t, 0) + 1
        else:
            survivors.append(f"{rel} :: {desc}")
        print(f"  {desc[:52]:52} -> {len(failed):3} caught", flush=True)

    (ROOT / "mutation_report.json").write_text(
        json.dumps({"kills": kills, "survivors": survivors}, indent=2))
    print(f"\n{len(MUTATIONS)} mutants, {len(survivors)} survived unnoticed")
    for s in survivors:
        print("  SURVIVED:", s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
