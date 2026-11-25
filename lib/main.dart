import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Robo Dino Runner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF535353)),
        useMaterial3: true,
      ),
      home: const DinoGamePage(),
    );
  }
}

class DinoGamePage extends StatefulWidget {
  const DinoGamePage({super.key});

  @override
  State<DinoGamePage> createState() => _DinoGamePageState();
}

enum _GameStatus { waiting, running, crashed }

enum _ObstacleKind { smallCactus, largeCactus, pterodactyl }

class _DustParticle {
  _DustParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.life,
    required this.maxLife,
  });

  double x;
  double y;
  double vx;
  double vy;
  double size;
  double life;
  final double maxLife;
}

class _Cloud {
  _Cloud({required this.x, required this.y, required this.gap});

  double x;
  final double y;
  final double gap;
}

class _GroundBump {
  _GroundBump({
    required this.x,
    required this.width,
    required this.height,
    required this.yOffset,
    required this.isPebble,
  });

  double x;
  final double width;
  final double height;
  final double yOffset;
  final bool isPebble;
}

class _Obstacle {
  _Obstacle({
    required this.kind,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.count,
    required this.gap,
    required this.speedOffset,
    required this.collisionBoxes,
    this.variant = 0,
  });

  final _ObstacleKind kind;
  double x;
  final double y;
  final double width;
  final double height;
  final int count;
  final double gap;
  final double speedOffset;
  final List<Rect> collisionBoxes;
  final int variant;
  bool spawnedNext = false;
  int animFrame = 0;
  double animTimerMs = 0;
}

class _Star {
  _Star({required this.x, required this.y, required this.variant});
  double x;
  final double y;
  final int variant;
}

