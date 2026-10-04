import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Compact, non-interactive metadata; room taps and selection gestures belong
/// to the containing row/card. Details can show the same badges with wrapping.
class FollowTagBadges extends StatelessWidget {
  final List<String> tags;
  final String? activeTag;
  final bool wrap;

  const FollowTagBadges({super.key, required this.tags, this.activeTag, this.wrap = false});

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall!;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double widthOf(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width.ceilToDouble() + 12;
      painter.dispose();
      return width;
    }

    Widget badge(String label, {bool active = false, double? width}) {
      return Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: active ? theme.colorScheme.secondaryContainer : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          maxLines: wrap ? null : 1,
          overflow: wrap ? null : TextOverflow.ellipsis,
          style: style.copyWith(
            color: active ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      if (wrap) {
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final tag in tags)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: badge(tag, active: tag == activeTag),
              ),
          ],
        );
      }
      final available = constraints.maxWidth;
      final children = <Widget>[];
      var used = 0.0;
      var shown = 0;
      for (var i = 0; i < tags.length; i++) {
        final remaining = tags.length - i - 1;
        final reserve = remaining == 0 ? 0.0 : widthOf('+$remaining') + 4;
        final gap = i == 0 ? 0.0 : 4.0;
        final width = math.min(widthOf(tags[i]), 120.0);
        final room = available - used - gap - reserve;
        // Keep a readable first tag when possible; collapse the rest by count.
        if (room < width && (i > 0 || room < 40)) break;
        if (gap > 0) children.add(const SizedBox(width: 4));
        final badgeWidth = math.min(width, room);
        children.add(badge(tags[i], active: tags[i] == activeTag, width: badgeWidth));
        used += gap + badgeWidth;
        shown++;
      }
      if (shown < tags.length) {
        if (shown > 0) children.add(const SizedBox(width: 4));
        children.add(Flexible(child: badge('+${tags.length - shown}')));
      }
      return Tooltip(
        message: tags.join(' · '),
        triggerMode: TooltipTriggerMode.manual,
        excludeFromSemantics: true,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );
    });
  }
}
