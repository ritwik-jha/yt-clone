import 'package:flutter/material.dart';

import '../core/theme.dart';

class ChipOption<T> {
  const ChipOption(this.value, this.label);
  final T value;
  final String label;
}

/// A row of filter chips: white when selected, dark grey otherwise. Scrolls
/// sideways, with arrow buttons, when the chips don't fit.
class ChipBar<T> extends StatefulWidget {
  const ChipBar({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 24),
  });

  final List<ChipOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsets padding;

  @override
  State<ChipBar<T>> createState() => _ChipBarState<T>();
}

class _ChipBarState<T> extends State<ChipBar<T>> {
  final _scroll = ScrollController();
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _update() {
    if (!_scroll.hasClients || !mounted) return;
    final p = _scroll.position;
    final left = p.pixels > 0;
    final right = p.pixels < p.maxScrollExtent;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _page(int direction) {
    final p = _scroll.position;
    _scroll.animateTo(
      (p.pixels + direction * p.viewportDimension * 0.7).clamp(
        0,
        p.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: YtSizes.chipBarHeight,
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _update());
        return false;
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: widget.options.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final option = widget.options[i];
              return Center(
                child: FilterPill(
                  label: option.label,
                  selected: option.value == widget.selected,
                  onTap: () => widget.onSelected(option.value),
                ),
              );
            },
          ),
          if (_canLeft)
            Positioned(
              left: 0,
              child: _Arrow(left: true, onTap: () => _page(-1)),
            ),
          if (_canRight)
            Positioned(
              right: 0,
              child: _Arrow(left: false, onTap: () => _page(1)),
            ),
        ],
      ),
    ),
  );
}

class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? YtColors.textPrimary : YtColors.surfaceHigh,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? YtColors.textPrimary : YtColors.outline,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          height: YtSizes.chipHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 14,
                color: selected ? Colors.black : YtColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.left, required this.onTap});
  final bool left;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
    width: 56,
    height: YtSizes.chipBarHeight,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: left ? Alignment.centerLeft : Alignment.centerRight,
        end: left ? Alignment.centerRight : Alignment.centerLeft,
        colors: const [YtColors.surface, YtColors.surface, Color(0x00212121)],
        stops: const [0, 0.55, 1],
      ),
    ),
    alignment: left ? Alignment.centerLeft : Alignment.centerRight,
    child: IconButton(
      tooltip: left ? 'Previous' : 'Next',
      icon: Icon(left ? Icons.chevron_left : Icons.chevron_right),
      onPressed: onTap,
    ),
  );
}
