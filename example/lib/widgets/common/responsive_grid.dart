import 'package:flutter/material.dart';

class ResponsiveGrid extends StatelessWidget {
  final List<Widget> leftColumn;
  final List<Widget> rightColumn;
  final double spacing;
  final double breakpoint;

  const ResponsiveGrid({
    super.key,
    required this.leftColumn,
    required this.rightColumn,
    this.spacing = 16.0,
    this.breakpoint = 960.0,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= breakpoint) {
          // Desktop / Tablet Studio 2-Column Console Layout matching SVG
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _intersperse(leftColumn, SizedBox(height: spacing)),
                ),
              ),
              SizedBox(width: spacing),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _intersperse(rightColumn, SizedBox(height: spacing)),
                ),
              ),
            ],
          );
        } else {
          // Mobile Responsive Fluid 1-Column Layout (zero overflows)
          final combined = <Widget>[];
          final maxLen = leftColumn.length > rightColumn.length
              ? leftColumn.length
              : rightColumn.length;

          for (int i = 0; i < maxLen; i++) {
            if (i < leftColumn.length) combined.add(leftColumn[i]);
            if (i < rightColumn.length) combined.add(rightColumn[i]);
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _intersperse(combined, SizedBox(height: spacing)),
          );
        }
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
