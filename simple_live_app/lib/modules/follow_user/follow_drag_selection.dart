import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

typedef FollowSelectionItemWrapper = Widget Function(String id, Widget child);

/// Range selection uses the displayed order and preserves selections outside
/// the drag. Item bounds are measured so both masonry cards and rows work.
class FollowDragSelection extends StatefulWidget {
  final bool enabled;
  final List<String> ids;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;
  final ScrollController scrollController;
  final Widget Function(FollowSelectionItemWrapper wrap) builder;

  const FollowDragSelection({
    super.key,
    required this.enabled,
    required this.ids,
    required this.selectedIds,
    required this.onChanged,
    required this.scrollController,
    required this.builder,
  });

  @override
  State<FollowDragSelection> createState() => _FollowDragSelectionState();
}

class _FollowDragSelectionState extends State<FollowDragSelection> {
  final _viewportKey = GlobalKey();
  final _itemKeys = <String, GlobalKey>{};
  Set<String> _before = {};
  int? _anchor;
  Offset? _pointer;
  bool _select = true;
  Timer? _edgeTimer;

  @override
  void didUpdateWidget(covariant FollowDragSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A status refresh/filter may change the displayed order mid-gesture.
    if (!widget.enabled || !listEquals(oldWidget.ids, widget.ids)) _stop();
    _itemKeys.removeWhere((id, _) => !widget.ids.contains(id));
  }

  Rect? _bounds(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  int? _indexAt(Offset point, {bool nearest = false}) {
    int? result;
    double distance = double.infinity;
    final viewport = _bounds(_viewportKey);
    for (var i = 0; i < widget.ids.length; i++) {
      final key = _itemKeys[widget.ids[i]];
      final rect = key == null ? null : _bounds(key);
      if (rect == null || viewport == null || !rect.overlaps(viewport)) continue;
      if (rect.contains(point)) return i;
      if (nearest) {
        final dx = point.dx - point.dx.clamp(rect.left, rect.right);
        final dy = point.dy - point.dy.clamp(rect.top, rect.bottom);
        final d = dx * dx + dy * dy;
        if (d < distance) {
          distance = d;
          result = i;
        }
      }
    }
    return result;
  }

  void _down(DragDownDetails details) {
    _stop();
    _anchor = _indexAt(details.globalPosition);
    _before = Set.of(widget.selectedIds);
    if (_anchor != null) _select = !_before.contains(widget.ids[_anchor!]);
  }

  void _update(Offset point) {
    if (_anchor == null) return;
    _pointer = point;
    final end = _indexAt(point, nearest: true);
    if (end == null) return;
    final first = end < _anchor! ? end : _anchor!;
    final last = end > _anchor! ? end : _anchor!;
    final range = widget.ids.sublist(first, last + 1);
    final selection = Set<String>.of(_before);
    if (_select) {
      selection.addAll(range);
    } else {
      selection.removeAll(range);
    }
    if (!setEquals(selection, widget.selectedIds)) widget.onChanged(selection);
  }

  void _start(DragStartDetails details) {
    _update(details.globalPosition);
    if (_anchor == null) return;
    _edgeTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final point = _pointer;
      final rect = _bounds(_viewportKey);
      final scroll = widget.scrollController;
      if (point == null || rect == null || !scroll.hasClients) return;
      const edge = 48.0;
      final double speed;
      if (point.dy < rect.top + edge) {
        speed = -12 * ((rect.top + edge - point.dy) / edge).clamp(0.0, 1.0);
      } else if (point.dy > rect.bottom - edge) {
        speed = 12 * ((point.dy - rect.bottom + edge) / edge).clamp(0.0, 1.0);
      } else {
        return;
      }
      final position = scroll.position;
      final next = (position.pixels + speed).clamp(position.minScrollExtent, position.maxScrollExtent);
      if (next == position.pixels) return;
      scroll.jumpTo(next);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _anchor != null && _pointer != null) _update(_pointer!);
      });
    });
  }

  void _stop() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _anchor = null;
    _pointer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _viewportKey,
      behavior: HitTestBehavior.translucent,
      supportedDevices: const {
        PointerDeviceKind.mouse,
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      },
      onPanDown: widget.enabled ? _down : null,
      onPanStart: widget.enabled ? _start : null,
      onPanUpdate: widget.enabled ? (details) => _update(details.globalPosition) : null,
      onPanEnd: widget.enabled ? (_) => _stop() : null,
      onPanCancel: widget.enabled ? _stop : null,
      child: widget.builder((id, child) => KeyedSubtree(
            key: _itemKeys.putIfAbsent(id, () => GlobalKey()),
            child: child,
          )),
    );
  }
}