class _DinoGamePageState extends State<DinoGamePage>
    with SingleTickerProviderStateMixin {
  // Logical canvas matching Chrome Dino proportions (600x150).
  static const double _worldWidth = 600.0;
  static const double _worldHeight = 150.0;
  static const double _groundLineY = 130.0;
  static const double _groundBottomY = 140.0;

  // Player dimensions matching attached pixel matrices scaled to Chrome Dino size.
  static const double _pixelSize = 1.65;
  static const double _standWidth = 18 * _pixelSize; // ~29.7
  static const double _standHeight = 29 * _pixelSize; // ~47.85
  static const double _duckWidth = 20 * _pixelSize; // ~33.0
  static const double _duckHeight = 15 * _pixelSize; // ~24.75
  static const double _playerX = 50.0;
  static const double _groundPlayerY = _groundBottomY - _standHeight;

  // Physics constants adapted from Chrome Dino (60 FPS normalized).
  static const double _initialSpeed = 6.0;
  static const double _maxSpeed = 13.0;
  static const double _acceleration = 0.001;
  static const double _gravity = 0.6;
  static const double _initialJumpVelocity = -10.4;
  static const double _dropVelocity = -5.0;
  static const double _speedDropCoeff = 3.0;
  static const double _minJumpHeight = 30.0;
  static const double _maxJumpHeight = 30.0;
  static const double _clearTimeMs = 1800.0;
  static const double _invertDistance = 700.0;
  static const double _invertDurationMs = 12000.0;

  // Faceplant landing animation duration (seconds).
  static const double _faceplantDuration = 0.25;

  late final Ticker _ticker;
  final FocusNode _focusNode = FocusNode();
  final math.Random _rng = math.Random();

  Duration? _lastElapsed;
  _GameStatus _status = _GameStatus.waiting;

  // Player state.
  double _playerY = _groundPlayerY;
  double _jumpVelocity = 0.0;
  bool _jumping = false;
  bool _ducking = false;
  bool _downPressed = false;
  bool _speedDrop = false;
  bool _reachedMinHeight = false;
  double _faceplantTimer = 0.0;
  double _jumpAngle = 0.0;

  // Animations.
  double _runAnimTimerMs = 0.0;
  int _runFrame = 0;
  double _blinkTimerMs = 0.0;
  double _nextBlinkDelayMs = 2400.0;
  bool _isBlinking = false;
  double _crashTimeMs = 0.0;

  // Score & speed.
  double _speed = _initialSpeed;
  double _distanceRan = 0.0;
  int _score = 0;
  int _highScore = 0;
  double _runningTimeMs = 0.0;
  int _milestoneFlashScore = 0;
  double _milestoneFlashTimerMs = 0.0;

  // Night mode.
  bool _isNight = false;
  double _nightBlend = 0.0; // 0.0 = day, 1.0 = night
  double _nightTimerMs = 0.0;
  int _lastNightMilestone = 0;
  double _moonX = 520.0;
  final List<_Star> _stars = [];

  // World elements.
  final List<_Obstacle> _obstacles = [];
  final List<String> _obstacleHistory = [];
  final List<_Cloud> _clouds = [];
  final List<_GroundBump> _groundBumps = [];
  final List<_DustParticle> _dustParticles = [];

  @override
  void initState() {
    super.initState();
    _initEnvironment();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _initEnvironment() {
    _clouds.clear();
    _clouds.add(_Cloud(x: 420, y: 42, gap: 220));
    _clouds.add(_Cloud(x: 160, y: 64, gap: 260));

    _groundBumps.clear();
    double gx = 10;
    while (gx < _worldWidth + 60) {
      _groundBumps.add(_createGroundBump(gx));
      gx += 16 + _rng.nextDouble() * 34;
    }

    _placeStars();
  }

  _GroundBump _createGroundBump(double x) {
    final bool isPebble = _rng.nextDouble() > 0.35;
    return _GroundBump(
      x: x,
      width: isPebble ? (1.5 + _rng.nextDouble() * 3.5) : (8 + _rng.nextDouble() * 14),
      height: isPebble ? 1.5 : 2.0,
      yOffset: isPebble ? (3 + _rng.nextDouble() * 6) : -1.5,
      isPebble: isPebble,
    );
  }

  void _placeStars() {
    _stars.clear();
    for (int i = 0; i < 3; i++) {
      _stars.add(
        _Star(
          x: i * 200.0 + _rng.nextDouble() * 180.0,
          y: 16.0 + _rng.nextDouble() * 52.0,
          variant: i % 2,
        ),
      );
    }
  }

  void _onTick(Duration elapsed) {
    if (_lastElapsed == null) {
      _lastElapsed = elapsed;
      return;
    }

    final double rawDeltaMs = (elapsed - _lastElapsed!).inMicroseconds / 1000.0;
    _lastElapsed = elapsed;
    // Clamp delta to keep physics stable after window focus changes.
    final double deltaMs = rawDeltaMs.clamp(0.0, 48.0);
    final double dtFrames = deltaMs / (1000.0 / 60.0);

    setState(() {
      _updateDust(deltaMs / 1000.0);

      if (_status == _GameStatus.waiting) {
        _updateWaitingBlink(deltaMs);
        return;
      }

      if (_status == _GameStatus.crashed) {
        _crashTimeMs += deltaMs;
        // Let character drop to the ground face-first if crashed mid-air.
        if (_playerY < _groundPlayerY) {
          _jumpVelocity += _gravity * 1.4 * dtFrames;
          _playerY += _jumpVelocity * dtFrames;
          if (_playerY >= _groundPlayerY) {
            _playerY = _groundPlayerY;
            _spawnFaceplantDust(_playerX + _standWidth * 0.85);
          }
        }
        _jumpAngle = (_jumpAngle + (1.45 - _jumpAngle) * 0.35).clamp(-0.5, 1.45);
        return;
      }

      // Running state.
      _runningTimeMs += deltaMs;
      _updatePlayer(deltaMs, dtFrames);
      _updateEnvironment(deltaMs, dtFrames);
      _updateNightMode(deltaMs);
      _updateObstacles(deltaMs, dtFrames);
      _checkCollisions();

      if (_status == _GameStatus.running) {
        _distanceRan += _speed * dtFrames;
        if (_speed < _maxSpeed) {
          _speed = (_speed + _acceleration * dtFrames).clamp(_initialSpeed, _maxSpeed);
        }

        final int newScore = (_distanceRan * 0.025).floor();
        if (newScore > _score) {
          if (newScore > 0 && newScore % 100 == 0 && newScore != _milestoneFlashScore) {
            _milestoneFlashScore = newScore;
            _milestoneFlashTimerMs = 1000.0;
          }
          _score = newScore;
          if (_score > _highScore) {
            _highScore = _score;
          }
        }

        if (_milestoneFlashTimerMs > 0) {
          _milestoneFlashTimerMs -= deltaMs;
        }
      }
    });
  }

  void _updateWaitingBlink(double deltaMs) {
    _blinkTimerMs += deltaMs;
    if (!_isBlinking && _blinkTimerMs >= _nextBlinkDelayMs) {
      _isBlinking = true;
      _blinkTimerMs = 0.0;
    } else if (_isBlinking && _blinkTimerMs >= 160.0) {
      _isBlinking = false;
      _blinkTimerMs = 0.0;
      _nextBlinkDelayMs = 1500.0 + _rng.nextDouble() * 3500.0;
    }
  }

  void _updatePlayer(double deltaMs, double dtFrames) {
    if (_jumping) {
      final double step = _speedDrop
          ? _jumpVelocity * _speedDropCoeff * dtFrames
          : _jumpVelocity * dtFrames;
      _playerY += step;
      _jumpVelocity += _gravity * dtFrames;

      if (_playerY < _groundPlayerY - _minJumpHeight || _speedDrop) {
        _reachedMinHeight = true;
      }
      if (_playerY < _maxJumpHeight || _speedDrop) {
        if (_reachedMinHeight && _jumpVelocity < _dropVelocity) {
          _jumpVelocity = _dropVelocity;
        }
      }

      // Tilt back on launch, pitch nose-first as we fall to prepare the faceplant!
      if (_jumpVelocity < 0) {
        _jumpAngle = -0.16;
      } else {
        final double fallT = (_jumpVelocity / 11.0).clamp(0.0, 1.0);
        _jumpAngle = -0.16 + fallT * 1.15; // Up to ~1.0 rad nose-down
      }

      if (_playerY >= _groundPlayerY) {
        _playerY = _groundPlayerY;
        _jumping = false;
        _jumpVelocity = 0.0;
        _reachedMinHeight = false;

        if (_downPressed) {
          // Speed drop directly into ducking pose.
          _speedDrop = false;
          _ducking = true;
          _faceplantTimer = 0.0;
          _jumpAngle = 0.0;
          _spawnFaceplantDust(_playerX + _duckWidth * 0.7);
        } else {
          // Trigger the hilarious faceplant landing!
          _speedDrop = false;
          _faceplantTimer = _faceplantDuration;
          _jumpAngle = 1.1;
          _spawnFaceplantDust(_playerX + _standWidth * 0.85);
        }
      }
    } else {
      _ducking = _downPressed;

      if (_faceplantTimer > 0 && !_ducking) {
        _faceplantTimer = (_faceplantTimer - deltaMs / 1000.0).clamp(0.0, _faceplantDuration);
        final double t = 1.0 - (_faceplantTimer / _faceplantDuration);
        if (t < 0.42) {
          // Slam face-first onto the ground!
          final double slamT = Curves.easeOut.transform(t / 0.42);
          _jumpAngle = 1.1 + slamT * 0.34; // ~1.44 rad (~82 deg)
        } else {
          // Spring back upright onto the wheel!
          final double recoverT = Curves.easeOutBack.transform(((t - 0.42) / 0.58).clamp(0.0, 1.0));
          _jumpAngle = 1.44 * (1.0 - recoverT);
        }
      } else {
        _jumpAngle = 0.0;
      }

      _runAnimTimerMs += deltaMs;
      final double frameRateMs = _ducking ? 110.0 : 85.0;
      if (_runAnimTimerMs >= frameRateMs) {
        _runFrame = 1 - _runFrame;
        _runAnimTimerMs = 0.0;
      }
    }
  }

  void _spawnFaceplantDust(double originX) {
    for (int i = 0; i < 6; i++) {
      _dustParticles.add(
        _DustParticle(
          x: originX + (_rng.nextDouble() - 0.3) * 10.0,
          y: _groundBottomY - 1.5 - _rng.nextDouble() * 4.0,
          vx: (_rng.nextDouble() - 0.15) * 70.0,
          vy: -18.0 - _rng.nextDouble() * 38.0,
          size: 1.6 + _rng.nextDouble() * 2.0,
          life: 0.32 + _rng.nextDouble() * 0.18,
          maxLife: 0.5,
        ),
      );
    }
  }

  void _updateDust(double dtSec) {
    for (int i = _dustParticles.length - 1; i >= 0; i--) {
      final _DustParticle p = _dustParticles[i];
      p.x += p.vx * dtSec;
      p.y += p.vy * dtSec;
      p.vy += 120.0 * dtSec;
      p.life -= dtSec;
      if (p.life <= 0) {
        _dustParticles.removeAt(i);
      }
    }
  }

  void _updateEnvironment(double deltaMs, double dtFrames) {
    // Scroll ground bumps.
    final double scroll = _speed * dtFrames;
    for (final _GroundBump bump in _groundBumps) {
      bump.x -= scroll;
      if (bump.x + bump.width < 0) {
        bump.x = _worldWidth + _rng.nextDouble() * 40.0;
      }
    }

    // Scroll clouds.
    final double cloudScroll = 0.2 * _speed * dtFrames * 0.25;
    for (int i = _clouds.length - 1; i >= 0; i--) {
      _clouds[i].x -= cloudScroll;
      if (_clouds[i].x < -60) {
        _clouds.removeAt(i);
      }
    }
    if (_clouds.isEmpty ||
        (_clouds.length < 5 && (_worldWidth - _clouds.last.x) > _clouds.last.gap)) {
      _clouds.add(
        _Cloud(
          x: _worldWidth + 20,
          y: 26.0 + _rng.nextDouble() * 46.0,
          gap: 120.0 + _rng.nextDouble() * 240.0,
        ),
      );
    }
  }

  void _updateNightMode(double deltaMs) {
    final int currentBucket = (_score / _invertDistance).floor();
    if (!_isNight && _score > 0 && currentBucket > _lastNightMilestone) {
      _isNight = true;
      _lastNightMilestone = currentBucket;
      _nightTimerMs = 0.0;
    }

    if (_isNight) {
      _nightTimerMs += deltaMs;
      if (_nightTimerMs >= _invertDurationMs) {
        _isNight = false;
        _nightTimerMs = 0.0;
      }
    }

    final double target = _isNight ? 1.0 : 0.0;
    final double step = deltaMs / 750.0;
    if (_nightBlend < target) {
      _nightBlend = (_nightBlend + step).clamp(0.0, 1.0);
    } else if (_nightBlend > target) {
      _nightBlend = (_nightBlend - step).clamp(0.0, 1.0);
    }

    if (_nightBlend > 0.02) {
      _moonX -= 0.25 * (deltaMs / 16.666);
      if (_moonX < -30) {
        _moonX = _worldWidth + 20;
      }
      for (final _Star s in _stars) {
        s.x -= 0.3 * (deltaMs / 16.666);
        if (s.x < -12) {
          s.x = _worldWidth + _rng.nextDouble() * 40;
        }
      }
    }
  }

  void _updateObstacles(double deltaMs, double dtFrames) {
    if (_runningTimeMs < _clearTimeMs) {
      return;
    }

    for (int i = _obstacles.length - 1; i >= 0; i--) {
      final _Obstacle obs = _obstacles[i];
      obs.x -= (_speed + obs.speedOffset) * dtFrames;

      if (obs.kind == _ObstacleKind.pterodactyl) {
        obs.animTimerMs += deltaMs;
        if (obs.animTimerMs >= 165.0) {
          obs.animFrame = 1 - obs.animFrame;
          obs.animTimerMs = 0.0;
        }
      }

      if (obs.x + obs.width < -10) {
        _obstacles.removeAt(i);
      }
    }

    if (_obstacles.isEmpty) {
      _spawnObstacle();
    } else {
      final _Obstacle last = _obstacles.last;
      if (!last.spawnedNext && (last.x + last.width + last.gap) < _worldWidth) {
        last.spawnedNext = true;
        _spawnObstacle();
      }
    }
  }

  void _spawnObstacle() {
    final List<_ObstacleKind> available = [
      _ObstacleKind.smallCactus,
      _ObstacleKind.largeCactus,
      if (_speed >= 8.5) _ObstacleKind.pterodactyl,
    ];

    _ObstacleKind chosen = available[_rng.nextInt(available.length)];
    // Prevent 3 identical obstacles in a row.
    if (_obstacleHistory.length >= 2 &&
        _obstacleHistory[0] == chosen.name &&
        _obstacleHistory[1] == chosen.name) {
      final List<_ObstacleKind> others = available.where((k) => k != chosen).toList();
      if (others.isNotEmpty) {
        chosen = others[_rng.nextInt(others.length)];
      }
    }

    _obstacleHistory.insert(0, chosen.name);
    if (_obstacleHistory.length > 2) {
      _obstacleHistory.removeLast();
    }

    late final _Obstacle obs;
    switch (chosen) {
      case _ObstacleKind.smallCactus:
        final int count = _speed >= 4.0 ? (1 + _rng.nextInt(3)) : 1;
        const double unitW = 17.0;
        const double h = 35.0;
        final double totalW = unitW * count;
        final double minGap = totalW * _speed + 120.0 * 0.6;
        obs = _Obstacle(
          kind: chosen,
          x: _worldWidth + 20,
          y: _groundBottomY - h,
          width: totalW,
          height: h,
          count: count,
          gap: minGap + _rng.nextDouble() * (minGap * 0.5),
          speedOffset: 0,
          variant: _rng.nextInt(3),
          collisionBoxes: [
            Rect.fromLTWH(2, 6, totalW - 4, h - 6),
          ],
        );
      case _ObstacleKind.largeCactus:
        final int count = _speed >= 7.0 ? (1 + _rng.nextInt(3)) : 1;
        const double unitW = 24.0;
        const double h = 48.0;
        final double totalW = unitW * count;
        final double minGap = totalW * _speed + 120.0 * 0.6;
        obs = _Obstacle(
          kind: chosen,
          x: _worldWidth + 20,
          y: _groundBottomY - h,
          width: totalW,
          height: h,
          count: count,
          gap: minGap + _rng.nextDouble() * (minGap * 0.5),
          speedOffset: 0,
          variant: _rng.nextInt(2),
          collisionBoxes: [
            Rect.fromLTWH(3, 5, totalW - 6, h - 5),
          ],
        );
      case _ObstacleKind.pterodactyl:
        const List<double> heights = [100.0, 75.0, 52.0];
        final double y = heights[_rng.nextInt(heights.length)];
        const double w = 44.0;
        const double h = 36.0;
        final double minGap = w * _speed + 150.0 * 0.6;
        obs = _Obstacle(
          kind: chosen,
          x: _worldWidth + 20,
          y: y,
          width: w,
          height: h,
          count: 1,
          gap: minGap + _rng.nextDouble() * (minGap * 0.5),
          speedOffset: _rng.nextBool() ? 0.7 : -0.7,
          collisionBoxes: const [
            Rect.fromLTWH(8, 12, 26, 12),
            Rect.fromLTWH(16, 8, 12, 18),
          ],
        );
    }

    _obstacles.add(obs);
  }

  void _checkCollisions() {
    if (_obstacles.isEmpty) return;

    final List<Rect> playerBoxes = _ducking
        ? [
            Rect.fromLTWH(
              _playerX + 3,
              _groundBottomY - _duckHeight + 3,
              _duckWidth - 6,
              _duckHeight - 5,
            ),
          ]
        : [
            Rect.fromLTWH(_playerX + 6, _playerY + 4, _standWidth - 10, 22),
            Rect.fromLTWH(_playerX + 5, _playerY + 26, _standWidth - 12, _standHeight - 28),
          ];

    for (final _Obstacle obs in _obstacles) {
      final Rect obsOuter = Rect.fromLTWH(obs.x, obs.y, obs.width, obs.height);
      final Rect playerOuter = _ducking
          ? Rect.fromLTWH(_playerX, _groundBottomY - _duckHeight, _duckWidth, _duckHeight)
          : Rect.fromLTWH(_playerX, _playerY, _standWidth, _standHeight);

      if (!playerOuter.overlaps(obsOuter)) continue;

      for (final Rect pBox in playerBoxes) {
        for (final Rect oBox in obs.collisionBoxes) {
          final Rect worldOBox = oBox.shift(Offset(obs.x, obs.y));
          if (pBox.overlaps(worldOBox)) {
            _status = _GameStatus.crashed;
            _crashTimeMs = 0.0;
            _faceplantTimer = 0.0;
            _jumpAngle = 1.2;
            _spawnFaceplantDust(_playerX + _standWidth * 0.85);
            return;
          }
        }
      }
    }
  }

  void _triggerJump() {
    if (_status == _GameStatus.crashed) {
      if (_crashTimeMs > 280.0) {
        _resetGame();
      }
      return;
    }

    if (_status == _GameStatus.waiting) {
      _status = _GameStatus.running;
    }

    if (!_jumping) {
      _jumping = true;
      _ducking = false;
      _faceplantTimer = 0.0;
      _reachedMinHeight = false;
      _speedDrop = false;
      _jumpVelocity = _initialJumpVelocity - (_speed / 12.0);
    }
  }

  void _releaseJump() {
    if (_jumping && _reachedMinHeight && _jumpVelocity < _dropVelocity) {
      _jumpVelocity = _dropVelocity;
    }
  }

  void _setDuckPressed(bool pressed) {
    _downPressed = pressed;
    if (_status != _GameStatus.running) return;

    if (pressed && _jumping) {
      _speedDrop = true;
      if (_jumpVelocity < 1.0) {
        _jumpVelocity = 1.0;
      }
    } else if (!pressed && _ducking) {
      _ducking = false;
    }
  }

  void _resetGame() {
    setState(() {
      _status = _GameStatus.running;
      _playerY = _groundPlayerY;
      _jumpVelocity = 0.0;
      _jumping = false;
      _ducking = false;
      _downPressed = false;
      _speedDrop = false;
      _reachedMinHeight = false;
      _faceplantTimer = 0.0;
      _jumpAngle = 0.0;
      _speed = _initialSpeed;
      _distanceRan = 0.0;
      _score = 0;
      _runningTimeMs = 0.0;
      _milestoneFlashScore = 0;
      _milestoneFlashTimerMs = 0.0;
      _isNight = false;
      _nightBlend = 0.0;
      _nightTimerMs = 0.0;
      _lastNightMilestone = 0;
      _obstacles.clear();
      _obstacleHistory.clear();
      _dustParticles.clear();
      _initEnvironment();
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final LogicalKeyboardKey key = event.logicalKey;
    final bool isJumpKey =
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.keyW;
    final bool isDuckKey =
        key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.keyS;
    final bool isRestartKey = key == LogicalKeyboardKey.enter;

    if (event is KeyDownEvent) {
      if (isJumpKey) {
        _triggerJump();
        return KeyEventResult.handled;
      }
      if (isDuckKey) {
        _setDuckPressed(true);
        return KeyEventResult.handled;
      }
      if (isRestartKey && _status == _GameStatus.crashed) {
        _resetGame();
        return KeyEventResult.handled;
      }
    } else if (event is KeyUpEvent) {
      if (isJumpKey) {
        _releaseJump();
        return KeyEventResult.handled;
      }
      if (isDuckKey) {
        _setDuckPressed(false);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final Color bgColor = Color.lerp(
      const Color(0xFFF7F7F7),
      const Color(0xFF141414),
      _nightBlend,
    )!;
    final Color inkColor = Color.lerp(
      const Color(0xFF535353),
      const Color(0xFFE5E5E5),
      _nightBlend,
    )!;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: bgColor,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'ROBO DINO RUNNER',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      letterSpacing: 3,
                      color: inkColor,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 780),
                    child: AspectRatio(
                      aspectRatio: _worldWidth / _worldHeight,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (_) {
                          _focusNode.requestFocus();
                          _triggerJump();
                        },
                        onTapUp: (_) => _releaseJump(),
                        onTapCancel: _releaseJump,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: inkColor.withValues(alpha: 0.2),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6.5),
                            child: CustomPaint(
                              painter: _DinoGamePainter(
                                status: _status,
                                playerX: _playerX,
                                playerY: _playerY,
                                standWidth: _standWidth,
                                standHeight: _standHeight,
                                duckWidth: _duckWidth,
                                duckHeight: _duckHeight,
                                pixelSize: _pixelSize,
                                groundLineY: _groundLineY,
                                groundBottomY: _groundBottomY,
                                jumping: _jumping,
                                ducking: _ducking,
                                runFrame: _runFrame,
                                isBlinking: _isBlinking,
                                jumpAngle: _jumpAngle,
                                faceplantTimer: _faceplantTimer,
                                faceplantDuration: _faceplantDuration,
                                score: _score,
                                highScore: _highScore,
                                milestoneFlashScore: _milestoneFlashScore,
                                milestoneFlashTimerMs: _milestoneFlashTimerMs,
                                nightBlend: _nightBlend,
                                moonX: _moonX,
                                stars: _stars,
                                clouds: _clouds,
                                groundBumps: _groundBumps,
                                obstacles: _obstacles,
                                dustParticles: _dustParticles,
                              ),
                              size: Size.infinite,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Touch / Mouse controls for Duck & Jump.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ControlPadButton(
                        label: 'AGACHAR',
                        icon: Icons.keyboard_arrow_down_rounded,
                        inkColor: inkColor,
                        onPressStart: () => _setDuckPressed(true),
                        onPressEnd: () => _setDuckPressed(false),
                      ),
                      const SizedBox(width: 18),
                      _ControlPadButton(
                        label: _status == _GameStatus.crashed ? 'REINICIAR' : 'PULAR',
                        icon: _status == _GameStatus.crashed
                            ? Icons.refresh_rounded
                            : Icons.keyboard_arrow_up_rounded,
                        inkColor: inkColor,
                        onPressStart: _triggerJump,
                        onPressEnd: _releaseJump,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _status == _GameStatus.waiting
                        ? 'Pressione ESPAÇO / ↑ ou toque para começar'
                        : 'ESPAÇO / ↑ Pular   •   ↓ Agachar / Cair rápido',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: inkColor.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlPadButton extends StatefulWidget {
  const _ControlPadButton({
    required this.label,
    required this.icon,
    required this.inkColor,
    required this.onPressStart,
    required this.onPressEnd,
  });

  final String label;
  final IconData icon;
  final Color inkColor;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  @override
  State<_ControlPadButton> createState() => _ControlPadButtonState();
}

class _ControlPadButtonState extends State<_ControlPadButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        widget.onPressStart();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onPressEnd();
      },
      onTapCancel: () {
        setState(() => _pressed = false);
        widget.onPressEnd();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 60),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: _pressed
                ? widget.inkColor.withValues(alpha: 0.14)
                : widget.inkColor.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.inkColor.withValues(alpha: 0.35),
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: widget.inkColor, size: 22),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  letterSpacing: 1,
                  color: widget.inkColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DinoGamePainter extends CustomPainter {
  _DinoGamePainter({
    required this.status,
    required this.playerX,
    required this.playerY,
    required this.standWidth,
    required this.standHeight,
    required this.duckWidth,
    required this.duckHeight,
    required this.pixelSize,
    required this.groundLineY,
    required this.groundBottomY,
    required this.jumping,
    required this.ducking,
    required this.runFrame,
    required this.isBlinking,
    required this.jumpAngle,
    required this.faceplantTimer,
    required this.faceplantDuration,
    required this.score,
    required this.highScore,
    required this.milestoneFlashScore,
    required this.milestoneFlashTimerMs,
    required this.nightBlend,
    required this.moonX,
    required this.stars,
    required this.clouds,
    required this.groundBumps,
    required this.obstacles,
    required this.dustParticles,
  });

  final _GameStatus status;
  final double playerX;
  final double playerY;
  final double standWidth;
  final double standHeight;
  final double duckWidth;
  final double duckHeight;
  final double pixelSize;
  final double groundLineY;
  final double groundBottomY;
  final bool jumping;
  final bool ducking;
  final int runFrame;
  final bool isBlinking;
  final double jumpAngle;
  final double faceplantTimer;
  final double faceplantDuration;
  final int score;
  final int highScore;
  final int milestoneFlashScore;
  final double milestoneFlashTimerMs;
  final double nightBlend;
  final double moonX;
  final List<_Star> stars;
  final List<_Cloud> clouds;
  final List<_GroundBump> groundBumps;
  final List<_Obstacle> obstacles;
  final List<_DustParticle> dustParticles;

  // Standing character pixel sprite (18x29) from user's attached standing image.
  static const List<String> _robotStandFrame0 = [
    '...###............',
    '...####...........',
    '....###...........',
    '......##..........',
    '......########....',
    '....###.......#...',
    '..##...........#..',
    '.##.............#.',
    '.##......#########',
    '#...###..#########',
    '#..#...#.#####..##',
    '#..#.#.#.#####..##',
    '#..#...#.#####..##',
    '#...###..#########',
    '.##......########.',
    '..###...........#.',
    '...#####......##..',
    '...############...',
    '..##..#####.......',
    '#.........#.......',
    '#...###...#.......',
    '#...########......',
    '.#####.....##.....',
    '....##..##..##....',
    '....##.###..##....',
    '....##..##..##....',
    '....##.....##.....',
    '.....#######......',
    '......#####.......',
  ];

  // Alternate running frame: rotating wheel hub + tiny backpack bounce.
  static const List<String> _robotStandFrame1 = [
    '...###............',
    '...####...........',
    '....###...........',
    '......##..........',
    '......########....',
    '....###.......#...',
    '..##...........#..',
    '.##.............#.',
    '.##......#########',
    '#...###..#########',
    '#..#...#.#####..##',
    '#..#.#.#.#####..##',
    '#..#...#.#####..##',
    '#...###..#########',
    '.##......########.',
    '..###...........#.',
    '...#####......##..',
    '...############...',
    '..##..#####.......',
    '#.........#.......',
    '#...###...#.......',
    '#...########......',
    '.#####.....##.....',
    '....##......##....',
    '....##.###..##....',
    '....##.###..##....',
    '....##.....##.....',
    '.....#######......',
    '......#####.......',
  ];

  // Waiting blink frame (visor glint closed).
  static const List<String> _robotBlinkFrame = [
    '...###............',
    '...####...........',
    '....###...........',
    '......##..........',
    '......########....',
    '....###.......#...',
    '..##...........#..',
    '.##.............#.',
    '.##......#########',
    '#...###..#########',
    '#..#...#.#########',
    '#..#...#.#########',
    '#..#...#.#########',
    '#...###..#########',
    '.##......########.',
    '..###...........#.',
    '...#####......##..',
    '...############...',
    '..##..#####.......',
    '#.........#.......',
    '#...###...#.......',
    '#...########......',
    '.#####.....##.....',
    '....##..##..##....',
    '....##.###..##....',
    '....##..##..##....',
    '....##.....##.....',
    '.....#######......',
    '......#####.......',
  ];

  // Crashed visor frame (dizzy X glint).
  static const List<String> _robotCrashedFrame = [
    '...###............',
    '...####...........',
    '....###...........',
    '......##..........',
    '......########....',
    '....###.......#...',
    '..##...........#..',
    '.##.............#.',
    '.##......#########',
    '#...###..#########',
    '#..#...#.####.#.##',
    '#..#.#.#.#####.###',
    '#..#...#.####.#.##',
    '#...###..#########',
    '.##......########.',
    '..###...........#.',
    '...#####......##..',
    '...############...',
    '..##..#####.......',
    '#.........#.......',
    '#...###...#.......',
    '#...########......',
    '.#####.....##.....',
    '....##..##..##....',
    '....##.###..##....',
    '....##..##..##....',
    '....##.....##.....',
    '.....#######......',
    '......#####.......',
  ];

  // Ducking character pixel sprite (20x15) from user's attached crouching image.
  static const List<String> _robotDuckFrame0 = [
    '..........##........',
    '..........##........',
    '...........#........',
    '............#.......',
    '...........#######..',
    '.........###########',
    '.....####.####.....#',
    '..#######.####.....#',
    '..#######.####.....#',
    '.########.#########.',
    '##.....###...#####..',
    '#..###..####........',
    '..#...#.####........',
    '..##.##.....###.....',
    '...###......####....',
  ];

  static const List<String> _robotDuckFrame1 = [
    '..........##........',
    '..........##........',
    '...........#........',
    '............#.......',
    '...........#######..',
    '.........###########',
    '.....####.####.....#',
    '..#######.####.....#',
    '..#######.####.....#',
    '.########.#########.',
    '##.....###...#####..',
    '#..###..####........',
    '..#.#.#.####........',
    '..##.##.....###.....',
    '...###......####....',
  ];

  static const List<String> _cloudSprite = [
    '.......######.............',
    '.....##########...........',
    '....############...####...',
    '..########################',
    '.#########################',
    '##########################',
  ];

  static const List<String> _smallCactusSprite = [
    '....###....',
    '....###....',
    '.#..###....',
    '##..###..#.',
    '##..###..##',
    '##..###..##',
    '##..###..##',
    '#######..##',
    '.#####..###',
    '....######.',
    '....###....',
    '....###....',
    '....###....',
    '....###....',
    '....###....',
    '....###....',
  ];

  static const List<String> _largeCactusSprite = [
    '.....####.....',
    '.....####.....',
    '.....####.....',
    '.##..####.....',
    '###..####..##.',
    '###..####..###',
    '###..####..###',
    '###..####..###',
    '###..####..###',
    '########...###',
    '.#######..####',
    '.....########.',
    '.....####.....',
    '.....####.....',
    '.....####.....',
    '.....####.....',
    '.....####.....',
    '.....####.....',
    '.....####.....',
    '.....####.....',
  ];

  static const List<String> _pteroFrame0 = [
    '......###.............',
    '.....#####............',
    '...#######............',
    '.#########............',
    '############..........',
    '....###########.......',
    '......#############...',
    '........##############',
    '..........########....',
    '...........######.....',
    '............####......',
    '.............##.......',
  ];

  static const List<String> _pteroFrame1 = [
    '...........###........',
    '..........#####.......',
    '.........######.......',
    '....###########.......',
    '.##############.......',
    '###################...',
    '.....#################',
    '.......#########......',
    '.........######.......',
    '......................',
    '......................',
    '......................',
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final double scaleX = size.width / 600.0;
    final double scaleY = size.height / 150.0;
    canvas.save();
    canvas.scale(scaleX, scaleY);

    final Color bgColor = Color.lerp(
      const Color(0xFFF7F7F7),
      const Color(0xFF141414),
      nightBlend,
    )!;
    final Color inkColor = Color.lerp(
      const Color(0xFF535353),
      const Color(0xFFE5E5E5),
      nightBlend,
    )!;
    final Color subtleInk = inkColor.withValues(alpha: 0.42);

    // Background fill.
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 600, 150),
      Paint()..color = bgColor,
    );

    // Night moon and stars.
    if (nightBlend > 0.02) {
      _paintNightSky(canvas, inkColor.withValues(alpha: nightBlend * 0.75), bgColor);
    }

    // Clouds.
    final Paint cloudPaint = Paint()..color = subtleInk;
    for (final _Cloud cloud in clouds) {
      _drawMatrix(canvas, _cloudSprite, cloud.x, cloud.y, 1.5, cloudPaint);
    }

    // Ground horizon line and scrolling pebbles/bumps.
    final Paint groundPaint = Paint()
      ..color = inkColor
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(0, groundLineY),
      Offset(600, groundLineY),
      groundPaint,
    );
    for (final _GroundBump bump in groundBumps) {
      canvas.drawRect(
        Rect.fromLTWH(
          bump.x,
          groundLineY + bump.yOffset,
          bump.width,
          bump.height,
        ),
        Paint()..color = bump.isPebble ? subtleInk : inkColor,
      );
    }

    // Obstacles.
    final Paint obsPaint = Paint()..color = inkColor;
    for (final _Obstacle obs in obstacles) {
      switch (obs.kind) {
        case _ObstacleKind.smallCactus:
          for (int i = 0; i < obs.count; i++) {
            final double px = obs.x + i * 17.0;
            _drawMatrix(canvas, _smallCactusSprite, px, obs.y, 1.55, obsPaint);
          }
        case _ObstacleKind.largeCactus:
          for (int i = 0; i < obs.count; i++) {
            final double px = obs.x + i * 24.0;
            _drawMatrix(canvas, _largeCactusSprite, px, obs.y, 1.72, obsPaint);
          }
        case _ObstacleKind.pterodactyl:
          final List<String> frame = obs.animFrame == 0 ? _pteroFrame0 : _pteroFrame1;
          _drawMatrix(canvas, frame, obs.x, obs.y, 1.95, obsPaint);
      }
    }

    // Dust particles on faceplant landing / crash.
    for (final _DustParticle p in dustParticles) {
      final double alpha = (p.life / p.maxLife).clamp(0.0, 1.0);
      canvas.drawRect(
        Rect.fromLTWH(p.x, p.y, p.size, p.size),
        Paint()..color = inkColor.withValues(alpha: alpha * 0.8),
      );
    }

    // Character (custom robot model + ducking model + faceplant animation).
    _paintCharacter(canvas, inkColor);

    // Score & High Score HUD.
    _paintScore(canvas, inkColor);

    // Game Over overlay.
    if (status == _GameStatus.crashed) {
      _paintGameOver(canvas, inkColor);
    }

    canvas.restore();
  }

  void _paintNightSky(Canvas canvas, Color nightColor, Color bgColor) {
    final Paint starPaint = Paint()..color = nightColor;
    for (final _Star s in stars) {
      canvas.drawRect(Rect.fromLTWH(s.x, s.y, 2, 2), starPaint);
      if (s.variant == 0) {
        canvas.drawRect(Rect.fromLTWH(s.x - 2, s.y, 1.5, 1.5), starPaint);
        canvas.drawRect(Rect.fromLTWH(s.x + 2.5, s.y, 1.5, 1.5), starPaint);
        canvas.drawRect(Rect.fromLTWH(s.x, s.y - 2, 1.5, 1.5), starPaint);
        canvas.drawRect(Rect.fromLTWH(s.x, s.y + 2.5, 1.5, 1.5), starPaint);
      }
    }

    // Crescent moon.
    canvas.drawCircle(Offset(moonX, 32), 9, starPaint);
    canvas.drawCircle(Offset(moonX - 4, 30), 8, Paint()..color = bgColor);
  }

  void _paintCharacter(Canvas canvas, Color inkColor) {
    final Paint charPaint = Paint()..color = inkColor;

    if (ducking && status != _GameStatus.crashed && !jumping) {
      final List<String> duckSprite = runFrame == 0 ? _robotDuckFrame0 : _robotDuckFrame1;
      _drawMatrix(
        canvas,
        duckSprite,
        playerX,
        groundBottomY - duckHeight,
        pixelSize,
        charPaint,
      );
      return;
    }

    late final List<String> sprite;
    if (status == _GameStatus.crashed) {
      sprite = _robotCrashedFrame;
    } else if (status == _GameStatus.waiting) {
      sprite = isBlinking ? _robotBlinkFrame : _robotStandFrame0;
    } else if (jumping || faceplantTimer > 0) {
      sprite = _robotStandFrame0;
    } else {
      sprite = runFrame == 0 ? _robotStandFrame0 : _robotStandFrame1;
    }

    // Pivot near front-bottom so forward pitch lands squarely on the ground ("cai de cara").
    final double pivotX = playerX + standWidth * 0.72;
    final double pivotY = playerY + standHeight;

    canvas.save();
    canvas.translate(pivotX, pivotY);
    canvas.rotate(jumpAngle);

    // Subtle squash during the peak of the faceplant on the ground.
    if (faceplantTimer > 0) {
      final double t = 1.0 - (faceplantTimer / faceplantDuration);
      final double impact = (1.0 - (t - 0.42).abs() * 2.2).clamp(0.0, 1.0);
      canvas.scale(1.0 + impact * 0.08, 1.0 - impact * 0.14);
    }

    canvas.translate(-pivotX, -pivotY);
    _drawMatrix(canvas, sprite, playerX, playerY, pixelSize, charPaint);

    // Comic impact lines right next to the visor during faceplant or crash!
    if ((faceplantTimer > 0 && jumpAngle > 1.15) ||
        (status == _GameStatus.crashed &&
            playerY >= (groundBottomY - standHeight) - 1.0)) {
      final Paint bonkPaint = Paint()
        ..color = inkColor
        ..strokeWidth = 1.5;
      final double fx = playerX + standWidth * 0.92;
      final double fy = playerY + 4;
      canvas.drawLine(Offset(fx + 3, fy), Offset(fx + 8, fy - 4), bonkPaint);
      canvas.drawLine(Offset(fx + 5, fy + 5), Offset(fx + 11, fy + 4), bonkPaint);
    }

    canvas.restore();
  }

  void _paintScore(Canvas canvas, Color inkColor) {
    final bool flashActive = milestoneFlashTimerMs > 0;
    final int shownScore = flashActive ? milestoneFlashScore : score;
    final bool hideCurrentForFlash =
        flashActive && ((milestoneFlashTimerMs / 150).floor() % 2 == 0);

    final String scoreText = shownScore.toString().padLeft(5, '0');
    final String hiText = highScore > 0 ? 'HI ${highScore.toString().padLeft(5, '0')}  ' : '';

    if (hiText.isNotEmpty) {
      final TextPainter hiPainter = TextPainter(
        text: TextSpan(
          text: hiText,
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            fontSize: 13,
            letterSpacing: 1.5,
            color: inkColor.withValues(alpha: 0.65),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      hiPainter.paint(canvas, Offset(586 - hiPainter.width - 54, 12));
    }

    if (!hideCurrentForFlash) {
      final TextPainter scorePainter = TextPainter(
        text: TextSpan(
          text: scoreText,
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            fontSize: 13,
            letterSpacing: 1.5,
            color: inkColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      scorePainter.paint(canvas, Offset(586 - scorePainter.width, 12));
    }
  }

  void _paintGameOver(Canvas canvas, Color inkColor) {
    final TextPainter titlePainter = TextPainter(
      text: TextSpan(
        text: 'G A M E   O V E R',
        style: TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w800,
          fontSize: 16,
          letterSpacing: 3,
          color: inkColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titlePainter.paint(
      canvas,
      Offset((600 - titlePainter.width) / 2, 46),
    );

    // Retro restart icon box below GAME OVER.
    const Offset center = Offset(300, 82);
    final Paint boxPaint = Paint()..color = inkColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 32, height: 26),
        const Radius.circular(4),
      ),
      boxPaint,
    );

    final Paint arrowPaint = Paint()
      ..color = Color.lerp(const Color(0xFFF7F7F7), const Color(0xFF141414), nightBlend)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCenter(center: center, width: 13, height: 13),
      -0.4,
      4.5,
      false,
      arrowPaint,
    );
    final Path head = Path()
      ..moveTo(center.dx + 4, center.dy - 8)
      ..lineTo(center.dx + 8, center.dy - 4)
      ..lineTo(center.dx + 3, center.dy - 2);
    canvas.drawPath(head, arrowPaint..style = PaintingStyle.stroke);
  }

  void _drawMatrix(
    Canvas canvas,
    List<String> matrix,
    double x,
    double y,
    double cellSize,
    Paint paint,
  ) {
    for (int r = 0; r < matrix.length; r++) {
      final String row = matrix[r];
      int c = 0;
      while (c < row.length) {
        if (row[c] == '#') {
          int end = c + 1;
          while (end < row.length && row[end] == '#') {
            end++;
          }
          // Merge horizontal runs into one rect for faster crisp pixel rendering.
          canvas.drawRect(
            Rect.fromLTWH(
              x + c * cellSize,
              y + r * cellSize,
              (end - c) * cellSize + 0.08,
              cellSize + 0.08,
            ),
            paint,
          );
          c = end;
        } else {
          c++;
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DinoGamePainter oldDelegate) => true;
}
