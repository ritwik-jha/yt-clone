import 'package:flutter/material.dart';

import '../core/theme.dart';

/// The masthead logo: a red rounded play button and the app's name, laid out
/// like the mockup's wordmark.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.height = 20, this.showName = true});

  final double height;
  final bool showName;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Video Stream home',
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: height * 1.42,
            height: height,
            decoration: BoxDecoration(
              color: YtColors.red,
              borderRadius: BorderRadius.circular(height * 0.25),
            ),
            child: Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: height * 0.9,
            ),
          ),
          if (showName) ...[
            SizedBox(width: height * 0.2),
            Text(
              'VideoStream',
              style: TextStyle(
                fontSize: height * 0.95,
                fontWeight: FontWeight.w700,
                letterSpacing: -height * 0.06,
                height: 1,
                color: YtColors.textPrimary,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
