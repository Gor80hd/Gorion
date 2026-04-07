import 'package:flutter/material.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/home/widget/map_view.dart';
import 'package:gorion_clean/features/home/widget/servers_panel.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, this.animateOnMount = true});

  final bool animateOnMount;

  static const _mapContentPadding = EdgeInsets.fromLTRB(
    ServersPanelWidget.panelWidth + 32,
    32,
    32,
    32,
  );

  @override
  Widget build(BuildContext context) {
    final mapView = animateOnMount
        ? const PageReveal(
            duration: Duration(milliseconds: 220),
            offset: Offset(0, 0.02),
            child: MapView(contentPadding: _mapContentPadding),
          )
        : const MapView(contentPadding: _mapContentPadding);

    return Stack(
      fit: StackFit.expand,
      children: [
        mapView,
        const Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [ServersPanelWidget(), Spacer()],
        ),
      ],
    );
  }
}
