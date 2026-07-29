import 'package:flutter/material.dart';

/// Builds its child only once the page has been visited, then keeps it.
///
/// A `PageView` with a `children:` list builds every page immediately. With
/// five tabs that meant opening the app fired every screen's requests at once —
/// the wardrobe, the outfit builder (including a full unpaginated `/clothes`),
/// the agenda, the favourites and the profile — and queued every one of their
/// images together. The image queue allows ten downloads at a time, so the
/// pictures on the screen actually being looked at waited behind dozens
/// belonging to screens that were not visible.
///
/// Deferring is only half of it. A PageView also DESTROYS a page once it
/// scrolls out of view, and rebuilds it — running initState again — on the way
/// back. The server log showed the cost plainly: five `/clothes` and four
/// `/models` within three seconds, all from the one screen that fetches both,
/// each `/clothes` returning the whole unpaginated wardrobe. Half a megabyte
/// re-downloaded for nothing.
///
/// So a page that has been shown is also kept alive. Returning to a tab is then
/// instant and issues no requests at all.
class LazyPage extends StatefulWidget {
  const LazyPage({super.key, required this.isActive, required this.builder});

  /// Whether this page is the one being shown (or is being swiped to).
  final bool isActive;

  /// Called at most once, the first time the page becomes active.
  final WidgetBuilder builder;

  @override
  State<LazyPage> createState() => _LazyPageState();
}

class _LazyPageState extends State<LazyPage>
    with AutomaticKeepAliveClientMixin {
  bool _seen = false;

  // Only worth keeping once there is something to keep; an unvisited page has
  // no state and should stay cheap.
  @override
  bool get wantKeepAlive => _seen;

  @override
  void initState() {
    super.initState();
    _seen = widget.isActive;
  }

  @override
  void didUpdateWidget(LazyPage old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !_seen) {
      _seen = true;
      updateKeepAlive();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);   // required by AutomaticKeepAliveClientMixin
    if (!_seen) {
      // Nothing that loads, nothing that measures — just something to occupy
      // the slot until the page is wanted.
      return const ColoredBox(color: Colors.transparent);
    }
    return widget.builder(context);
  }
}
