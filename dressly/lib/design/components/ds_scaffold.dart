import 'package:flutter/material.dart';

import '../ds.dart';

/// Page frame: theme background, no app bar, an optional floating
/// [DsTabBar] centred above the bottom edge. Scrollable bodies pad their
/// bottom by [bottomInset] so the last item can scroll clear of the bar.
class DsScaffold extends StatelessWidget {
  const DsScaffold({super.key, required this.body, this.tabBar, this.floating});

  /// Distance between the bar and the bottom safe area.
  static const double _barGap = 16;

  final Widget body;
  final DsTabBar? tabBar;

  /// Floating action shown above the tab bar.
  final Widget? floating;

  /// Bottom padding a scrollable body needs to clear the floating tab bar.
  static double bottomInset(BuildContext context) =>
      DsTabBar.height + _barGap * 2 + MediaQuery.paddingOf(context).bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.ds.colors.bg,
      extendBody: true,
      body: SafeArea(bottom: false, child: body),
      floatingActionButton: floating,
      bottomNavigationBar: tabBar == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: _barGap),
                child: Center(heightFactor: 1, child: tabBar),
              ),
            ),
    );
  }
}
