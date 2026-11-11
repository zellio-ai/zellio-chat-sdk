#
# CocoaPods spec for the zellio_chat Flutter plugin.
# Run `pod lib lint zellio_chat.podspec` to validate it.
#
# The native iOS SDK sources are copied into zellio_chat/Sources/zellio_chat/Vendor by
# scripts/vendor-ios.sh. They compile into this pod, so no other pod is needed.
#
Pod::Spec.new do |s|
  s.name             = 'zellio_chat'
  s.version          = '1.0.1'
  s.summary          = 'ZeeChat for Flutter. A thin wrapper over the native Zellio iOS chat SDK.'
  s.description      = <<-DESC
A Flutter plugin for ZeeChat. The native SDK draws all screens. This plugin forwards calls and events.
                       DESC
  s.homepage         = 'https://zellio.ai'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'Zellio' => 'sdk@zellio.ai' }
  s.source           = { :path => '.' }
  s.source_files     = 'zellio_chat/Sources/zellio_chat/**/*.swift'
  s.resource_bundles = { 'zellio_chat_privacy' => ['zellio_chat/Sources/zellio_chat/Vendor/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
