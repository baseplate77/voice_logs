#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint voxsynth_asr.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'voxsynth_asr'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain an i386 slice. We also exclude x86_64
  # for the simulator because sherpa-rs-sys 0.6.8's build.rs misses the -L
  # search path for the x86_64-apple-ios target — and with Apple Silicon
  # everywhere, nobody runs iOS simulators on Intel. Revisit if needed.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64' }
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust/voxsynth_asr voxsynth_asr',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${BUILT_PRODUCTS_DIR}/libvoxsynth_asr.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
  }
  # Force the Rust staticlib into the consuming app's link step. With
  # static pod linkage, voxsynth_asr.framework is just an .a bundled into
  # a framework directory — no linking happens at pod-build time, so a
  # pod_target_xcconfig -force_load is a no-op. user_target_xcconfig
  # pushes it into Runner's OTHER_LDFLAGS, which works.
  #
  # -lc++: sherpa-onnx (bundled inside libvoxsynth_asr.a) is C++. Earlier
  # builds got libc++ for free via flutter_gemma's MediaPipe pods; we
  # declare it explicitly so the ASR path doesn't depend on Gemma being
  # in the Podfile.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-force_load ${PODS_CONFIGURATION_BUILD_DIR}/voxsynth_asr/libvoxsynth_asr.a -lc++',
  }
  s.libraries = 'c++'
end