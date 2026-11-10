require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "ZellioChatReactNative"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = { :type => package["license"] }
  s.authors      = { "Zellio" => "support@zellio.ai" }
  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/zellio-ai/zellio-chat-sdk.git", :tag => "#{s.version}" }

  # ios/*            the Turbo module (Objective-C++) and one Swift bridge file.
  # ios/vendor/swift the ZeeChat iOS SDK sources. `npm run vendor:ios` copies them from ../ios/Sources and
  #                  `npm pack` runs it first. They are compiled here, so no extra pod is needed.
  s.source_files = ["ios/*.{h,m,mm,swift}", "ios/vendor/swift/**/*.swift"]
  s.private_header_files = "ios/RNZellioChat.h"

  # The privacy manifest of the SDK. A resource bundle is how Apple wants it from a pod.
  s.resource_bundles = { "ZellioChatReactNativePrivacy" => ["ios/vendor/resources/PrivacyInfo.xcprivacy"] }

  s.swift_version = "5.0"
  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES" }
  s.frameworks = ["SwiftUI", "UIKit"]

  # Adds React-Core, the codegen headers and the New Architecture flags.
  install_modules_dependencies(s)
end
