import 'package:flutter/material.dart';

import '../state/paged_list.dart';

/// Grid backed by a [PagedList]: pull-to-refresh, infinite scroll, and a
/// trailing spinner while the next page loads.
///
/// Only the grid rebuilds when the list changes — the surrounding screen (app
/// bar, search field, filter chips) is outside the [AnimatedBuilder], so a
/// scroll-triggered page load no longer rebuilds it.
class PagedGrid<T> extends StatefulWidget {
  const PagedGrid({
    super.key,
    required this.controller,
    required this.itemBuilder,
    required this.gridDelegate,
    this.onRefresh,
    this.emptyBuilder,
    this.header,
    this.padding = const EdgeInsets.all(8),
  });

  final PagedList<T> controller;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final SliverGridDelegate gridDelegate;
  final Future<void> Function()? onRefresh;
  final WidgetBuilder? emptyBuilder;

  /// Optional row above the grid, given the number of items loaded so far.
  final Widget Function(int count)? header;
  final EdgeInsets padding;

  @override
  State<PagedGrid<T>> createState() => _PagedGridState<T>();
}

class _PagedGridState<T> extends State<PagedGrid<T>> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    // Fetch a screenful before the user reaches the bottom, so the next page is
    // usually already there by the time it would be needed.
    const trigger = 600.0;
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - trigger) {
      widget.controller.loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final items = widget.controller.items;

        if (items.isEmpty && widget.controller.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (items.isEmpty) {
          final empty = widget.emptyBuilder?.call(context) ??
              const SizedBox.shrink();
          return widget.onRefresh == null
              ? empty
              : RefreshIndicator(
                  onRefresh: widget.onRefresh!,
                  // Needs a scrollable for the gesture to exist at all.
                  child: ListView(children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.7,
                      child: empty,
                    ),
                  ]),
                );
        }

        final grid = CustomScrollView(
          controller: _scroll,
          slivers: [
            if (widget.header != null)
              SliverToBoxAdapter(child: widget.header!(items.length)),
            SliverPadding(
              padding: widget.padding,
              sliver: SliverGrid(
                gridDelegate: widget.gridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) => widget.itemBuilder(context, items[i]),
                  childCount: items.length,
                ),
              ),
            ),
            if (widget.controller.hasMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
          ],
        );

        return widget.onRefresh == null
            ? grid
            : RefreshIndicator(onRefresh: widget.onRefresh!, child: grid);
      },
    );
  }
}
