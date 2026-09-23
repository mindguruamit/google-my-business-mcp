import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindguru_prompter/services/camera_service.dart';
import 'package:mindguru_prompter/utils/constants.dart';

void main() {
  group('vivo X200 FE', () {
    final caps = DeviceCapabilities.profileFor(
      manufacturer: 'vivo',
      model: 'V2503',
      marketName: 'vivo X200 FE',
    );

    test('is detected', () => expect(caps.isVivoX200FE, isTrue));

    test('max is 4K, no 8K', () {
      expect(caps.maxResolution(CameraLensDirection.back), VideoResolution.uhd4k);
      expect(caps.supports8K(CameraLensDirection.back), isFalse);
      expect(caps.supports8K(CameraLensDirection.front), isFalse);
    });

    test('4K allows 60fps, 1080p allows 120fps, 720p does not', () {
      final lens = caps.lens(CameraLensDirection.back);
      expect(allowedFrameRatesFor(VideoResolution.uhd4k, lens), contains(FrameRate.fps60));
      expect(allowedFrameRatesFor(VideoResolution.uhd4k, lens), isNot(contains(FrameRate.fps120)));
      expect(allowedFrameRatesFor(VideoResolution.fhd1080, lens), contains(FrameRate.fps120));
      expect(allowedFrameRatesFor(VideoResolution.hd720, lens), isNot(contains(FrameRate.fps120)));
    });

    test('front camera also does 4K60', () {
      final front = caps.lens(CameraLensDirection.front);
      expect(front!.supports(VideoResolution.uhd4k), isTrue);
      expect(front.maxFpsFor(VideoResolution.uhd4k), 60);
    });
  });

  group('Samsung 8K flagship', () {
    final caps = DeviceCapabilities.profileFor(
      manufacturer: 'samsung',
      model: 'SM-S938B',
      marketName: 'Galaxy S25 Ultra',
    );

    test('supports 8K capped at 30fps', () {
      expect(caps.isSamsung8kFlagship, isTrue);
      expect(caps.maxResolution(CameraLensDirection.back), VideoResolution.uhd8k);
      final allowed = allowedFrameRatesFor(
        VideoResolution.uhd8k,
        caps.lens(CameraLensDirection.back),
      );
      expect(allowed, [FrameRate.fps24, FrameRate.fps30]);
    });
  });

  group('native Camera2 map', () {
    test('parses sizes, profiles and high-speed modes', () {
      final lens = LensCapabilities.fromMap({
        'id': '0',
        'facing': 'back',
        'videoSizes': [
          {'width': 3840, 'height': 2160, 'maxFps': 60},
          {'width': 1920, 'height': 1080, 'maxFps': 60},
        ],
        'highSpeedSizes': [
          {'width': 1920, 'height': 1080, 'maxFps': 120},
        ],
        'profiles': {'hd720': true, 'fhd1080': true, 'uhd4k': true, 'uhd8k': false},
        'videoStabilization': true,
        'hdr10Bit': true,
      });
      expect(lens.maxResolution, VideoResolution.uhd4k);
      expect(lens.supports(VideoResolution.qhd1440), isTrue);
      expect(lens.supports(VideoResolution.uhd8k), isFalse);
      expect(lens.highSpeedFpsFor(VideoResolution.fhd1080), 120);
      expect(lens.hdr10Bit, isTrue);
    });
  });
}
