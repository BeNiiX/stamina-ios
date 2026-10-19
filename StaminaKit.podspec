Pod::Spec.new do |s|
  s.name             = 'StaminaKit'
  s.version          = '1.1.1'
  s.summary          = 'STAMINA attribution SDK for iOS — install attribution, sessions, revenue per acquisition source.'
  s.description      = 'Zero-dependency attribution SDK: AdServices (Apple Search Ads), IDFA after ATT, IDFV, WebView UA, persisted event queue, sessions. One line to integrate.'
  s.homepage         = 'https://getstamina.io'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'STAMINA' => 'hello@getstamina.io' }
  s.source           = { :git => 'https://github.com/BeNiiX/stamina-ios.git', :tag => "v#{s.version}" }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Sources/StaminaKit/**/*.swift'
  s.resource_bundles = { 'StaminaKit' => ['Sources/StaminaKit/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'WebKit', 'AdSupport', 'AppTrackingTransparency', 'AdServices'
end
