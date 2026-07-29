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
/// Deferring is enough to fix that; discarding is not wanted. Once a page has
/// been shown it stays built, so going back to it is instant and does not
/// refetch.
class LazyPage extends StatefulWidget {
  const LazyPage({super.key, required this.isActive, required this.builder});

  /// Whether this page is the one being shown (or is being swiped to).
  final bool isActive;

  /// Called at most once, the first time the page becomes active.
  final WidgetBuilder builder;

  @override
  State<LazyPage> createState() => _LazyPageState();
}

class _LazyPageState extends State<LazyPage> {
  bool _seen = false;

  @override
  void initState() {
    super.initState();
    _seen = widget.isActive;
  }

  @override
  void didUpdateWidget(LazyPage old) {
    super.didUpdateWidget(old);
    if (widget.isActive) _seen = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_seen) {
      // Nothing that loads, nothing that measures — just something to occupy
      // the slot until the page is wanted.
      return const ColoredBox(color: Colors.transparent);
    }
    return widget.builder(context);
  }
}
