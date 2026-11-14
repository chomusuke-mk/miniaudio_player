import 'package:flutter/material.dart';

class ResponsiveColumnGroup {
  final int flex;
  final List<Widget> children;

  const ResponsiveColumnGroup({
    required this.flex,
    required this.children,
  });
}

class ResponsiveGrid extends StatelessWidget {
  final List<ResponsiveColumnGroup> columns;
  final double spacing;
  final double breakpoint;

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

        // Mobile / narrow fluid 1-column layout (zero overflows)
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
