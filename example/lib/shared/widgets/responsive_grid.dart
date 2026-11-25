import 'package:material_ui/material_ui.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';
import 'studio_card.dart';

/// Column definition consumed by [ResponsiveGrid.multi].
class ResponsiveColumnGroup {
  /// Relative flex proportion allocated to this column when wide enough.
  final int flex;

  /// Vertical stack of child widgets hosted inside this column.
  final List<Widget> children;

  /// Creates a [ResponsiveColumnGroup] with relative [flex] and [children].
  const ResponsiveColumnGroup({
    required this.flex,
    required this.children,
  });
}

/// Adaptive grid displaying multi-column flex rows above [breakpoint] and
/// stacking child items interleaved in a single fluid column below it.
class ResponsiveGrid extends StatelessWidget {
  /// Ordered column groups laid out horizontally above [breakpoint].
  final List<ResponsiveColumnGroup> columns;

  /// Horizontal and vertical spacing between columns and stacked cards.
  final double spacing;

  /// Minimum width threshold at which horizontal columns activate.
  final double breakpoint;

  /// Creates a two-column [ResponsiveGrid] from [leftColumn] and [rightColumn]
  /// with configurable [spacing], [breakpoint], [leftFlex], and [rightFlex].
  ResponsiveGrid({
    super.key,
    required List<Widget> leftColumn,
    required List<Widget> rightColumn,
    this.spacing = 16.0,
    this.breakpoint = 960.0,
    int leftFlex = 1,
    int rightFlex = 2,
  }) : columns = [
         ResponsiveColumnGroup(flex: leftFlex, children: leftColumn),
         ResponsiveColumnGroup(flex: rightFlex, children: rightColumn),
       ];

  /// Creates a multi-column [ResponsiveGrid] from arbitrary [columns], [spacing],
  /// and [breakpoint].
  const ResponsiveGrid.multi({
    super.key,
    required this.columns,
    this.spacing = 16.0,
    this.breakpoint = 960.0,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= breakpoint) {
          final rowChildren = <Widget>[];
          for (int i = 0; i < columns.length; i++) {
            final col = columns[i];
            if (i > 0) {
              rowChildren.add(SizedBox(width: spacing));
            }
            rowChildren.add(
              Expanded(
                flex: col.flex,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _intersperse(
                    col.children,
                    SizedBox(height: spacing),
                  ),
                ),
              ),
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rowChildren,
          );
        }

        // Single-column fluid stack for narrow viewports.
        final combined = <Widget>[];
        int maxLen = 0;
        for (final col in columns) {
          if (col.children.length > maxLen) {
            maxLen = col.children.length;
          }
        }
        for (int i = 0; i < maxLen; i++) {
          for (final col in columns) {
            if (i < col.children.length) {
              combined.add(col.children[i]);
            }
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _intersperse(combined, SizedBox(height: spacing)),
        );
      },
    );
  }

  /// Inserts [separator] between consecutive items of [list].
  List<Widget> _intersperse(List<Widget> list, Widget separator) {
    if (list.isEmpty) return const [];
    final result = <Widget>[];
    for (int i = 0; i < list.length; i++) {
      result.add(list[i]);
      if (i < list.length - 1) {
        result.add(separator);
      }
    }
    return result;
  }
}

/// Preview illustrating a two-column [ResponsiveGrid] layout.
@StudioPreview(
  name: 'Responsive Grid (2-Column)',
  group: 'Shared Widgets',
  size: Size(720, 180),
)
Widget responsiveGridPreview() {
  return ResponsiveGrid(
    breakpoint: 500,
    leftColumn: const [
      StudioCard(
        title: 'LEFT (FLEX 1)',
        child: Text(
          'Left column slot',
          style: TextStyle(color: StudioColors.textSecondary, fontSize: 11),
        ),
      ),
    ],
    rightColumn: const [
      StudioCard(
        title: 'RIGHT (FLEX 2)',
        child: Text(
          'Right column slot',
          style: TextStyle(color: StudioColors.textSecondary, fontSize: 11),
        ),
      ),
    ],
  );
}
