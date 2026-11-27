import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'constants.dart';

// Logo Hembus.in dipecah jadi 4 kepingan supaya bisa dianimasikan satu-satu.
const String _svgOrange =
    '''<svg width="40" height="40" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M14 2C16.7614 2 19 4.23858 19 7V14C19 15.1366 18.6194 16.1836 17.9805 17.0234C17.2703 16.3726 16.6313 15.2171 16.958 12.1758C17.2255 9.68628 17.3644 8.99731 16.4316 8.77539C13.6816 8.12262 11.819 10.3755 10.7295 12.3389C9.12721 16.1443 10.8425 18.0922 13.2168 19H7C4.23858 19 2 16.7614 2 14V7C2 4.23858 4.23858 2 7 2H14Z" fill="#E08A45"/></svg>''';

const String _svgYellow =
    '''<svg width="40" height="40" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M33 2C35.7614 2 38 4.23858 38 7V14C38 16.7614 35.7614 19 33 19H26C24.8588 19 23.8073 18.6172 22.9658 17.9736C23.6183 17.2674 24.7772 16.6357 27.8047 16.9609C30.2945 17.2285 30.9833 17.368 31.2051 16.4346C31.8578 13.6846 29.6049 11.8219 27.6416 10.7324C23.8646 9.14198 21.9166 10.8195 21 13.166V7C21 4.23858 23.2386 2 26 2H33Z" fill="#F2C14E"/></svg>''';

const String _svgLightBlue =
    '''<svg width="40" height="40" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M33 21C35.7614 21 38 23.2386 38 26V33C38 35.7614 35.7614 38 33 38H26C23.2386 38 21 35.7614 21 33V26C21 24.8648 21.3782 23.8178 22.0156 22.9785C22.7178 23.6328 23.3432 24.7945 23.0195 27.8076C22.752 30.2977 22.6122 30.9863 23.5459 31.208C26.2956 31.8603 28.1586 29.6078 29.248 27.6445C30.8403 23.8627 29.1552 21.9151 26.8037 21H33Z" fill="#A4C9FE"/></svg>''';

const String _svgBlue =
    '''<svg width="40" height="40" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M14 21C15.1305 21 16.1732 21.3752 17.0107 22.0078C16.3585 22.7144 15.2006 23.3478 12.1719 23.0225C9.68177 22.7549 8.9932 22.6152 8.77148 23.5488C8.11886 26.2988 10.3716 28.1615 12.335 29.251C16.1458 30.8556 18.0939 29.1325 19 26.7529V33C19 35.7614 16.7614 38 14 38H7C4.23858 38 2 35.7614 2 33V26C2 23.2386 4.23858 21 7 21H14Z" fill="#73AAFD"/></svg>''';

class SplashPage extends StatefulWidget {
  /// Halaman yang tampil setelah splash selesai.
  final Widget next;

  const SplashPage({super.key, required this.next});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  static const double _logo = 120;

  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _run();
  }

  Future<void> _run() async {
    await _c.forward();
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (context, animation, secondaryAnimation) => widget.next,
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // Nilai 0..1 untuk rentang waktu [begin, end] dari total animasi.
  double _t(double begin, double end, Curve curve) {
    final v = ((_c.value - begin) / (end - begin)).clamp(0.0, 1.0);
    return curve.transform(v);
  }

  // Satu kepingan logo: muncul dari tengah sambil berputar.
  Widget _tile(String svg, double begin) {
    final t = _t(begin, begin + 0.4, Curves.easeOutBack);
    final o = _t(begin, begin + 0.2, Curves.linear);
    return Opacity(
      opacity: o,
      child: Transform.rotate(
        angle: (1 - t) * -math.pi / 2,
        child: Transform.scale(
          scale: t,
          child: SvgPicture.string(svg, width: _logo, height: _logo),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final glow = _t(0.0, 0.5, Curves.easeOut);
            final pulse = 1 + 0.06 * math.sin(_t(0.5, 0.8, Curves.easeInOut) * math.pi);
            final textT = _t(0.55, 0.85, Curves.easeOutCubic);
            final tagT = _t(0.72, 1.0, Curves.easeOut);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 260,
                  height: 260,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Cahaya lembut di belakang logo
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              kAccent.withValues(alpha: 0.25 * glow),
                              kAccent.withValues(alpha: 0),
                            ],
                          ),
                        ),
                        child: const SizedBox(width: 260, height: 260),
                      ),
                      Transform.scale(
                        scale: pulse,
                        child: SizedBox(
                          width: _logo,
                          height: _logo,
                          child: Stack(
                            children: [
                              _tile(_svgOrange, 0.00),
                              _tile(_svgYellow, 0.08),
                              _tile(_svgLightBlue, 0.16),
                              _tile(_svgBlue, 0.24),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Opacity(
                  opacity: textT,
                  child: Transform.translate(
                    offset: Offset(0, 16 * (1 - textT)),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'Hembus'),
                          TextSpan(
                            text: '.in',
                            style: TextStyle(color: kAccent),
                          ),
                        ],
                      ),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 8 - 6 * textT,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Opacity(
                  opacity: tagT,
                  child: const Text(
                    'SMART EXHAUST FAN',
                    style: TextStyle(
                      color: kMuted,
                      fontSize: 12,
                      letterSpacing: 3,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}